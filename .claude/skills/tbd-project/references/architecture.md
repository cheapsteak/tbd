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
- **Suspend/resume coordinator** — auto-suspends idle Claude sessions on worktree deselection, supports manual suspend/resume
- **Conductor manager** — meta-agent sessions scoped across repos
- **State broadcaster** — pushes deltas to subscribed clients (worktree CRUD, notifications, conflict changes, terminal pins, reorder)
- **Background git fetch** — periodic fetch (every 60s) for all repos
- **PID file** at `~/.tbd/tbdd.pid`

### TBDApp (SwiftUI)
Connects to daemon on launch (starts it if not running). Stateless except for UI layout.
- **Sidebar** — collapsible repo sections, worktree rows with PR status icons/badges/inline rename, context menus, drag-to-reorder
- **Tab system** — generic Tab model wrapping PaneContent (.terminal/.webview/.codeViewer/.note), per-worktree tab list
- **Pane types** — terminal (TBDTerminalView), webview (WKWebView), code viewer (Highlightr syntax highlighting), note (freeform text editor)
- **Terminal rendering** — grouped tmux sessions + direct PTY attachment (NOT control mode)
- **Pinned terminal dock** — vertical dock showing pinned terminals from worktrees not currently visible
- **Conductor overlay** — Guake-style dropdown triggered by Opt+. hotkey
- **State polling** — refreshes repos/worktrees/terminals/notifications every 2s via batched RPCs; state.subscribe stream for push deltas
- **Layout persistence** — per-tab `LayoutNode` tree (using .pane(PaneContent)) in UserDefaults
- **Optimistic UI** — worktree creation inserts placeholder immediately, replaced when RPC returns; pendingWorktreeIDs prevents polling from clobbering placeholders
- **AppState split** — base (properties/polling/connection) + Repos + Worktrees + Terminals + Notifications + Notes extensions
- **macOS native notifications** via UNUserNotificationCenter, configurable sounds
- **Programmatic app icon** — generated at launch with purple gradient, branch lines, "TBD" text, optional worktree ribbon

### tbd (CLI)
Stateless. Connects to daemon socket, sends RPC, prints result, exits.
- POSIX socket client (not NIO — simpler for one-shot connections)
- Auto-resolves repo/worktree from `$PWD` via `resolve.path` RPC
- All commands support `--json` for machine-readable output

## Data Model (SQLite)

Six tables: `repo`, `worktree`, `terminal`, `notification`, `note`, `conductor`. See `Sources/TBDShared/Models.swift` and `Sources/TBDShared/ConductorModels.swift` for struct definitions and `Sources/TBDDaemon/Database/` + `Sources/TBDDaemon/Conductor/` for GRDB record types.

### Migrations
- **v1** — initial schema: repo, worktree, terminal, notification tables
- **v2** — adds `gitStatus` column to worktree (defaults to "current")
- **v3** — adds `hasConflicts` bool column to worktree (defaults to false), replacing the gitStatus enum
- **v4-v8** — adds pinnedAt, claudeSessionID, suspendedAt, suspendedSnapshot, archivedClaudeSessions columns
- **v9** — adds `conductor` table + synthetic "Conductors" pseudo-repo (well-known UUID)
- **v10+** — adds note table, sortOrder on worktree, renamePrompt/customInstructions on repo

### Key model types
- `WorktreeStatus`: `.active`, `.archived`, `.main`, `.creating`, `.conductor`
- `Repo`: `renamePrompt` + `customInstructions` optional fields for per-repo prompt customization
- `Worktree`: `hasConflicts` bool (merge-tree vs main), `sortOrder` int for drag-to-reorder, `archivedClaudeSessions`
- `Terminal`: `pinnedAt`, `claudeSessionID`, `suspendedAt`, `suspendedSnapshot` for pinning + suspend/resume
- `Note`: freeform editor content tied to a worktree
- `Conductor`: meta-agent session with scoped repos, permissions (`.observe`/`.observeAndInteract`), heartbeat config
- `ConductorPermission`: enum — `.observe` (read-only) or `.observeAndInteract` (can send to terminals)
- `PRStatus`: PR number + URL + `PRMergeableState` (open/changesRequested/mergeable/merged/closed)
- `PaneContent`: `.terminal(terminalID:)`, `.webview(url:)`, `.codeViewer(filePath:)`, `.note(noteID:)`
- `Tab`: wraps PaneContent with UUID + optional label
- `LayoutNode`: recursive tree — `.pane(PaneContent)` or `.split(axis, ratio, first, second)`

### Key RPC param structs
- `TerminalCreateParams`: `worktreeID`, optional `cmd`, optional `type: TerminalCreateType` (`.shell`/`.claude`), optional `resumeSessionID`, optional `prompt` (initial prompt sent to new Claude session)
- `TerminalSendParams`: `terminalID`, `text`, optional `submit: Bool` (when true, sends Enter keypress after text to submit it)
- `TerminalCreateType`: enum `shell`/`claude`, conforms to `ExpressibleByArgument` in CLI for `--type` flag parsing
- `RepoUpdateInstructionsParams`: `repoID` + optional `renamePrompt` and `customInstructions`
- `WorktreeReorderParams`: `repoID` + ordered `worktreeIDs` array

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

### TmuxManager API highlights
- `sendKeys(server:paneID:text:)` — sends literal text (tmux `-l` flag); used for typing into terminals
- `sendKey(server:paneID:key:)` — sends a tmux key name like "Enter" or "Escape" (no `-l` flag); used to submit Claude prompts after `sendKeys`
- `sendKeyCommand(server:paneID:key:)` — static command builder for `sendKey`, paired with `sendKeysCommand`
- `sendCommand(server:paneID:command:)` — text followed by Enter in a single tmux invocation
- `capturePaneOutput` / `capturePaneWithAnsi` — plain text or ANSI-escaped snapshot
- `paneCurrentCommand` / `panePID` — used by ClaudeStateDetector
- `windowExists` — reconcile check

