# Native sidebar — the worktree list on NSOutlineView, with drag to nest

Status: design, approved for implementation planning
Date: 2026-10-31
Tracks: #142 (drag to nest)

This spec moves the app's sidebar from a SwiftUI `List` onto AppKit: an
`NSOutlineView` for the main list and an `NSTableView` for the pinned dock, both
drawn with native AppKit cells. On that foundation it adds the first feature the
`List` could not carry: dragging worktrees to nest, un-nest and reorder them at
any depth.

## Problem

The sidebar is one SwiftUI `List(selection:)` in
`Sources/TBDApp/Sidebar/SidebarView.swift`, with nesting drawn as leading
padding, plus a second `List` for the pinned dock. On macOS a `List` is backed by
an AppKit table, but SwiftUI exposes only part of that table, and the sidebar has
spent its life working around the gap:

- **Drag to nest cannot be built on it.** Issue #142 records eight failed
  attempts. On a `List` row, `.onMove` and `.draggable`/`.dropDestination` cannot
  coexist: the row-reorder drag wins and the drop callbacks never fire. And
  `.dropDestination` reports no location, so "onto this row" and "between these
  rows" cannot be told apart.
- **Reorder indices go stale.** `.onMove` hands back indices captured against an
  earlier snapshot. A daemon push between the capture and the callback crashed
  the app (#175), and every reorder site now carries a stale-index guard.
- **Silent failure modes.** Wrapping a root row in a bare `ForEach` stops AppKit
  from ever starting a drag session (#518). A tap gesture on a row swallows the
  mouse-down the table needs to start one (#83, #142).
- **Selection gaps.** The backing table has no selection anchor on a remote
  session row, so arrow-key traversal from one is not guaranteed.
- **Hover and hit-testing workarounds.** Rows carry near-transparent backgrounds
  to be hit-testable, `onHover(false)` can fail to arrive after a view is torn
  down, and scrolling to a newly expanded row must wait a run-loop turn for its
  rows to mount.
- **Render cost.** Field measurement on a sidebar of about 320 rows put 15% of
  stall samples in the `List`'s own diff (`OutlineListCoordinator.recursivelyDiffRows`).

`CLAUDE.md`'s "SwiftUI or AppKit: choose by the job" names this case: lists with
custom mouse interaction start in AppKit, all the way down to the cells.

The data side of nesting already exists and is unused. The daemon's
`worktree.move` RPC and `WorktreeStore.move` validate a new parent (not self, not
`main`, not archived, no cycle) and renumber the destination siblings. A move
that changes a remote row's parent sets `remote_parent_assigned`, so adoption
never re-nests a lane the user placed. `AppState.moveWorktree` has no caller.

## Goals

- The main sidebar list renders in an `NSOutlineView` and the pinned dock in an
  `NSTableView`, both with native AppKit cells.
- Drag to nest a worktree under another, to un-nest it, and to reorder siblings
  at any depth; reorder scratch spaces within their section; drag several
  selected rows at once.
- Everything else looks and behaves as it does today.
- The new sidebar ships behind a default-off flag, and the SwiftUI path runs
  unchanged while the flag is off.

## Non-goals

- Nesting across repos by drag. The CLI can still create such a nest.
- Dragging a row into the dock to pin it.
- Dragging unadopted remote sessions or any header.
- Reordering repos. `Repo` has no stored order.
- Collapsible worktree subtrees. They stay always expanded.
- Changing the footer (Add Repository, the filter menu), the profile picker
  panel, the emoji panel, popovers or sheets. None is a list; all stay SwiftUI.

## Scope

The native sidebar renders every row the SwiftUI sidebar renders:

- **Scratch section** – its header, scratch space rows, the "Click to create
  scratch space" prompt when there are none, and its Hibernated group.
- **Repo sections** – the header, the main row, nested worktree subtrees
  (including adopted remote lanes and cross-repo children), inline remote
  sessions, and the Ended, Remote, Exited and Hibernated groups, including the
  per-parent Remote and Exited groups.
- **Remote section** – provider headers, each provider's unmatched sessions, and
  their groups.
- **Pinned dock** – pinned roots, their subtrees while selected, remote pins, the
  height clamp (at most five rows and 40% of the list's height), and pin reorder.

`SidebarSectionLayout` and its flags (`sidebarWorkflowGroupsKey`,
`sidebarCollapseEndedSessionsKey`) decide which rows appear, exactly as today.

## Architecture

New code lives in `Sources/TBDApp/Sidebar/Native/`.

### Units

- **`SidebarTree`** – a pure value. Each `SidebarNode` has a stable
  `SidebarNodeID`, a kind and children. The kind carries an `Equatable` row model
  holding everything its cell draws. Kinds: scratch header, scratch prompt, repo
  header, worktree, remote session, provider header and group header. IDs come
  from identities that already exist: worktree, session and repo UUIDs, and
  `SidebarGroupID`.
- **`SidebarTreeBuilder`** – reads `AppState` and returns a `SidebarTree`. It
  reuses the existing pure types: `SidebarSectionLayout`, `RowStatusIndicator`,
  `PRBindingPresentation`, `PinnedDockContent` and the remote grouping in
  `SidebarRemoteGroups`. Work that SwiftUI row bodies repeat on every evaluation
  today runs here once per rebuild. Text needed only on hover, such as PR
  freshness tooltips, is computed when the pointer arrives, not per rebuild.
- **`SidebarOutlineController`** – an `NSViewController` that owns an
  `NSScrollView` and an `NSOutlineView` subclass, runs the update loop below, and
  acts as the outline's data source and delegate.
- **`SidebarItem`** – `NSOutlineView` identifies items by object identity, so the
  controller keeps one `SidebarItem` reference per `SidebarNodeID` across
  rebuilds. Each holds the node's latest value.
- **Cells** – one `NSTableCellView` subclass per kind. Each exposes only
  `configure(_ model:)` and never reads `AppState`. Cells are built in code, so
  each sets its own `identifier`; without one, `makeView(withIdentifier:owner:)`
  never reuses it. `configure` sets every visual property the model drives,
  including opacity, because `prepareForReuse` resets a reused view's alpha. A
  `SidebarRowView` (`NSTableRowView`) draws the selection tint and the hierarchy
  guide lines. The existing AppKit views `TypingDotsView` and `InlineTextField`
  are reused inside the cells.
- **`DockTableController`** – an `NSTableView` over `PinnedDockContent.rows`,
  using the worktree cell and the same update loop.
- **`SidebarSelectionBridge`** – maps outline selection to `AppState` and back.
- **`SidebarDropPolicy`** – pure; decides what a drag proposal means.
- **`NativeSidebarView`** – an `NSViewControllerRepresentable` that mounts the
  controller. `SidebarView` shows it, with the SwiftUI footer beneath, when the
  flag is on.

### Update loop

1. The controller runs the builder inside `withObservationTracking`. Its
   `onChange` fires once, on whichever thread made the change, and then
   disarms; the controller hops to the main thread, sets a single
   rebuild-scheduled flag and rebuilds on the next main-loop turn, re-arming the
   tracking as it does. A burst of writes therefore costs one pass. The builder
   never writes to `AppState`, and neither does anything the apply step
   triggers, or each rebuild would schedule the next. Tests drive the loop
   through `flushPendingRebuild()`.
2. The first load is a `reloadData`. After that, the controller diffs the new
   tree against the previous one and applies the result in one
   `beginUpdates`/`endUpdates` block:
   - **Structure** – the diff runs over the whole tree, not per parent, so an ID
     present in both trees under different parents becomes
     `moveItem(at:inParent:to:inParent:)` and keeps its row view, its subtree's
     expansion and its selection. A per-parent diff would see a removal and an
     insertion instead and lose all three. Every index comes from replaying the
     previous steps against a working copy of the old tree: `NSOutlineView`
     applies each call to the state the earlier calls left, so indices taken
     straight from a `CollectionDifference` go wrong as soon as moves are
     involved. Calls under a parent that is not expanded are skipped, since
     `NSOutlineView` ignores them; a parent inserted in this pass gets its
     children by being expanded, and a leaf that gains its first child gets
     `reloadItem` and then `expandItem`.
   - **Expansion** – each header's expanded flag drives `expandItem` and
     `collapseItem` in the same block, and a worktree row inserted with
     children is expanded after its insertion.
   - **Content** – rows whose model changed but whose position did not are
     reconfigured in place, on every row view `enumerateAvailableRowViews`
     returns, which includes rows prepared ahead of scrolling. A reload would
     swap in a recycled cell and lose transient state such as hover. The name
     label of a row being renamed is left alone. A row whose height class
     changed also gets `noteHeightOfRows`, inside a zero-duration
     `NSAnimationContext` so the height does not animate.
3. After `endUpdates`, if the outline's `numberOfRows` differs from the new
   tree's visible row count, the controller falls back to `reloadData`,
   re-expands, and restores the selection and scroll anchor below. The
   fallback is logged at `.fault` level, because it means the diff is wrong.
4. Before applying, the controller records the first visible row's ID and its
   offset from the top of the clip view, and restores them afterwards.
   `NSTableView` moves the clip view on its own during layout after height
   changes, as this app's transcript table showed.
5. While a drag session or an inline rename is in progress, the controller
   holds structural changes and applies them when it ends. Content changes
   still apply.

`updateNSViewController` does nothing: the controller observes `AppState`
itself. Mutating a table during SwiftUI's update pass blanked the transcript's
table, and this keeps every outline mutation outside that pass.

Swift's `Observations` sequence would replace the manual re-arming, but it
needs macOS 26 and the package targets macOS 15. AppKit's automatic observation
tracking in `layout` and `draw` is not used either: on macOS 15 it needs an
`Info.plist` key, which the unbundled app does not have, and it would put
`AppState` reads back into cells.

### Row heights and indentation

Heights are fixed per kind and variant. They come from the row model, so nothing
measures: a worktree row is `WorktreeRowView.rowHeight` (the value the dock
already uses), and a row showing a subtitle ("Creating worktree…", "Running
setup…", "→ promoted to …") is taller by one subtitle line. Implementation takes
each value from the SwiftUI path's rendered rows.

Today a section header and the top-level rows beneath it share a leading edge,
and each nesting level adds 16 pt. In outline terms, a row's visual depth is its
outline level minus one. The outline uses `indentationPerLevel = 16` and
overrides `frameOfCell(atColumn:row:)` to apply that offset, and
`SidebarRowView` draws one 1 pt guide line per ancestor at `depth * 16 + 8`, as
`WorktreeRowView` does today. The native disclosure triangle is hidden by
overriding `frameOfOutlineCell(atRow:)` to return `.zero`; headers draw today's
chevrons.

The outline is configured for custom drawing: `style = .plain`,
`selectionHighlightStyle = .regular` (`drawSelection(in:)` never runs with
`.none` or the source-list style), `rowSizeStyle = .custom`, zero vertical
`intercellSpacing`, and `autoresizesOutlineColumn = false`. `SidebarRowView`
overrides `interiorBackgroundStyle` so cell text keeps its color on the light
tint instead of turning white.

## Interaction

### Selection

- The outline allows multiple selection with native cmd-click and shift-click.
  Worktree, scratch and remote session rows are selectable; headers are not.
- Clicking a header runs its action through the outline's `action`, calling what
  the SwiftUI headers call today: `selectRepo(id:)`, `selectScratchSection()`,
  `selectRemoteProvider(_:)`, or `toggleSidebarGroup(_:)`. A header whose
  selection is active (`selectedRepoID`, `selectedScratchSection`,
  `selectedRemoteProvider`) draws today's selected appearance.
- **Outline to `AppState`.** `SidebarSelectionBridge` writes the same set of IDs
  the `List` tags produce today into `appState.selectedWorktreeIDs`: worktree IDs
  and remote session IDs. That property's `didSet` stays the only place selection
  is routed, covering pure-remote versus mixed selections, `selectionOrder`,
  navigation history and unread clearing.
- **`AppState` to outline.** An `isApplyingModelSelection` guard covers the
  whole apply, through `endUpdates`, so the selection changes `NSOutlineView`
  posts while rows move are not echoed to `AppState`. At the end of the apply
  the controller selects the rows `AppState` names.
- The dock and the main outline both mirror the one selection set.
- `SidebarRowView` draws today's tint (accent at 0.2 opacity).

### Expansion and reveal

- Expanded state stays where it lives: `Repo.expanded` in the database, the
  scratch section's `@AppStorage` key, and `AppState.expandedSidebarGroups`.
- The setters (`setRepoExpanded(id:expanded:)`, the scratch key,
  `toggleSidebarGroup`) run only from user gestures: chevron clicks and the
  Collapse and Expand menu items. The next rebuild applies the result. The
  outline's own expansion notifications are ignored, since they also fire for
  expansions the controller makes while applying a tree.
- Worktree subtrees are always expanded; the delegate refuses to collapse them.
- Reveal calls the same `AppState` methods as the SwiftUI path:
  `revealSidebarGroups`, the Ended reveal, and the selection reveal with its
  baseline rule. `SidebarView.revealBaseline` moves to a shared pure function
  both paths call.
- For `pendingScrollToWorktreeID`, the controller scrolls the target row to the
  center in the same apply pass that expanded its section, then clears the
  value. No run-loop hop is needed because the controller owns the rows.

### Hover

- One tracking area on the outline determines the hovered row and tells its
  cell. A tracking area gets no exit event when content scrolls under a
  still pointer, so the hovered row is recomputed from the pointer position on
  every clip-view scroll and after every apply, and cleared when a drag starts.
- Repo and scratch headers reveal their `+` and chevron on hover, with the repo
  header's 80 ms debounce. Hovering a chevron dims that section's rows to 0.7
  opacity.
- A worktree row's nested `+` keeps `HoverMenuModel`'s 400 ms hover delay,
  ⌥-click, and close on app deactivation. It opens the existing SwiftUI
  `WorktreeProfilePickerView` in `FloatingPanel`, anchored to the AppKit button.
- The pin toggle is an AppKit button in the leading gutter, shown on hover and
  always once pinned. The guide line keeps its gap there.
- Tooltips for a truncated name and for the PR glyph use a replica of today's
  bubble, drawn in an overlay view below the row. Other help text uses
  `toolTip`.

### Rename

Setting `editingWorktreeID` makes the cell replace its name label with the
existing `InlineTextField`, with the emoji autocomplete panel anchored to the
field. New-worktree flows set it to start a rename, as today. The focus-race
handling in `RenameableLabel` carries over.

### Context menus, popovers and sheets

- `menu(for:)` builds an `NSMenu` from the existing models: worktree rows from
  `RowActionMenu`, dispatched through `RowActionMenuActions.run`, plus the New
  Cloud/Remote Session items; the repo header's six items, with its confirmation
  as an `NSAlert` sheet; the scratch header's two items; and the remote session
  row's actions, extracted into a model where they are view-only today. The
  Collapse and Expand items that keyboard users rely on stay.
- The provider needs-auth popover and the sheets present their existing SwiftUI
  content through `NSPopover` and `presentAsSheet`, so the SwiftUI path does not
  change.

### Keyboard and accessibility

- Arrow and shift-arrow navigation are native, including from a remote session
  row. Cmd-1…9, ⌘N, ⌘⇧A and ⌘K work at the `AppState` level and are untouched.
- Each cell sets an accessibility label from its model: the name, then the
  status a sighted user reads from the suffix.
- Controls shown only on hover, the pin toggle and the nested `+`, are also
  offered as `accessibilityCustomActions`, so VoiceOver reaches them without a
  pointer.

## Drag and drop

### What can be dragged

- Worktree rows other than the main row, local or adopted remote lanes, and
  scratch rows. Unadopted remote sessions and headers return no pasteboard
  writer.
- A drag that starts on a selected row carries the selection; a drag that starts
  on an unselected row carries that row. From a selection, the drag leaves out
  main rows, unadopted remote sessions, and any row whose ancestor is also
  carried, since that row travels with its ancestor. If the selection mixes
  scratch rows and worktrees, the drag carries the kind under the cursor.
- The payload is a private, in-process UTI carrying the ordered worktree IDs. The
  dock uses a different UTI, so rows never cross between the dock and the list.

### Where it can go

`validateDrop` hands the outline's proposal (an item and a child index, or "on
item") to `SidebarDropPolicy`, which answers in IDs, never indices:
`.nest(under:)`, `.place(parent:before:)` with `before: nil` meaning the end of
the group, or `.reject`. It may retarget the proposal with
`setDropItem(_:dropChildIndex:)`. `acceptDrop` resolves the answer again against
the current tree, so a daemon push during the drag cannot land a move on rows
that are gone.

Each rule applies to every carried row; if one fails, the drop is rejected.

- **Onto a worktree row** – nest the carried rows as its last children, in their
  top-to-bottom order. Their subtrees move with them.
- **Onto the main row** – un-nest the carried rows to the top of that repo's
  worktrees, directly below the main row.
- **Between siblings at any depth** – place the carried rows there. The same
  parent is a reorder; a different parent re-parents. This covers moving a row
  into a nested group from outside, to a chosen position within it, and out of
  it to any shallower level.
- **Between a repo's top-level rows** – un-nest to the top level.
- **Scratch rows** – reorder within the scratch section only, and no other row
  drops into it.
- **Rejected:**
  - a drop onto a carried row or one of its descendants;
  - nesting under a scratch row, a remote session or a header;
  - a destination in another repo's section, unless the carried rows are
    reordered among their current siblings there;
  - a gap inside a state group (Remote, Exited or Hibernated) other than the one
    the rows came from, because a row's state decides which group renders it;
  - any position inside a collapsed section. Collapsed sections do not spring
    open during a drag, since that would fight model-driven expansion.
- **Retargeted:** a proposal above the main row, or among the inline remote
  sessions that follow a repo's worktrees, becomes the nearest valid top-level
  gap.

### Depth at the end of a subtree

The gap below a subtree's last row is ambiguous: it can mean the end of that
subtree's children or a shallower level. The pointer's horizontal position
chooses, as in Finder's list view, and the insertion line indents to the depth it
chose.

### Feedback

A nest highlights the target row. A place draws an insertion line at the
destination's visual depth, aligned with the guide lines. The native
`NSOutlineView` indicator indents by raw outline level, which is one level
deeper than the visual depth used here; where it cannot be aligned, the outline
suppresses it and `SidebarRowView` draws the line. The drag image shows the
carried rows only, not their subtrees.

### Commit: `worktree.moveMany`

A new RPC applies a drop in one write transaction, all or nothing:

```swift
public static let worktreeMoveMany = "worktree.moveMany"

public struct WorktreeMoveManyParams: Codable, Sendable {
    public let moveID: UUID             // client-generated, echoed in the delta
    public let worktreeIDs: [UUID]      // carried rows, in top-to-bottom order
    public let newParentID: UUID?       // nil = top level of the rows' own group
    public let beforeWorktreeID: UUID?  // nil = end of the destination group
}
```

The request names the destination by IDs, and the daemon computes every
`sortOrder` inside its transaction. The client never does sort-order arithmetic
against values a concurrent write may have changed.

The daemon, in `WorktreeStore.moveMany`:

1. Validates each carried row: it exists, is not `main`, and a scratch row is
   not given a parent. A non-nil `newParentID` passes `validateParent` for every
   carried row (not self, exists, not `main`, not archived, closes no cycle).
2. Identifies the destination group. For a parent, its children. For the top
   level, rows with no parent, the same `repoID` and a status other than `main`,
   compared with `repoID IS ?` so scratch rows, whose `repoID` is NULL, form
   their own group. Every carried row must belong to that one top-level group.
   `beforeWorktreeID`, when given, must belong to the destination group and not
   be carried.
3. Computes the new order with `SiblingPlacement.place(group:carried:before:)`,
   a pure function in `TBDShared`: the group without the carried rows, with the
   carried rows inserted before `before`, or appended.
4. Writes each carried row's `parentWorktreeID`, and `sortOrder` 0…n−1 across
   the group in the new order. A carried remote row whose parent changes gets
   `remote_parent_assigned = 1`, exactly as `move` sets it.
5. After the transaction commits, broadcasts a `worktreeSiblingsReordered`
   delta carrying the request's `moveID` and the destination group's full
   result, every row in it with its `parentWorktreeID` and new `sortOrder`, and
   replies. The delta and the reply travel on different sockets, so the app may
   see either first. The existing `worktreeMoved` delta carries only the moved row,
   so a client applying it holds stale sibling sort orders until its next poll;
   the full-group delta brings a client to the daemon's state in one step. A
   client that predates the delta catches up at its next poll. The
   implementation confirms that an unknown delta is skipped rather than ending
   the subscription.

Any failed check throws a typed error and writes nothing. `worktree.move` stays
for `tbd worktree reparent`. Single-row drags send `moveMany` with one ID, so
the sidebar has one commit path.

`AppState.moveWorktrees(ids:newParentID:before:)` replaces the unused
`moveWorktree`:

- **Local first.** It applies the move to `worktrees` or `scratchWorktrees`
  with the same `SiblingPlacement.place` the daemon runs, so the rows land
  under the cursor before any message leaves the app. The daemon's group
  includes archived rows and the app's lists do not, but the placement keeps
  the relative order of the rows both sides hold, so the two agree on every
  visible row.
- **A pending-move overlay.** The app re-fetches worktrees every 2 s, and other
  paths call `refreshWorktrees` too. Fetches are not serialized: each RPC opens
  its own socket, so a fetch that read the database before the commit can be
  answered after the local move, after the delta, or after a newer fetch.
  Assigning its old order would snap the rows back. So `AppState` records each
  in-flight move and re-applies it on top of every fetch result and every
  `worktreeSiblingsReordered` or `worktreeMoved` delta before the result is
  compared and assigned. A stale result then produces the arrays the app
  already holds and publishes nothing, and another writer's delta cannot undo
  a move the daemon has not yet answered. This follows the archive tombstones
  in `applyWorktreeArchivedDelta`, which keep a fetch that predates an archive
  from resurrecting its row, and the rebase-pending-mutations rule of sync
  engines such as Replicache.
- **A fence for stale fetches.** `AppState` numbers each worktree fetch when it
  sends it. When a move's RPC succeeds, the number the next fetch will get
  becomes that move's fence, and from then on any fetch result numbered below
  the highest fence is discarded, so a fetch that read the daemon before a
  commit is never applied after it. A move leaves the overlay once its RPC has
  succeeded and the app has applied either the `worktreeSiblingsReordered`
  delta carrying its `moveID`, whether it arrived before or after the reply, or
  a fetch numbered at or above its fence.
  The `moveID` keeps a move by the CLI or another window from retiring this
  one.
- **Failure.** At the drop, `AppState` snapshots the carried rows' parents and
  the order of their source and destination groups. If the RPC fails, the move
  leaves the overlay, the app restores those rows and groups from the snapshot,
  leaving every other row as it is, then refreshes from the daemon, whose state
  is the truth, and a toast names the row and the reason. The snapshot covers
  the case where the daemon is unreachable and the refresh fails too; scoping
  it to the affected groups keeps any other change that landed during the RPC.

The overlay and the fence rely on two daemon invariants, which `moveMany`'s
tests pin: `moveMany` replies only after its transaction commits, and
`worktree.list` reads in a fresh transaction, never from a cache, so under
SQLite's WAL mode a fetch begun after the reply sees the commit.

A daemon revision number on every fetch result and delta would fence all stale
reads, including one that undoes another writer's delta, the way Linear's and
Replicache's sync engines do. It needs a new result shape for `worktree.list`
and a revision that stays monotonic across daemon restarts. The fence and
`moveID` cover this feature's case with only the protocol it already adds; a
revision becomes worth its cost if flicker from other writers shows up.

### Dock

The dock reorders pins only, through the existing `reorderPins` and its
`PinnedDockReorder` stale-order guard.

## Responsiveness

A drop never waits for the daemon. The rows move in the app first, and the RPC
and its echo arrive after the user has already seen the result. What remains on
the main thread has a budget:

- **Rebuild and apply** – building the tree, diffing it and applying the result
  takes at most 8 ms, half a frame, on a sidebar of 320 rows, the size measured
  on a heavy install, and at most 16 ms with 800 remote sessions. The same
  budget covers every rebuild, whether a drop, a status change or a poll caused
  it.
- **Drop to screen** – the outline shows a drop's result on the main-loop turn
  after the drop, within the rebuild budget.
- **Drop validation** – `validateDrop` runs on every mouse movement during a
  drag. `SidebarDropPolicy` answers by walking ancestors and looking up children
  through the existing children index, so its cost grows with the tree's depth,
  not its size; each call takes under 1 ms on the trees above.
- **No blocking work** – the rebuild, the drop path and the cells do no IPC, no
  disk access and no Launch Services queries on the main thread.

`SidebarListUpdateBench` (env-gated, not a CI timing test, since timing on a
shared runner flakes) is extended to measure a full rebuild and apply, a drop
and a `validateDrop` call on 320-row and 800-session trees. The rebuild and apply
steps also emit `os_signpost` intervals, so Instruments can attribute a slow
frame to them.

## Flag and rollout

- **Key** – the app-only UserDefaults key `useAppKitSidebar`, as
  `AppState.appKitSidebarKey`, with its shipped default in exactly one constant,
  `AppState.appKitSidebarDefault = false`. An unset key reads as that constant,
  so graduating is a one-line change that keeps any explicit opt-out.
- **Toggle** – Settings → Experimental, "Native sidebar with drag to nest
  (experimental)". `SidebarView` chooses its path from the key, so the toggle
  swaps the sidebar without a restart.
- **Off** – the SwiftUI `List` path runs unchanged.
- **During the soak** – a change to sidebar behavior lands in both paths, and
  its PR says so.
- **Soak** – two weeks with the flag on in daily use, starting when the PR that
  adds the flag merges. At that merge a reminder is scheduled for 14 days later
  to open the graduation PR.
- **Graduation criteria**, checked in the graduation PR:
  1. The soak ran its two weeks.
  2. The parity checklist below was walked live and ticked off.
  3. No hang-stack sample in `~/Library/Logs/TBD/hang-stacks/` from the soak
     has a frame in `Sidebar/Native/`.
  4. `SidebarListUpdateBench` shows the native path within every budget in
     "Responsiveness", and no slower than the `List` path at 800 remote
     sessions.
- **Graduation** – flips `appKitSidebarDefault` to true. Deleting the SwiftUI
  sidebar path is a later, separate PR, once the new default has held.

No durable resource is added. `moveMany` edits existing rows, and the flag lives
in UserDefaults, so no reconciler is involved.

### Parity checklist

The behaviors a rewrite most easily loses:

1. Selection routing: pure-remote selections go to `selectRemoteSession`, mixed
   selections keep the local rows, and cmd-click order reaches
   `selectionOrder`.
2. Reorder within a state group moves the right rows with workflow groups on,
   and remote sessions are never droppable among worktrees.
3. Reveal order: groups and repos expand before the scroll; the selection reveal
   follows the baseline rule; the Ended reveal opens with groups off.
4. The dock: shared selection, subtree shown only while selected, its own scroll,
   its height clamp.
5. Rename on create through `editingWorktreeID`, and the focus race with
   terminals.
6. Chevron hover dimming, the gutter pin toggle and its gap in the guide line,
   `HoverMenuModel` timing and close on deactivate, truncation-only tooltips,
   PR-glyph click-through, and the context-menu Collapse/Expand items.
7. Section styling: hidden repos at 0.55 opacity, the missing-repo badge with
   Locate…, dimmed gone sessions and missing scratch directories, provider health
   suffixes, the selected provider's background.
8. Every input a row draws refreshes it: status suffix, typing dots, PR glyph,
   unread bold, subtitles, the dev-server dot, the no-status mark.

## Testing

Most coverage is pure:

- **`SidebarTreeBuilder`** – `AppState` fixtures map to expected trees for each
  section kind, with workflow groups on and off, collapse-ended on and off,
  hidden repos, the repo filter, the scratch prompt and cross-repo children. One
  test per row-model input proves that changing it changes the tree, which guards
  parity item 8.
- **Tree diff** – old and new trees map to the expected insert, remove, move and
  reconfigure operations, and held structural changes apply at drag end.
- **`SidebarDropPolicy`** – a case per rule above, including the end-of-subtree
  depth choice, the onto-main un-nest, retargeting, collapsed sections, and the
  carried set for multi-row drags.
- **`SiblingPlacement.place`** – before, end, carried rows already in the group,
  and preserved relative order of non-carried rows.
- **`SidebarSelectionBridge`** – both directions, with mixed local and remote
  selections.

Daemon:

- `moveMany` writes nothing when any row fails validation, keeps the carried
  order, shifts scratch siblings through the NULL-safe group, sets
  `remote_parent_assigned` only when a remote row's parent changes, and rejects
  carried rows from different top-level groups. The RPC handler has a test, and
  the `worktreeSiblingsReordered` delta it broadcasts carries the whole
  destination group.

App:

- `moveWorktrees` matches the daemon's order locally before the RPC returns.
- A fetch result that predates the commit, assigned while the move is in
  flight, leaves the rows where the move put them and publishes nothing.
- A fetch numbered below the fence and answered after the overlay retired is
  discarded.
- A delta from another writer, applied while the move is in flight, does not
  move the carried rows.
- A move leaves the overlay after the delta with its own `moveID`, or a fetch
  at or above its fence, and not after a delta with another `moveID`.
- Applying `worktreeSiblingsReordered` leaves the app's sibling sort orders
  equal to the daemon's.
- A failed RPC restores the carried rows and their groups from the snapshot,
  keeps a change to any other row that landed during the RPC, refreshes, and
  shows the toast, including when the refresh fails.
- Offscreen AppKit tests through `OffscreenHost` mount the outline and the dock
  and check rows and kinds, the selection round trip, expansion through the
  `AppState` setters, `validateDrop` and `acceptDrop` with a stub
  `NSDraggingInfo`, rebuild coalescing through `flushPendingRebuild()`, and the
  rename field appearing when `editingWorktreeID` is set.
- One test per flag branch: off mounts the `List`, on mounts the native sidebar.
  Flag tests use `TestDefaultsSuite`, never `UserDefaults.standard`.
- The env-gated `SidebarRenderHarness` renders both paths from one fixture as
  side-by-side images for review. It is not a CI gate.

The 80 ms header debounce and any other new hover timer take an injected clock,
per `CLAUDE.md`.

## Risks

- **Lost behavior.** The SwiftUI sidebar is about 7,400 lines with many small
  interactions. The parity checklist and per-input builder tests target the
  likeliest losses, and the flag keeps the old path one toggle away.
- **A row that stops refreshing.** Native cells redraw only when the controller
  tells them to. The builder is the only reader of `AppState`, so a missed input
  shows up as a builder test that fails, not as a cell that forgot to observe.
- **Main-thread rebuild cost.** A rebuild walks every row, about 320 on a heavy
  sidebar today. Coalescing bounds the passes, and the budgets in
  "Responsiveness", enforced at graduation, bound their cost.
- **Rows that jump after a drop.** A stale poll or a partial echo could move
  rows back after the user placed them. The pending-move overlay and the
  full-group delta exist to prevent that, and each has a test.
- **Scroll jumps on structural updates.** `NSTableView` moves the clip view
  during its own layout after height changes, and its anchoring is not
  documented. The controller restores the first visible row's ID and offset
  after each apply, and offscreen tests check scroll position across inserts,
  removes, cross-parent moves and height-class changes.
- **A wrong diff.** Replaying a whole-tree diff against a working copy is the
  subtlest code here. Tests cover reversals, cross-parent moves and moves under
  collapsed parents, and the `numberOfRows` check falls back to `reloadData`
  with a `.fault` log if a diff still goes wrong in the field.
- **Two paths during the soak.** Sidebar changes must land in both. The soak is
  time-boxed to keep that window short.

## Rejected alternatives

- **Custom drag and drop on the SwiftUI `List`.** `.onMove` and
  `.draggable`/`.dropDestination` cannot coexist on a row, and dropping `.onMove`
  for drop zones between rows still leaves `.dropDestination` with no location.
  Issue #142's eight attempts are the evidence.
- **Hosted SwiftUI row content in AppKit cells.** Fixed-height rows with no
  selectable text avoid the height and text-selection failures that sank hosted
  rows in the transcript, and hosting would reuse today's row views. It still
  keeps SwiftUI's gesture handling inside every row, the source of the
  mouse-down conflicts in #83 and #142, and SwiftUI body re-evaluation, where
  expensive row work has repeatedly hidden. It also contradicts `CLAUDE.md`'s
  rule to go AppKit all the way down to the cells.
- **A "Move under…" context menu instead of drag.** It would ship nesting
  quickly but leave the sidebar on the foundation that keeps failing.
- **Folding the dock into the outline as a Pinned section.** Simpler structure,
  but it moves pinned items users rely on and loses the dock's height clamp.
- **The native source-list look.** Less custom drawing, but it changes how the
  sidebar looks and makes comparing the two paths during the soak harder.
- **Replacing the `List` without a flag.** Dogfooding and `scripts/restart.sh`
  give one machine a fast revert, but this repo serves other organizations, and
  `CLAUDE.md` requires a flag for replacing a load-bearing path and for moving
  items users rely on.
- **Dragging only the row under the cursor.** Simpler, but a drag that leaves
  the rest of a selection behind contradicts every macOS list.
- **Sequential `worktree.move` calls with client-computed sort orders.** A
  failure partway through leaves a partial move, and the client would compute
  each `sortOrder` from values a concurrent write may have changed.
- **Rejecting a drop onto the main row.** The main row is the repo's own
  checkout, not a parent, so the daemon refuses it as one. Rejecting the drop
  would be correct but unhelpful; it maps onto un-nesting to the top of the repo,
  which is what the gesture asks for.
