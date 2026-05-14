# Unread Jump Menu — Design

A Slack-style cmd-K floating panel that surfaces worktrees with unread notifications, falls back to recently-visited worktrees, and acts as a fuzzy quick-switcher when the user types.

## Summary

cmd-K opens a borderless overlay anchored to the main TBD window. Default state lists unread worktrees (most-recent-notification first), then recents (LRU). The top item is pre-selected so cmd-K → enter jumps the user to whatever is asking for attention. Typing turns the panel into a fuzzy quick-switcher across all worktrees. The list is capped at 20 rows.

## Motivation

A user running 6–10 agents needs a one-keystroke-after-the-shortcut way to triage worktrees needing attention. Today they scan the sidebar for severity badges and click. With this feature, the happy path is cmd-K → enter → the most-recently-pinged worktree is focused. The shortcut becomes the user's triage inbox, with a recents fallback for the idle case and a quick-switcher when they want to navigate by name.

## User Experience

### Trigger and panel

- **cmd-K** toggles the panel. Pressing it while open closes it.
- The panel is a borderless floating overlay built on the existing `FloatingPanel` (NSPanel subclass, `.popUpMenu` level, non-activating, no shadow).
- Width ~440pt, anchored above-center of the key TBD window. Height fits content up to a scroll-limited maximum.
- A search field sits at the top with placeholder `Jump to worktree…` and is auto-focused on open.
- A scrollable list sits below the search field. The list shows at most **20 rows** at any time.

### Default state (empty query)

Two sections, in order:

- **Unread** — worktrees with unread notifications, sorted by most-recent notification timestamp, descending.
- **Recent** — worktrees recently visited (LRU), most-recent first, excluding anything already in Unread.

Section headers are visible when there's content in each section. Combined cap = 20 rows. Unreads fill first; if there are more than 20 unreads, Recents drop off entirely.

### Typed query

- Section headers disappear; the list flattens into a single ranked match list.
- Match scope expands to **all worktrees**, not just unreads + recents.
- Match rule: case-insensitive substring on worktree display name **and** repo name (either matches). Simple v1; fzf-style scoring deferred.
- Max 20 results.

### Empty states

- Typing with no matches → "No matching worktrees".
- Default state with zero unreads and zero recents (fresh install, first launch) → "No recent activity".

### Row content

A single dense line per row:

```
[severity dot] [emoji] Worktree Name        repo-name    2m
```

- **Severity dot** (left): red = error, orange = attentionNeeded, blue = taskComplete, green = responseComplete. Hidden when the worktree has no unread notification.
- **Emoji + name**: the worktree's display name (with its leading emoji).
- **Repo name** (inline after the worktree name, dim): the repo this worktree belongs to.
- **Time-ago** (far right of the row, dim): for Unread rows, time since the most-recent notification; for Recent rows, time since last visit. Suppressed while typing (the filter takes the user out of recency-browsing mode).
- **Selected row** uses the system accent color at low opacity for its background.

## Keyboard Model

| Key | Action |
|---|---|
| cmd-K | Toggle the panel |
| Up / Down | Move selection within the visible list |
| Enter | Jump to the selected worktree, close the panel |
| Escape | Close the panel, no state change |
| Type | Filter the list |
| Backspace on empty query | No-op |

Jumping is implemented by mutating `appState.selectedWorktreeIDs = [target]`. The existing `selectedWorktreeIDs.didSet` machinery handles navigation history and the auto-mark-read pass for visible worktrees, so unread clearing requires no additional code.

## Data Model and RPC Changes

The current `listNotifications` RPC returns `[UUID: NotificationType]` — severity only, no timestamps. The menu needs timestamps to sort by recency.

### Daemon

Extend `NotificationStore` (in `Sources/TBDDaemon/Database/NotificationStore.swift`) with a method that returns one row per worktree containing the highest-severity unread type **and** the most-recent unread `createdAt`:

```swift
struct UnreadSummary {
    let type: NotificationType
    let mostRecentAt: Date
}

func unreadSummaryByWorktree() throws -> [UUID: UnreadSummary]
```

The SQL is a single GROUP BY query over the notifications table, joining/aggregating to pick max severity and max `createdAt` per `worktreeID` among unread rows.

### RPC

Extend the existing `listNotifications` RPC payload (rather than adding a parallel RPC) to carry `mostRecentAt` alongside the severity type. One round-trip, no new endpoint surface.

### App state

Migrate the existing field:

```swift
// before
@Published var notifications: [UUID: NotificationType?]

// after
@Published var unreadByWorktree: [UUID: UnreadSummary]
```

Update the only existing consumer — `WorktreeRowView`'s severity dot — to read `appState.unreadByWorktree[id]?.type` instead of the old field. One source of truth, no parallel shape.

