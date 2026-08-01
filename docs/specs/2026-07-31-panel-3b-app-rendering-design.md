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

The pure reducer already lives in `TBDShared` (`PanelSurfaceReducer.swift`), so
the app runs the *same* reducer the daemon runs, locally, on the main thread.
A user gesture never waits on the round-trip:

1. Gesture → run `PanelSurfaceReducer` against the local mirror → render
   immediately (as instant as today's `@Binding` mutation).
2. Fire `apply(origin: .appUser)` in the background.
3. The daemon runs the same reducer, commits, broadcasts `panelSurfaceChanged`.
4. The app reconciles: the delta almost always matches what the app already
   computed (same reducer, same input) → no-op.

Async only appears where it is imperceptible: the agent path (nobody waits on a
CLI command) and the background commit of a user gesture (masked by the
optimistic render). The daemon is also a local unix-socket process — the
round-trip is sub-millisecond regardless.

### Conflicts

Divergence between the optimistic local result and the daemon's broadcast
happens only on genuine concurrency — an agent applied to the same tab between
the app's `baseRevision` and its commit. Single-user, rare. Resolution is
last-writer-wins: snap the mirror to daemon truth from the delta. If the app's
own `apply` is rejected for a stale `baseRevision`, refetch via `panel.get` and
re-render. No CRDT, no operational transform.

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
  chokepoint. Ports the existing divider's drag behavior (native-resize rework
  is #9).

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

- Note deletion affordance (#7) — required before graduation, since close no
  longer deletes.
- Native resize indicator / unified divider (#9).
- `move` / drag-to-reposition.
- Flag soak and graduation (#8): enable `enableDaemonManagedPanels`, dogfood,
  then graduate; retire legacy app-side persistence afterward.
