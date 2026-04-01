# Snapshot Display During Terminal Resume — Approaches Tried

**Date**: 2026-03-31
**Context**: When a suspended Claude terminal resumes, we want to show the last terminal state (captured via `tmux capture-pane -e`) while the live tmux session connects.

## Approach 1: Separate SnapshotTerminalView (FAILED)

**Idea**: Show a read-only `SnapshotTerminalView` (NSViewRepresentable wrapping SwiftTerm) while suspended, then swap to `TerminalPanelView` when `suspendedAt` is cleared.

**Problems**:
- **Timing**: `clearSuspended` runs in the daemon on resume. If it clears before the app polls (2s interval), the app never sees the snapshot — goes straight from blank to live terminal.
- **If delayed**: A 3s timer ensures the app sees the snapshot, but if the user switches away and back later, the snapshot is already cleared. The user doesn't control when they return.
- **If snapshot kept in DB**: Works, but creates a **blank screen gap** — snapshot disappears when `suspendedAt` clears, then `TerminalPanelView` needs 1-3s to connect to tmux.

## Approach 2: ZStack with SnapshotTerminalView over TerminalPanelView (FAILED)

**Idea**: Layer both views in a ZStack. Snapshot on top, live terminal underneath connecting in background. Use `onFirstData` callback to remove the snapshot overlay.

**Problems**:
- **NSView opacity**: `TerminalPanelView` (an NSView via NSViewRepresentable) renders with an opaque black background immediately, covering the snapshot before it has content.
- **Flickering**: Two competing NSViews in the same frame cause visual artifacts. SwiftUI struggles to composite overlapping NSViews reliably.
- **State oscillation**: The `suspendedAt` flag being set/cleared by both the daemon and the app caused the views to flicker between snapshot and live states.

## Approach 3: Single TerminalView with initialSnapshot (CURRENT)

**Idea**: Feed the ANSI snapshot directly into the same `TBDTerminalView` that will connect to tmux. The live PTY output overwrites the snapshot content naturally.

**Implementation**:
- `TerminalPanelView` gains an `initialSnapshot: String?` parameter
- In `onReady` (after layout), feed the snapshot with `\r\n` normalization before starting the tmux client
- No view swap — the terminal buffer transitions from snapshot to live content seamlessly

**Key details**:
- `tmux capture-pane -e` outputs bare `\n`. SwiftTerm expects `\r\n` for correct rendering. Normalize: strip `\r\n` → `\n` → `\r\n`.
- The `layout()` override (not `updateNSView`) is needed to feed content after the view has real dimensions.
- `clearSuspended` keeps the snapshot in the DB — it's overwritten on the next suspend.

## Other Lessons

- **`esc to interrupt` in status bar**: Present when Claude is actively working. Correctly used as a busy indicator. Cannot test idle state of the current session by capturing its pane (the capture command itself makes the session active).
- **`response_complete` hook gaps**: The hook doesn't always fire (daemon restart, missed hook). Just-in-time capture-pane check at suspend time fills this gap.
- **Re-seed timing**: Re-seeding the idle hook immediately after resume (5s) caused instant re-suspension on brief worktree departures. 30s delay is safer.
