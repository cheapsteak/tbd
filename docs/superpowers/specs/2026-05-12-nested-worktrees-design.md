# Nested Worktrees Design

Add one level of parent/child nesting to TBD's per-repo worktree list, so that worktrees spawned from inside another worktree's session appear indented under their spawner instead of dumped at the end of the flat list. Nesting is also user-controllable via drag-and-drop.

## Goals

- A worktree can have at most one parent worktree (depth-1 cap).
- New worktrees created by `tbd worktree create` from inside a TBD-managed terminal automatically attach to a sensible parent (the group head of where the CLI was invoked).
- Users can manually reorder and re-parent worktrees by drag-and-drop in the sidebar, including promoting a child back to flat.
- Parents and their children move as a unit when dragged.
- Archiving a parent that still has active children is blocked, not cascaded.

## Non-goals

- Multi-level nesting. The cap is one level for now; deeper hierarchies are out of scope.
- Cross-repo lineage. Parent and child must live in the same repo.
- Nesting under the `main` worktree. Main remains a special row that cannot be a parent.
- Drag-and-drop in the CLI or in `worktree list` JSON output.
- Changing how `sortOrder` is stored on disk beyond what depth-1 nesting requires.

## Data model

### `Worktree` (TBDShared/Models.swift)

Add one nullable field:

```swift
public var parentWorktreeID: UUID?
```

Decoded with `decodeIfPresent` so older JSON / older DB rows still load.

Invariant (enforced everywhere it can be written): if `parentWorktreeID != nil`, the referenced worktree exists in the same repo, has `parentWorktreeID == nil`, and is not the `main` worktree.

### `sortOrder` semantics

`sortOrder` becomes scoped *within siblings*:

- Top-level worktrees (parent nil) are ordered by `sortOrder` relative to each other.
- Children of a given parent are ordered by `sortOrder` relative to each other.
- Sort orders across levels are independent. No global ordering is implied.

The existing column is reused; no schema change beyond the new parent column.

### Migration

Add migration `v10` (or next available) in `Sources/TBDDaemon/Database/Database.swift`:

- `ALTER TABLE worktrees ADD COLUMN parent_worktree_id TEXT NULL`.
- No backfill — all existing rows become top-level (parent nil), which preserves current behavior.

Update the GRDB record type in `Sources/TBDDaemon/Database/` to include the new column, and update the Codable model in `TBDShared/Models.swift` in the same commit (per CLAUDE.md rule on DB-column changes).

## CLI: auto-parent on create

`Sources/TBDCLI/Commands/WorktreeCommands.swift::WorktreeCreate` adds two flags and one auto-detect step:

- `--no-parent` (boolean) — force top-level, ignore env.
- `--parent <id-or-name>` — explicit parent override. Resolved server-side; rejected if it points to a different repo, to `main`, or to a worktree that already has a parent.

Auto-detect, when neither flag is set and `TBD_WORKTREE_ID` is present in env:

1. Resolve the env value to a worktree (via daemon — same lookup path as `tbd link`).
2. If the resolved worktree is in the same repo as the new worktree *and* is not `main`:
   - If its own `parentWorktreeID == nil`, use it as the new parent.
   - Otherwise, use *its* `parentWorktreeID` as the new parent ("group-head rule").
3. Otherwise (cross-repo, missing, archived, or `main`), do not auto-parent.

The CLI just forwards `parentWorktreeID` in `WorktreeCreateParams`; the auto-detect logic can live either in the CLI or in the daemon. Putting it in the daemon (server-side resolution from `TBD_WORKTREE_ID` passed as a param) keeps validation and group-head lookup in one place and avoids duplicating the rule across clients. **Decision:** the daemon does the resolution. The CLI passes an optional `callerWorktreeID` taken from env; the `--parent` and `--no-parent` flags override that.

### RPC change

`WorktreeCreateParams` (TBDShared/RPCProtocol.swift) gains:

```swift
public var parentWorktreeID: UUID?      // explicit, from --parent
public var callerWorktreeID: UUID?      // from TBD_WORKTREE_ID, used for auto-parent
public var suppressAutoParent: Bool     // from --no-parent
```

Resolution order in `worktree.create`:

