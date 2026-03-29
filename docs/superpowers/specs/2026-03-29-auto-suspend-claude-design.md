# Auto-suspend/resume Claude Code on worktree switch

## Problem

Claude Code processes consume 500MB–1GB+ of memory each. With multiple worktrees open, idle Claude instances accumulate significant memory pressure even when only one worktree is actively in use. Users see system slowdown from swap pressure despite most Claude instances sitting at an idle prompt.

## Solution

Automatically exit idle Claude Code instances when the user switches away from a worktree, and resume them (with full conversation context) when switching back. Pinned terminals are never suspended.

## Data model

### New terminal fields

Add to the `Terminal` model and database:

| Field | Type | Purpose |
|-------|------|---------|
| `claudeSessionID` | `String?` | Claude Code session UUID. Set at launch for TBD-created terminals (via `--session-id`), or lazily captured at suspend time for user-spawned instances. |
| `suspendedAt` | `Date?` | Timestamp when daemon auto-suspended this terminal. `nil` = not suspended. |

**Migration**: New migration `v6` adds both columns to the `terminal` table with nil defaults. `Models.swift` gets matching optional fields (both optional, so existing rows decode fine).

### Session ID lifecycle

Two paths for obtaining the session ID:

**Path A — TBD-created terminals**: When the daemon creates a Claude terminal, it generates a UUID and passes `--session-id <uuid>` in the launch command. The UUID is stored as `claudeSessionID` immediately at creation time. This is the reliable, race-free path.

**Path B — User-spawned terminals**: When a user manually runs `claude` in a shell tab, there's no `--session-id`. The session ID is captured lazily at suspend time via PID file lookup:

1. `tmux list-panes -t <paneID> -F "#{pane_pid}"` → shell PID
2. `pgrep -P <shellPID> -x claude` → Claude process PID (must filter for `claude` specifically — the shell may also have MCP server children, `caffeinate`, etc.)
3. Read `~/.claude/sessions/<claudePID>.json` → parse `sessionId`
4. Cache the result as `claudeSessionID` on the terminal record

If lazy capture fails (process already exited, file missing, no `claude` child found), the terminal is skipped for suspension — conservative by default.

**Note**: `~/.claude/sessions/<pid>.json` is an implementation detail of Claude Code, not a documented API. Files are deleted when Claude exits (verified: 59/59 session files on disk belong to live processes, zero orphans). The session ID is stable for the lifetime of the process.

## Idle detection

### `ClaudeStateDetector`

New file: `Sources/TBDDaemon/Tmux/ClaudeStateDetector.swift`

Takes a `TmuxManager` dependency. `TmuxManager` needs new public methods: `capturePaneOutput(server:paneID:)` (wraps `capture-pane -p`), `paneProcessID(server:paneID:)` (wraps `list-panes -F "#{pane_pid}"`), and `paneCurrentCommand(server:paneID:)` (wraps `list-panes -F "#{pane_current_command}"`).

#### `isIdle(server:paneID:) async -> Bool`

Determines whether a Claude Code instance is idle and safe to suspend.

