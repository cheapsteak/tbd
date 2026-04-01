# Manual Suspend/Resume for Worktrees

Add the ability to manually suspend and resume Claude terminals via sidebar context menu and terminal tab header buttons.

## Context

Auto-suspend already handles suspending idle Claude instances when switching worktrees. This feature adds explicit user control — suspend a specific terminal or all Claude terminals in a worktree on demand, without navigating away.

## RPC Layer

Four new RPC methods:

| Method | Params | Result | Behavior |
|--------|--------|--------|----------|
| `terminal.suspend` | `terminalID: UUID` | `.ok` | Suspend one Claude terminal |
| `terminal.resume` | `terminalID: UUID` | `.ok` | Resume one suspended terminal |
| `worktree.suspend` | `worktreeID: UUID` | `.ok` | Suspend all Claude terminals in worktree |
| `worktree.resume` | `worktreeID: UUID` | `.ok` | Resume all suspended terminals in worktree |

Worktree-level methods are convenience wrappers that iterate terminals and call the terminal-level methods.

### Error cases

- `terminal.suspend` on a non-Claude terminal → error
- `terminal.suspend` on an already-suspended terminal → no-op, `.ok`
- `terminal.resume` on a non-suspended terminal → no-op, `.ok`
- Idle timeout (10s) → abort suspend, return error ("Claude is busy")

## Coordinator Changes

Two new public methods on `SuspendResumeCoordinator`:

### `manualSuspend(terminal:)`

Similar to existing `suspendTerminal(_:)` but:

- **Skips pin check** — manual action overrides pins
- **Skips `worktreeIdleFromHook` check** — only uses capture-pane idle detection
- **Polls idle state up to 10s** (50 × 200ms). If still not idle, aborts and returns error
- Same flow otherwise: capture snapshot → `/exit` → verify exit → mark `suspendedAt` in DB

### `manualResume(terminal:)`

Same behavior as existing `resumeTerminal(_:)` — creates new tmux window with `claude --resume <sessionID> --dangerously-skip-permissions`, updates tmux IDs, clears `suspendedAt` after delay.

### Worktree-level handlers

- `handleWorktreeSuspend` — fetches terminals for worktree, filters to `label?.hasPrefix("claude") && suspendedAt == nil`, calls `manualSuspend` for each concurrently via `TaskGroup`
- `handleWorktreeResume` — fetches terminals where `suspendedAt != nil`, calls `manualResume` for each concurrently

## UI — Sidebar Context Menu

In `SidebarContextMenu.swift`, add to existing menu for non-main, non-creating worktrees:

```
Rename...
Suspend Claude    ← if any Claude terminal is not suspended
Resume Claude     ← if any Claude terminal is suspended
Archive
─────────
Open in Finder
Copy Path
```

- Both items can be visible simultaneously (some terminals suspended, some not)
- Neither shown if worktree has no Claude terminals
- "Suspend Claude" calls `daemonClient.worktreeSuspend(worktreeID:)`
- "Resume Claude" calls `daemonClient.worktreeResume(worktreeID:)`

## UI — Terminal Tab Header Button

In `TabBarItem`, add suspend/unsuspend button for Claude terminals:

- **Visible when:** tab is a `.terminal` with `label?.hasPrefix("claude") == true`
- **Not suspended:** pause icon (`pause.circle`) → calls `terminal.suspend`
- **Suspended:** play icon (`play.circle`) → calls `terminal.resume`
- **Position:** right of tab label (before invisible spacer), same size/style as close button (16×16)
- **Visibility:** on hover or when selected (matches close button pattern)

### Suspended tab appearance

- Tab label dimmed (`.tertiary` foreground)
- Tab icon swapped to `moon.zzz` or similar when suspended

### Terminal content area

- Shows frozen ANSI snapshot (already implemented in PR #48)
- "Suspended" badge overlay to distinguish from live terminal

## Data Flow

No new state needed in AppState — everything derives from existing `Terminal.suspendedAt`.

1. User clicks suspend button → RPC to daemon
2. Coordinator waits for idle (up to 10s), captures snapshot, sends `/exit`, marks `suspendedAt` in DB
3. Next poll cycle (≤2s), AppState picks up updated terminal
4. SwiftUI re-renders: tab shows suspended state, content shows snapshot + badge

Resume is the reverse — new tmux window created, view identity change triggers SwiftUI recreation, `suspendedAt` cleared after delay.

## Edge Cases

- **Suspend during resume / resume during suspend:** Cancel in-flight task via existing `inFlight[terminal.id]` map, then proceed with new action
- **Rapid toggle:** Same cancellation mechanism handles double-clicks
- **Suspend currently-viewed worktree:** Snapshot appears in-place, no navigation change
- **Auto-resume after manual suspend:** Not an issue — auto-resume only triggers on "arriving" worktrees (selection change diffing). Staying on the worktree doesn't trigger arrival.
- **Terminal deleted during idle wait:** Check terminal still exists in DB after idle wait before proceeding to `/exit`
- **Scope:** Label-based only — only TBD-managed Claude terminals (`label?.hasPrefix("claude")`). User-launched Claude in a shell terminal is not affected.
