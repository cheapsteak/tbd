# Terminal Pane Pinning & Dock

## Problem

Pinned worktrees keep worktrees visible across sessions, but there's no way to keep a specific terminal pane visible when navigating between worktrees. Users working across multiple worktrees often want to reference a terminal from one worktree while working in another.

## Solution

Add terminal pane pinning with a persistent dock. Pinned terminals appear in a right-side dock alongside whatever worktree the user is viewing. The dock hides pinned terminals whose home worktree is already visible (no duplication).

## Data Model

### Database Migration

Add a nullable `pinnedAt` column (ISO 8601 timestamp) to the `terminal` table (migration v5). NULL = not pinned, timestamp = pinned at that time. Sort by `pinnedAt ASC` for ordering within the dock.

### Shared Model

Add `pinnedAt: Date?` to the `Terminal` struct in `Models.swift`. Optional field, so existing data decodes without issue.

### RPC

New `terminal.setPin` method with params `{ terminalID: UUID, pinned: Bool }`. Sets or clears `pinnedAt` and broadcasts a `terminalPinChanged` state delta.

### AppState

Computed property `pinnedTerminals: [Terminal]` — all terminals across all worktrees where `pinnedAt != nil`, sorted by `pinnedAt ASC`. Derived from the existing `appState.terminals[worktreeID]` dictionary; no separate storage needed.

## Layout Behavior

### Single Worktree Selected

The content area splits into two regions when pinned terminals from other worktrees exist:

- **Left:** Normal single-worktree view — tab bar, split layout, full controls. Unchanged.
- **Right:** Pinned terminal dock — pinned terminals stacked vertically, each with a header.

**Filtering rule:** Pinned terminals whose home worktree IS the currently viewed worktree are excluded from the dock. They are already visible in-place within the worktree's own layout. This means:

- Pinned terminals from only THIS worktree → no dock, full-width worktree view.
- Pinned terminals from only OTHER worktrees → dock appears on the right.
- Pinned terminals from BOTH → dock shows only those from other worktrees.

### Multi-Worktree Selected (Cmd+Click / Worktree Pins)

The dock still appears on the right if there are pinned terminals from worktrees NOT in the current grid selection. Same filtering rule: if a pinned terminal's home worktree is visible in the grid, it's excluded from the dock.

- All pinned terminals' home worktrees are in the grid → no dock.
- Some pinned terminals' home worktrees are NOT in the grid → dock appears.

### No Pinned Terminals

No dock renders. Full width goes to the main content (single-worktree or multi-worktree grid). No empty placeholder.

## Dock Layout

### Structure

A vertical column on the right side of the main content area. Multiple pinned terminals stack vertically within the dock, each getting equal height.

### Header Per Dock Cell

`[pin icon (filled)] [worktree display name]` — left-aligned, compact, same styling as multi-worktree grid headers.

### Sizing

Default 70/30 split between main content and dock. User can drag the divider to resize. The dock/content ratio is persisted in UserDefaults (same pattern as layout persistence).

## Pane Header Changes

### Current

Pane headers display the terminal ID, which is not useful to the user.

### New

Replace the terminal ID with a pin icon:

- **Unpinned terminal:** Pin icon appears on hover only (outline style). Click pins the terminal.
- **Pinned terminal:** Pin icon always visible (filled style). Click unpins the terminal.

Pin icon appears at the left-most position. When displayed in the dock, the worktree display name appears to the right of the pin icon.

When displayed within the home worktree's own layout, no worktree name is shown (context is obvious).

## Non-Goals

- Configurable dock position (left/right/top/bottom) — start with right only, make configurable later
- Configurable stacking direction (horizontal/vertical) — start with vertical stacking, make configurable later
- Drag-to-reorder within the dock
- Pinning non-terminal pane types (webview, codeViewer)