1. If `suppressAutoParent`, ignore both `parentWorktreeID` and `callerWorktreeID`. New worktree is flat.
2. Else if `parentWorktreeID` is set, validate (same repo, not main, target's parent is nil) and use it. Reject with an error on violation.
3. Else if `callerWorktreeID` is set and refers to a valid same-repo non-main worktree, apply the group-head rule.
4. Else: flat.

The new worktree is appended to its sibling group (highest existing `sortOrder + 1` within its parent scope).

## App: sidebar rendering

`Sources/TBDApp/Sidebar/RepoSectionView.swift`:

Inside `body` under `if repo.expanded`, replace the single `ForEach(worktrees)` block with a two-pass render:

```swift
let active = (appState.worktrees[repo.id] ?? [])
    .filter { $0.status == .active || $0.status == .creating }
let topLevel = active.filter { $0.parentWorktreeID == nil }
                     .sorted { $0.sortOrder < $1.sortOrder }
let childrenByParent = Dictionary(grouping: active.filter { $0.parentWorktreeID != nil },
                                  by: { $0.parentWorktreeID! })
```

For each top-level worktree, render its row, then `childrenByParent[id]` sorted by `sortOrder`, each with an additional 12pt of leading inset (so children sit at total leading ~24pt vs. ~12pt for flat).

The `main` worktree continues to render separately at the top of the section with its existing `isMain: true` styling. It cannot be a parent, so no special handling is needed beyond the validation rules above.

There is no per-parent chevron — children are always visible whenever the repo section is expanded. (Depth-1 + typical group sizes of 1–4 make collapse unnecessary; the existing repo-level chevron already provides bulk hide/show.)

### Archive UI on parents

In `SidebarContextMenu.swift` (or wherever the worktree row's Archive menu item is built), check whether the worktree has any active children:

```swift
let hasActiveChildren = (appState.worktrees[repo.id] ?? [])
    .contains { $0.parentWorktreeID == worktree.id && ($0.status == .active || $0.status == .creating) }
```

If `hasActiveChildren`, render the Archive menu item with `.disabled(true)` and `.help("Archive nested worktrees first")` so hovering shows the reason.

On the CLI side, `tbd worktree archive` returns an error from the daemon with the same message — discoverable, no surprise cascade.

## Drag and drop

The existing `.onMove { source, destination in appState.reorderWorktrees(...) }` on the worktree `ForEach` is replaced because `.onMove` exposes only source/destination offsets, not local drop coordinates or a way to disambiguate "between rows" from "on a row."

### Mechanic

Each worktree row gets:

- `.draggable { WorktreeDragPayload(id: worktree.id) }` — provides the drag source. Use a custom `Transferable` carrying the UUID.
- An overlay or `.dropDestination(for: WorktreeDragPayload.self)` that receives drops and reads `DropInfo.location.y` against the row's bounds to pick a band.

The dragged ghost uses the system default (a snapshot of the row that tracks the cursor unchanged — no indent animation on the ghost).

### Drop bands per row

Computed as fractions of the row's height:

| Drop target | Y band | Action |
|---|---|---|
| Flat childless row | top 25% | reorder above target at flat depth |
| Flat childless row | middle 50% | nest under target (becomes its first child) |
| Flat childless row | bottom 25% | reorder below target at flat depth |
| Flat parent row | top 25% | reorder above target at flat depth |
| Flat parent row | middle 50% | append to target's group as last child |
| Flat parent row | bottom 25% | insert as **first** child of target (the parent's bottom edge is visually adjacent to its first child's top, so this band falls inside the group rather than "below the whole subtree at flat depth") |
| Child row | top 50% | reorder above target within group |
| Child row | bottom 50% | reorder below target within group |

To insert a new flat worktree below an expanded parent's whole subtree, drop on the *top band of the next flat row* (or the empty space at the bottom of the repo section).

Child rows have no middle band; rule 2a ("drop on a child = join group") is satisfied implicitly by the top/bottom bands at indented depth.

### Drop validation (rejects)

A drop is rejected (no-op, no feedback shown as a valid target) when:

- The dragged worktree has active children *and* the action would put it at any non-flat position. Parents with children can only land flat. (Rule 3a.)
- The drop target is a descendant of the dragged worktree (prevents cycles — trivially true at depth-1 but still guarded).
- The drop target is in a different repo.
- The drop target is the `main` worktree and the action would be "nest under main."

### Group drag

When a parent worktree is dragged, its children come along. Implementation: the daemon-side `worktree.move` handler updates the `sortOrder` of the parent and shifts the parent's children to the new location in a single transaction. Children's `parentWorktreeID` stays the same; only `sortOrder` of surrounding flat-level worktrees changes.

In SwiftUI, the dragged ghost only shows the parent row (system default). That's acceptable visually — the group "snaps" into place after the drop. Custom multi-row ghost rendering is out of scope for v1.

### Visual feedback during drag

While a drop target is valid:

- **Nest action (middle band on a flat row)**: target row gets a full-row tint (e.g., `Color.accentColor.opacity(0.15)`).
- **Reorder action (any other valid band)**: an insertion line appears between rows at the depth where the item will land — flat depth for flat-level drops, indented depth for child-level drops. Line is rendered as a thin colored rectangle (e.g., 2pt tall, `Color.accentColor`) overlaying the row gap.

While a drop target is invalid: no visual; the row passes the drag through.

## RPC

Two changes to TBDShared/RPCProtocol.swift:

### `WorktreeCreateParams`

Adds `parentWorktreeID`, `callerWorktreeID`, `suppressAutoParent` as described above. All optional/defaulted so older clients still work.

### Replace `worktree.reorder` with `worktree.move`

Today's `worktree.reorder` only supports same-level offset shuffling. Replace it (or add alongside and deprecate) with:

```swift
public static let worktreeMove = "worktree.move"

public struct WorktreeMoveParams: Codable, Sendable {
    public let worktreeID: UUID
    public let newParentID: UUID?    // nil = top-level
    public let newSortOrder: Int     // position within the new sibling group
}
```

The handler validates depth cap, same-repo, not-main, not-descendant; updates `parentWorktreeID` and `sortOrder` for the moved worktree; renumbers surrounding siblings in the destination group to make room; and if a parent moves between flat positions, shifts its children's adjacent flat siblings together.

### State delta

Add `worktreeMoved` to `StateDelta.swift` carrying the worktree id, new parent id, and new sort order. Existing `worktreeReordered` is removed (or kept as an alias emitting the new delta) so subscribed clients update consistently.

## Daemon-side validation

In `WorktreeStore` / `WorktreeLifecycle`:

- `create`: applies the parent-resolution order above. On validation failure, returns an RPC error.
- `move`: enforces depth cap, cycle prevention, same-repo, not-main, dragged-parent-only-lands-flat. Returns RPC error on violation.
- `archive`: if the target has any active or creating children, returns an RPC error: "Archive nested worktrees first."

These rules also serve as the safety net for the app — if the UI ever offered an action by mistake, the daemon refuses.

## Files touched

- `Sources/TBDShared/Models.swift` — add `parentWorktreeID` to `Worktree`.
- `Sources/TBDShared/RPCProtocol.swift` — extend `WorktreeCreateParams`; add `worktreeMove` + `WorktreeMoveParams`.
- `Sources/TBDShared/StateDelta.swift` — add `worktreeMoved` payload.
- `Sources/TBDDaemon/Database/Database.swift` — v10 migration adding `parent_worktree_id`.
- `Sources/TBDDaemon/Database/WorktreeStore.swift` — record type update; new `move` method; archive guard.
- `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Create.swift` — parent resolution (auto + explicit) and validation.
- `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Archive.swift` — refuse archive when active children exist.
- `Sources/TBDDaemon/Server/RPCRouter+WorktreeHandlers.swift` — wire `worktree.move`; extend create handler.
- `Sources/TBDCLI/Commands/WorktreeCommands.swift` — `--parent`, `--no-parent`; pass `TBD_WORKTREE_ID` as `callerWorktreeID`.
- `Sources/TBDApp/DaemonClient.swift` — call `worktree.move`; extend create call.
- `Sources/TBDApp/AppState+Worktrees.swift` — replace `reorderWorktrees` with a move method that takes a new parent.
- `Sources/TBDApp/Sidebar/RepoSectionView.swift` — two-pass render (top-level + grouped children).
- `Sources/TBDApp/Sidebar/WorktreeRowView.swift` — accept an `indentLevel` (or `isChild`) parameter; expose drop-target bands.
- `Sources/TBDApp/Sidebar/SidebarContextMenu.swift` — disable Archive on parents-with-children with tooltip.

## Tests

- DB: round-trip a worktree with and without `parentWorktreeID`; migration leaves existing rows with NULL parent.
- Daemon create: covers each branch of the parent-resolution order, including `--no-parent` overriding env, `--parent` overriding env, cross-repo `callerWorktreeID` ignored, group-head rule when caller is a child.
- Daemon move: depth-cap violation rejected; cycle rejected; cross-repo rejected; main-as-parent rejected; dragged-parent-with-children-going-non-flat rejected; valid moves update `sortOrder` and `parentWorktreeID` and emit `worktreeMoved`.
- Daemon archive: refuses when active children exist; succeeds when children are all archived; succeeds for leaf and top-level-without-children.
- CLI: `--parent`, `--no-parent`, env-driven auto-parent, group-head fallback when caller has a parent.
- App snapshot or unit test of sidebar ordering: top-level + nested rendering, correct indent, parent and children move together when sort orders change.

## Open questions

None — all design questions resolved through brainstorming. Edge cases (cross-repo CLI, child caller, parent with children, main worktree) are explicitly handled by the rules above.
