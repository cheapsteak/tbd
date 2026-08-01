# Phase 3b — Render the app from the daemon panel surface

Status: design, approved for implementation planning
Date: 2026-07-31
Precedes: flag soak/graduation (Phase 3c, not covered here)

## Problem

The daemon owns a panel surface (`WorkspaceTabSurface` per worktree/tab,
Approach C, spec `2026-07-22-panel-agent-surface-c-primary-anchor-design.md`).
The store, the `panel.get`/`panel.apply` RPCs, the one-shot legacy import, the
shadow comparator, and the `tbd panel` CLI are all built and merged. But the
app still **renders** from the legacy `Pane*` model: `SplitLayoutView` draws a
`LayoutNode` tree, gestures mutate it locally, and `panelSurfaceChanged` deltas
hit `default: break` in `AppState.handleDelta`. So the already-shipped agent
write path (`tbd panel open/close/navigate/...`) is inert — a mutation commits
in the daemon but never appears on screen.

Phase 3b makes the app render its workspace from the daemon surface and route
its own gestures through `panel.apply`, so daemon-owned state — whether changed
by the user or by an agent — is what the user sees.

## Non-goals

- **Flipping any flag's default.** 3b ships default-off; graduation is a later
  phase (task #8).
- **Note deletion.** Once the app renders from the new model, closing a note
  panel removes the panel but the note file survives (close ≠ delete). A delete
  affordance is deferred (task #7); in the interim a note is removable only via
  the filesystem. Accepted for a default-off soak feature.
- **`move` (drag-a-panel-to-another-edge).** Drag-and-drop repositioning is its
  own UI project and unneeded day one. Deferred.
- **Native resize indicator / unified divider** (task #9). 3b ports the existing
  divider behavior; the native-resize rework is a follow-up.
- **Retiring legacy app-side persistence.** It stays live during the soak as the
  flag-off fallback. Retiring it is a later phase.

## Approach: flag-switched dual path with an optimistic local mirror

Three cutover strategies were weighed:

- **A — flag-switched dual path (chosen).** A new app flag picks the rendering
  path at the workspace root. Off = today's legacy path, untouched. On = a new
  view renders an in-memory `WorkspaceTabSurface` mirror.
- **B — adapter bridge (rejected).** Feed the existing `SplitLayoutView` from a
  `WorkspaceTabSurface → LayoutNode` adapter and translate its `@Binding`
  mutations back into operations. Rejected: the legacy `LayoutNode` is a
  homogeneous pane tree whose `PaneContent` *has* a terminal case, while the new
  model is a primary-anchor tree whose viewer `PanelContent` has none. Adapting
  flattens and re-inflates the exact primary/viewer distinction the redesign
  exists to make, and the synchronous `@Binding` write-back races the async
  daemon commit (two writers, one binding).
- **C — read-first, mutate-later (rejected).** Render read-only from the surface
  while gestures still mutate legacy. Rejected: the import is one-shot per
  launch, so the rendered surface would be stale mid-session — strictly worse
  than legacy — and it can't validate the `apply → delta → render` round-trip
  because there are no applies.

### Why "daemon-owned" does not mean "laggy"

No gesture in the app is continuous with respect to the layout tree. The
divider's `DragGesture.onChanged` moves a local overlay only; `onEnded` commits,
and `SplitContainer.commitRatios()` is the sole writer into the tree
(`SplitLayoutView.swift:135-137`). Every other operation — open, close,
navigate, history — is a discrete click. So there is no per-frame path that
could accumulate round-trip cost.

The flow for a user gesture is therefore a single round-trip:

1. Gesture → `panel.apply(origin: .appUser)`.
2. The daemon reduces, commits, and returns the authoritative
   `PanelApplyResult.tab` in the response.
3. The app upserts that tab into the mirror → render.
4. The broadcast `panelSurfaceChanged` that follows carries the same tab at the
   same revision, so it lands as a no-op.

The daemon is a local unix-socket process, so this is a sub-millisecond hop plus
one SQLite commit — far under a frame, and it buys a single source of truth with
no reconciliation machinery.

The pure reducer in `TBDShared` (`PanelSurfaceReducer.swift`) makes an
optimistic local layer available if soak measurement ever shows a perceptible
gap: the app can run the same reducer the daemon runs, render immediately, and
let the response confirm. That is strictly additive in front of the same
chokepoint and changes no other component, so it is deliberately not built now.

### Conflicts

The app sends the mirror's current `revision` as `baseRevision`. Note what the
daemon actually does with it: `PanelCoordinator` does not reject an otherwise
valid operation for being based on a stale revision — it only *relabels* an
already-failing vanished-target error as `.staleTarget`. A valid operation
applies against current truth regardless. So `baseRevision` is diagnostic here,
not a lock, and the refetch path is reached mainly through transport or daemon
errors rather than through concurrency.

Staleness is instead handled where it can actually bite: the mirror never
accepts a tab whose `revision` is strictly older than the one it already holds.
Without that guard a `panel.get` in flight (snapshotted at revision N) can
resolve after an agent's delta at N+1 and silently revert the mirror — and
because deltas are only emitted on change, nothing would correct it until the
next mutation. The same window exists between an `apply` and its own response.
Removal is exempt: a tab absent from a full `panel.get`, or named in a delta's
`removedTabIDs`, is dropped whatever revision the mirror holds. Last-writer-wins
on content, authoritative-set on existence. No CRDT, no operational transform.

## Ownership and operations

The daemon owns the whole surface, **including split ratios**. Widths must
survive restart (design decision), and ratios are welded to the split nodes the
daemon already owns for open/close — splitting ratio ownership app-side would
force a permanent dual-store reconciliation (daemon owns structure, app owns
per-`SplitID` ratios, reconciled on every structural change) plus app-side
auto-placement of agent-opened panels. Single ownership with one shared reducer
is simpler; the app just fires operations and renders.

Operations wired in 3b: `open`, `close`, `navigate`, `history`, `resize`.

- **Resize** stays purely local during the drag (no per-frame RPC); one
  `apply(resize)` fires on drag-end. On release the daemon persists the ratios,
  so widths survive restart.
- **Ephemeral state** — keyboard focus, scroll position, in-progress drag —
  never reaches the daemon. Only structural state (which panels exist, their
  content, split ratios, history) is daemon-owned.

Deferred operations: `move`.

## Components

### `AppState` — the mirror and the delta handler

- Hold an in-memory mirror of the surface: `[worktreeID: PanelGetResult]` (tabs
  + active tab), populated from `panel.get` when `enableDaemonManagedPanels` is
  on, and kept current by the delta handler.
- Replace `default: break` for `.panelSurfaceChanged` in `handleDelta` with a
  reconcile: upsert the delta's affected `tabs`, drop `removedTabIDs`, set the
  active tab. Guarded to mutate the mirror only when the render flag is on (the
  daemon may broadcast during the store-only soak with the render flag off).
- A gesture chokepoint that: runs `PanelSurfaceReducer` against the mirror,
  updates the mirror (optimistic render), then fires
  `panel.apply(envelope, origin: .appUser)` with the mirror's current
  `revision` as `baseRevision`; on rejection, refetch + re-render.

### `PanelSurfaceWorkspaceView` (new) — the renderer

- Renders a `WorkspaceTabSurface`: the `.primary` anchor plus the recursive
  viewer-panel split tree, from the mirror.
- Emits gestures (open/close/navigate/history/resize) to the `AppState`
  chokepoint. Reuses the existing `SplitDivider` (native-resize rework is #9).
- Reuses the existing leaf view (`PanePlaceholder` — toolbar, pane label, history
  controls, content rendering) rather than duplicating it, by way of a mutation
  seam: the leaf calls an injected action set, which the legacy path fills with
  today's local tree mutations and this path fills with `panel.apply` calls. The
  leaf is fed by a `PanelContent → PaneContent` mapping, total because
  `PanelContent` is a strict subset (no terminal case). This is content-only —
  the mapping is never used to rebuild a `LayoutNode` tree, which is what makes
  it different from the rejected adapter bridge: the tree renderer and the source
  of truth stay separate per path, and no `@Binding` races the daemon.

### Workspace root — the switch

At the point that today instantiates `SplitLayoutView`, branch on the flag:
render `PanelSurfaceWorkspaceView` when `enableDaemonManagedPanels` is on **and**
the daemon reports `panelSurfaceEnabled` (the store must be on for a surface to
exist); otherwise the legacy path, unchanged.

## Flags — the soak ladder (three independent rungs)

- `daemon_panel_surface_enabled` (existing daemon `config` column, default off) —
  store + import + shadow-compare. Already built. Unchanged here.
- **`enableDaemonManagedPanels` (new, app `UserDefaults`, default off)** — the
  app renders panels from the daemon surface and routes its gestures through
  `panel.apply`. Precedent: `enableTranscript` (app-only presentation toggle,
  default off). Guarded to require `daemon_panel_surface_enabled` on; with the
  store flag off it falls back to the legacy path (can't render a surface that
  was never imported).
- `agent_panel_control_enabled` (existing, default off) — gates
  `origin: .agentCLI` applies. **Not touched in 3b.** App gestures use
  `origin: .appUser`, which the coordinator gates only on
  `daemon_panel_surface_enabled`, so the app write path works without the agent
  flag.

No new database migration — the config column already exists (added with the
daemon surface). This is an app-only presentation flag, so `UserDefaults` is the
right home per the project convention (large/risky *daemon* behavior gates on a
config column; app-only behavior may gate on `UserDefaults`).

## Testing

- **Flag off:** the workspace root renders the legacy `SplitLayoutView`; gestures
  still mutate the legacy model and persist; `panelSurfaceChanged` deltas do not
  touch any rendering state.
- **Flag on:** the workspace root renders `PanelSurfaceWorkspaceView` from the
  mirror; each gesture updates the mirror and fires an `apply`.
- **Reconcile:** an `apply`-then-matching-delta is a no-op on the mirror; a
  concurrent-divergence delta snaps the mirror to daemon truth; a
  `baseRevision`-rejected apply triggers a refetch + re-render.
- **Guard:** with the render flag on but the store flag off, the root still
  renders legacy.
- Shared-reducer parity (local vs daemon result) is already covered by existing
  `PanelSurfaceReducer` tests; 3b does not re-cover it.

## Open follow-ups (not in 3b)

- **Per-panel history on the wire — required before graduation.**
  `PanelGetResult` carries tabs only, and `WorkspaceTabSurface` has no histories;
  the daemon keeps `PanelHistory` in its own store. So on the daemon path the app
  cannot know a panel's back/forward state, and the history chevrons render
  disabled even after the daemon has recorded navigations. The `.history`
  operation itself is wired and correct — only the affordance is dark. Reading
  `paneHistories` as a stand-in would be wrong, not merely incomplete: the legacy
  import reuses legacy pane IDs as panel IDs for viewers, so the same key returns
  plausible but stale legacy state. The fix is to return per-panel history from
  `panel.get` / `PanelApplyResult`, which is a daemon + `TBDShared` change.
- **Surfaces for tabs created after the import — required before graduation.**
  The legacy import is one-shot per worktree, and nothing in the daemon creates a
  `WorkspaceTabSurface` outside it. A tab created after that import therefore has
  no surface, so the render branch falls back to legacy for that tab. The
  fallback is correct — rendering blank would be worse — but it means one window
  can hold both models at once, with `tbd panel …` silently doing nothing on the
  legacy tabs. That materially narrows what the soak exercises. The fix is
  daemon-side surface creation on tab creation, outside 3b's app-only scope.
- Note deletion affordance (#7) — required before graduation, since close no
  longer deletes.
- Native resize indicator / unified divider (#9).
- `move` / drag-to-reposition.
- Flag soak and graduation (#8): enable `enableDaemonManagedPanels`, dogfood,
  then graduate; retire legacy app-side persistence afterward.
