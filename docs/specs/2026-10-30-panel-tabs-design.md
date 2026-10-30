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

The model the daemon owns also carries a design that no longer fits. Spec C
kept a free-form split tree: any panel can split on any edge, nested to any
depth, with a ratio list per split. That freedom came from a time when TBD was
shaped like tmux. In use, it causes two problems:

- **Files and transcripts fight over the same slot.** The transcript button
  takes over a file viewer, and a file link clicked inside a transcript takes
  over the transcript's own viewer when no other viewer exists. Rendering this
  model from the daemon makes it worse: the natural second click of the
  transcript button is `close`, which removes the panel and the file the
  transcript replaced.
- **Agents must reason about geometry.** `tbd panel open` asks for an anchor,
  an edge and a share, which is layout work an agent has no good basis for.

Two daemon-side gaps also stand between the surface and graduation:

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
- While the feature is on, every workspace tab the app shows has a surface,
  except a tab whose legacy layout still splits off a terminal (see "Legacy
  import").
- One Settings toggle turns the whole feature on, default off.

## Non-goals

- **Flipping the default.** This ships off; graduation is a later change.
- **More than one region.** The model leaves room for a second region (see
  "Future extensions"), but only one is built.
- **Dragging tabs to reorder them.**
- **Note deletion.** Closing a note's tab removes the tab and keeps the note
  (close ≠ delete). A delete affordance is required before graduation, not now.
- **Retiring the legacy layout store.** It stays live as the flag-off path.

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

The transcript button sits in the primary terminal's header. On the daemon path
the app decides what to send from its copy of the surface:

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
soak measurement ever shows a visible gap: the app could run the same reducer,
render at once, and let the reply confirm. It is not built.

`baseRevision` is sent for diagnostics only. The daemon applies a valid
operation against current state regardless of the base; it uses a stale base
only to relabel an already-failing vanished-target error as `staleTarget`.

Staleness is handled in the app's copy instead: it never adopts a tab whose
revision is lower than the one it holds. Without that guard a `panel.get` in
flight at revision N could land after a delta at N+1 and revert the copy, and
since deltas fire only on change, nothing would correct it until the next
mutation. Removal is exempt: a tab absent from a full `panel.get`, or named in a
delta's `removedTabIDs`, is dropped whatever revision the copy holds.

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
from it.

- `workspace_tab_surface` keeps one row per workspace tab. Its `layout` column
  holds the `SideRegion` JSON without histories; `primaryContent`, `label`,
  `position` and `revision` keep their meaning.
- `panel_history` keeps one row per panel. The store joins histories into
  `ViewerPanel.history` when it reads a surface and splits them out when it
  writes one, inside the same transaction.
- `panel_operation_receipt` keeps idempotent replay unchanged; its stored
  result is a v2 `PanelApplyResult`.

`PanelSurfaceStore.applyReducing` keeps its shape: load, reduce and persist
inside one write transaction, so concurrent applies to one tab cannot lose an
update.

### Coordinator and gating

`PanelCoordinator.apply` keeps its pipeline: gate, idempotency replay,
resource-existence check for `open` and `navigate`, reduce, persist, broadcast.
The gate reads one flag, `panel_tabs_enabled`, for every mutating origin, app
and agent alike. `panel.get` stays ungated.

### Tab sync

A new RPC, `panel.syncTabs`, replaces the one-shot `panel.importLegacy`:

```swift
struct PanelSyncTabsParams {
    let worktreeID: UUID
    let tabs: [LegacyTabPayload]   // every workspace tab, in order
    let paneHistories: [UUID: MRUHistory<PaneContent>]
}
```

While the flag is on, the app sends it when it connects and whenever a workspace
tab is created, closed, reordered or relabelled. In one transaction the daemon:

- **imports each listed tab that has no surface,** converting its legacy layout
  (see "Legacy import");
- **never overwrites a tab that has a surface,** so the daemon stays the
  authority for what is inside a tab;
- **re-parents a listed tab's surface that sits under another worktree.** Tab
  IDs are global, and promoting a scratch worktree moves its tabs to the main
  worktree; the tab's panels move with it;
- **updates `position`, `label` and `primary`** on existing surfaces to match
  the list. No operation changes a primary, so the primary is app-owned like
  the tab itself; the file viewer, for one, points a file tab's primary at a
  new file in place;
- **deletes this worktree's surfaces for tabs not in the list,** with their
  histories, and names them in the delta's `removedTabIDs`.

It broadcasts one `panelSurfaceChanged` for whatever changed. The worktree's
existing cascade still removes every surface when the worktree row is deleted.
Archiving keeps the row, so the cascade never fires: `WorktreeStore.archive`,
which every archive path goes through, deletes the worktree's surfaces, their
histories and its operation receipts in the same transaction, and the app drops
the worktree from its copy. A revive needs nothing back, because the next sync
re-imports its tabs from the legacy layout.

The sync does not carry the selected tab. The app already records it in
`worktree.activeTabID` through `worktree.setActiveTab` on every switch, flag or
no flag, and `tbd panel` commands without `--tab` read that column, so they act
on the tab the user is looking at.

### Wire

`PanelGetResult`, `PanelApplyResult` and `PanelSurfaceDelta` keep their shapes
and carry the v2 `WorkspaceTabSurface`, histories included. The app ignores a
delta's `activeTabID`, because workspace-tab selection is the app's: the field
only reports back what the app itself recorded.

App and daemon ship in one build. A daemon left running an older binary sends
surfaces the app cannot decode; the app treats an undecodable surface as absent
and renders legacy.

### Legacy import

The converter in `TBDShared` maps one legacy tab to one surface:

- The tab's `content` becomes the primary.
- A tab whose layout holds a terminal anywhere but its primary is not
  converted. It gets no surface, renders legacy, and the sync result names it
  in `skipped`. Spec C's importer promoted such terminals to new workspace
  tabs, but workspace tabs are app-owned here, so a daemon-made tab would be
  deleted by the next sync. Terminal splits cannot be created since spec C's
  phase 1, so only layouts older than that carry one.
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

### Flag and rollout

One new `config` column, `panel_tabs_enabled`, added in a `.sql` migration with
no SQL default, so NULL stays distinct from an explicit choice. The shipped
default lives only in `?? Config.panelTabsDefault` (false) in
`ConfigRecord.toModel()`, so graduation is a one-line change that preserves every
explicit opt-out. The daemon reports the flag in its capabilities result as
`panelTabsEnabled`, which the app already reads; the result's
`panelSurfaceEnabled` field goes with its column.

One Settings toggle sets it, with the working label "Side panel with tabs,
shared with agents (experimental)", through a new `config.setPanelTabsEnabled`
RPC; `tbd config` gains the matching key. It turns on the store, the tab sync,
app rendering and agent control together.

Retired in the same change, through the column-retire checklist in
`Sources/TBDDaemon/Database/CLAUDE.md` (one epoch bump): `config.daemon_panel_surface_enabled`,
`config.agent_panel_control_enabled`, and `worktree.panel_surface_imported_at`.
The shadow comparator (`PanelShadowCompare.swift`) is deleted: it compared the
legacy tree against the daemon's, and a tabbed region cannot be compared with a
split tree.

### CLI and agent guidance

`tbd panel` (`Sources/TBDCLI/Commands/PanelCommands.swift`):

- `list [--tab]` — the side region's panels: kind, content, active, collapsed.
- `open <content> [--new-panel] [--tab]`
- `navigate --panel <id> <content> [--tab]`
- `close --panel <id> [--tab]`
- `select --panel <id> [--tab]`
- `back` / `forward --panel <id> [--tab]`
- `jump --panel <id> --index <n> [--tab]`
- `collapse` / `expand [--tab]`
- `resize --width <share> [--tab]`

`move`, `select-tab`, and the anchor, edge, share and ratio options are removed.
The agent guidance in `Sources/TBDShared/TBDSkillContent.swift` is rewritten to
match: an agent opens content and lets the reuse rule place it.

## App

### The app's copy of the surface

`AppState+PanelSurface.swift` holds the surfaces per worktree as a tracked
property of the `@Observable` `AppState`. It is filled by `panel.get` when the
flag is on, kept current by a `panelSurfaceChanged` case in `handleDelta`, and
cleared when the daemon reports the flag off. A delta or fetch while the flag is
off leaves it untouched. It is also cleared and refetched whenever the app
(re)subscribes to the daemon: a new daemon may have reset revisions, and the
revision guard would otherwise refuse every lower one.

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
store, marks dirty the worktree of a tab that has no surface when that tab's
layout changes, so a tab the sync skipped is offered again once its extra
terminal closes. A tab with a surface is never marked this way: its legacy
layout is not read.

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
  exactly what `PanePlaceholder` does today. The rollback guarantee is checked
  expression by expression against `PanePlaceholder` as it stands on main when
  the seam lands.
- **The daemon set** turns each action into an operation and reads history and
  on-state from the app's copy. Close is disabled on the primary, which no
  operation can remove.

### The renderer

`PanelSurfaceWorkspaceView` lays out the primary on the left, the existing
`SplitDivider`, and a `SideRegionView` on the right when the region has panels
and is not collapsed.

- **The primary** renders through `PanePlaceholder` with the daemon action set,
  so the terminal keeps its header and transcript button. Its content comes
  from the app's own workspace tab, not from the surface: the primary is
  app-owned, so a re-pointed primary shows at once rather than after the sync
  carries it to the daemon.
- **`SideRegionView`** shows a tab strip (each tab: icon, title, close button;
  a click selects) with a collapse button, and below it the active panel through
  `PanePlaceholder`, which keeps its history chevrons and actions. The leaf's own
  title is hidden here, because the tab shows it.
- **When the region is collapsed** but has panels, an expand button sits in the
  primary's header.
- **Shortcuts:** collapse/expand gets a keyboard shortcut, and a modifier-click
  on a file link opens it with `newPanel` wherever the click handler can see
  modifier keys. The plan chooses both after checking existing bindings.

### The render branch

`TerminalContainerView.layoutContent` asks one plain function,
`workspaceRenderPath(worktreeID:tabID:)`, which returns the daemon path only when
the daemon reports `panel_tabs_enabled` on **and** the app's copy holds a
surface for that tab. Every other case renders the legacy `SplitLayoutView`,
unchanged. The multi-worktree grid builds its own panes and stays legacy.

## Testing

Each gated branch is tested both ways, asserting opposite outcomes.

- **Shared:** property tests over random operation sequences, checking every
  validator rule after each step; a table of `open` cases covering each step of
  the reuse rule and each kind; `close` choosing the next active panel by
  recency; and the legacy converter (pre-order, kind-filtered history, width
  from the ratio, and a skipped tab when a terminal sits outside the primary).
- **Daemon:** the gate under NULL, false and true; a pre-migration config row
  reads NULL, and an explicit false survives a change to the default constant;
  the migration empties the three v1 tables; tab sync imports missing tabs,
  never overwrites a tab's panels, updates order, labels and primaries,
  re-parents a surface from another worktree, deletes absent tabs with their
  histories, and broadcasts once; receipt replay returns the stored v2 result;
  `get` returns histories.
- **CLI:** parsing for each new and changed command, and rejection of the
  removed options.
- **App:**
  - The copy: flag off leaves it untouched; a delta upserts; an older revision
    is refused; a removal is applied whatever the revision; a full `get` drops
    absent tabs; a delta's `activeTabID` does not move the selected tab;
    resubscribing clears and refetches it.
  - The tab-sync observer: a change to tab IDs, order, labels or a primary sends
    one sync per worktree; an unrelated `AppState` change sends none; flag off
    sends none.
  - The render branch: flag off renders legacy; flag on with no surface renders
    legacy; flag on with a surface renders the daemon path; daemon flag off
    renders legacy.
  - The transcript button's three states each send the right operation.
  - `PaneActions.legacy` passes the existing pane tests unchanged.
  - The Settings toggle writes the config flag.

## Risks

- **Legacy `layouts` read sites.** Several call sites derive which terminals a
  tab renders from the legacy `layouts` store (`AppState`,
  `AppState+Terminals`, `AppState+TerminalFocus`, `TerminalContainerView`). On a
  daemon-rendered tab they fall back to the tab's content, which is correct
  because the primary is the only place a terminal can appear. A future model
  that put a terminal anywhere else would break them.
- **The legacy layout goes stale while the flag is on.** Gestures on a
  daemon-rendered tab do not write the legacy store, so turning the flag off
  shows the layout from before the soak.
- **Old terminal splits keep a tab on legacy.** A workspace tab whose layout
  predates the removal of terminal splits renders legacy while the flag is on,
  and `tbd panel` cannot act on it. Closing the extra terminal, or moving it to
  its own tab, brings the tab onto the surface at the next sync.
- **Notes are only closable during the soak.** Close keeps the note, and there
  is no delete affordance yet.
- **Local-daemon latency is assumed.** If `panel.apply` ever crossed a network,
  the single round trip would need the optimistic layer.

## Rejected alternatives

- **Keep spec C's free split tree.** It invites layouts nobody wants, makes
  agents pick edges and shares, and lets files and transcripts fight over one
  slot.
- **Express the new layout as a limited split tree.** Less churn, but the types
  would keep anchors, edges and ratio lists that the layout no longer has.
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
- **Three flags (store, render, agent).** The store-only rung existed for shadow
  comparison, which cannot compare a tabbed region with a split tree; one toggle
  is what a person turning the feature on needs.
- **Keep the one-shot import.** New workspace tabs would render legacy, and
  `tbd panel` would silently do nothing on them.

## Future extensions

- **A second region,** stacked in the side column: an additional field on
  `WorkspaceTabSurface`, with the reuse rule extended to choose a region.
- **The transcript in the primary area.** A `primaryView` field (terminal or
  transcript) used when the primary is a terminal, plus an operation to switch
  it. The terminal stays the anchor and its session keeps running; the
  one-transcript-view rule already covers it.
- **Drag to reorder tabs,** as a `move(panelID, index)` operation.
- **A note delete affordance,** required before graduation.
- **Retiring the legacy layout store** after graduation.
