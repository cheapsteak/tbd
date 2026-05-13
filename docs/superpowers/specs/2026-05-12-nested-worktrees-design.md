# Nested Worktrees Design

Add parent/child nesting to TBD's worktree sidebar so that worktrees spawned from inside another worktree's session appear indented under their spawner instead of dumped at the end of the flat list. Nesting is multi-level, can cross repo boundaries, and is also user-controllable via drag-and-drop.

## Goals

- A worktree can have one parent worktree; arbitrary nesting depth is allowed.
- Parent and child can live in different repos. A child of a worktree in repo A renders under that parent inside repo A's sidebar section, regardless of which repo the child itself lives in.
- New worktrees created by `tbd worktree create` from inside a TBD-managed terminal automatically attach to their caller. Flags allow opting out, becoming a sibling, or setting an explicit parent.
- Users can manually reorder and re-parent worktrees by drag-and-drop in the sidebar, including promoting any child back to flat in its own repo.
- Parents and their entire subtrees move as a unit when dragged.
- Archiving a worktree that still has active children is blocked, not cascaded.

## Non-goals

- Per-parent collapse/expand of children. Children render whenever their containing repo section is expanded.
- A "lineage" filter or alternate view that flattens repos.
- Repo-changing drags. A worktree's home repo is determined by its on-disk location and `repoID`; drag-and-drop changes `parentWorktreeID` and `sortOrder` only.
- Drag-and-drop in the CLI or in `tbd worktree list` JSON output.

## Concepts

- **Home repo** of a worktree: the repo it physically lives in (`worktree.repoID`). Determined at create time, never changed by drag-and-drop.
- **Section repo** of a row: the repo whose sidebar section is currently rendering this worktree. Equal to the home repo of the worktree's top-level ancestor. May differ from the worktree's own home repo for cross-repo children.
- **Top-level worktree**: `parentWorktreeID == nil`. Lives in its own home repo's section.
- **Nested worktree**: any worktree with a non-nil parent. Rendered indented under its parent, recursively, regardless of repo crossings.
- **Subtree**: a worktree plus all its descendants.

## Data model

### `Worktree` (TBDShared/Models.swift)

Add one nullable field:

```swift
public var parentWorktreeID: UUID?
```

Decoded with `decodeIfPresent` so older JSON / older DB rows still load.

Invariants (enforced at every write site):

- If non-nil, the referenced worktree exists.
- The referenced worktree is not `main` (main cannot be a parent — it is a repo-root pin, not a task).
- The reference does not create a cycle (the referenced worktree is not a descendant of the current worktree).

There is **no** same-repo constraint and **no** depth cap.

### `sortOrder` semantics

`sortOrder` is scoped within siblings:

- Top-level worktrees in a given repo are ordered relative to each other.
- Children of a given parent are ordered relative to each other, regardless of any child's home repo.

Existing column is reused; no schema change beyond the new parent column.

### Migration

Add the next sequential migration (e.g. `v10`) in `Sources/TBDDaemon/Database/Database.swift`:

- `ALTER TABLE worktrees ADD COLUMN parent_worktree_id TEXT NULL`.
- No backfill — all existing rows become top-level. Behavior preserved for everyone.

Update the GRDB record type in `Sources/TBDDaemon/Database/WorktreeStore.swift` and the Codable model in `TBDShared/Models.swift` in the same commit (per CLAUDE.md rule on DB-column changes).

## CLI: auto-parent on create

`Sources/TBDCLI/Commands/WorktreeCommands.swift::WorktreeCreate` adds three mutually-exclusive flags governing parent attachment:

- `--no-parent` — force top-level, ignore env.
- `--sibling` — new worktree becomes a sibling of the caller (its parent equals the caller's own `parentWorktreeID`, which may be nil).
- `--parent <id-or-name>` — explicit parent override. Resolved server-side; rejected if the resolved worktree is `main` or if the parent assignment would create a cycle.

When none of the flags are passed and `TBD_WORKTREE_ID` is present in env, the CLI forwards that value as `callerWorktreeID`. The daemon then:

1. Resolves `callerWorktreeID` to a worktree. If the resolved worktree is missing or is `main`, falls back to top-level.
2. Otherwise, uses the resolved worktree as the new worktree's parent. (Multi-level: nest directly under the caller, regardless of caller's own depth.)

