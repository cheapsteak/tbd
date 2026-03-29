# Auto-suspend/resume Claude Code on worktree switch

## Problem

Claude Code processes consume 500MB–1GB+ of memory each. With multiple worktrees open, idle Claude instances accumulate significant memory pressure even when only one worktree is actively in use. Users see system slowdown from swap pressure despite most Claude instances sitting at an idle prompt.

## Solution

Automatically exit idle Claude Code instances when the user switches away from a worktree, and resume them (with full conversation context) when switching back. Pinned terminals are never suspended.

**v1 scope**: Only daemon-created Claude terminals (where `label` starts with `"claude"`). User-spawned Claude instances are not suspended. This eliminates runtime process inspection at suspend time and avoids dependency on undocumented PID files for the suspend path.

**v1 assumes a single TBDApp UI session controls worktree selection.** Daemon selection state is global, not per-client. Multi-client correctness (multiple app windows) would require per-client selection tracking in a future version.

## Data model

### New terminal fields

Add to the `Terminal` model and database:

| Field | Type | Purpose |
|-------|------|---------|
| `claudeSessionID` | `String?` | Claude Code session UUID. Set at launch via `--session-id`. Mutable — updated after each resume cycle since `--resume` generates a new ID. |
| `suspendedAt` | `Date?` | Timestamp when daemon auto-suspended this terminal. `nil` = not suspended. |

**Migration**: New migration `v6` adds both columns to the `terminal` table with nil defaults. In `Models.swift`, both fields must use `decodeIfPresent` (synthesized `Codable` does not use property default values for missing keys — a `let foo: String? = nil` still throws `keyNotFound` if the key is absent in JSON). Update `TerminalRecord` in `TerminalStore.swift` with matching GRDB columns.

### Session ID lifecycle