## Recents — In-Memory LRU

### Why not derive from back/forward navigation

The cmd+[ / cmd+] back/forward stack is path-history with forward-clear-on-new-nav semantics:

```
visit A, B, C, D    → back: [A, B, C]   current: D   forward: []
press Back twice    → back: [A]          current: B   forward: [C, D]
jump to E from B    → back: [A, B]       current: E   forward: []   ← D dropped
```

Reading the back stack as "recents" makes D invisible even though the user was just there, and the ordering doesn't reflect actual last-visit per worktree. Different data structure for different semantics.

### Dedicated LRU

Add a small tracker in `AppState`, fed from the same `selectedWorktreeIDs.didSet` hook that already records nav history:

```swift
@Published private(set) var recentWorktreeIDs: [UUID] = []  // LRU, most-recent first

// inside selectedWorktreeIDs.didSet, after existing nav-history work:
if let id = selectedWorktreeIDs.first {
    recentWorktreeIDs.removeAll { $0 == id }
    recentWorktreeIDs.insert(id, at: 0)
    if recentWorktreeIDs.count > 32 { recentWorktreeIDs.removeLast() }
}
```

In-memory only. The list resets when the app relaunches. Slack behaves the same way; persistence is a future iteration if it ever turns out to matter.

The jump menu reads `recentWorktreeIDs`, filters out IDs already present in `unreadByWorktree` (no duplicates across sections) and IDs no longer in the worktree list (handles deletion), then takes the top N needed to fill the 20-row budget.

## Architecture

New module: `Sources/TBDApp/JumpMenu/`.

- **`JumpMenuController.swift`** — owns a `FloatingPanel` instance and the lifecycle around it. Exposes a singleton (or AppState-held instance) so the keyboard shortcut can call `toggle()`. Computes panel positioning relative to the current key window. Handles open / close / focus restoration on close.
- **`JumpMenuViewModel.swift`** — `@Observable` (or `ObservableObject` if the project's deployment target predates the new macro). Holds `query: String` and exposes a computed `rows: [JumpMenuRow]`. All ranking, capping, and fuzzy-match logic lives here so it can be unit-tested without the SwiftUI layer.
- **`JumpMenuView.swift`** — SwiftUI view: search field at top, list of rows below. Keyboard handling via `.onKeyPress` (macOS 14+) or a small `NSEvent.addLocalMonitorForEvents` shim if the deployment target is lower.
- **`JumpMenuRow.swift`** — small value type for a row's data plus its row view.

Wiring point: `Sources/TBDApp/Helpers/KeyboardShortcuts.swift` gains one new entry, likely in the existing **Go** menu:

```swift
Button("Jump to Unread") { JumpMenuController.shared.toggle() }
    .keyboardShortcut("k", modifiers: .command)
```

## Snapshot Semantics

The menu computes its row list once when opened. Notifications arriving while the panel is visible do **not** mutate the displayed list. Closing and reopening refreshes. Rationale: predictable selection, no rows shifting underneath the user's keyboard cursor mid-triage.

## Edge Cases and Open Risks

1. **cmd-K conflict in terminal panes.** SwiftUI Commands shortcuts normally take precedence over view-level key handlers, but if TBD's terminal emulator routes key events through a custom NSResponder chain that runs before menu validation, cmd-K could be swallowed before the menu sees it. Mitigation: verify during implementation. If the Commands route doesn't reach the menu reliably from a focused terminal, hoist registration to a global `NSEvent.addLocalMonitorForEvents` shim at app level.
2. **Tie-breaking on equal timestamps.** Two notifications recorded in the same millisecond — sort by worktree UUID lexicographically as the deterministic tiebreaker so the default-selected item is stable across opens.
3. **Worktree deletion while menu is open.** Static snapshot semantics mean a stale UUID may be in the list. Pressing enter on a missing UUID should be a no-op + close, not a crash. Filter the snapshot against the live worktree map at render time.
4. **Fuzzy match upgrade path.** v1 ships substring matching on name + repo. fzf-style scoring (initials, contiguous-run bonuses, etc.) is a drop-in inside `JumpMenuViewModel` later — the view doesn't need to know.
5. **Daemon disconnect / stale data.** If the daemon is unreachable when the menu opens, the displayed snapshot is whatever was last pushed to `unreadByWorktree`. Acceptable for a triage tool — no special error UI required.

## Out of Scope (v1)

- Persisting `recentWorktreeIDs` across app relaunches.
- "Mark all as read" or per-row mark-read actions from inside the menu.
- Cmd-Shift-Enter or other modifier-chord secondary actions.
- fzf-style fuzzy scoring.
- Multi-window or per-window menus — one menu, anchored to the key window.
- A configurable shortcut (cmd-K is hardcoded).
- Live updates while the menu is open.
