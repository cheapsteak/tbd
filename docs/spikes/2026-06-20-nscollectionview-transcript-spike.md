# Spike: AppKit virtualized transcript list (issue #129)

Date: 2026-06-20 — branch `spike-nscollectionview-transcript`
Status: THROWAWAY prototype. Compiles, gate unit-tested. Interactive
verification (virtualization count, text selection, bottom-pin) is pending a
human GUI run — see launch recipe + open risks below.

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

## Verdict criteria

GO if: realize count ≈ visible (not 500) **and** in-row text selection works.
NO-GO (or needs more work) if text selection cannot be made to win the drag from
NSTableView row tracking — that would mean the #244 fix doesn't survive the AppKit
list, which is the whole reason this proof point gates the decision.