**Important**: `claude --resume <id>` generates a NEW internal session ID (confirmed: GitHub issues #8069, #10806, #12235). The stored `claudeSessionID` goes stale after every resume. The design must account for this.

**Important**: Do NOT use `claude --continue` as an alternative. It resumes the most recent session per cwd, but the user regularly runs multiple Claude sessions in the same worktree directory. `--continue` would resume the wrong session.

**At terminal creation**: The daemon generates a UUID, passes `--session-id <uuid>` in the launch command, and stores it as `claudeSessionID`. This is the reliable, race-free path for the first suspend cycle.

**After each resume**: The daemon re-captures the session ID via PID file lookup once the new Claude process has started (see Resume flow step 7). This is the only point where `~/.claude/sessions/<pid>.json` is read. `claudeSessionID` is mutable throughout the terminal's lifetime.

**Note**: `~/.claude/sessions/<pid>.json` is an implementation detail of Claude Code, not a documented API. Files are deleted when Claude exits (verified: 59/59 session files on disk belong to live processes, zero orphans). The session ID is stable for the lifetime of the process.

## Idle detection

### `ClaudeStateDetector`

New file: `Sources/TBDDaemon/Tmux/ClaudeStateDetector.swift`

Takes a `TmuxManager` dependency. `TmuxManager` needs new public methods: `capturePaneOutput(server:paneID:)` (wraps `capture-pane -p`) and `paneCurrentCommand(server:paneID:)` (wraps `list-panes -F "#{pane_current_command}"`).

#### `isIdle(server:paneID:) async -> Bool`

Determines whether a Claude Code instance is idle and safe to suspend.

1. **Guard**: check `pane_current_command` — Claude appears as a semver-like string (e.g. `2.1.86`). If the value is `zsh`, `bash`, or doesn't match `\d+\.\d+\.\d+`, return `false`.
2. Run `tmux capture-pane -p -t <paneID>`
3. Take the last 5 lines of output
4. Check for **both** conditions:
   - **Status bar present**: text contains any of the status indicators (see constants below)
   - **Bare prompt**: a line matching the prompt pattern with no user input after it
5. Return `true` only if both conditions are met

**Pattern constants** (centralized, since these are Claude Code UI details with no stability contract):

```swift
static let claudeProcessPattern = #"^\d+\.\d+\.\d+"#  // e.g. "2.1.86"
static let promptPattern = "^❯[\\s\\u{00a0}]*$"        // ❯ followed by only whitespace/nbsp
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

Extracts the Claude Code session UUID for a running instance. Used only for post-resume session ID refresh.

1. Get shell PID via `tmux list-panes -t <paneID> -F "#{pane_pid}"`
2. Run `pgrep -P <shellPID> -x claude` to find the Claude child process. If multiple matches, return `nil`.
3. Read `~/.claude/sessions/<claudePID>.json`
4. Parse JSON and return `sessionId`. Treat decode errors as `nil`.
5. Return `nil` at any step if the lookup fails

## Suspend flow

Triggered when the user switches away from a worktree. Orchestrated by the `SuspendResumeCoordinator` actor (see Concurrency section).

For each terminal in the **departing** worktree:

1. **Skip if not daemon-created Claude**: `label` does not start with `"claude"` → skip (v1 scope)
2. **Skip if pinned**: `pinnedAt != nil` → skip
3. **Skip if already suspended**: `suspendedAt != nil` → skip
4. **Skip if no session ID**: `claudeSessionID == nil` → skip (can't resume without it)
5. **Check idle state**: call `isIdleConfirmed(server:paneID:)` → skip if `false` (includes 1s debounce)

**--- Point of no return below ---**

Steps 1–5 are cancellable (the coordinator can cancel the suspend task during any of them). Once step 6 executes, the suspend is committed — `/exit` has been sent and cannot be retracted.

6. **Exit Claude**: send `/exit` followed by Enter to the pane. Note: `TmuxManager.sendKeys` currently uses `-l` (literal text). A new `sendCommand(server:paneID:command:)` method is needed that sends text + Enter key (either via `send-keys` without `-l`, or two calls: `-l` for the text then `Enter` for the key).
7. **Verify exit**: poll `pane_current_command` every 200ms for up to 3 seconds.
   - If Claude exits within timeout → proceed to step 8
   - If Claude is still running after timeout → it may be finishing a turn before processing `/exit`. Mark as suspended anyway (`suspendedAt = Date()`) — Claude will exit eventually and the session is preserved. The pane will die when it does, and resume will create a new window as usual.
8. **Update database**: set `suspendedAt = Date()`
9. **Broadcast state delta**

Steps 1–5 that skip leave the terminal running — conservative by default.

**No suspend message for v1**: TBD-created panes use `zsh -ic <command>` — the pane dies when Claude exits, so there's no shell to echo into. The user sees the terminal resume when they switch back, which is sufficient feedback.

**Race condition note**: Claude could start working between `isIdleConfirmed()` and the `/exit` send. This is benign — Claude Code queues `/exit` and processes it after the current turn completes. The session is preserved. Since `/exit` is past the point of no return, the terminal is always marked as suspended once step 6 executes.

## Resume flow

Triggered when a worktree is selected. Orchestrated by the `SuspendResumeCoordinator` actor.

For each terminal in the **arriving** worktree where `suspendedAt != nil`:

1. **Check if Claude is already running**: `pane_current_command` matches Claude. This could mean the user manually restarted it, OR a timed-out suspend's `/exit` hasn't been processed yet. **Do not clear `suspendedAt` in this case** — wait for Claude to exit (the queued `/exit` will eventually process). If the terminal is still running after another 5s, then assume the user restarted it intentionally: clear `suspendedAt`, re-capture session ID, done.
2. **Check pane is alive**: verify the tmux pane/window still exists via `TmuxManager.windowExists()`. The pane will almost always be dead (TBD-created panes use `zsh -ic` — the shell exits when Claude exits).
3. **Build resume command**: `claude --resume <claudeSessionID> --dangerously-skip-permissions` (daemon always launches managed Claude with this flag today)
4. **Create new tmux window**: call `TmuxManager.createWindow(server:session:cwd:shellCommand:)` with the resume command. Update the terminal record's `tmuxWindowID` and `tmuxPaneID` to the new values.
5. **Force app UI reconnection**: the state delta broadcast must cause the app to recreate the `TerminalPanelView` for this terminal. Since `TerminalPanelView` binds tmux in `makeNSView` (which only runs once) and `updateNSView` is a no-op, a changed `tmuxWindowID` won't rebind the view. **Fix**: include `tmuxWindowID` in the view's `.id()` modifier (e.g. `.id("\(terminalID)-\(tmuxWindowID)")`), so SwiftUI destroys and recreates the view when the window ID changes.
6. **Clear state**: set `suspendedAt = nil`
7. **Re-capture session ID**: wait ~5s for Claude to start, then call `captureSessionID(server:paneID:)` to get the new session UUID. Update `claudeSessionID` in the DB. If capture fails, log a warning — the terminal is usable but won't be suspendable next time until the ID is captured.
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

**Cancellation semantics**: The suspend flow has a point of no return (sending `/exit`). The coordinator can cancel an in-flight suspend only during the pre-exit phase (steps 1–5). The suspend task must check for cancellation via `Task.isCancelled` before step 6, and must NOT check after. Once `/exit` is sent, the suspend runs to completion — the terminal will be marked as suspended regardless of subsequent selection changes.

When a resume arrives for a terminal that is already marked `suspendedAt != nil` (suspend completed), the coordinator runs the normal resume flow. When a resume arrives while a suspend is still in its cancellable phase (steps 1–5), the coordinator cancels the suspend task. When a suspend arrives for a terminal with an in-flight resume, it skips.

## Integration

### New RPC: `worktreeSelectionChanged`

The app's worktree selection is local to `AppState.selectedWorktreeIDs`. State deltas only flow daemon→app, not the reverse. A new RPC method is needed:

**Method**: `worktreeSelectionChanged`
**Params**: `{ selectedWorktreeIDs: [UUID] }` (idempotent — daemon diffs against its own last-known selection)
**Result**: `{ success: Bool }`

The app calls this from:
1. `onChange(of: appState.selectedWorktreeIDs)` in `ContentView.swift` — on every selection change
2. The reconnect/refresh path in `AppState` — after daemon restart or reconnect, the app must re-send its current selection so the daemon has an accurate baseline. Without this, a daemon restart while the user stays on the same worktree leaves the daemon with an empty selection cache and no resume trigger.

The daemon diffs against its last-known selection. **Unknown worktree IDs are silently ignored** — the app uses optimistic placeholder UUIDs during worktree creation (before the daemon assigns the real ID), so the daemon will sometimes see IDs it doesn't recognize. These are not errors.

### Reconcile changes

The existing reconcile flow (`WorktreeLifecycle+Reconcile.swift`) deletes terminal records whose tmux window is dead. Auto-suspended terminals have dead panes by design. **Reconcile must skip terminals where `suspendedAt != nil`** — they will be recreated on resume.

### Daemon startup reconciliation

On daemon startup, sweep all terminals with `suspendedAt != nil`:
- Check if the tmux pane is alive and Claude is running → clear `suspendedAt` (user or system restarted it)
- Check if the pane is dead → leave `suspendedAt` set (will be resumed when worktree is next selected)

This runs BEFORE the normal reconcile, so suspended terminals are already flagged and reconcile will skip them.

### App UI reconnection

`TerminalPanelView` binds to tmux once in `makeNSView` and never rebinds (`updateNSView` is a no-op). When resume creates a new tmux window, the old view is stale. **Fix**: change the view identity in `PanePlaceholder.swift` to include the tmux window ID:

```swift
// Before:
.id(terminalID)

// After:
.id("\(terminal.id)-\(terminal.tmuxWindowID)")
```

This forces SwiftUI to destroy and recreate the `TerminalPanelView` when the window ID changes, triggering a fresh `makeNSView` that binds to the new tmux session.

## Terminal creation changes

When the daemon creates a Claude terminal (in `WorktreeLifecycle+Create.swift`):
1. Generate a UUID for the session: `UUID().uuidString`
2. Store it as `claudeSessionID` on the terminal record
3. Append `--session-id <uuid>` to the Claude launch command (the daemon already appends `--dangerously-skip-permissions`)

## Scope boundaries

### In scope (v1)
- Auto-suspend idle daemon-created Claude terminals on worktree switch
- Auto-resume with correct session on worktree switch back
- Session ID re-capture after resume (handles `--resume` generating new IDs)
- Respect pinned terminals (never suspend)
- Deterministic `--session-id` for TBD-created terminals
- 1s idle detection debounce
- `SuspendResumeCoordinator` actor for concurrency and rapid-switch handling
- New DB migration for `claudeSessionID` and `suspendedAt`
- New `worktreeSelectionChanged` RPC method (idempotent)
- `ClaudeStateDetector` for idle detection and post-resume session ID capture
- Pane recreation on resume (new tmux window)
- App UI reconnection via composite view identity
- Reconcile fix (preserve suspended terminals)
- Daemon startup reconciliation

### Out of scope (v2+)
- Suspending user-spawned Claude instances (requires lazy PID file capture at suspend time)
- UI indicator for suspended state (future enhancement)
- User setting to enable/disable auto-suspend
- Suspending non-Claude terminals
- Timer-based suspension (only on worktree switch)
- Per-terminal `skipPermissions` toggle (daemon always uses `--dangerously-skip-permissions` today)

## Known limitations

- `~/.claude/sessions/<pid>.json` is an undocumented implementation detail, used only for post-resume session ID refresh. If Claude Code changes this format, the first suspend/resume cycle works (uses the creation-time `--session-id`), but subsequent cycles won't until the code is updated.
- `claude --resume` ignores `CLAUDE_CONFIG_DIR` environment variable (GitHub issue #16103). Users with custom config dirs may see resume failures.
- Idle detection patterns (`❯` prompt, status bar strings) are Claude Code UI details with no stability contract. Changes to Claude's TUI would cause false negatives (failing to detect idle), not false positives (incorrectly suspending). Patterns are centralized as constants for easy updates.
- `pane_current_command` reporting Claude as a semver string (e.g. `2.1.86`) is empirically observed behavior, not documented by tmux or Claude Code. If this changes, the `claudeProcessPattern` regex would need updating. Failure mode is false negatives (Claude not detected as foreground process → not suspended), not false positives.

## Implementation notes

These are codebase-specific details the implementer should be aware of:

- **Startup ordering**: The daemon currently starts serving RPCs before reconcile runs (`Daemon.swift`). The startup reconciliation sweep (clearing stale `suspendedAt`) must complete before selection RPCs are processed, otherwise a race exists where a selection RPC triggers resume while reconcile is still cleaning up. Either block RPC serving until reconcile finishes, or have the coordinator queue selection changes until reconcile is done.
- **Reconcile orphan cleanup**: `WorktreeLifecycle+Reconcile.swift` kills tmux windows not present in the DB. Since resume creates new windows, ensure the reconcile snapshot and the resume path don't race (the coordinator serializes this naturally if reconcile uses it).
- **App state propagation**: The app polls terminals every ~2s (`AppState.swift`). There is no push/subscription path for terminal state deltas. After `worktreeSelectionChanged` RPC returns, the app should trigger an immediate terminal refresh (not wait for the next poll cycle), otherwise the user may briefly see "Terminal session expired" for the old dead window.
- **Worktree name collision**: `WorktreeLifecycle+Create.swift` may keep stale `name`/`branch`/`path` on retry after name collision. Resume uses the stored worktree cwd. This is a pre-existing bug, not introduced by this feature, but the implementer should be aware it exists.
- **TmuxManager testability**: `TmuxManager` is a concrete struct with a private `runTmux`. `ClaudeStateDetector` tests need a protocol or injectable command runner to mock tmux output. `TmuxManager` already has `dryRun` mode for command builders; extend this pattern or extract a `TmuxCommandRunner` protocol.

## Testing

- **ClaudeStateDetector**: unit tests with mocked tmux output covering all states (idle, idle+input, busy, popup, picker menu, non-Claude foreground process). Test `claudeProcessPattern` regex against real version strings.
- **Idle debounce**: test that `isIdleConfirmed` returns false when first check passes but second doesn't
- **Session ID capture**: test missing/corrupt session file returns nil, test multiple `pgrep` matches returns nil
- **Session ID refresh**: test that `claudeSessionID` is updated after resume via PID lookup
- **Suspend flow**: verify skip conditions (not-claude-label, pinned, already suspended, no session ID, not idle). Verify exit verification with timeout and skip-on-failure.
- **Resume flow**: verify command includes `--dangerously-skip-permissions`. Test new window creation and terminal record update. Test "Claude already running" detection.
- **App UI reconnection**: verify that changing `tmuxWindowID` on a terminal triggers view recreation
- **Reconcile**: verify terminals with `suspendedAt != nil` are preserved (not deleted as dead windows)
- **Coordinator**: verify suspend cancellation when resume arrives for same terminal. Verify skip when suspend arrives during resume.
- **DB migration**: verify new columns exist with nil defaults, existing rows decode with `decodeIfPresent`
- **Terminal creation**: verify `--session-id` is passed in launch command and stored on record
