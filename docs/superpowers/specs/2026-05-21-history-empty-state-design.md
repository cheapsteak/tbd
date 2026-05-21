# Session history as the empty state

**Date:** 2026-05-21
**Status:** Approved

## Goal

When a worktree has no open tabs, show its session history instead of the bare
"No terminals" placeholder. Closing the last tab should land the user on a useful
list of past Claude sessions they can resume, rather than a dead-end empty state.

## Current behavior

In `Sources/TBDApp/Terminal/TerminalContainerView.swift`:

- The tab bar (`TabBar`) renders only when `!worktreeTabs.isEmpty` (line ~140).
- `layoutContent(worktree:)` decides the main area:
  - `historyActiveWorktrees.contains(worktreeID)` → `HistoryPaneView`
  - else `activeTab` exists → `SplitLayoutView`
  - else → a "No terminals" VStack (terminal icon + "Create Terminal" button)

So when all tabs are closed, the user sees the "No terminals" placeholder and the
tab bar — including its `+` menu and history button — disappears entirely.

Session history is otherwise reached via the history button in the tab bar, which
calls `AppState.toggleHistory(worktreeID:)`, adding the worktree to
`historyActiveWorktrees` and triggering `fetchSessions`.

## Design

### 1. Tab bar always visible

Remove the `if !worktreeTabs.isEmpty` guard so `TabBar` renders even with zero
tabs. `TabBar` already handles an empty `tabs` array (the `ForEach` is empty; the
`+` menu and history button still render). This preserves every terminal-creation
path (shell / Claude / Claude-profile / Codex / note) from the empty state.

### 2. Implicit history in the empty-tabs branch

In `layoutContent(worktree:)`, the `else` branch (no `activeTab`) currently shows
the "No terminals" VStack. New behavior, driven by `historyLoadStates[worktreeID]`:

| Load state                                | Shown                                   |
|--------------------------------------------|-----------------------------------------|
| `.idle`, `.loading`, `.loadingStale`       | `HistoryPaneView`                       |
| `.loaded` with ≥1 session                  | `HistoryPaneView`                       |
| `.loaded([])` (no past sessions)           | existing "No terminals" empty state     |
| `.failed`                                  | existing "No terminals" empty state     |

This is *implicit* history: the worktree is **not** added to
`historyActiveWorktrees`, so the history button's selected styling stays off and
the explicit toggle continues to work independently. During loading,
`HistoryPaneView` renders its own loading header, so there is no flash of the
"No terminals" placeholder before sessions resolve.

On `.failed`, falling back to "No terminals" is acceptable because the tab bar's
`+` menu is visible right above it — the failure is non-blocking. The user can
still explicitly toggle history to see the error.

### 3. Fetching sessions when tabs go empty

`fetchSessions` is currently only called by `toggleHistory`. It must also run
when the empty-tabs state is entered, in two situations:

- Selecting a worktree that already has no tabs.
- Closing the last open tab of the currently selected worktree.

Add a trigger in `TerminalContainerView` (`.task(id: worktreeTabs.isEmpty)`)
that, whenever tabs become empty on a non-`.main` worktree, calls
`appState.fetchSessions(worktreeID:)`. The fetch runs unconditionally on each
empty-tabs transition (not gated on `.idle`) so the history list is refreshed
after closing a tab — `fetchSessions` keeps any prior data visible via
`.loadingStale` while it revalidates, so this never flashes the placeholder.

`.main` worktrees auto-create a terminal when empty (existing
`.task(id: worktreeID)` logic), so they never sit in the empty state and need no
session fetch.

### 4. Unchanged

- The explicit history toggle, `HistoryPaneView`, and Resume/Revive flows are
  untouched. Resuming a session adds a tab → `activeTab` becomes non-nil → the
  terminal shows.
- The "No terminals" VStack stays as-is, now reachable only via the
  `.loaded([])` and `.failed` cases.

## Testing

- Worktree with past sessions, all tabs closed → history pane shown, history
  button not highlighted.
- Worktree with no past sessions, all tabs closed → "No terminals" empty state.
- Closing the last tab of a worktree with sessions → history pane appears.
- Creating a terminal from the empty-state tab bar `+` menu → terminal shows,
  history pane dismissed.
- `.main` worktree with no tabs → auto-creates a terminal, no history pane.
- Explicit history toggle still works while tabs are open.
