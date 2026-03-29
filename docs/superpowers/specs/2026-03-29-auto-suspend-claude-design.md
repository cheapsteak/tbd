# Auto-suspend/resume Claude Code on worktree switch

## Problem

Claude Code processes consume 500MB–1GB+ of memory each. With multiple worktrees open, idle Claude instances accumulate significant memory pressure even when only one worktree is actively in use. Users see system slowdown from swap pressure despite most Claude instances sitting at an idle prompt.

## Solution

Automatically exit idle Claude Code instances when the user switches away from a worktree, and resume them (with full conversation context) when switching back. Pinned terminals are never suspended.

## Data model

### New terminal fields

Add two optional fields to the `Terminal` model and database:

| Field | Type | Purpose |
|-------|------|---------|
| `suspendedAt` | `Date?` | Timestamp when daemon auto-suspended this terminal. `nil` = not suspended. |
| `suspendedSessionID` | `String?` | Claude Code session UUID captured before exit. Used for `claude --resume <id>`. |

**Migration**: New migration `v6` adds both columns to the `terminal` table with nil defaults. `Models.swift` gets matching optional fields (both optional, so existing rows decode fine).

## Idle detection

### `ClaudeStateDetector`

New file: `Sources/TBDDaemon/Tmux/ClaudeStateDetector.swift`

Takes a `TmuxManager` dependency for running tmux commands. `TmuxManager` will need a new public `capturePaneOutput(server:paneID:)` method (thin wrapper around `runTmux` for `capture-pane -p`), and a `paneProcessID(server:paneID:)` method for `list-panes -F "#{pane_pid}"`.

Provides two methods:

#### `isIdle(server:paneID:) async -> Bool`

Determines whether a Claude Code instance is idle and safe to suspend.

1. Run `tmux capture-pane -p -t <paneID>` via `TmuxManager.runTmux`
2. Take the last 5 lines of output
3. Check for **both** conditions:
   - **Status bar present**: text contains any of `⏵⏵`, `bypass`, `auto mode`, `? for shortcuts`
   - **Bare prompt**: a line matching `❯` followed by only whitespace/non-breaking-space to end of line (regex: `^❯[\s\u{00a0}]*$`)
4. Return `true` only if both conditions are met

States that are correctly classified as **not idle**:
- Claude mid-generation (no prompt visible)
- User has typed partial input after the prompt (`❯ some text`)
- Interactive picker/menu visible (no prompt line)
- Popup/overlay obscuring the prompt (status bar visible but no prompt line)

#### `captureSessionID(server:paneID:) async -> String?`

Extracts the Claude Code session UUID for a running instance.

1. Run `tmux list-panes -t <paneID> -F "#{pane_pid}"` to get the shell PID
2. Run `pgrep -P <shellPID>` to find the claude child process PID
3. Read `~/.claude/sessions/<claudePID>.json`
4. Parse the JSON and return the `sessionId` string
5. Return `nil` at any step if the lookup fails (process gone, file missing, etc.)

## Suspend flow

Triggered when the app changes worktree selection (the daemon already receives this via RPC state deltas).

For each terminal in the **departing** worktree:

1. **Skip if not a Claude terminal**: `label` does not start with `"claude"` → skip
2. **Skip if pinned**: `pinnedAt != nil` → skip
3. **Skip if already suspended**: `suspendedAt != nil` → skip
4. **Check idle state**: call `isIdle(server:paneID:)` → skip if `false`
5. **Capture session ID**: call `captureSessionID(server:paneID:)` → skip if `nil` (can't resume without it)
6. **Exit Claude**: `tmux send-keys -t <paneID> "/exit" Enter`
7. **Update database**: set `suspendedAt = Date()`, `suspendedSessionID = <uuid>`
8. **Broadcast state delta** so the app UI can show a "suspended" indicator

Each step that skips leaves the terminal running — the design is conservative. If anything is uncertain, don't suspend.

## Resume flow

Triggered when a worktree is selected.

For each terminal in the **arriving** worktree where `suspendedAt != nil`:

1. **Wait for shell readiness**: after Claude exits, the shell prompt needs a moment to appear. Poll with `tmux capture-pane` looking for a shell prompt (e.g. `$` or `%` or `❯` from zsh), up to 2 seconds, checking every 200ms. If the shell prompt never appears, skip (don't send blind input).
2. **Build resume command**: `claude --resume <suspendedSessionID>` + append ` --dangerously-skip-permissions` if the user's `skipPermissions` setting is enabled
3. **Send command**: `tmux send-keys -t <paneID> "<command>" Enter`
4. **Clear state**: set `suspendedAt = nil`, `suspendedSessionID = nil`
5. **Broadcast state delta**

## Integration point

The suspend/resume logic hooks into the daemon's existing worktree selection handling. When the daemon processes a selection change:

1. Identify departing worktrees (were selected, now aren't)
2. Identify arriving worktrees (weren't selected, now are)
3. Run suspend flow for departing worktrees (async, non-blocking — sends `/exit` but does not wait for Claude to actually terminate)
4. Run resume flow for arriving worktrees (async, independent of suspend — arriving worktrees are different from departing worktrees, so there's no ordering dependency)

## Scope boundaries

### In scope
- Auto-suspend idle Claude terminals on worktree switch
- Auto-resume with correct session on worktree switch back
- Respect pinned terminals (never suspend)
- New DB migration for `suspendedAt` and `suspendedSessionID`
- `ClaudeStateDetector` for idle detection and session ID capture

### Out of scope
- UI indicator for suspended state (future enhancement)
- User setting to enable/disable auto-suspend (always on for v1; add setting if users want it)
- Suspending non-Claude terminals
- Suspending terminals in the currently selected worktree
- Timer-based suspension (only on worktree switch)

## Testing

- **ClaudeStateDetector**: unit tests with mocked tmux output covering all states (idle, idle+input, busy, popup, picker menu)
- **Suspend flow**: verify skip conditions (pinned, non-claude, already suspended, not idle, no session ID)
- **Resume flow**: verify command construction with and without `--dangerously-skip-permissions`
- **DB migration**: verify new columns exist with nil defaults, existing rows still decode
