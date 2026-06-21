# Spike: AppKit virtualized transcript list (issue #129)

Date: 2026-06-20 (spike) / 2026-06-21 (live verification) — branch `spike-nscollectionview-transcript`
Status: THROWAWAY prototype, LIVE-VERIFIED. **Verdict: virtualization GO, in-row
text selection NO-GO via clean approaches** — see "Live verification results"
below. The branch is a record, not for merge.

## TL;DR verdict

- **Virtualization works and is a big win.** With 500 preseeded rows the table
  realized only **82 distinct rows** (visible + the bottom set after pin), and the
  mount came up **fast with no freeze** — where the production `LazyVStack` path
  hard-freezes for ~3.9 s reconciling all 500 (`ForEachState.applyNodes`). This is
  the O(N)→O(visible) win #129 needs.
- **In-row text selection is the blocker (#244).** The only implementation that
  delivered drag-select (a manual `mouseDown` → forward) caused **infinite
  recursion → SIGSEGV** (NSHostingView's responder chain forwards the event back
  up to the table's `mouseDown`). The clean, non-recursive fix
  (`validateProposedFirstResponder` + no forward) stops the crash **but selection
  stops working** — the drag never reaches the hosted SwiftUI text. A diagnostic
  that force-enabled `.textSelection` (bypassing the hover gate) **still** didn't
  select, proving it's not hover routing but the deeper `NSTableView`-owns-the-mouse
  vs hosted-text-wants-the-drag conflict. Making selection robust would require a
  substantial custom event-tracking layer (manually driving the hosted text view's
  selection without recursion) — not a quick win.
- **Residual cost:** ~104 sub-second watchdog stalls during the run, from the pane
  rebuilding `transcriptRenderNodes(from:)` O(N) per update (no cache) plus each
  visible cell's own `NSHostingView` automatic-row-height SwiftUI layout. Tuning,
  not a blocker for the virtualization question, but note the per-visible-cell
  hosting overhead is real (≈visible-count hosting views, recycled — not 500).

## Goal (go/no-go)

Prove an AppKit virtualizing list can replace the transcript's
`LazyVStack { ForEach }` to fix #129's O(N) `ForEach.applyNodes` reconciliation.
`LazyVStack` makes *body realization* lazy but NOT *list reconciliation* — every
content change still diffs all N rows. A real AppKit virtualizer realizes and
reconciles only ~visible rows → O(visible).

Three proof points to validate live:
1. **Virtualization** — with 500 synthetic items, only ~visible rows (~10–30)
   realize, not 500.
2. **Text selection vs row selection (#244)** — a mouse drag inside a row
   selects TEXT (reaching the hosted SwiftUI `.textSelection`), not the row.
3. **Bottom-pin / streaming** — appends auto-scroll when already at bottom; a
   user scrolled up is left alone.

## Approach chosen: view-based NSTableView (not NSCollectionView)

`VirtualizedTranscriptList` (`Sources/TBDApp/Panes/Transcript/VirtualizedTranscriptList.swift`)
is an `NSViewRepresentable` wrapping `NSScrollView` + a single-column
`NSTableView` with `usesAutomaticRowHeights = true` and `style = .plain`. Each
row is an `NSTableCellView` (`HostingTableCellView`) containing an
`NSHostingView<RowHost>` that hosts one SwiftUI `TranscriptRow`.

**Why NSTableView over NSCollectionView:** the transcript rows are
variable-height self-sizing content. NSTableView's `usesAutomaticRowHeights`
lets each row's `NSHostingView` autolayout-fit and reports that height to the
table — the documented happy path for variable heights, and the table only
realizes visible rows + a small overscan. NSCollectionView would require a
compositional list layout with *estimated* heights to self-size, which is
strictly more risk for variable content and no extra payoff here. NSCollectionView
would only be worth it if NSTableView blocked us; it did not.

## How the three proof points are wired

### 1. Virtualization + realize counter
- `tableView(_:viewFor:row:)` is the virtualization seam — AppKit calls it only
  for rows entering the visible region (plus overscan). It reuses recycled
  `HostingTableCellView`s via `makeView(withIdentifier:)`.
- Each realize logs `virt.realize id=<nodeID> row=<n>` at `.debug` on
  `Logger(subsystem: "com.tbd.app", category: "perf-transcript")`, gated by
  `ProcessInfo...["TBD_PERF_ROW_REALIZE"] == "1"`. (No `print()` — SwiftLint
  `no_print_in_sources` enforced; confirmed clean.)
- Streaming updates diff in `Coordinator.update(to:)`: a pure append (same
  prefix, longer) → `insertRows(at:withAnimation:[])`, keeping existing rows'
  hosting views alive and realizing only the newly-visible tail; anything else
  falls back to `reloadData()` (still O(visible) to realize).

### 2. Text selection vs row selection (#244)
- `tableView.selectionHighlightStyle = .none`, `shouldSelectRow` returns
  `false` → AppKit never claims a click/drag for row selection.
- `RowHost` mirrors production `SelectableTranscriptRow`: owns `@State isHovered`
  and flips `\.transcriptTextSelection` true on hover, so
  `.textSelection(.enabled)` materializes per-hovered-row exactly like
  production (preserves the #120 single-live-NSTextField behavior).
- `TranscriptTableView.mouseDown` forwards the event to the deepest `hitTest`
  view under the cursor (the NSHostingView's internal text view) instead of
  letting `super.mouseDown` start row-tracking. **This is the risky bit — see
  open risks.**

### 3. Bottom-pin / streaming
- `Coordinator.isNearBottom()` checks `documentHeight - viewportBottom < 40pt`.
- After an append/reload, if we *were* near bottom, `scrollRowToVisible(last)`
  re-pins. Initial load force-pins to bottom (newest content visible).
- The SwiftUI `atBottom` binding is set true `.onAppear` for the spike (the
  jump-to-bottom button is driven by the virtualizer's own pin, not the
  LazyVStack sentinel).

## Gate

`TranscriptItemsView.useVirtualizedTranscript(_ environment:) -> Bool` returns
true only when `TBD_VIRT_TRANSCRIPT == "1"`. `bodyView` branches on it: ON →
`VirtualizedTranscriptList`; OFF → the original `LazyVStack { ForEach }`,
unchanged. Unit test: `Tests/TBDAppTests/TranscriptVirtualizationGateTests.swift`
covers absent/empty/non-1 (false) and "1" (true). `swift test --filter
TranscriptVirtualizationGateTests` → 4/4 pass.

## Launch recipe (interactive verification — human required)

Headless tests cannot verify virtualization/selection/pin; needs a running GUI.
Build the bundled app first (do not run `swift run TBDApp` directly), then launch
with the three env vars:

```sh
scripts/restart.sh          # builds .build/debug/TBD.app + restarts this worktree
open .build/debug/TBD.app \
  --env TBD_VIRT_TRANSCRIPT=1 \
  --env TBD_TRANSCRIPT_PERF_HARNESS=1 \
  --env TBD_PERF_PRESEED=500 \
  --env TBD_PERF_ROW_REALIZE=1
```

Then stream the realize log (note: `log` is a zsh builtin here — use the full
path):

```sh
/usr/bin/log stream --level debug \
  --predicate 'subsystem == "com.tbd.app" AND category == "perf-transcript"'
```

(If `.debug` rows don't appear, once-per-subsystem:
`sudo log config --subsystem com.tbd.app --mode "level:debug,persist:debug"`.)

### What to look for
- **Virtualization:** with 500 preseeded items, count distinct `virt.realize`
  lines on initial display — expect ~10–30 (visible + overscan), NOT 500.
  Scrolling emits more realize lines for newly-visible rows; that's expected
  and is the whole point (O(visible) per viewport, not O(N) per change).
- **Text selection:** hover a chat-bubble row, then click-drag across its text.
  The TEXT should highlight (selection), and the row should NOT highlight as a
  selected row. Cmd-C should copy the selected text.
- **Bottom-pin:** with `TBD_PERF_INJECT_COUNT`/`TBD_PERF_INJECT_MS` streaming
  appends, when scrolled to bottom new rows should auto-scroll into view; scroll
  up a few rows and confirm appends no longer yank you down.

## Open risks / things NOT resolved headlessly

- **TEXT SELECTION IS THE GATING RISK and is UNVERIFIED.** The
  `TranscriptTableView.mouseDown` → `hitTest` → forward approach is the standard
  way to let a hosted view win the drag, but I could not confirm headlessly that
  (a) `NSHostingView`'s internal SwiftUI text view actually receives the drag
  sequence (down/dragged/up) cleanly, (b) selection doesn't get cancelled when
  the table tries to autoscroll, or (c) drag that crosses a row boundary behaves
  sanely (selection cannot span rows — each row is its own text view, same as
  production). If the forward fights row tracking, fallbacks to try:
  override `validateProposedFirstResponder`, or set the cell's hosting view as
  the hit-test winner via `acceptsFirstMouse`. Document outcome after the live run.
- **Row height churn during streaming:** `usesAutomaticRowHeights` recomputes
  heights lazily; rapid appends + `insertRows` may cause visible reflow/jitter.
  Acceptable for a spike; note severity after live run.
- **Hover gate + recycled cells:** `HostingTableCellView` reuses its
  `NSHostingView` and just swaps `rootView`. `RowHost`'s `@State isHovered`
  belongs to the SwiftUI identity, which should reset on rootView swap — verify
  no stale hover (wrong row showing selectable text) during fast scroll.
- **Bottom-pin precision:** the 40pt `isNearBottom` threshold and the
  `DispatchQueue.main.async` re-pin are coarse; fine for go/no-go.

## Live verification results (2026-06-21)

Verified interactively with the perf harness (`TBD_VIRT_TRANSCRIPT=1` +
`TBD_TRANSCRIPT_PERF_HARNESS=1`, preseed 500, `TBD_PERF_ROW_REALIZE=1`).

**Render plumbing — two non-obvious bugs had to be fixed before anything showed:**
1. *Reentrancy → blank.* `updateNSView` mutated the table (`reloadData`/`insertRows`)
   synchronously inside SwiftUI's update pass → "reentrant operation in its
   NSTableView delegate" → AppKit dropped the reload → `viewFor` never fired
   (`virt.realize=0`), blank. Fix: defer a coalesced apply via `DispatchQueue.main.async`
   (commit `0a41330`).
2. *Nested scroll → blank.* The gate originally swapped the virtualizer in *inside*
   `TranscriptItemsView`, which lives inside the pane's SwiftUI `ScrollView`. A
   SwiftUI `ScrollView` proposes UNBOUNDED height to its content, so the
   `NSViewRepresentable` never got a bounded viewport → no visible region → blank.
   Fix: move the gate up to `LiveTranscriptPaneView.transcriptWithAutoscroll` so the
   virtualizer *replaces* the `ScrollView` and fills the pane (commit `d95f6be`).

   Lesson: a virtualizer must own its scrolling; never nest it in a SwiftUI ScrollView.

**Proof point 1 — virtualization: ✅ CONFIRMED.** 82 distinct `virt.realize` rows
out of 500 (rows 0–28 at top, 471+ at bottom after force-pin), no mount freeze.
Production `LazyVStack` on the same 500 = a 3.9 s `ForEachState.applyNodes` freeze.

**Proof point 2 — in-row text selection (#244): ❌ BLOCKED.**
- The first attempt (`TranscriptTableView.mouseDown` → `hitTest` → forward the event
  to the hosted view) *did* select text live, but then **crashed**: SIGSEGV, "stack
  size exceeded due to excessive recursion", **27,948 levels** of
  `TranscriptTableView.mouseDown → NSHostingView.mouseDown → forwardMethod → …`. The
  hosted view's responder chain forwards the unhandled event back up to the table's
  `mouseDown`, which forwards down again — unbounded mutual recursion (commit `f6b245f`
  removed it).
- The clean replacement (`validateProposedFirstResponder` returns true; no manual
  forward; `selectionHighlightStyle=.none`, `shouldSelectRow=false`) **does not
  crash but also does not select** — the drag never reaches the hosted text.
- Diagnostic: forcing `.environment(\.transcriptTextSelection, true)` (selection
  always-on, bypassing the hover gate) **still didn't select** → the cause is NOT
  `.onHover` not firing; it's the deeper conflict that `NSTableView` owns the mouse
  (each row is a separate `NSHostingView` that never becomes first responder / never
  receives the down→dragged→up sequence). Note: even if solved, selection still can't
  span rows (each cell is its own text view) — but that matches production, which
  already gates selection to a single hovered row.

**Proof point 3 — bottom-pin / streaming:** appends rendered and the view re-pinned
to bottom (realize log showed bottom rows + injected rows). Not stress-tested;
adequate-looking for the spike, coarse (40pt threshold).

## Verdict & paths forward

**Virtualization is proven and high-value; in-row text selection is a genuine
blocker via every clean approach tried.** The approach is NOT adoptable as-is.

Options for whoever picks this up (ranked):
1. **SwiftUI-only windowing (lowest risk).** Keep the `LazyVStack` but cap rendered
   items (e.g. last N + "load earlier", drop far-offscreen rows) so reconciliation N
   is bounded without AppKit. Lower ceiling than true virtualization, but **preserves
   native text selection** and avoids the entire #244 event conflict.
2. **Virtualize + replace drag-select with a copy affordance.** Adopt the NSTableView
   virtualizer (the big perf win) but drop in-row drag-select in favor of a per-message
   "copy" button / "copy message" action — sidesteps the table-vs-text event conflict
   entirely. UX change; needs product sign-off.
3. **Custom event layer to make drag-select work (highest effort/risk).** Manually
   drive the hosted text view's selection from the table's mouse events without
   recursion (own tracking loop / explicit first-responder management). Uncertain it
   can be made robust; this is the part the spike showed is hard.
4. **Drop virtualization; pursue cheaper #129 levers** (node-array churn, per-update
   cost) and accept O(N) reconciliation — only viable if windowing (#1) isn't enough.

Recommendation: pursue **#1 (windowing)** first as a lower-risk partial fix, and only
take on **#3** if true unbounded virtualization with full drag-select is a hard
requirement.