This rule fires across repos: a CLI in repo A creating a worktree in repo B auto-nests the new B-worktree under the A-worktree.

### RPC change

`WorktreeCreateParams` (TBDShared/RPCProtocol.swift) gains three optional fields:

```swift
public var parentWorktreeID: UUID?      // from --parent
public var siblingOfWorktreeID: UUID?   // from --sibling (the caller); daemon resolves to caller.parentWorktreeID
public var callerWorktreeID: UUID?      // from TBD_WORKTREE_ID (when no flag set)
public var suppressAutoParent: Bool     // from --no-parent
```

Resolution order in `worktree.create`:

1. If `suppressAutoParent` → flat (parent nil).
2. Else if `parentWorktreeID` set → validate (not main, no cycle) → use as parent.
3. Else if `siblingOfWorktreeID` set → resolve to that worktree's `parentWorktreeID` (which may be nil) → use as parent.
4. Else if `callerWorktreeID` set and resolves to a non-main worktree → use as parent.
5. Else → flat.

The new worktree is appended to its destination sibling group (highest existing `sortOrder + 1` within that group).

## App: sidebar rendering

`Sources/TBDApp/Sidebar/RepoSectionView.swift` switches from a flat per-repo list to a recursive render rooted at top-level worktrees.

### Layout

For each repo section that's expanded:

1. Render the `main` worktree row (existing styling, never indented, never a parent).
2. Collect this repo's **top-level worktrees**: all worktrees with `repoID == repo.id` and `parentWorktreeID == nil`. Sort by `sortOrder`.
3. For each top-level worktree, render it and recursively render its children. A child's children are looked up across all repos (a parent can have children whose `repoID` differs).

A recursive view `WorktreeSubtreeView(worktree, depth, sectionRepoID)` handles one node:

- Renders `WorktreeRowView(worktree, indentLevel: depth)`.
- Looks up `appState.children(of: worktree.id)` (a precomputed `[parentID: [Worktree]]` map across all repos, sorted by `sortOrder`).
- For each child, recurses with `depth + 1`.

`WorktreeRowView` accepts an `indentLevel: Int` parameter and applies `.padding(.leading, CGFloat(indentLevel) * 12)` (in addition to its existing 12pt leading for the repo section).

### Cross-repo indicator

When `worktree.repoID != sectionRepoID`, the row appends a muted suffix `(<sectionRepoName-of-its-home-repo>)` in `.caption` font and `.secondary` foregroundStyle after the worktree's display name. This is the only visual difference between same-repo and cross-repo nested rows.

(There is no double-render. A cross-repo child appears exactly once, under its parent.)

### Always expanded

There is no per-parent chevron. Whenever the repo section is expanded, the entire subtree under each top-level worktree renders. Indent depth grows without bound; cramping at depth 4+ is accepted for v1 and revisited if it becomes a problem in practice.

### Archive UI

In `Sources/TBDApp/Sidebar/SidebarContextMenu.swift`, the Archive menu item on a worktree row checks for any direct active children (across all repos):

```swift
let hasActiveChildren = appState.allWorktrees.contains {
    $0.parentWorktreeID == worktree.id
        && ($0.status == .active || $0.status == .creating)
}
```

If `hasActiveChildren`, the Archive item is `.disabled(true)` with `.help("Archive nested worktrees first")` so hover reveals the reason.

The CLI's `tbd worktree archive` returns the same error from the daemon — no tooltip surface, but the message is identical.

## Drag and drop

The existing `.onMove` on the worktree `ForEach` is removed because it can only express same-level offset reorders. Drag-and-drop is rebuilt on `.draggable` + `.dropDestination` so the handler can read drop coordinates and pick reorder vs. nest.

### Drag payload

Each row sources a drag of a `WorktreeDragPayload(id: UUID)` via a `Transferable` conformance.

### Drop bands

Per row, the handler reads `DropInfo.location.y` and converts it to a fraction of the row's height. The band layout depends on the *target* row's situation:

| Target row | Y band | Action |
|---|---|---|
| Top-level row, no children | top 25% | reorder above target at top-level (in its repo's section) |
| Top-level row, no children | middle 50% | nest under target (becomes its first child) |
| Top-level row, no children | bottom 25% | reorder below target at top-level |
| Top-level row, has children | top 25% | reorder above target at top-level |
| Top-level row, has children | middle 50% | append to target's child group |
| Top-level row, has children | bottom 25% | insert as target's **first** child (the parent's bottom edge is visually adjacent to its first child) |
| Nested row, no children | top 25% | reorder above target within target's parent group |
| Nested row, no children | middle 50% | nest under target (becomes its first child) |
| Nested row, no children | bottom 25% | reorder below target within target's parent group |
| Nested row, has children | top 25% | reorder above target within target's parent group |
| Nested row, has children | middle 50% | append to target's child group |
| Nested row, has children | bottom 25% | insert as target's **first** child |

To insert below an entire subtree at its top-level depth, drop on the *top band of the next top-level row* or on the empty area at the bottom of the repo section.

### Drop validation (rejects)

A drop is rejected (treated as no valid drop target; no feedback shown) when:

- The dragged worktree is the target.
- The dragged worktree is an ancestor of the target (would create a cycle).
- The target is the `main` worktree of any repo and the action would nest under it.

There is no rule against "parents being nested" — multi-level allows arbitrary subtree moves as long as no cycle results.

### Cross-section drops

Dragging a worktree from one repo's section to another repo's section is meaningful and permitted:

- Drop on a row in any repo's section → re-parents under that row (the dragged worktree's subtree now renders inside that row's section, even if the dragged worktree's home repo is different).
- Drop on the empty area at the bottom of a repo section → un-parents (`parentWorktreeID = nil`) **only if** the dragged worktree's home repo matches that section. Otherwise the drop is rejected. (Reason: un-parented worktrees render in their home repo's section, so dropping in a foreign repo's empty area would not put the row where the user gestured. Forcing the user to target their home repo's empty area keeps drop-position and outcome aligned.)
- The dragged worktree's `repoID` never changes via drag-and-drop.

### Group drag

When a node is dragged, its entire subtree comes with it. The dragged ghost shows only the dragged node (SwiftUI default); the subtree snaps into place after drop. Custom multi-row ghost rendering is out of scope for v1.

The daemon handles subtree moves transactionally: only the dragged node's `parentWorktreeID` and `sortOrder` change. Descendants keep their `parentWorktreeID` pointing at their existing parent within the subtree, and their `sortOrder` is unchanged. The visual relocation happens because the rendering walks parent pointers; no descendant rows need to be rewritten in the DB.

### Visual feedback

- **Valid nest target** (middle band of any row): target row gets a full-row tint (`Color.accentColor.opacity(0.15)`).
- **Valid reorder target** (top/bottom band of any row): a thin (2pt) accent-colored insertion line is drawn at the appropriate y-offset, indented to match the destination depth.
- **Invalid target**: no visual; the drag passes through.

## RPC

Two changes in `Sources/TBDShared/RPCProtocol.swift`:

### `WorktreeCreateParams`

Adds `parentWorktreeID`, `siblingOfWorktreeID`, `callerWorktreeID`, `suppressAutoParent` as described above. All optional/defaulted so older clients still work.

### Replace `worktree.reorder` with `worktree.move`

```swift
public static let worktreeMove = "worktree.move"

public struct WorktreeMoveParams: Codable, Sendable {
    public let worktreeID: UUID
    public let newParentID: UUID?    // nil = top-level (within worktreeID's home repo)
    public let newSortOrder: Int     // position within destination sibling group
}
```

The handler validates not-self, not-ancestor, not-nesting-under-main; updates the moved worktree's `parentWorktreeID` and `sortOrder`; renumbers surrounding siblings in the destination group to make room.

Existing `worktree.reorder` is removed (or kept as an alias emitting the same delta) so subscribed clients update consistently.

### State delta

Add `worktreeMoved` to `Sources/TBDShared/StateDelta.swift` carrying the worktree id, new parent id, and new sort order. Replaces `worktreeReordered`.

