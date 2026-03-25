# TBD Architecture

## System Overview

Three components, one SPM package:

### tbdd (Daemon)
Long-running headless process. Owns all state and logic.
- **SQLite** at `~/.tbd/state.db` — worktree ledger, repo list, per-repo config (WAL mode, GRDB)
- **Unix socket** at `~/.tbd/sock` — primary RPC interface
- **HTTP** on localhost (port in `~/.tbd/port`) — for debugging/curl
- **Tmux manager** — one tmux server per repo (`tbd-<djb2-hash-of-repo-path>`), creates/destroys windows
- **Git manager** — fetch, worktree add/remove/list, conflict check, headSHA, merge-base ancestry
- **Hook executor** — resolves and runs hooks per priority chain
- **Worktree lifecycle** — orchestrates create/archive/revive/reconcile + conflict detection
- **PR status manager** — polls GitHub for PR state (open/merged/closed, mergeable) per worktree
- **SSH agent resolver** — finds live SSH agent socket, maintains `~/.ssh/tbd-agent.sock` symlink
- **State broadcaster** — pushes deltas to subscribed clients (worktree CRUD, notifications, conflict changes)
- **Background git fetch** — periodic fetch (every 60s) for all repos
- **PID file** at `~/.tbd/tbdd.pid`

### TBDApp (SwiftUI)
Connects to daemon on launch (starts it if not running). Stateless except for UI layout.
- **Sidebar** — collapsible repo sections, worktree rows with PR status icons/badges/inline rename, context menus
- **Tab system** — generic Tab model wrapping PaneContent (.terminal/.webview/.codeViewer), per-worktree tab list
- **Pane types** — terminal (TBDTerminalView), webview (WKWebView), code viewer (Highlightr syntax highlighting)
- **Terminal rendering** — grouped tmux sessions + direct PTY attachment (NOT control mode)
- **State polling** — refreshes repos/worktrees/terminals/notifications every 2s via 2 RPCs (batched worktree list + batched terminal list), full Equatable comparison, only updates @Published if data changed
- **Layout persistence** — per-tab `LayoutNode` tree (using .pane(PaneContent)) in UserDefaults
- **Optimistic UI** — worktree creation inserts placeholder immediately, replaced when RPC returns; pendingWorktreeIDs prevents polling from clobbering placeholders
- **AppState split** — base (properties/polling/connection) + Repos + Worktrees + Terminals + Notifications extensions
- **Programmatic app icon** — generated at launch with purple gradient, branch lines, "TBD" text, optional worktree ribbon

### tbd (CLI)
Stateless. Connects to daemon socket, sends RPC, prints result, exits.
- POSIX socket client (not NIO — simpler for one-shot connections)
- Auto-resolves repo/worktree from `$PWD` via `resolve.path` RPC
- All commands support `--json` for machine-readable output

## Data Model (SQLite)

Four tables: `repo`, `worktree`, `terminal`, `notification`. See `Sources/TBDShared/Models.swift` for struct definitions and `Sources/TBDDaemon/Database/` for GRDB record types.

### Migrations
- **v1** — initial schema: repo, worktree, terminal, notification tables
- **v2** — adds `gitStatus` column to worktree (defaults to "current")
- **v3** — adds `hasConflicts` bool column to worktree (defaults to false), replacing the gitStatus enum

### Key model types
- `WorktreeStatus`: `.active`, `.archived`, `.main`, `.creating`
- `Worktree.hasConflicts`: bool indicating merge-tree conflict detection against main
- `PRStatus`: open/merged/closed state + `PRMergeableState` (mergeable/conflicting/unknown)
- `PaneContent`: `.terminal(terminalID:)`, `.webview(url:)`, `.codeViewer(filePath:)`
- `Tab`: wraps PaneContent with UUID + optional label
- `LayoutNode`: recursive tree — `.pane(PaneContent)` or `.split(axis, ratio, first, second)`

## Tmux Architecture

**Grouped sessions** (not control mode). Rationale in `docs/tmux-integration.md`.

