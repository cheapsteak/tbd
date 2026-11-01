# Panel tabs — a side region with tabs, rendered from the daemon

Status: design, approved for implementation planning
Date: 2026-10-30
Builds on: [`2026-07-22-panel-agent-surface-c-primary-anchor-design.md`](2026-07-22-panel-agent-surface-c-primary-anchor-design.md) (spec C)

This spec replaces spec C's layout model with a fixed one and makes the app
render it from the daemon. It supersedes these parts of spec C: the layout tree
(§5.2–§5.4), the default file-routing policy (§6.1), placement (§7.3), the
agent feature gate (§10.2), and the CLI (§10.3). Spec C's other decisions
stand: the daemon owns panel state, terminals appear only as a workspace tab's
primary, history uses MRU semantics, and every mutation goes through one
operation pipeline.

## Problem

The daemon already owns a panel surface. Its store, the `panel.get` and
`panel.apply` RPCs, the legacy import, and the `tbd panel` CLI are built and
merged behind two default-off flags. But the app still renders from its own
legacy `LayoutNode` tree, and `AppState.handleDelta` drops
`panelSurfaceChanged` in its `default: break`. An agent that runs
`tbd panel open` commits a change the user never sees.

Spec C's model is a free-form split tree: any panel can split on any edge,
nested to any depth, with a ratio list per split. That freedom suits a
terminal multiplexer, where the user arranges panes by hand; TBD's panels are
viewers beside an agent's terminal, and there it causes two problems:

- **Files and transcripts fight over the same slot.** The transcript button
  takes over a file viewer, and a file link clicked inside a transcript takes
  over the transcript's own viewer when no other viewer exists. Rendering this
  model from the daemon makes it worse: the natural second click of the
  transcript button is `close`, which removes the panel and the file the
  transcript replaced.
- **Agents must reason about geometry.** `tbd panel open` asks for an anchor,
  an edge and a share, which is layout work an agent has no good basis for.

Two daemon-side gaps also stand between the surface and everyday use:

- **Per-panel history is not on the wire.** `PanelGetResult` carries tabs only,
  so the app cannot show a panel's back/forward state.
- **Tabs created after the one-shot import have no surface.** They fall back to
  legacy, so one window can mix both models, and `tbd panel` silently does
  nothing on some tabs.

## Goals

- A fixed layout: each workspace tab is its primary plus one side region, and
  the side region holds viewer panels as tabs.
- The app renders that layout from the daemon, and routes its own gestures
  through `panel.apply`, so user and agent changes take one path.
- Per-panel history travels with the surface.
- Every workspace tab the app shows has a surface, except a tab whose legacy
  layout still splits off a terminal (see "Legacy import").
- Chrome that names each thing once: one row of tabs across the window, and no
  pane headers repeating what a tab already shows.
- Everyone gets it. No setting turns it off.

## Non-goals

- **More than one region.** The model leaves room for a second region (see
  "Future extensions"), but only one is built.
- **Dragging tabs to reorder them.**
- **Retiring the legacy layout store.** It stays live for the multi-worktree
  grid and for tabs the converter skips.

## The model

A workspace tab is the tab in the worktree's top tab bar. Workspace tabs stay
app-owned: the app decides which exist, their order, their labels, and which is
selected. What moves to the daemon is everything inside one.

```swift
struct WorkspaceTabSurface {     // one per workspace tab
    var worktreeID: UUID
    var tabID: WorkspaceTabID
    var label: String?
    var position: Int
    var revision: UInt64
    var primary: PrimaryContent  // terminal | note | file | web | transcript
    var side: SideRegion         // always present; no panels means hidden
}

struct SideRegion {
    var panels: [ViewerPanel]    // tab-strip order, left to right
    var activePanelID: PanelID?  // nil exactly when panels is empty
    var recency: [PanelID]       // most recent first; drives reuse
    var collapsed: Bool          // hidden, panels kept
    var width: Double            // share of the workspace tab's width
}

struct ViewerPanel {             // one tab in the side region's strip
    let id: PanelID
    var history: PanelHistory    // MRU, as today; the cursor entry is the content shown
}
```

`PrimaryContent` and `PanelContent` keep their spec C definitions. A panel has
no stored `content` field: its content is `history.entries[history.cursor]`,
which removes the duplicate spec C had to keep in step with the history.