## Daemon-side validation

`Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Create.swift`:

- Applies the resolution order above.
- Validates the chosen parent (not main, not creating a cycle — trivially true at create time since the new worktree has no descendants, but the check is the same code path as `move`).
- Returns an RPC error on violation; the partially-created DB row is rolled back.

`Sources/TBDDaemon/Database/WorktreeStore.swift::move`:

- Enforces not-self, not-ancestor (walks `parentWorktreeID` upward from `newParentID`), not-main.
- Renumbers `sortOrder` within the destination group.
- Emits `worktreeMoved` after commit.

`Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Archive.swift`:

- Before archiving, checks for any active or creating direct children. Returns an RPC error "Archive nested worktrees first" on violation.

### Reconcile

`Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Reconcile.swift` should, at daemon startup, null out any `parentWorktreeID` that points to a missing or archived parent. This handles the rare case where the parent's row was removed out-of-band; the orphan becomes top-level in its own home repo.

## Files touched

- `Sources/TBDShared/Models.swift` — add `parentWorktreeID` to `Worktree`.
- `Sources/TBDShared/RPCProtocol.swift` — extend `WorktreeCreateParams`; add `worktreeMove` + `WorktreeMoveParams`.
- `Sources/TBDShared/StateDelta.swift` — add `worktreeMoved` payload, remove/alias `worktreeReordered`.
- `Sources/TBDDaemon/Database/Database.swift` — migration adding `parent_worktree_id`.
- `Sources/TBDDaemon/Database/WorktreeStore.swift` — record type update; new `move` method with cycle check; archive guard.
- `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Create.swift` — parent resolution.
- `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Archive.swift` — refuse archive when active children exist.
- `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Reconcile.swift` — null out parent references to missing/archived worktrees on startup.
- `Sources/TBDDaemon/Server/RPCRouter+WorktreeHandlers.swift` — wire `worktree.move`; extend create handler.
- `Sources/TBDCLI/Commands/WorktreeCommands.swift` — `--parent`, `--sibling`, `--no-parent`; pass `TBD_WORKTREE_ID` as `callerWorktreeID`.
- `Sources/TBDApp/DaemonClient.swift` — call `worktree.move`; extend create call.
- `Sources/TBDApp/AppState+Worktrees.swift` — replace `reorderWorktrees` with `moveWorktree(id:, newParentID:, newSortOrder:)`; expose `children(of:)` lookup map.
- `Sources/TBDApp/Sidebar/RepoSectionView.swift` — recursive subtree render.
- `Sources/TBDApp/Sidebar/WorktreeRowView.swift` — accept `indentLevel` and `sectionRepoID`; render `(repo-name)` suffix when home repo differs; expose drop bands.
- `Sources/TBDApp/Sidebar/SidebarContextMenu.swift` — disable Archive on parents-with-children with tooltip.

## Tests

- DB round-trip with and without `parentWorktreeID`; migration leaves existing rows with NULL parent.
- Daemon create: each branch of the resolution order, including `--no-parent` overriding env, `--sibling` resolving to caller's parent (nil and non-nil cases), `--parent` overriding env, missing/archived `callerWorktreeID` falls back to flat, main as `callerWorktreeID` falls back to flat, cross-repo caller succeeds.
- Daemon move: not-self, not-ancestor (multi-level cycle check), not-main; cross-repo move succeeds; sort-order renumber works at top-level and within a parent group; subtree moves don't touch descendants' DB rows.
- Daemon archive: refuses when active children exist (same-repo and cross-repo children); succeeds when children are all archived; succeeds for leaf nodes.
- Reconcile: parent pointer to a missing worktree gets nulled.
- CLI: `--parent`, `--sibling`, `--no-parent`, env-driven auto-parent, group-head behavior gone (direct caller used instead).
- App snapshot / unit test of sidebar ordering: top-level + nested rendering, correct indent levels at depth 1 and 2, cross-repo `(repo-name)` suffix appears only when section repo differs.

## Open questions

None — design questions resolved. Visual cramping at very deep nesting and the eventual need for per-parent collapse are noted as future work but not blockers for v1.
