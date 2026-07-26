# Drag-and-drop reordering in the pinned worktree dock

**Status:** design approved 2026-07-26, not yet implemented.
**Depends on:** the pinned dock ([PR #517](https://github.com/cheapsteak/tbd/pull/517),
spec [`2026-07-26-pinned-worktree-dock-design.md`](2026-07-26-pinned-worktree-dock-design.md)).
Ships as a follow-up PR once #517 merges.

## Problem

The dock orders pins by `pinnedAt` ascending — oldest pin first, new pins append. That order
records *when* you pinned things, which has nothing to do with how you want to see them. With
the cap at five visible rows, the pins you use most can sit below the scroll line purely
because you pinned them first.

Drag-to-reorder was deliberately out of scope in the dock's original spec. This adds it.

## Solution

Drag a pinned row to reorder the dock. The order persists, survives restarts, and is never
disturbed by pinning something new — a fresh pin still appends to the end.

**Only top-level pinned rows are draggable.** Expanded children are derived from
`parentWorktreeID`, not stored as pins; dragging one would either mean nothing or imply
re-parenting, which is a different and much riskier feature. Children move with their parent.
The Watch Desk slot is a separate view and is not draggable at all.

## Architecture

### Storage — a dedicated column

Migration `v64_worktree_pin_sort_order` adds a nullable `pinSortOrder INTEGER` to `worktree`,
through `addColumnIfMissing` per `Database/CLAUDE.md`.

**Re-check that number at implementation time.** `v64` assumes #517's `v63_worktree_pinned_at`
is the highest when this lands. Main is currently taking migration numbers faster than this
branch can — #517's own migration was authored as `v60` and had to be renumbered to `v63` on
rebase after three others landed first. Read the tail of `Database.swift` and take the next
free number. This is cheap precisely because the body uses `addColumnIfMissing`: per
`Database/CLAUDE.md`, renumbering an additive migration bricked the daemon twice before those
helpers existed, and now just no-ops on a database that already ran it.

`Worktree.sortOrder` already exists but is **not** reusable: it drives repo-section tree
ordering via `worktree.reorder`, so writing pin order into it would scramble the sidebar every
time you reordered the dock. The two are different orderings of different lists — the sidebar's
is per-repo and hierarchical, the dock's is flat and global.

Rewriting `pinnedAt` timestamps to encode order was rejected for the same class of reason: it
would make `pinnedAt` a sort key wearing a timestamp's clothes, leaving "when did I pin this?"
permanently unanswerable.

Three changes in **one commit**, per the migration rule in the root `CLAUDE.md`:

1. `Sources/TBDDaemon/Database/Database.swift` — the migration.
2. `Sources/TBDDaemon/Database/WorktreeStore.swift` — `WorktreeRecord.pinSortOrder: Int?`,
   threaded through `init(from:)` and `toModel()`.
3. `Sources/TBDShared/Models.swift` — `Worktree.pinSortOrder: Int?`, optional so existing rows
   and cached JSON still decode.

### Ordering, and why there is no backfill

`PinnedDockContent.rows` sorts by `pinSortOrder` ascending, **falling back to `pinnedAt`** for
rows whose column is still `NULL`:

```swift
.sorted { lhs, rhs in
    switch (lhs.pinSortOrder, rhs.pinSortOrder) {
    case let (l?, r?):   return l < r
    case (nil, _?):      return false          // unordered sorts after ordered
    case (_?, nil):      return true
    case (nil, nil):     return (lhs.pinnedAt ?? .distantPast) < (rhs.pinnedAt ?? .distantPast)
    }
}
```

Existing pins therefore keep their current visual order the moment the migration lands, with no
backfill `UPDATE` and no flicker. The first drag assigns real values to everything.

Pinning assigns `max(pinSortOrder) + 1` so a new pin appends and never disturbs a curated order.

### RPC

`worktree.reorderPins` with `WorktreeReorderPinsParams { worktreeIDs: [UUID] }` — the pinned
worktrees in display order. The handler mirrors `ModelProfileStore.reorder` almost verbatim:
write `index` for each id in the list, then push anything absent to `count + rowid` so rows the
client did not know about land after the ordered ones rather than colliding at the same value.

Global, no repo scoping — the dock is one flat cross-repo list, so this matches
`modelProfile.reorder` rather than the repo-scoped `worktree.reorder`.

### View — the nested `ForEach` this requires

`.onMove` hands the handler indices into **its own `ForEach`'s elements**. `PinnedDockView`
currently iterates a *flat* `[PinnedDockRow]` that already contains expanded children, so
attaching `.onMove` there would move the wrong row whenever a subtree is expanded.

`RepoSectionView` already solves this: its `ForEach` iterates top-level worktrees and each
element renders a whole subtree via `WorktreeSubtreeView`, so move indices line up with roots.
`PinnedDockView` adopts the same shape:

```swift
ForEach(pinnedRoots) { root in
    ForEach(PinnedDockContent.subtree(of: root, in: rows)) { row in
        WorktreeRowView(worktree: row.worktree,
                        indentLevel: row.depth,
                        sectionRepoID: row.sectionRepoID)
            .tag(row.worktree.id)
    }
}
.onMove { source, destination in
    appState.reorderPins(fromOffsets: source, toOffset: destination)
}
```

The outer `ForEach` carries `.onMove`; the inner emits the root plus its expanded descendants.
`PinnedDockContent` keeps returning its flat `[PinnedDockRow]` — its existing tests stay valid —
and gains a `subtree(of:in:)` helper that slices the contiguous run belonging to one root.

### App state

`AppState.reorderPins(fromOffsets:toOffset:)` mirrors `reorderTopLevelWorktrees`
(`AppState+Worktrees.swift:785`):

1. Snapshot the current pinned roots in display order — the same order the `ForEach` rendered.
2. **Guard against stale indices.** `source`/`destination` can outlive the snapshot they were
   captured against; if `source` contains an out-of-range index or `destination` exceeds the
   count, log a warning and return rather than crashing. The existing method does exactly this,
   and it is not theoretical — a pin can be removed by another surface mid-drag.
3. Apply `move(fromOffsets:toOffset:)` to derive the new order.
4. Update local state optimistically so the row lands under the cursor immediately.
5. Persist via `worktree.reorderPins`; on failure, roll back to the snapshot and alert.

Optimistic update is right here, unlike `setPinned`, because the client knows the entire
resulting order rather than depending on a daemon-assigned timestamp.

## Feature flag

**None.** The root `CLAUDE.md` requires a default-off flag for behavior that acts without a user
gesture, destroys state, or wholesale-replaces a load-bearing path. This is additive UI on an
existing surface, driven entirely by an explicit drag, replacing nothing that carries load — the
"small additive UI" exemption. Worst case for a bug is a wrong visual order, fixed by dragging
again.

## Testing

**`PinnedDockContentTests`** (extend)
- Rows sort by `pinSortOrder` ascending when every pin has one.
- Rows with `pinSortOrder == nil` sort after rows that have one.
- Two `nil` rows fall back to `pinnedAt` order — the no-backfill guarantee.
- `subtree(of:in:)` returns exactly the root plus its descendants, and just the root when
  collapsed.

**`WorktreeStore` (daemon)**
- `v64` adds the column; pre-existing rows read back `nil`.
- `reorderPins` writes `0..<n` in list order.
- A pinned worktree absent from the list is pushed after the ordered ones, not left colliding.
- Round-trip of a non-nil and a nil `pinSortOrder`.

**`AppState.reorderPins`**
- A move produces the expected resulting order.
- An out-of-range `source` index returns without mutating state (the stale-index guard).
- A `destination` beyond the count returns without mutating state.

**Live**
- Drag a pin from bottom to top; order holds across an app restart.
- Drag with a subtree expanded — the parent moves with its children, and the correct row moves.
- Pin something new: it appends at the end, leaving the curated order untouched.
- Drag with more than five pins, so the dock is scrolled and capped.

## Out of scope

- Reordering expanded children, or drag-to-re-parent.
- Dragging a worktree *into* the dock from the repo list to pin it. Pinning stays the gutter
  button and the context menu.
- Dragging the Watch Desk slot.
- A CLI equivalent. The RPC makes one trivial later.
