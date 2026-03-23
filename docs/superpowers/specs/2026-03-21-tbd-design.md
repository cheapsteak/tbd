# TBD: Terminal-Based Development Workspace Manager

A macOS native app for managing git worktrees and terminals in multi-agent Claude Code workflows.

## Overview

TBD helps teams run multiple Claude Code agents in parallel, each in an isolated git worktree with its own terminal environment. It combines the worktree management of Conductor and dmux with raw terminal panels that feel like iTerm2.

### Core Philosophy

Everything the app can do must be accessible to coding agents. The UI is one client of a daemon that owns all state. Any Claude Code agent in any terminal can create worktrees, send notifications, and manage terminals via a CLI tool.

## System Architecture

Three SPM targets in one Swift package:

```
tbd/
├── Package.swift
├── Sources/
│   ├── TBDApp/          # SwiftUI macOS app
│   ├── TBDDaemon/       # Background daemon (tbdd)
│   ├── TBDCLI/          # CLI tool (tbd)
│   └── TBDShared/       # Shared types, protocol definitions
```

### Components

**`tbdd` (daemon)** — Long-running headless process that owns all state and logic:
- SQLite database at `~/.tbd/state.db` for the worktree ledger, repo list, per-repo config, display names
- Unix socket server at `~/.tbd/sock` + HTTP server on localhost (port stored in `~/.tbd/port`)
- Tmux manager: one tmux server per repo, creates/destroys windows, tracks pane IDs
- Hook executor: resolves and runs hooks per a priority chain
- Git manager: fetch, worktree add/remove, branch operations
- FSEvents watcher: monitors worktree directories for external changes, reconciles with ledger
- Notification broadcaster: pushes state deltas to connected UI clients via persistent connection

**`TBD.app` (UI)** — SwiftUI app that connects to the daemon on launch (starts daemon if not running):
- Subscribes to the daemon's state stream for reactive UI updates
- Renders terminals via SwiftTerm (abstracted behind a protocol for future swap to Ghostty renderer)
- Owns only window layout state (split positions, tab order) persisted in UserDefaults

**`tbd` (CLI)** — Stateless tool that sends a command to the daemon socket, prints the response, exits.

### Why This Split

The daemon survives app crashes. Agents can interact even when the UI is closed. The UI is a view; the daemon is the brain. Each component is testable independently.

## Data Model

SQLite database at `~/.tbd/state.db`:

### `repos`

| Column | Type | Description |
|---|---|---|
| id | TEXT (UUID) | Primary key |
| path | TEXT | Absolute path to main worktree root |
| remote_url | TEXT | Origin remote URL (for duplicate detection) |
| display_name | TEXT | Shown in sidebar (defaults to directory name) |
| default_branch | TEXT | Base branch for new worktrees (auto-detected, e.g. `main`, `master`) |
| created_at | TIMESTAMP | When added |

### `worktrees`

| Column | Type | Description |
|---|---|---|
| id | TEXT (UUID) | Primary key |
| repo_id | TEXT (FK) | Parent repo |
| name | TEXT | Auto-generated name (e.g. `20260321-fuzzy-penguin`) |
| display_name | TEXT | User-renamable sidebar title (defaults to name) |
| branch | TEXT | Git branch name |
| path | TEXT | Absolute path to worktree directory |
| status | TEXT | `active`, `archived` |
| created_at | TIMESTAMP | |
| archived_at | TIMESTAMP | Null if active |
| tmux_server | TEXT | Tmux server socket name (e.g. `tbd-a1b2c3d4`) |

### `terminals`

| Column | Type | Description |
|---|---|---|
| id | TEXT (UUID) | Stable pane ID (used by CLI) |
| worktree_id | TEXT (FK) | Parent worktree |
| tmux_window_id | TEXT | Tmux window target (e.g. `@3`) |
| tmux_pane_id | TEXT | Tmux pane ID for control mode routing (e.g. `%5`) |
| label | TEXT | Optional tab label |
| created_at | TIMESTAMP | |

### `notifications`

| Column | Type | Description |
|---|---|---|
| id | TEXT (UUID) | Primary key |
| worktree_id | TEXT (FK) | Target worktree |
| type | TEXT | `response_complete`, `error`, `task_complete`, `attention_needed` |
| message | TEXT | Optional freetext |
| read | BOOLEAN | Cleared when user clicks worktree |
| created_at | TIMESTAMP | |