1. **Guard**: check `pane_current_command` — if it's `zsh`, `bash`, or doesn't look like a Claude version string, return `false` (Claude isn't the foreground process)
2. Run `tmux capture-pane -p -t <paneID>`
3. Take the last 5 lines of output
4. Check for **both** conditions:
   - **Status bar present**: text contains any of the status indicators (see constants below)
   - **Bare prompt**: a line matching the prompt pattern with no user input after it
5. Return `true` only if both conditions are met

**Pattern constants** (centralized, since these are Claude Code UI details with no stability contract):

```swift
static let promptPattern = "^❯[\\s\\u{00a0}]*$"  // ❯ followed by only whitespace/nbsp
static let statusIndicators = ["⏵⏵", "bypass", "auto mode", "? for shortcuts"]
```

States correctly classified as **not idle**:
- Claude mid-generation (no prompt visible)
- User has typed partial input after the prompt (`❯ some text`)
- Interactive picker/menu visible (no prompt line)
- Popup/overlay obscuring the prompt (status bar visible but no prompt line)

#### `captureSessionID(server:paneID:) async -> String?`

Extracts the Claude Code session UUID for a running instance (used for user-spawned terminals that lack a pre-assigned `claudeSessionID`).

1. Get shell PID via `paneProcessID(server:paneID:)`
2. Run `pgrep -P <shellPID> -x claude` to find the Claude child process (not MCP servers or other children)
3. Read `~/.claude/sessions/<claudePID>.json`
4. Parse JSON and return `sessionId`
5. Return `nil` at any step if the lookup fails

## Suspend flow

Triggered when the user switches away from a worktree. Requires a new RPC method (see Integration section).

For each terminal in the **departing** worktree:

1. **Skip if pinned**: `pinnedAt != nil` → skip
2. **Skip if already suspended**: `suspendedAt != nil` → skip
3. **Skip if not Claude**: check `pane_current_command` — if it doesn't look like Claude, skip. (Covers both TBD-created terminals where `label == "claude"` and user-spawned Claude instances.)
4. **Check idle state**: call `isIdle(server:paneID:)` → skip if `false`
5. **Ensure session ID**: if `claudeSessionID` is nil, call `captureSessionID(server:paneID:)` and store it. If still nil → skip (can't resume without it)
6. **Exit Claude**: `tmux send-keys -t <paneID> "/exit" Enter`
7. **Verify exit** (async): poll `pane_current_command` every 200ms for up to 3 seconds. If Claude is still running after timeout, clear `suspendedAt` and log a warning — don't leave the terminal in a bad state.
8. **Update database**: set `suspendedAt = Date()`
9. **Broadcast state delta**

Each step that skips leaves the terminal running — conservative by default.

**Race condition note**: Claude could start working between `isIdle()` and the `/exit` send. This is benign — Claude Code queues `/exit` and processes it after the current turn completes. The session ID remains valid.

## Resume flow

Triggered when a worktree is selected.

For each terminal in the **arriving** worktree where `suspendedAt != nil`:

1. **Check if Claude is already running**: `pane_current_command` shows Claude → clear `suspendedAt`, done (user manually restarted it)
2. **Check pane is alive**: verify the tmux pane/window still exists. If dead → create a new tmux window in the same session with the resume command (the `zsh -ic` wrapper means the pane dies when Claude exits)
3. **Build resume command**: `claude --resume <claudeSessionID>` + append ` --dangerously-skip-permissions` if the user's `skipPermissions` setting is enabled
4. **If pane alive** (shell prompt visible): `tmux send-keys -t <paneID> "<command>" Enter`
5. **If pane dead**: create new window via `TmuxManager.createWindow(server:session:cwd:shellCommand:)` with the resume command. Update the terminal record's `tmuxWindowID` and `tmuxPaneID` to the new values.
6. **Clear state**: set `suspendedAt = nil`
7. **Broadcast state delta**

**Stale session handling**: if `claude --resume <id>` fails (session file deleted, corrupted), Claude will show an error. This is acceptable — the user sees the error and can start a new session manually.

## Integration

### New RPC: `worktreeSelectionChanged`

The app's worktree selection is local to `AppState.selectedWorktreeIDs`. State deltas only flow daemon→app, not the reverse. A new RPC method is needed:

**Method**: `worktreeSelectionChanged`
**Params**: `{ selectedWorktreeIDs: [UUID], previousWorktreeIDs: [UUID] }`
**Result**: `{ success: Bool }`

The app calls this from its `onChange(of: appState.selectedWorktreeIDs)` handler in `ContentView.swift`. The daemon computes departing/arriving sets and runs suspend/resume flows.

### Rapid switch handling

If the user switches A→B→A within seconds:
- The suspend for A may still be in flight when the resume for A triggers
- Track in-flight suspend operations per terminal ID (e.g. a `Set<UUID>` of terminals being suspended)
- If a resume arrives for a terminal being suspended, cancel/await the suspend before proceeding
- If a suspend arrives for a terminal being resumed, skip it

### Daemon startup reconciliation

On daemon startup, sweep all terminals with `suspendedAt != nil`:
- Check if the tmux pane is alive and Claude is running → clear `suspendedAt` (user or system restarted it)
- Check if the pane is dead → leave `suspendedAt` set (will be resumed when worktree is next selected)

## Terminal creation changes

When the daemon creates a Claude terminal (in `WorktreeLifecycle+Create.swift`):
1. Generate a UUID for the session: `UUID().uuidString`
2. Store it as `claudeSessionID` on the terminal record
3. Append `--session-id <uuid>` to the Claude launch command

This ensures TBD-created terminals always have a known session ID from the start, independent of PID file availability.

## Scope boundaries

### In scope
- Auto-suspend idle Claude terminals on worktree switch
- Auto-resume with correct session on worktree switch back
- Respect pinned terminals (never suspend)
- Deterministic `--session-id` for TBD-created terminals
- Lazy session ID capture for user-spawned Claude instances
- New DB migration for `claudeSessionID` and `suspendedAt`
- New `worktreeSelectionChanged` RPC method
- `ClaudeStateDetector` for idle detection and session ID capture
- Pane recreation on resume when original pane is dead
- Rapid switch protection
- Daemon startup reconciliation

### Out of scope
- UI indicator for suspended state (future enhancement)
- User setting to enable/disable auto-suspend (always on for v1; add setting if users want it)
- Suspending non-Claude terminals
- Suspending terminals in the currently selected worktree
- Timer-based suspension (only on worktree switch)

## Testing

- **ClaudeStateDetector**: unit tests with mocked tmux output covering all states (idle, idle+input, busy, popup, picker menu, non-Claude foreground process)
- **Session ID capture**: test `pgrep` filtering (must find `claude` not MCP servers), test missing session file gracefully returns nil
- **Suspend flow**: verify skip conditions (pinned, non-claude, already suspended, not idle, no session ID). Verify exit verification with timeout and rollback.
- **Resume flow**: verify command construction with and without `--dangerously-skip-permissions`. Test pane-alive vs pane-dead paths. Test "Claude already running" detection.
- **Rapid switch**: verify suspend cancellation when resume arrives for same terminal
- **DB migration**: verify new columns exist with nil defaults, existing rows still decode
- **Terminal creation**: verify `--session-id` is passed in launch command and stored on record
