# Worktree Pinning & Ordered Split View

## Problem

Multi-selected worktrees in split view render in arbitrary order because selection uses an unordered `Set<UUID>`. Users also have no way to persistently keep certain worktrees visible — every session starts with an empty selection.

## Solution

Add worktree pinning (persistent, ordered) and change the selection model from `Set<UUID>` to `[UUID]` so split view respects pin/click order.

## Data Model

### Database Migration

Add a nullable `pinnedAt` column (ISO 8601 timestamp) to the `worktree` table. `NULL` means not pinned; a timestamp means pinned at that time. Sort by `pinnedAt ASC` for pin order.

### Shared Model

Add `pinnedAt: Date?` to the `Worktree` model in `Models.swift`. Optional field, so existing data decodes without issue.

### AppState

Change `selectedWorktreeIDs: Set<UUID>` to `selectedWorktreeIDs: [UUID]`. Call sites update accordingly:
- `.contains()` stays the same (Array has contains)
- `.insert()` becomes `append()` with a guard against duplicates
- `.remove()` becomes `.removeAll(where:)`

## Selection Behavior

### App Launch

Query worktrees where `pinnedAt IS NOT NULL`, sorted by `pinnedAt ASC`. Populate `selectedWorktreeIDs` with these IDs in that order.

### Cmd+Click (Unpinned Worktree)

Append to `selectedWorktreeIDs` if not present; remove if already present.

### Cmd+Click (Pinned Worktree)

No-op. Pinned items cannot be deselected via cmd+click. User must unpin first.

### Regular Click

Replace selection with just that worktree: `selectedWorktreeIDs = [worktree.id]`. Pinned items remain pinned in the DB but aren't forced into the selection during manual single-select. Pins reassert on next app launch.

### Pinning a Worktree

Sets `pinnedAt` to current timestamp. If the worktree is not in `selectedWorktreeIDs`, insert it at the correct position — before any unpinned items, sorted by `pinnedAt` among other pins.

### Unpinning a Worktree

Sets `pinnedAt` to NULL. The worktree stays in `selectedWorktreeIDs` at its current position but loses cmd+click removal protection.

## Split View Ordering

`MultiWorktreeView` uses `selectedWorktreeIDs` directly (no Set-to-Array conversion needed). The array order is:

1. Pinned worktrees, sorted by `pinnedAt ASC`
2. Manually cmd+clicked worktrees, in click order

Grid layout logic (column count based on total count) is unchanged.

## Pin Icon

### Hover Behavior

- Appears on the very left of the worktree row
- **Pinned items:** pin icon always visible, filled style
- **Unpinned items:** pin icon appears on hover only, outline style
- Click toggles pin state via daemon RPC

### Overlay Integration

The pin icon lives inside the row content (not in the overflow overlay), so it scrolls and clips naturally with the row. Care must be taken to integrate with the existing overlay system for overflowing sidebar items.

## Context Menu

Add "Pin" / "Unpin" item to the existing worktree right-click context menu. Label reflects current pin state.

## RPC

New `setWorktreePin` method with params `{ worktreeID: UUID, pinned: Bool }`. Sets or clears `pinnedAt` and broadcasts a state delta so the app updates immediately.

## Non-Goals

- Drag-to-reorder in split grid
- Reordering pinned items in the sidebar
- Persisting non-pin selection state across sessions