## Worktree Lifecycle

Split across 4 files: base struct, +Create, +Archive, +Reconcile.

### Create (two-phase async)
**Phase 1 (beginCreateWorktree):** Generate name → insert DB row with `status = .creating` → return immediately. App shows optimistic placeholder in UI before RPC even fires.

**Phase 2 (completeCreateWorktree):** Best-effort fetch → create parent dir → git worktree add (tries origin/<default> then local <default>, retries with new name on collision) → ensure tmux server → create 2 windows (claude + setup hook) with `TBD_PROMPT_*` env vars → insert terminals → update status to `.active`. On failure, deletes the DB row.

### Archive (two-phase async)
**Phase 1 (beginArchiveWorktree):** Validate not `.main` or `.creating` → update status to `.archived` + set archivedAt → kill tmux windows → delete terminals from DB → return immediately. Broadcasts `worktreeArchived` delta.

**Phase 2 (completeArchiveWorktree):** Fire-and-forget background task — run archive hook (blocking, 60s timeout) → git worktree remove.

### Revive
Validate archived status → create parent dir → git worktree add (existing branch) → create tmux windows + terminals → update status to active.

### Conflict Detection
Concurrent per-repo scan of all active worktrees. Uses merge-tree conflict detection against main branch. Updates `hasConflicts` bool on worktree. Broadcasts `worktreeConflictsChanged` deltas.

### Reconcile (on daemon startup)
Compare `git worktree list` against DB. Missing on disk → mark archived + kill tmux windows. Unknown on disk (inside `.tbd/worktrees/`) → add with default name. Fixes stale tmux server names. Validates terminal records for all live worktrees (active + main) against tmux — deletes records pointing to dead windows. Cleans up orphaned tmux windows not tracked by any terminal record.

## System Prompt Layers

`SystemPromptBuilder` manages the prompt context injected into Claude sessions created by TBD.

- `promptLayers(repo:worktree:)` returns a `[String: String]` of env-var-name → value pairs:
  - `TBD_PROMPT_CONTEXT` — built-in TBD context (always set) describing `tbd` CLI commands, env vars, and how to spawn new terminals/worktrees
  - `TBD_PROMPT_INSTRUCTIONS` — per-repo `customInstructions` (only if configured)
  - `TBD_PROMPT_RENAME` — rename-prompt text (only for non-main worktrees that haven't been renamed yet; the main worktree is skipped)
- These layers are set as environment variables on every terminal (shell and Claude) via `TmuxManager.createWindow(env:)`, so spawned children can re-inject them via `claude --append-system-prompt "$TBD_PROMPT_CONTEXT"` etc.
- `build(repo:worktree:isResume:)` joins the layers in order (rename, context, instructions) with `---` separators for the direct `--append-system-prompt` passed to the initial Claude invocation. Returns `nil` for resumed sessions.
- `buildForConductor(repo:)` produces the equivalent prompt for a conductor session (context + optional instructions).

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

Methods:
- **Repo**: `repo.add`, `repo.remove`, `repo.list`, `repo.updateInstructions`
- **Worktree**: `worktree.create`, `worktree.list`, `worktree.archive`, `worktree.revive`, `worktree.rename`, `worktree.reorder`, `worktree.selectionChanged`, `worktree.suspend`, `worktree.resume`
- **Terminal**: `terminal.create` (supports `type`/`prompt`), `terminal.list`, `terminal.send` (supports `submit`), `terminal.delete`, `terminal.setPin`, `terminal.output`, `terminal.conversation`, `terminal.suspend`, `terminal.resume`, `terminal.recreateWindow`
- **Notification**: `notify`, `notifications.list`, `notifications.markRead`
- **PR**: `pr.list`, `pr.refresh`
- **Note**: `note.create`, `note.get`, `note.update`, `note.delete`, `note.list`
- **Conductor**: `conductor.setup`, `conductor.start`, `conductor.stop`, `conductor.teardown`, `conductor.list`, `conductor.status`, `conductor.suggest`, `conductor.clearSuggestion`
- **Meta**: `daemon.status`, `resolve.path`, `cleanup`, `state.subscribe`

## CLI Commands

Highlights of new flags (see `Sources/TBDCLI/Commands/` for full definitions):

- `tbd terminal create <worktree> [--type claude|shell] [--cmd <command>] [--prompt <text>] [--json]`
  - `--type` selects the terminal kind (default: shell). `TerminalCreateType` conforms to `ExpressibleByArgument` so the flag parses directly into the enum.
  - `--prompt` sends an initial prompt to the Claude session (only meaningful with `--type claude`).
  - All new terminals automatically receive `TBD_WORKTREE_ID`, `TBD_PROMPT_CONTEXT`, and (when applicable) `TBD_PROMPT_INSTRUCTIONS` / `TBD_PROMPT_RENAME` as env vars.
- `tbd terminal send --terminal <id> --text <text> [--submit] [--json]`
  - `--submit` presses Enter after the text (useful for submitting a Claude prompt in one call).
- `tbd terminal conversation <terminal-id> [--messages N]` — read recent Claude conversation messages from a terminal.
- `tbd worktree` — supports `create`, `list`, `archive`, `revive`, `rename`, and the daemon additionally exposes `worktree.reorder` / `worktree.suspend` / `worktree.resume` via the app.
- `tbd repo` — the daemon exposes `repo.updateInstructions` for per-repo `renamePrompt` and `customInstructions` (edited from the app's Repo Instructions view).