```
tmux server: tbd-<djb2-hash-of-repo-path>
├── Session "main" (daemon-managed, persists across app restarts)
│   ├── Window @1: claude code
│   ├── Window @2: setup hook / shell
│   ├── Window @3: claude code
│   └── Window @4: setup hook / shell
├── Session "tbd-view-abc123" (grouped, created by app for viewing)
│   └── Currently viewing @1
└── Session "tbd-view-def456" (grouped)
    └── Currently viewing @3
```

- Daemon creates windows in `main` session
- App creates grouped sessions per visible terminal panel
- Each grouped session shares all windows but has independent current-window
- Each has independent PTY size (no size conflicts)
- `main` persists when app closes. Grouped sessions are ephemeral.
- Server name uses djb2 hash of repo path (deterministic, survives DB recreations)

## Worktree Lifecycle

Split across 4 files: base struct, +Create, +Archive, +Reconcile.

### Create (two-phase async)
**Phase 1 (beginCreateWorktree):** Generate name → insert DB row with `status = .creating` → return immediately. App shows optimistic placeholder in UI before RPC even fires.

**Phase 2 (completeCreateWorktree):** Best-effort fetch → create parent dir → git worktree add (tries origin/<default> then local <default>, retries with new name on collision) → ensure tmux server → create 2 windows (claude + setup hook) → insert terminals → update status to `.active`. On failure, deletes the DB row.

### Archive (two-phase async)
**Phase 1 (beginArchiveWorktree):** Validate not `.main` or `.creating` → update status to `.archived` + set archivedAt → kill tmux windows → delete terminals from DB → return immediately. Broadcasts `worktreeArchived` delta.

**Phase 2 (completeArchiveWorktree):** Fire-and-forget background task — run archive hook (blocking, 60s timeout) → git worktree remove.

### Revive
Validate archived status → create parent dir → git worktree add (existing branch) → create tmux windows + terminals → update status to active.

### Conflict Detection
Concurrent per-repo scan of all active worktrees. Uses merge-tree conflict detection against main branch. Updates `hasConflicts` bool on worktree. Broadcasts `worktreeConflictsChanged` deltas.

### Reconcile (on daemon startup)
Compare `git worktree list` against DB. Missing on disk → mark archived + kill tmux windows. Unknown on disk (inside `.tbd/worktrees/`) → add with default name. Fixes stale tmux server names. Cleans up orphaned tmux windows not tracked by any terminal record.

## SSH Agent Resolver

Maintains a stable symlink at `~/.ssh/tbd-agent.sock` pointing to a live SSH agent socket.
- Checks if current symlink target is connectable
- If stale, discovers candidates from `/private/tmp/com.apple.launchd.*/Listeners`
- Probes each with `ssh-add -l` (2s timeout)
- Atomically updates symlink via temp + rename
- Worktrees can use `SSH_AUTH_SOCK=~/.ssh/tbd-agent.sock` for reliable SSH access

## Hook System

Priority order (first match wins):
1. App per-repo config (`~/.tbd/repos/<repo-id>/hooks/<event>`)
2. `conductor.json` → `scripts.<event>`
3. `.dmux-hooks/<dmux-event-name>`
4. `~/.tbd/hooks/default/<event>`

Events: `setup`, `archive`, `preMerge`, `postMerge`

Environment variables: `TBD_REPO_PATH`, `TBD_WORKTREE_PATH`, `TBD_WORKTREE_NAME`, `TBD_BRANCH`, `TBD_EVENT`, `TBD_TARGET_BRANCH` (merge only), `TBD_WORKTREE_ID`

## RPC Protocol

JSON-RPC style over Unix socket (newline-delimited) and HTTP POST `/rpc`.

Methods: `repo.add`, `repo.remove`, `repo.list`, `worktree.create`, `worktree.list`, `worktree.archive`, `worktree.revive`, `worktree.rename`, `terminal.create`, `terminal.list`, `terminal.send`, `terminal.delete`, `notify`, `daemon.status`, `state.subscribe`, `resolve.path`, `notifications.list`, `notifications.markRead`, `pr.refresh`, `cleanup`