## Tmux Architecture

### Topology

Each repo gets its own **tmux server** (via `-L` socket name) with exactly **one session**. Each terminal panel is a **tmux window** within that session. Each window has exactly one tmux pane (the default). No tmux pane splits are used — all spatial layout is managed by SwiftUI.

- **Server**: named `tbd-<repo-id-short>` (first 8 chars of UUID), selected via `tmux -L tbd-<repo-id-short>`
- **Session**: one per server, named `main`
- **Windows**: one per terminal panel, each containing a single pane

This isolates repos so a crash in one tmux server doesn't affect others.

### Control Mode Connection

The UI app runs `tmux -L tbd-<repo-id-short> -CC attach -t main` to get a control mode stream per repo. This single connection receives output from all windows in that server's session.

Tmux control mode emits `%output <pane-id> <data>` notifications using **pane IDs** (e.g. `%0`, `%1`), not window IDs. Since each window has exactly one pane, the daemon maintains a pane-to-window mapping. The `terminals` table stores both `tmux_window_id` (e.g. `@3`) and `tmux_pane_id` (e.g. `%5`). The UI demuxes `%output` by pane ID to route data to the correct SwiftTerm view.

### Session Persistence

When the app closes, it detaches from control mode. Tmux servers keep running. On relaunch, the app reattaches and SwiftTerm views pick up the current window content. Scrollback is preserved by tmux.

### Terminal Creation Flow

1. Daemon receives "create terminal" request
2. Daemon runs: `tmux -L tbd-<repo-id-short> new-window -t main -c <worktree-path>`
3. Daemon queries the new window's pane ID and records both window ID and pane ID in the `terminals` table, assigns a stable UUID
4. Daemon broadcasts the new terminal to connected UI clients
5. UI creates a SwiftTerm view, connects it to that tmux pane via the control mode stream

## Terminal Rendering

SwiftTerm is the initial terminal emulator, chosen for maturity and macOS support. It is abstracted behind a protocol (`TerminalRenderer`) so it can be swapped for Ghostty's renderer later without changing the rest of the app.

### SwiftTerm-to-Tmux Control Mode Bridge

SwiftTerm is designed to connect to a local PTY. Using it with tmux control mode requires a custom bridge layer (a `TerminalDelegate` implementation) that handles the impedance mismatch:

1. **Output path**: Tmux emits `%output <pane-id> <octal-escaped-data>` on the control mode stream. The bridge decodes the octal escapes into raw bytes and feeds them into SwiftTerm's `Terminal.feed()` method for the corresponding view.
2. **Input path**: User keystrokes captured by SwiftTerm are forwarded to tmux via `send-keys -t <pane-id> -l <text>` commands sent to the control mode connection's stdin.
3. **Resize**: When a SwiftUI panel resizes, the bridge sends `resize-window -t <window-id> -x <width> -y <height>` for each visible window. The control client size is set to the maximum of all visible windows via `refresh-client -C`. Tmux pads smaller windows — this is a known control mode constraint (iTerm2 handles it the same way).
4. **Flow control**: The bridge handles `%pause` / `%continue` notifications from tmux to prevent buffer overflow.

This is the highest-risk component in the system. iTerm2 has ~3,000 lines dedicated to its tmux gateway. The `TerminalRenderer` protocol should be designed with this bridging in mind from day one. The control mode parser should be hardened and tested independently since a malformed notification could desync all terminals in a repo.

Split panes are real SwiftUI panels (not tmux panes) for proper drag handles, resize cursors, and styled dividers.

### Split Layout Data Model

Layout is stored as a recursive tree per worktree (persisted in UserDefaults as JSON):

```swift
enum LayoutNode {
    case terminal(terminalId: UUID)
    case split(direction: .horizontal | .vertical, children: [LayoutNode], ratios: [Float])
}
```

This supports arbitrary nesting, flexible ratios, and future drag-to-reorganize (tree manipulation) without data model changes.

Split buttons are visible in each panel's title bar for horizontal and vertical splitting.

## Worktree Lifecycle

### Creation

