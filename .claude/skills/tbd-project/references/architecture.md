# TBD Architecture

## System Overview

Three components, one SPM package:

### tbdd (Daemon)
Long-running headless process. Owns all state and logic.
- **SQLite** at `~/.tbd/state.db` — worktree ledger, repo list, per-repo config (WAL mode, GRDB)
- **Unix socket** at `~/.tbd/sock` — primary RPC interface
- **HTTP** on localhost (port in `~/.tbd/port`) — for debugging/curl
- **Tmux manager** — one tmux server per repo (`tbd-<first-8-chars-of-repo-id>`), creates/destroys windows
- **Git manager** — fetch, worktree add/remove/list, rebase, merge, conflict check, headSHA, merge-base ancestry
- **Hook executor** — resolves and runs hooks per priority chain
- **Worktree lifecycle** — orchestrates create/archive/revive/merge/reconcile + git status refresh
- **SSH agent resolver** — finds live SSH agent socket, maintains `~/.ssh/tbd-agent.sock` symlink
- **State broadcaster** — pushes deltas to subscribed clients (worktree CRUD, notifications, git status changes)
- **PID file** at `~/.tbd/tbdd.pid`

### TBDApp (SwiftUI)
Connects to daemon on launch (starts it if not running). Stateless except for UI layout.
- **Sidebar** — collapsible repo sections, worktree rows with badges, context menus
- **Terminal area** — tabs + recursive split layouts, each panel is a TBDTerminalView (SwiftTerm subclass with natural text editing)
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

### Migrations
- **v1** — initial schema: repo, worktree, terminal, notification tables
- **v2** — adds `gitStatus` column to worktree (defaults to "current")

### Key model types
- `WorktreeStatus`: `.active`, `.archived`, `.main`
- `GitStatus`: `.current` (ahead/equal to main), `.behind` (main has newer commits), `.conflicts` (would conflict), `.merged` (squash-merged by TBD)

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
fetch → generate name → git worktree add (tries origin/<default> then local <default>, retries with new name on collision) → insert DB → ensure tmux server → create 2 windows (claude + setup hook) → insert terminals

### Archive
run archive hook (blocking, 60s timeout) → kill tmux windows → delete terminals from DB → git worktree remove → update DB status. Refuses to archive worktrees with `.main` status.

### Revive
validate archived status → create parent dir → git worktree add (existing branch) → create tmux windows + terminals → update status to active

### Merge (rebase + fast-forward)
validate clean state (worktree + main repo) → validate commits exist → fire preMerge hook → fetch → checkout default branch → ff to origin → squash merge worktree branch → build commit message (single commit: use as-is, multiple: first as title + rest as bullets) → commit → push to origin → fire postMerge hook → optionally archive. Refuses to merge `.main` worktrees.

### Merge Status Check
Cached by (worktreeID, worktreeHead, targetHead, hasUncommitted). Checks uncommitted changes, commit count, and merge conflicts via `git merge-tree`.

### Git Status Refresh
Concurrent per-repo scan of all active worktrees. Computes `.current`/`.behind`/`.conflicts` using merge-base ancestry + merge-tree conflict detection. Broadcasts `worktreeGitStatusChanged` deltas. Skips `.merged` worktrees (terminal state).

### Reconcile (on daemon startup)
compare `git worktree list` against DB. Missing on disk → mark archived + kill tmux windows. Unknown on disk (inside `.tbd/worktrees/`) → add with default name. Fixes stale tmux server names. Cleans up orphaned tmux windows not tracked by any terminal record.

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

Methods: `repo.add`, `repo.remove`, `repo.list`, `worktree.create`, `worktree.list`, `worktree.archive`, `worktree.revive`, `worktree.rename`, `worktree.merge`, `worktree.mergeStatus`, `terminal.create`, `terminal.list`, `terminal.send`, `notify`, `daemon.status`, `state.subscribe`, `resolve.path`, `notifications.list`, `notifications.markRead`, `cleanup`
