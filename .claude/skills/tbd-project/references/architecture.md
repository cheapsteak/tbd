# TBD Architecture

## System Overview

Three components, one SPM package:

### tbdd (Daemon)
Long-running headless process. Owns all state and logic.
- **SQLite** at `~/.tbd/state.db` — worktree ledger, repo list, per-repo config (WAL mode, GRDB)
- **Unix socket** at `~/.tbd/sock` — primary RPC interface
- **HTTP** on localhost (port in `~/.tbd/port`) — for debugging/curl
- **Tmux manager** — one tmux server per repo (`tbd-<first-8-chars-of-repo-id>`), creates/destroys windows
- **Git manager** — fetch, worktree add/remove/list, rebase, squash merge
- **Hook executor** — resolves and runs hooks per priority chain
- **Worktree lifecycle** — orchestrates create/archive/revive/merge/reconcile
- **State broadcaster** — pushes deltas to subscribed clients
- **PID file** at `~/.tbd/tbdd.pid`

### TBDApp (SwiftUI)
Connects to daemon on launch (starts it if not running). Stateless except for UI layout.
- **Sidebar** — collapsible repo sections, worktree rows with badges, context menus
- **Terminal area** — tabs + recursive split layouts, each panel is a SwiftTerm view
- **Terminal rendering** — grouped tmux sessions + direct PTY attachment (NOT control mode)
- **State polling** — refreshes repos/worktrees every 2s (only updates @Published if data changed)
- **Layout persistence** — per-terminal `LayoutNode` tree in UserDefaults

### tbd (CLI)
Stateless. Connects to daemon socket, sends RPC, prints result, exits.
- POSIX socket client (not NIO — simpler for one-shot connections)
- Auto-resolves repo/worktree from `$PWD` via `resolve.path` RPC
- All commands support `--json` for machine-readable output

## Data Model (SQLite)

Four tables: `repo`, `worktree`, `terminal`, `notification`. See `Sources/TBDShared/Models.swift` for struct definitions and `Sources/TBDDaemon/Database/` for GRDB record types.

## Tmux Architecture

**Grouped sessions** (not control mode). Rationale in `docs/tmux-integration.md`.

```
tmux server: tbd-<repo-id-short>
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

## Worktree Lifecycle

### Create
fetch → generate name → git worktree add → insert DB → ensure tmux server → create 2 windows (claude + setup hook) → insert terminals

### Archive
run archive hook (blocking, 60s timeout) → kill tmux windows → delete terminals from DB → git worktree remove → update DB status

### Merge (squash)
validate clean state → validate commits exist → check conflicts → fire preMerge hook → fetch → checkout default branch → git merge --squash → commit → fire postMerge hook → optionally archive

### Reconcile (on daemon startup)
compare `git worktree list` against DB. Missing on disk → mark archived. Unknown on disk → add with default name.

## Hook System

Priority order (first match wins):
1. App per-repo config (`~/.tbd/repos/<repo-id>/hooks/<event>`)
2. `conductor.json` → `scripts.<event>`
3. `.dmux-hooks/<dmux-event-name>`
4. `~/.tbd/hooks/default/<event>`

Events: `setup`, `archive`, `preMerge`, `postMerge`

Environment variables: `TBD_REPO_PATH`, `TBD_WORKTREE_PATH`, `TBD_WORKTREE_NAME`, `TBD_BRANCH`, `TBD_EVENT`, `TBD_TARGET_BRANCH` (merge only)

## RPC Protocol

JSON-RPC style over Unix socket (newline-delimited) and HTTP POST `/rpc`.

Methods: `repo.add`, `repo.remove`, `repo.list`, `worktree.create`, `worktree.list`, `worktree.archive`, `worktree.revive`, `worktree.rename`, `worktree.merge`, `worktree.mergeStatus`, `terminal.create`, `terminal.list`, `terminal.send`, `notify`, `daemon.status`, `resolve.path`, `notifications.markRead`, `cleanup`