1. User clicks "+" on a repo in sidebar, or agent runs `tbd worktree create --repo /path`
2. Daemon runs `git fetch origin <default_branch>` (using the repo's stored default branch) — if it fails, falls back to local `origin/<default_branch>` with a warning flag on the worktree
3. Generates auto-name: `YYYYMMDD-adjective-animal` (e.g. `20260321-fuzzy-penguin`). Adjective and animal drawn from a large randomized word pool.
4. Branch name: `tbd/<name>`
5. Runs `git worktree add <repo-root>/.tbd/worktrees/<name>/ -b tbd/<name> origin/<default_branch>`
6. Inserts row into `worktrees` table (status=`active`)
7. Creates two tmux windows:
   - **Terminal 1**: Runs `claude --dangerously-skip-permissions` (configurable per-repo to disable the flag)
   - **Terminal 2**: `cd`s into worktree, runs the resolved setup hook
8. Inserts terminal rows, broadcasts state to UI
9. CLI returns the worktree name and path

### Archive

1. User clicks archive, or agent runs `tbd worktree archive <name>`
2. No confirmation prompt
3. Daemon runs the resolved archive hook in the worktree directory (blocking, 60s timeout)
4. If hook fails: abort, surface error. User can retry or `--force` to skip the hook.
5. Kill all tmux windows belonging to this worktree
6. Run `git worktree remove <path>` — directory deleted, branch kept
7. Update ledger: status=`archived`, set `archived_at`
8. Broadcast state to UI

### Revival

1. User or agent runs `tbd worktree revive <name>`
2. Daemon finds the archived ledger entry, gets the branch name
3. Runs `git worktree add <path> <branch>` (same path as before)
4. Creates fresh terminals (Claude Code + setup hook)
5. Updates ledger: status=`active`, clears `archived_at`

### State Reconciliation

`git worktree list` is authoritative for what exists on disk. The ledger adds metadata (display name, creation date, archive history, notification state). On launch, the daemon reconciles:
- Worktree disappeared externally → mark archived in ledger
- Unknown worktree appeared → add to ledger with default name

## Hook System

### Hook Types

| TBD event | Conductor equivalent | dmux equivalent |
|---|---|---|
| `setup` | `scripts.setup` from `conductor.json` | `worktree_created` |
| `archive` | `scripts.archive` from `conductor.json` | `before_worktree_remove` |

### Resolution Order (first match wins, no chaining)

1. **App per-repo config** (`~/.tbd/repos/<repo-id>/hooks/<event>`) — local overrides/testing
2. **`conductor.json`** → `scripts.<event>` — Conductor compatibility
3. **`.dmux-hooks/<dmux-event-name>`** — dmux compatibility
4. **`~/.tbd/hooks/default/<event>`** — global fallback

First match wins. No chaining prevents double-execution when dmux hooks internally call conductor scripts.

### Execution

- `setup` hooks run **async** in Terminal 2 so output is visible. Non-blocking; Claude Code starts immediately in Terminal 1.
- `archive` hooks run **sync** by the daemon (not in a terminal). Blocking with 60s timeout.

### Environment Variables

```
TBD_REPO_PATH       — main repo root
TBD_WORKTREE_PATH   — worktree directory
TBD_WORKTREE_NAME   — auto-generated name
TBD_BRANCH          — git branch name
TBD_EVENT           — setup | archive
```

Conductor scripts work without these (they detect via `$PWD` and `git worktree list`). dmux hooks that don't depend on `DMUX_*` vars work as-is.

## Server & CLI Protocol

### Transport

- Unix socket at `~/.tbd/sock` (primary, user-scoped permissions)
- HTTP on `localhost:<port>` (port in `~/.tbd/port`, for debugging/curl)

Both use the same JSON-RPC style protocol.

### Methods

```
repo.add            { path: string }
repo.remove         { repo_id: string }
repo.list           {}

worktree.create     { repo_id: string }  → { id, name, path, branch }
worktree.list       { repo_id?: string, status?: "active"|"archived" }
worktree.archive    { worktree_id: string, force?: bool }
worktree.revive     { worktree_id: string }
worktree.rename     { worktree_id: string, display_name: string }

terminal.create     { worktree_id: string, cmd?: string }
terminal.list       { worktree_id: string }
terminal.send       { terminal_id: string, text: string }

notify              { worktree_id?: string, type: enum, message?: string }

daemon.status       {}  → { version, uptime, connected_clients }
state.subscribe     {}  → streaming: pushes state deltas as they occur
```

### CLI Ergonomics

The `tbd` CLI resolves context automatically:
- `tbd notify --type response_complete` — auto-detects worktree from `$PWD` (queries daemon with current path to match against known worktree paths)
- `tbd worktree create --repo .` — resolves `.` to the repo root
- All commands accept `--json` for machine-readable output (default is human-friendly)
- `tbd worktree create` blocks until directory exists and terminals are spawned; setup hook runs async in its terminal

**`terminal.send` semantics:** This is `tmux send-keys -l` (literal mode) — it sends text to the target terminal without interpreting key names. Agents can use this to type into any terminal programmatically. The CLI requires the caller to specify a terminal ID explicitly (no auto-detection) to prevent accidental input to the wrong terminal.

**When the app isn't running:** CLI errors out with a clear message. No queueing.

**Version negotiation:** The `state.subscribe` response includes the daemon's version. The CLI checks daemon version compatibility on every call and warns if mismatched (e.g. after an upgrade with a stale daemon). A `daemon.status` method returns version, uptime, and connected clients.

## Notification System

### Inbound Flow

Agents call `tbd notify` from within a worktree terminal. The CLI auto-resolves the worktree from `$PWD`. If not inside a TBD-managed worktree or daemon isn't running, exits silently (no-op).

### Sidebar Presentation

| Type | Indicator |
|---|---|
| `response_complete` | **Bold** worktree title |
| `error` | Red dot badge |
| `task_complete` | Green dot badge |
| `attention_needed` | Orange dot badge |

Multiple unread notifications stack — most severe type wins (error > attention > task_complete > response). Badges clear when user clicks the worktree.

### macOS System Notifications

Opt-in per user in app settings. When enabled, the daemon sends a `UNUserNotification`. Clicking brings TBD to front and selects the worktree.

### Claude Code Integration

Users opt in by adding a Claude Code hook. Two approaches:

**Global (recommended quick-start):** Add to `~/.claude/settings.json`:
```json
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "tbd notify --type response_complete 2>/dev/null || true"
      }]
    }]
  }
}
```
Applies to all Claude Code sessions. Self-filtering — `tbd notify` is a no-op when not inside a TBD-managed worktree or when the daemon isn't running.

**Per-repo (team-shared):** Add to the repo's `.claude/settings.json` and commit.

**`tbd setup-hooks`** automates this:
- `tbd setup-hooks --global` — adds the hook to `~/.claude/settings.json`
- `tbd setup-hooks --repo [path]` — adds to the repo's project-level `.claude/settings.json`

## UI Layout

### Window Structure

```
┌─────────────────────────────────────────────────┐
│  Toolbar: [+ Add Repo]  [Filter: All ▼]  [⚙]   │
├──────────────┬──────────────────────────────────┤
│  Sidebar     │  Terminal Area                    │
│              │                                   │
│  ▼ my-app    │  ┌─Tab1─┬─Tab2─┬─Tab3──┐        │
│    + New     │  │              [⬓][⬒]  │        │
│    ● wt-1   │  │  SwiftTerm view      │        │
│      (bold) │  │  (tmux window)       │        │
│    ○ wt-2   │  │                      │        │
│    ○ wt-3   │  │──────────────────────│        │
│              │  │              [⬓][⬒]  │        │
│  ▼ other-repo│  │  SwiftTerm view      │        │
│    + New     │  │  (split pane)        │        │
│    ○ wt-4   │  │                      │        │
│              │  └──────────────────────┘        │
├──────────────┴──────────────────────────────────┤
│  Status bar: tbdd connected │ 3 active worktrees │
└─────────────────────────────────────────────────┘
```

### Sidebar

- Repos are collapsible sections with a "+" button for new worktree
- Each worktree shows: display name, notification badge, branch name (subtle)
- Right-click context menu: Rename, Archive, Open in Finder, Open in IDE, Copy Path
- Cmd-click for multi-select → auto-splits terminal area, one primary terminal per selected worktree
- Filter dropdown: All repos, or a specific repo
- Archived worktrees hidden by default, toggleable via filter

### Terminal Area

- Tab bar across the top (per-worktree)
- Split buttons visible in each panel's title bar: [⬓] horizontal, [⬒] vertical
- Keyboard shortcuts: Cmd-D horizontal split, Cmd-Shift-D vertical split
- Draggable dividers between splits
- Standard terminal shortcuts: Cmd-T new tab, Cmd-W close tab

### Keyboard Shortcuts

- Cmd-1..9 — switch worktrees by sidebar order
- Cmd-N — new worktree in focused repo
- Cmd-Shift-A — archive focused worktree
- Cmd-D — split horizontal
- Cmd-Shift-D — split vertical

## Onboarding

### First Run

1. App launches, starts daemon
2. Empty sidebar with prominent "Add Repository" button
3. User picks a folder → repo added, hooks detected (prints which hook system found)
4. User clicks "+" → first worktree created, two terminals appear
5. Claude Code already running in terminal 1

### Daemon Lifecycle

- `TBD.app` starts `tbdd` on launch if not already running
- `tbdd` can also run standalone: `tbdd start` (foreground) or via launchd
- `tbdd stop` shuts down gracefully
- PID file at `~/.tbd/tbdd.pid`

**Crash recovery:** On startup, the daemon checks for stale PID files (verifies the PID is actually alive) and stale socket files, cleaning them up before binding. Tmux servers are independent processes and survive daemon crashes. On restart, the daemon reconciles its ledger against `git worktree list` and reconnects to existing tmux servers.

### Default Branch Detection

The base branch for new worktrees defaults to `origin/main` but is auto-detected per repo via `git symbolic-ref refs/remotes/origin/HEAD` on `repo.add`. This handles repos using `master`, `develop`, or other default branches. The detected default is stored in the `repos` table and can be overridden in per-repo settings.

### Error Handling

- **`git worktree add` fails** (e.g. branch name collision after partial creation): Daemon cleans up any partial state, retries with a fresh name (new adjective-animal), and surfaces the error if retry also fails.
- **`repo.remove` with active worktrees**: Refuses with an error listing active worktrees. User must archive them first or use `--force` to cascade-archive all.
- **Archive hook timeout**: If the hook is killed at 60s, archive aborts. `--force` skips the hook entirely and proceeds with cleanup regardless of hook state.
- **Multiple UI clients**: The daemon supports multiple simultaneous `state.subscribe` connections. Each receives the same deltas. This is uncommon but harmless.

### SQLite Considerations

The daemon uses WAL mode for the SQLite database. Since only the daemon writes (CLI and UI go through the daemon's RPC), there are no concurrent writer conflicts. FSEvents callbacks and RPC handlers serialize writes through the daemon's main actor.

## Decisions Log

| Decision | Choice | Rationale |
|---|---|---|
| Worktree-terminal relationship | Grouped (B) | Sidebar as workspace switcher, click to see that worktree's terminals |
| Multi-repo | Yes | Single window supports multiple repos with nesting and filtering |
| Merging | Out of scope | Users handle merging via PRs; git workflow integration comes later |
| Server protocol | Unix socket + HTTP | Socket for performance, HTTP for debugging. CLI wraps socket. |
| Architecture | Daemon + UI + CLI | Daemon survives crashes, agents work without UI, clean separation |
| Terminal rendering | SwiftTerm (swappable) | Abstracted behind protocol for future Ghostty swap |
| Splits | Real SwiftUI panels | Better drag/resize than tmux panes |
| Tmux mapping | One window per panel | App owns layout, tmux handles session persistence |
| Tmux servers | One per repo | Isolation, no naming collisions |
| Worktree names | YYYYMMDD-adjective-animal | Fun, unique, no conflicts |
| Branch base | origin/main with local fallback | Fetch first, fall back if network fails |
| Hook resolution | App config → conductor.json → .dmux-hooks → global default | First match wins, no chaining, no double-execution |
| State source of truth | git worktree list + ledger metadata | Git is authoritative for existence, ledger adds display names/dates/history |
| Archive confirmation | None | Archive hook handles cleanup; no prompts |
| Cross-machine sync | Not in v1 | Fully independent per machine |
| Socket permissions | User-scoped (~/.tbd/sock) | Security: only current user can connect |
