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
| `claudeSessionID` | `String?` | Claude Code session UUID. Set at launch for TBD-created terminals (via `--session-id`), or lazily captured at suspend time for user-spawned instances. Mutable — updated after each resume cycle (see Session ID lifecycle). |
| `suspendedAt` | `Date?` | Timestamp when daemon auto-suspended this terminal. `nil` = not suspended. |
| `skipPermissions` | `Bool` | Whether this terminal was launched with `--dangerously-skip-permissions`. Set at creation time, read at resume time. Defaults to `false`. |

**Migration**: New migration `v6` adds all three columns to the `terminal` table with nil/false defaults. `Models.swift` gets matching fields (optional for `claudeSessionID` and `suspendedAt`, defaulted for `skipPermissions`).

### Session ID lifecycle

**Important**: `claude --resume <id>` generates a NEW internal session ID (confirmed: GitHub issues #8069, #10806, #12235). The stored `claudeSessionID` goes stale after every resume. The design must account for this.

**Important**: Do NOT use `claude --continue` as an alternative. It resumes the most recent session per cwd, but the user regularly runs multiple Claude sessions in the same worktree directory. `--continue` would resume the wrong session.

Two paths for obtaining the session ID:

**Path A — TBD-created terminals**: When the daemon creates a Claude terminal, it generates a UUID and passes `--session-id <uuid>` in the launch command. The UUID is stored as `claudeSessionID` immediately at creation time. This is the reliable, race-free path for the first suspend cycle.

**Path B — User-spawned terminals**: When a user manually runs `claude` in a shell tab, there's no `--session-id`. The session ID is captured lazily at suspend time via PID file lookup:

1. `tmux list-panes -t <paneID> -F "#{pane_pid}"` → shell PID
2. `pgrep -P <shellPID> -x claude` → Claude process PID (must filter for `claude` specifically — the shell may also have MCP server children, `caffeinate`, etc.). If multiple matches, skip (ambiguous — don't suspend).
3. Read `~/.claude/sessions/<claudePID>.json` → parse `sessionId` (treat JSON decode errors as nil — file may be partially written)
4. Cache the result as `claudeSessionID` on the terminal record

If lazy capture fails (process already exited, file missing, no `claude` child found, multiple matches), the terminal is skipped for suspension — conservative by default.

**Session ID refresh after resume**: After every resume (both Path A and Path B), the daemon must re-capture the session ID via PID file lookup once the new Claude process has started. This is done as part of the resume flow (see Resume flow step 7). `claudeSessionID` is mutable throughout the terminal's lifetime.

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

#### `isIdleConfirmed(server:paneID:) async -> Bool`

Debounced idle check. Calls `isIdle()` twice with a 1-second gap. Returns `true` only if both checks pass. This guards against a transient prompt flash between Claude's multi-step turns — the prompt briefly appears between tool calls for a few hundred milliseconds, but disappears when the next turn starts.

The 1s debounce is conservative. False positives are benign: if Claude starts a new turn between the check and `/exit`, `/exit` is queued and processed after the turn completes. The session is preserved either way.

#### `captureSessionID(server:paneID:) async -> String?`

Extracts the Claude Code session UUID for a running instance.

1. Get shell PID via `paneProcessID(server:paneID:)`
2. Run `pgrep -P <shellPID> -x claude` to find the Claude child process (not MCP servers or other children). If multiple matches, return `nil`.
3. Read `~/.claude/sessions/<claudePID>.json`
4. Parse JSON and return `sessionId`. Treat decode errors as `nil` (file may be partially written).
5. Return `nil` at any step if the lookup fails

## Suspend flow

Triggered when the user switches away from a worktree. Requires a new RPC method (see Integration section). Orchestrated by the `SuspendResumeCoordinator` actor (see Concurrency section).

For each terminal in the **departing** worktree:

1. **Skip if pinned**: `pinnedAt != nil` → skip
2. **Skip if already suspended**: `suspendedAt != nil` → skip
3. **Skip if not Claude**: check `pane_current_command` — if it doesn't look like Claude, skip. (Covers both TBD-created terminals where `label == "claude"` and user-spawned Claude instances.)
4. **Check idle state**: call `isIdleConfirmed(server:paneID:)` → skip if `false` (includes 1s debounce)
5. **Ensure session ID**: if `claudeSessionID` is nil, call `captureSessionID(server:paneID:)` and store it. If still nil → skip (can't resume without it)
6. **Exit Claude**: `tmux send-keys -t <paneID> "/exit" Enter`
7. **Verify exit**: poll `pane_current_command` every 200ms for up to 3 seconds. If Claude is still running after timeout, log a warning and skip — don't mark as suspended.
8. **Show suspend message**: after exit confirmed, send `echo '[Session suspended — will resume when you switch back]'` to the pane via `tmux send-keys`. This gives the user a visible indicator if they peek at the terminal.
9. **Update database**: set `suspendedAt = Date()`
10. **Broadcast state delta**

Each step that skips leaves the terminal running — conservative by default.

**Race condition note**: Claude could start working between `isIdleConfirmed()` and the `/exit` send. This is benign — Claude Code queues `/exit` and processes it after the current turn completes. The session ID remains valid.

## Resume flow

Triggered when a worktree is selected. Orchestrated by the `SuspendResumeCoordinator` actor.

For each terminal in the **arriving** worktree where `suspendedAt != nil`:

1. **Check if Claude is already running**: `pane_current_command` shows Claude → clear `suspendedAt`, re-capture session ID via PID lookup, done (user manually restarted it)
2. **Check pane is alive**: verify the tmux pane/window still exists. If dead → create a new tmux window (the `zsh -ic` wrapper means the pane dies when Claude exits)
3. **Build resume command**: `claude --resume <claudeSessionID>` + append ` --dangerously-skip-permissions` if `skipPermissions == true` on the terminal record
4. **If pane alive** (shell prompt visible): `tmux send-keys -t <paneID> "<command>" Enter`
5. **If pane dead**: create new window via `TmuxManager.createWindow(server:session:cwd:shellCommand:)` with the resume command. Update the terminal record's `tmuxWindowID` and `tmuxPaneID` to the new values.
6. **Clear state**: set `suspendedAt = nil`
7. **Re-capture session ID**: wait ~5s for Claude to start, then call `captureSessionID(server:paneID:)` to get the new session UUID (since `--resume` generates a new ID). Update `claudeSessionID` in the DB. If capture fails, log a warning — the terminal is usable but won't be suspendable next time until the ID is captured.
8. **Broadcast state delta**

**Stale session handling**: if `claude --resume <id>` fails (session file deleted, corrupted), Claude will show an error. This is acceptable — the user sees the error and can start a new session manually.

## Concurrency

### `SuspendResumeCoordinator` actor

Serializes all suspend/resume operations to prevent data races and handle rapid switching.

```swift
actor SuspendResumeCoordinator {
    private var inFlight: [UUID: Task<Void, Never>] = [:]

    func suspend(terminalID: UUID, ...) { ... }
    func resume(terminalID: UUID, ...) { ... }
}
```

When a resume arrives for a terminal with an in-flight suspend, the coordinator cancels the suspend task before starting the resume. When a suspend arrives for a terminal with an in-flight resume, it skips. This naturally handles rapid switching (A→B→A) and serves as the debounce mechanism — no separate timer needed.

## Integration

### New RPC: `worktreeSelectionChanged`

The app's worktree selection is local to `AppState.selectedWorktreeIDs`. State deltas only flow daemon→app, not the reverse. A new RPC method is needed:

**Method**: `worktreeSelectionChanged`
**Params**: `{ selectedWorktreeIDs: [UUID], previousWorktreeIDs: [UUID] }`
**Result**: `{ success: Bool }`

The app calls this from its `onChange(of: appState.selectedWorktreeIDs)` handler in `ContentView.swift`. The daemon computes departing/arriving sets and runs suspend/resume flows via the `SuspendResumeCoordinator`.

### Daemon startup reconciliation

On daemon startup, sweep all terminals with `suspendedAt != nil`:
- Check if the tmux pane is alive and Claude is running → clear `suspendedAt` (user or system restarted it)
- Check if the pane is dead → leave `suspendedAt` set (will be resumed when worktree is next selected)

## Terminal creation changes

When the daemon creates a Claude terminal (in `WorktreeLifecycle+Create.swift`):
1. Generate a UUID for the session: `UUID().uuidString`
2. Store it as `claudeSessionID` on the terminal record
3. Store `skipPermissions` based on the user's current setting
4. Append `--session-id <uuid>` to the Claude launch command (and `--dangerously-skip-permissions` if applicable, as it already does)

This ensures TBD-created terminals always have a known session ID from the start, independent of PID file availability.

## Scope boundaries

### In scope
- Auto-suspend idle Claude terminals on worktree switch
- Auto-resume with correct session on worktree switch back
- Session ID re-capture after resume (handles `--resume` generating new IDs)
- Respect pinned terminals (never suspend)
- Deterministic `--session-id` for TBD-created terminals
- Lazy session ID capture for user-spawned Claude instances
- 1s idle detection debounce
- Terminal buffer message on suspend
- `SuspendResumeCoordinator` actor for concurrency and rapid-switch handling
- New DB migration for `claudeSessionID`, `suspendedAt`, `skipPermissions`
- New `worktreeSelectionChanged` RPC method
- `ClaudeStateDetector` for idle detection and session ID capture
- Pane recreation on resume when original pane is dead
- Daemon startup reconciliation

### Out of scope
- UI indicator for suspended state beyond the terminal buffer message (future enhancement)
- User setting to enable/disable auto-suspend (always on for v1; add setting if users want it)
- Suspending non-Claude terminals
- Suspending terminals in the currently selected worktree
- Timer-based suspension (only on worktree switch)

## Known limitations

- `~/.claude/sessions/<pid>.json` is an undocumented implementation detail. If Claude Code changes this format, lazy capture and post-resume refresh will fail silently (terminals won't be suspendable until the code is updated, but nothing breaks).
- `claude --resume` ignores `CLAUDE_CONFIG_DIR` environment variable (GitHub issue #16103). Users with custom config dirs may see resume failures.
- Idle detection patterns (`❯` prompt, status bar strings) are Claude Code UI details with no stability contract. Changes to Claude's TUI would cause false negatives (failing to detect idle), not false positives (incorrectly suspending). Patterns are centralized as constants for easy updates.

## Testing

- **ClaudeStateDetector**: unit tests with mocked tmux output covering all states (idle, idle+input, busy, popup, picker menu, non-Claude foreground process)
- **Idle debounce**: test that `isIdleConfirmed` returns false when first check passes but second doesn't (simulating inter-turn prompt flash)
- **Session ID capture**: test `pgrep` filtering (must find `claude` not MCP servers), test multiple matches returns nil, test missing/corrupt session file returns nil
- **Session ID refresh**: test that `claudeSessionID` is updated after resume via PID lookup
- **Suspend flow**: verify skip conditions (pinned, non-claude, already suspended, not idle, no session ID). Verify exit verification with timeout and rollback. Verify echo message after exit.
- **Resume flow**: verify command construction with and without `--dangerously-skip-permissions`. Test pane-alive vs pane-dead paths. Test "Claude already running" detection.
- **Coordinator**: verify suspend cancellation when resume arrives for same terminal. Verify skip when suspend arrives during resume.
- **DB migration**: verify new columns exist with nil/false defaults, existing rows still decode
- **Terminal creation**: verify `--session-id` is passed in launch command and stored on record. Verify `skipPermissions` stored.