Rules the validator enforces:

- **A panel's kind is fixed.** The kinds are file, web, note and transcript,
  read from the panel's content. Navigating or reusing a panel keeps its kind,
  so a file never lands in a transcript's tab and a transcript never lands in a
  file's tab.
- **At most one transcript view per terminal in a workspace tab.** Today a
  transcript view can only be a side-region panel. The rule names views rather
  than panels so that a future primary-area transcript view (see "Future
  extensions") falls under it unchanged.
- **`activePanelID` names a panel in `panels`,** and is nil only when `panels`
  is empty.
- **`recency` is a permutation of the panel IDs.**
- **Every history is well formed and non-empty,** capped at 10 entries, with
  spec C §6's MRU semantics: back/forward/jump move the cursor and never
  reorder; a navigation commits the current entry to the front, moves rather
  than duplicates the destination, and evicts from the tail.
- **`width` lies in 0.1–0.9,** the legacy divider's limit, and defaults to
  0.5. The divider clamps a drag to the same range.

Recency is an ordered list, not a timestamp, so the reducer stays pure and
needs no clock.

## Operations

```swift
enum PanelOperation {
    case open(content: PanelContent, newPanel: Bool)
    case navigate(panelID: PanelID, destination: PanelContent)
    case history(panelID: PanelID, action: PanelHistoryAction)  // back | forward | jump
    case select(panelID: PanelID)
    case close(panelID: PanelID)
    case setCollapsed(Bool)
    case resize(width: Double)
}
```

- **`open`** is the one entry point for command-clicks, transcript links and
  `tbd panel open`. It resolves in order:
  1. If a panel already shows exactly this content, select it.
  2. Otherwise, for file, web or note content with `newPanel` false, pick the
     active panel if it is the same kind, else the most recent panel of that
     kind in `recency`. Navigate it (the old content stays in its history) and
     select it.
  3. Otherwise (a transcript, `newPanel` true, or no panel of that kind), insert
     a new panel right after the active one and select it.

  Every `open` also clears `collapsed`: opening something the user cannot see
  is never the intent.
- **`navigate`** points one named panel at new content, as a link clicked
  inside a rendered document does. The destination must match the panel's kind.
  It commits history like any navigation.
- **`history`** moves one panel's cursor, unchanged from spec C.
- **`select`** makes a panel active, moves it to the front of `recency`, and
  clears `collapsed`.
- **`close`** removes a panel and its history. If it was the active panel, the
  most recent remaining panel becomes active; otherwise the active panel stays.
  Closing the last panel leaves the region empty, and an empty region is
  hidden.
- **`setCollapsed`** hides or shows the region without touching its panels.
- **`resize`** sets the region's width. During a divider drag the width changes
  only in a local overlay; one `resize` is sent on release.

Gone from spec C's vocabulary: `move`, `PanelPlacement` with its anchors and
edges, split IDs and ratio lists, `selectTab`, and the daemon's rewrite of
`.automatic` placement from `panel_history.updatedAt`.

### The transcript button

The transcript button sits at the trailing end of the workspace tab bar (see
"The renderer"), shown while the selected tab's primary is a Claude terminal
and the transcript view is turned on. The app decides what to send from its
copy of the surface:

- **No transcript panel for this terminal:** send `open(.transcript(terminalID))`.
- **The panel exists but another panel is in front, or the region is
  collapsed:** send `select(panelID)`.
- **The panel is in front and visible:** send `close(panelID)`.

The button shows as on whenever the panel exists.

## Round trip and conflicts

No gesture is continuous with respect to the surface: a divider drag moves a
local overlay and commits once on release, and every other gesture is a single
click. So a gesture sends one `panel.apply` and adopts the authoritative tab
the daemon returns. The `panelSurfaceChanged` delta that follows carries the
same tab at the same revision and changes nothing.

The daemon is a local Unix-socket process, so a commit costs far less than a
frame. The pure reducer in `TBDShared` keeps an optimistic layer available if
measurement ever shows a visible gap: the app could run the same reducer,
render at once, and let the reply confirm. It is not built.

Revisions are daemon-wide. Every write that creates or changes a surface — an
operation, an import, a sync's update of position, label, primary or
worktree, or a scratch promote's move of its surfaces to the main worktree —
takes its revision from one persistent counter, incremented in the
write's own transaction, that never decreases. So a tab's revisions keep
rising when its surface is deleted and imported again, whether a sync dropped
it, an archive and revive replaced it, or the migration emptied the tables, and
any two snapshots of one tab compare correctly, across a daemon restart too.

`baseRevision` is sent for diagnostics only. The daemon applies a valid
operation against current state regardless of the base; it uses a stale base
only to relabel an already-failing vanished-target error as `staleTarget`.

Staleness is handled in the app's copy instead: it never adopts a tab whose
revision is lower than the one it holds for that tab, under any worktree. Tab
IDs are global, so a tab the copy adopts under one worktree, from a delta or a
full `panel.get`, leaves every other worktree's entry: promoting a scratch
worktree re-parents its tabs. Without that guard a `panel.get` in
flight at revision N could land after a delta at N+1 and revert the copy, and
since deltas fire only on change, nothing would correct it until the next
mutation. Removal is exempt: a tab absent from a full `panel.get`, or named in a
delta's `removedTabIDs`, is dropped whatever revision the copy holds. A tab
named in `removedTabIDs` leaves every worktree's entry, not only the delta's,
because a copy that missed a re-parent still holds the tab under the worktree
it left.

The app decides the transcript button's operation from its copy, so an agent
mutation landing between the user's read and the click can make that one click
act on a stale picture. The worst case is a select where a close was meant, or
the reverse; the reply corrects the copy and the next click acts on the truth.

## Daemon

### Store

The schema keeps spec C's three tables. One `.sql` migration deletes every row
of `panel_operation_receipt`, `panel_history` and `workspace_tab_surface`. No
v1 row holds unique data: the app has never rendered from the daemon, so the
legacy layout is still the truth on every install, and the tab sync re-imports
from it. The same migration adds `panel_revision_counter`, one row holding the
daemon-wide revision counter (see "Round trip and conflicts"), starting at
zero.

- `workspace_tab_surface` keeps one row per workspace tab. Its `layout` column
  holds the `SideRegion` JSON without histories; `primaryContent`, `label` and
  `position` keep their meaning, and `revision` holds the counter value the
  row's last write took. `awaitingListing` marks a surface a scratch promote
  moved that no tab sync has listed yet (see "Tab sync"); it is the store's
  own, and `WorkspaceTabSurface` does not carry it.
- `panel_history` keeps one row per panel. The store joins histories into
  `ViewerPanel.history` when it reads a surface and splits them out when it
  writes one, inside the same transaction.
- `panel_operation_receipt` keeps idempotent replay, for the tab the receipt
  names (see "Coordinator"); its stored result is a v2
  `PanelApplyResult`.

`PanelSurfaceStore.applyReducing` keeps its shape: load, reduce and persist
inside one write transaction, so concurrent applies to one tab cannot lose an
update.

### Coordinator

`PanelCoordinator.apply` keeps its pipeline: idempotency replay,
resource-existence check for `open` and `navigate`, reduce, persist, broadcast.
No setting gates it: the app and agents mutate through it alike.

A receipt replays only for the tab it names. An operation ID whose receipt
names another tab is refused with `operationIDReused` and applies nothing:
reusing an ID is a caller bug, a replay would answer with the other tab's
result, and applying anew would overwrite that tab's receipt. The worktree is
not compared. Tab IDs are global and a tab's receipts move with it when a sync
re-parents it or a scratch promote moves it, so a retry that still names the
worktree the tab left replays that tab's own result.

### Tab sync

A new RPC, `panel.syncTabs`, replaces the one-shot `panel.importLegacy`:

```swift
struct PanelSyncTabsParams {
    let worktreeID: UUID
    let tabs: [LegacyTabPayload]   // every workspace tab, in order
    let paneHistories: [UUID: MRUHistory<PaneContent>]
}
```

The app sends it when it connects and whenever a workspace tab is created,
closed, reordered or relabelled. In one transaction the daemon:

- **imports each listed tab that has no surface,** converting its legacy layout
  (see "Legacy import");
- **never overwrites a readable surface,** so the daemon stays the authority
  for what is inside a tab;
- **replaces an unreadable surface,** one whose row fails to decode or
  validate, with the tab's legacy import and a logged warning, histories
  included, at a fresh revision, and reports it as imported. No later sync
  could read that row either, so keeping it would leave the tab on legacy for
  good. A tab whose unreadable row has no import, because the converter
  skips it, keeps the row and is named in `skippedTabIDs`, so the app stops
  asking for a surface it cannot get;
- **re-parents a listed tab's surface that sits under another worktree.** Tab
  IDs are global, and promoting a scratch worktree moves its tabs to the main
  worktree; the tab's panels move with it, and so do its operation receipts,
  so the worktree that now holds the tab prunes them and its archive reclaims
  them;
- **updates `position`, `label` and `primary`** on existing surfaces to match
  the list. No operation changes a primary, so the primary is app-owned like
  the tab itself; the file viewer, for one, points a file tab's primary at a
  new file in place;
- **clears the `awaitingListing` marker** of every listed tab's surface. The
  marker is the store's own, so clearing it alone changes nothing the app sees
  and takes no revision;
- **deletes this worktree's surfaces for tabs not in the list,** with their
  histories, and names them in the delta's `removedTabIDs`. A surface still
  awaiting its listing is kept until a grace period runs out: it is one a
  scratch promote moved here, and the sync may predate the move (see below).

It broadcasts one `panelSurfaceChanged` for whatever changed. The worktree's
existing cascade still removes every surface when the worktree row is deleted.
Archiving keeps the row, so the cascade never fires: `WorktreeStore.archive`,
which every archive path but a scratch promote goes through, deletes the
worktree's surfaces, their histories and its operation receipts in the same
transaction and returns the deleted tabs' IDs. Whichever path drove the
archive then broadcasts a `panelSurfaceChanged` naming them in
`removedTabIDs`, beside its `worktreeArchived`, and the app drops the worktree
from its copy, along with its pending sync and its readiness to sync. A sync
for an archived worktree changes nothing and reports nothing, so one that lands
after the archive cannot import its tabs again. A revive needs nothing back,
because the next sync re-imports its tabs from the legacy layout, at revisions
above any they had.

A scratch promote retires the scratch row in its own transaction, which moves
the scratch worktree's tabs to the new repo's main worktree. The same
transaction moves their surfaces, histories included, to the main worktree at
fresh revisions, and re-points the scratch worktree's operation receipts at the
main worktree, so no panel row is left on the archived row and a `panel.apply`
retried across the promote still replays its stored result. The moved surfaces
take positions after the main worktree's own, in the order they had, so no two
of its surfaces share a position before the next sync sets them. The promote then
broadcasts a `panelSurfaceChanged` for the main worktree carrying the moved
surfaces, beside its `worktreeArchived`, and the app adopts them there.

The app learns of the new main worktree before the promote moves anything, so
a sync for it can be built from a tab list that does not yet name the moved
tabs and still land after the move. Pruning on that list would delete the
moved surfaces and their histories, and a later sync would import them again
from the legacy layout, losing every panel opened since the first import. So
the move marks each moved surface `awaitingListing`, and a sync does not prune a
marked surface. The first sync that lists the tab clears the marker, and from
then on an unlisting sync prunes it like any other. An operation lists no tab,
so it keeps the marker. The marker expires: an unlisting sync prunes a marked
surface once `PanelSurfaceStore.awaitingListingGrace`, ten minutes and far
longer than the seconds-long race it guards, has passed since the row's last
write, so a moved tab the app never lists does not stay on the main worktree,
which is never archived.

The sync does not carry the selected tab. The app already records it in
`worktree.activeTabID` through `worktree.setActiveTab` on every switch, and
`tbd panel` commands without `--tab` read that column, so they act on the tab
the user is looking at.

### Wire

`PanelGetResult`, `PanelApplyResult` and `PanelSurfaceDelta` keep their shapes
and carry the v2 `WorkspaceTabSurface`, histories included. The app ignores a
delta's `activeTabID`, because workspace-tab selection is the app's: the field
only reports back what the app itself recorded.

App and daemon ship in one build. A daemon left running an older binary sends
surfaces the app cannot decode; the app treats an undecodable surface as absent
(see "The render branch"). An older app reads the capability field the daemon
no longer sends as off, and keeps its legacy layout.

### Legacy import

The converter in `TBDShared` maps one legacy tab to one surface:

- The tab's `content` becomes the primary.
- A tab whose layout holds a terminal anywhere but its primary is not
  converted. If it has no readable surface it gets none, renders legacy, and
  the sync result names it in `skippedTabIDs`, with its reason in `skipped`; a
  tab that already has a readable surface keeps it and is not named. Spec C's importer promoted
  such terminals to new workspace tabs, but workspace tabs are app-owned here,
  so a daemon-made tab would be deleted by the next sync. Terminal splits
  cannot be created since spec C's phase 1, so only layouts older than that
  carry one.
- Each viewer pane in the legacy layout becomes one `ViewerPanel`, in pre-order,
  with a freshly minted panel ID. Legacy pane IDs cannot be reused: a note
  pane's ID is the note's own ID, so one note open in two tabs would collide,
  and panel IDs are a table-wide key.
- A pane's legacy history is kept, filtered to entries of the pane's current
  kind. A pane with no history starts with a one-entry history of its content.
- The first panel becomes active, and `recency` follows panel order.
- `width` comes from the top-level split's ratio for the viewer side when one
  exists, clamped to the valid range, else the default.
- `collapsed` starts false.

### Rollout

There is no feature flag: the store, the tab sync, app rendering and agent
control are always on. Four columns are retired through the column-retire
checklist in `Sources/TBDDaemon/Database/CLAUDE.md`:
`config.panel_tabs_enabled`, `config.daemon_panel_surface_enabled`,
`config.agent_panel_control_enabled`, and `worktree.panel_surface_imported_at`.
With them go `Config.panelTabsDefault`, the capabilities result's
`panelTabsEnabled` and `panelSurfaceEnabled` fields, the
`config.setPanelTabsEnabled` RPC, the `panel-tabs` key of `tbd config`, and the
Settings toggle. The shadow comparator (`PanelShadowCompare.swift`) is deleted:
it compared the legacy tree against the daemon's, and a tabbed region cannot be
compared with a split tree.

CLAUDE.md asks for a default-off flag when a change replaces a load-bearing
path. The owner chose to ship this without one, having used it on their own
install, so the way back is a revert and a release.

### CLI and agent guidance

`tbd panel` (`Sources/TBDCLI/Commands/PanelCommands.swift`). Every subcommand
takes the worktree as its first positional argument (a name or ID, so any
worktree can be targeted, not only the current one), an optional `--tab`
(default: the worktree's active tab), and `--json` for the raw result:

- `list <worktree> [--tab] [--json]` — the side region's panels: kind, content,
  active, collapsed.
- `open <worktree> <content> [--new-panel] [--tab] [--json]`
- `navigate <worktree> --panel <id> <content> [--tab] [--json]`
- `close <worktree> --panel <id> [--tab] [--json]`
- `select <worktree> --panel <id> [--tab] [--json]`
- `back` / `forward <worktree> --panel <id> [--tab] [--json]`
- `jump <worktree> --panel <id> --index <n> [--tab] [--json]`
- `collapse` / `expand <worktree> [--tab] [--json]`
- `resize <worktree> --width <share> [--tab] [--json]`

`<content>` is one of `--file <path>` (with `--render` or `--source` to force a
presentation), `--web <url>`, `--transcript <terminal-id>` or
`--note <note-id>`. A relative `--file` path resolves against the CLI's current
directory, not the target worktree's root, so an agent working outside the
worktree passes an absolute path.

`move`, `select-tab`, and the anchor, edge, share and ratio options are removed.
The agent guidance in `Sources/TBDShared/TBDSkillContent.swift` is rewritten to
match: an agent opens content and lets the reuse rule place it. It names no
setting, because none can refuse a command.

## App

### The app's copy of the surface

`AppState+PanelSurface.swift` holds the surfaces per worktree as a tracked
property of the `@Observable` `AppState`. It is filled by `panel.get` and kept
current by a `panelSurfaceChanged` case in `handleDelta`. A worktree's detail
view loads it whenever the shown tab has no surface in the copy, after sending
any tab sync still pending. So a tab left without a surface
by a failed `panel.get`, or by an import delta missed while the subscription
was down, loads again when it is shown, and a shown tab with a surface asks for
no load. Neither does a tab the last sync named in `skippedTabIDs`: no load
would find a surface for it, and it is offered to the daemon again when its
layout changes (see the second observer below).

A full `panel.get` is merged into the copy rather than assigned, because deltas
keep arriving during its flight. A tab the copy held when the get was issued,
and the result omits, is dropped, unless a delta or an apply reply changed it
in flight; a listed tab goes through the revision guard; and a tab removed in
flight is never put back by the result's listing.

One rule recovers what a subscription gap missed. Every acknowledgement of a
subscription refetches every worktree that has a
tab list in the app, whether or not the copy holds a surface for it. The
refetch waits for the acknowledgement: the daemon registers the subscriber
before it sends the ack, so a `panel.get` issued after the ack cannot miss a
change, which lands either in its reply or in a later delta. So the rule also
covers a `panel.get` the daemon answered before registering, one that failed
across the resubscribe, and a worktree whose last load found no surface. The
refetches go out after any tab sync pending or in flight, and merge under the
guard like any other `panel.get`: revisions are daemon-wide and never
decrease, so a daemon restart leaves them comparable, and the merge makes a
refetch that overlaps another load of the same worktree safe. The copy is kept
meanwhile, so side regions stay on screen through a reconnect.

At connect the app marks every worktree with tabs dirty and syncs the ready
ones before the first acknowledgement, which then does the loading: a fetch
taken before the sync's imports could drop them, and launch loads each
worktree once.

One chokepoint, `applyPanelOperation`, builds the envelope (a fresh operation
ID, origin `.appUser`, the copy's revision as `baseRevision`), sends it, and
adopts the returned tab under the revision guard. On failure it logs, shows a
toast naming the error, and refetches the worktree's surfaces.

Workspace tabs are created, closed, reordered, relabelled and re-pointed from
many places (notes, terminal reconciliation, the setup tab's auto-close, the
PR tab, terminal revival, the file viewer). So the sync is not hooked at each
one: a single observer of the app's tab list marks a worktree dirty when its
tab IDs, order, labels or primaries change, and one sync per dirty worktree is
sent on the next main-actor turn. A second observer, on the legacy layout
store, marks dirty the worktree of a tab the last sync named in
`skippedTabIDs` when that tab's layout changes, so it is offered again once its
extra terminal closes. No other tab is marked this way: a tab with a surface
has its legacy layout unread, and a tab the copy has merely not loaded would
otherwise send a sync on every ordinary legacy layout write.

### The leaf seam

`PanePlaceholder` performs no layout mutation itself. It drops its
`@Binding var layout` and calls an injected `PaneActions` set covering:
history steps, in-panel navigation (a link inside rendered markdown), a
command-clicked file path in a terminal, a file preview opened from a
transcript, file links from a transcript, close, the transcript toggle and its
on-state, the history it displays, and whether close is allowed. On the daemon
set, every file-opening action becomes `open(.file(...))` and the reuse rule
places it.

- **`PaneActions.legacy`** closes over the legacy layout binding and does
  exactly what `PanePlaceholder` did before the seam. It serves the
  multi-worktree grid and tabs the converter skips.
- **The daemon set** turns each action into an operation and reads history and
  on-state from the app's copy. No operation removes the primary.

On the daemon path the leaf draws no header: a tab names and closes what it
shows, and the controls the header held move into the tab row (see "The
renderer"). The state only those controls read — the rendered/source toggle,
whether a file can render, a web page's current address — lives above the
leaf, in the view that draws the row, and is passed in. A leaf in a legacy
split keeps its header, because no tab names it there.

### The renderer

`PanelSurfaceWorkspaceView` draws a workspace tab in two columns: the primary
on the left, the existing `SplitDivider`, and a `SideRegionView` on the right
when the region has panels and is not collapsed. Each column starts with its
own strip of tabs, and the two strips share one row: the workspace tab bar
spans the primary's column, the side region's strip spans its own, and the
divider runs through the row, so a drag resizes both. When the region is
hidden, the workspace tab bar spans the whole width. No pane draws a header.

- **The workspace tab bar** is drawn by this view, not by
  `TerminalContainerView` above it, so that it can share the row. Its trailing
  end holds, in order: the selected tab's own control, Session History, and the
  expand button while the region is collapsed and has panels. The selected
  tab's control is the transcript button for a Claude terminal, the
  rendered/source toggle for a file that can render, and copy-address for a web
  page; a note or a plain terminal has none. A primary has no history, so the
  bar carries no history buttons.
- **The primary** renders through `PanePlaceholder` with the daemon action set.
  Its content comes from the app's own workspace tab, not from the surface: the
  primary is app-owned, so a re-pointed primary shows at once rather than after
  the sync carries it to the daemon.
- **The side region's strip** reads, left to right: history search (the
  searchable history list), back and forward; the panel tabs (icon, title,
  close; a click selects; a right-click offers the file menu); then the active
  panel's own control (the rendered/source toggle for a file, copy-address for
  a web page) and the collapse button at the trailing edge. The three history
  buttons act on the active panel and stay in place, dimmed, when it has no
  history to step through — a transcript or a note — so the tabs never shift
  under the pointer. Below the strip, the active panel renders through
  `PanePlaceholder`.
- **The terminal's pin** is in its workspace tab's right-click menu (Pin or
  Unpin). The pinned-terminal dock keeps its unpin.
- **A note's title** is edited by renaming its tab, in the workspace tab bar or
  the side region's strip, by double-click or Rename Tab. The rename writes the
  note's title and clears any label the workspace tab carried, so the tab shows
  the title.
- **Closing a note's side-region tab** works as closing a workspace note tab
  does: when the note has content the app asks first, then closes the panel
  and deletes the note. Nothing in the app lists notes, so a note closed and
  kept would be unreachable. The `close` operation itself keeps the note, so an
  agent's `tbd panel close` does too.
- **A web page's full address** shows in its tab's tooltip.
- **While Session History is open,** no workspace tab is selected, so the
  history view takes the whole width under a full-width tab bar.
- **Shortcuts:** `⌘\` collapses and expands the region, bound on whichever of
  the two buttons is showing, and a Shift-click on a file link opens it with
  `newPanel`.

### The render branch

`TerminalContainerView.layoutContent` asks one plain function,
`workspaceRenderPath(worktreeID:tabID:)`. It returns the legacy path only for a
tab the last sync named in `skippedTabIDs`, whose layout still splits off a
terminal. Every other tab takes the daemon path: with the copy's surface when it
holds one, and with an empty side region until then. A new tab therefore draws
the same layout before and after its surface arrives, and its terminal view is
never rebuilt. A gesture on a tab with no surface yet sends the worktree's
pending tab sync first, then applies. The multi-worktree grid builds its own
panes and stays legacy.

## Testing

Each branch is tested both ways, asserting opposite outcomes.

- **Shared:** property tests over random operation sequences, checking every
  validator rule after each step; a table of `open` cases covering each step of
  the reuse rule and each kind; `close` choosing the next active panel by
  recency; and the legacy converter (pre-order, kind-filtered history, width
  from the ratio, and a skipped tab when a terminal sits outside the primary).
- **Daemon:** an app and an agent operation both apply with no config
  consulted; the migration empties the three v1 tables; tab sync imports missing tabs,
  never overwrites a readable tab's panels, replaces an unreadable surface
  with its import and reports an unreadable one it cannot convert as skipped,
  updates order, labels and primaries,
  re-parents a surface from another worktree, deletes absent tabs with their
  histories, and broadcasts once; a sync that omits a surface a promote moved
  keeps it within the grace and prunes it past the grace, the first sync that
  lists it clears the marker, and an operation keeps it; archiving or deleting
  the worktree reclaims a marked surface;
  receipt replay returns the stored v2 result;
  `get` returns histories.
- **CLI:** parsing for each new and changed command, and rejection of the
  removed options.
- **App:**
  - The copy: a delta upserts; an older revision is refused; a removal is
    applied whatever the revision; a full `get` drops absent tabs; a delta's
    `activeTabID` does not move the selected tab; resubscribing keeps
    rendering it and, only once the daemon acknowledges the subscription,
    refetches every worktree with a tab list, one with no surface included; a
    get that failed across the resubscribe is refetched by the
    acknowledgement; launch loads each worktree once, after the sync.
  - The tab-sync observer: a change to tab IDs, order, labels or a primary sends
    one sync per worktree; an unrelated `AppState` change sends none.
  - The render branch: a skipped tab renders legacy; a tab with a surface
    renders the daemon path with it; a tab with no surface yet renders the
    daemon path with an empty side region, and its primary keeps its view
    identity when the surface arrives; a gesture on it syncs before it applies.
  - The chrome, as values: the workspace tab bar's trailing control for each
    primary kind; the strip's history buttons enabled for a file or web panel
    and dimmed for a transcript or note; the strip's per-kind control; the
    expand button only while the region is collapsed and has panels.
  - Notes: closing a side-region note tab with content asks, then closes and
    deletes; an empty one closes and deletes without asking; a declined
    confirmation changes nothing; the `close` operation alone keeps the note.
    Renaming a note's tab writes the note's title.
  - The transcript button's three states each send the right operation.
  - `PaneActions.legacy` passes the existing pane tests unchanged.

## Risks

- **Legacy `layouts` read sites.** Several call sites derive which terminals a
  tab renders from the legacy `layouts` store (`AppState`,
  `AppState+Terminals`, `AppState+TerminalFocus`, `TerminalContainerView`). On a
  daemon-rendered tab they fall back to the tab's content, which is correct
  because the primary is the only place a terminal can appear. A future model
  that put a terminal anywhere else would break them.
- **No switch to turn it off.** The way back is a revert and a release. The
  legacy layout store is not written by gestures on a daemon-rendered tab, so
  a reverted build shows each tab's layout from before its import.
- **Old terminal splits keep a tab on legacy.** A workspace tab whose layout
  predates the removal of terminal splits renders legacy, and `tbd panel`
  cannot act on it. Closing the extra terminal, or moving it to its own tab,
  brings the tab onto the surface at the next sync.
- **Links in a primary document open in the side region,** because no
  operation re-points a primary.
- **A note further back in a panel's history outlives the panel.** Closing a
  note panel deletes the note it shows; notes the panel navigated away from
  are kept, and nothing lists them.
- **Local-daemon latency is assumed.** If `panel.apply` ever crossed a network,
  the single round trip would need the optimistic layer.

## Rejected alternatives

- **Keep spec C's free split tree.** It invites layouts nobody wants, makes
  agents pick edges and shares, and lets files and transcripts fight over one
  slot.
- **Express the new layout as a limited split tree.** Less churn, but the types
  would carry anchors, edges and ratio lists that the fixed layout does not
  have.
- **Adapt the daemon surface into the legacy `LayoutNode` and reuse
  `SplitLayoutView`.** The legacy tree has a terminal case in every pane, which
  the new model forbids outside the primary, and its synchronous `@Binding`
  write-back races the daemon's commit.
- **Render read-only from the daemon while gestures still edit legacy.** The
  surface would go stale mid-session, and the round trip would go untested.
- **Keep the model in the app only.** Agents could not drive it.
- **An optimistic layer now.** Nothing in the app is continuous enough to need
  one; it can be added in front of the same chokepoint later.
- **A preview tab that the next file replaces, without history.** The user
  wants back/forward kept; history in a reused file tab gives the same reuse
  and keeps it.
- **A new tab for every file opened.** Tabs pile up and need constant closing.
- **The transcript in its own split beside the file viewer.** It needs no tabs,
  but it widens the layout to three columns.
- **The transcript as its own workspace tab.** It cannot sit beside the
  terminal.
- **Ship behind a default-off flag and soak.** The repo's usual path for a
  load-bearing change; the owner chose to ship without one (see "Rollout").
- **Render a tab legacy until its surface arrives.** Every new tab would switch
  layouts once and rebuild its terminal view.
- **Keep the one-shot import.** New workspace tabs would render legacy, and
  `tbd panel` would silently do nothing on them.
- **A header row under the strip for history and per-kind controls,** shown
  only for files and web pages. It costs a row and moves the content's top edge
  between kinds.
- **Hiding the history buttons for a transcript or note.** The tabs would shift
  sideways under the pointer on every switch to or from one.
- **The transcript button on the terminal's own tab, or in the window
  toolbar.** The tab already carries a status glyph, a title and a close
  button; the window toolbar is per window, and the button acts on one tab.
- **× keeps a side-region note.** Nothing lists notes, so a kept note would be
  unreachable.

## Future extensions

- **A second region,** stacked in the side column: an additional field on
  `WorkspaceTabSurface`, with the reuse rule extended to choose a region.
- **The transcript in the primary area.** A `primaryView` field (terminal or
  transcript) used when the primary is a terminal, plus an operation to switch
  it. The terminal stays the anchor and its session keeps running; the
  one-transcript-view rule already covers it.
- **Drag to reorder tabs,** as a `move(panelID, index)` operation.
- **Retiring the legacy layout store,** once the grid renders from the surface
  and no install holds a tab with a terminal split.
