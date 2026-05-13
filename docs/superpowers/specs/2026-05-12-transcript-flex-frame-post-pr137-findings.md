# Findings: SwiftUI transcript pane hang, post-PR-#137

**Companion to:** [`2026-05-12-transcript-flex-frame-post-pr137-brief.md`](2026-05-12-transcript-flex-frame-post-pr137-brief.md)
**Issue:** [cheapsteak/tbd#129](https://github.com/cheapsteak/tbd/issues/129) (reopened 2026-05-12)
**Spindumps:** `freeze.1.log`, `freeze.2.log`

## TL;DR

`freeze.2.log` confirms the same broad bug class as `freeze.1.log`: a short main-thread hang in SwiftUI/AttributeGraph layout, not daemon I/O and not the titlebar/sidebar chrome branch. The dominant signal remains SwiftUI transaction flushing through lazy scroll content, `GeometryReader`, `ForEach`, `LazyVStack`, `_FlexFrameLayout`, and AppKit bridge measurement. The next smallest falsification test should remove or gate the transcript row hover environment mutation, because `freeze.2.log` starts with SwiftUI hover hit-testing before entering the same AttributeGraph/layout storm.

## 1. Re-evaluation of the prior hypothesis

The `.scrollPosition(id:)` hypothesis was right-but-minor, not dominant. PR #137 removed `.scrollPosition(id:)`, unscoped scroll animation, and unscoped `.defaultScrollAnchor`; `freeze.1.log` still showed the same `StackLayout` / `_FlexFrameLayout` / `ScrollViewLayoutComputer` shape.

`freeze.2.log` adds one new clue: sample 1 enters through hover dispatch and SwiftUI hit-testing:

```text
EventBindingManager.enqueueHoverUpdateIfNeeded
NSHostingView.didRequestHoverUpdate
HoverEventDispatcher.receiveEvents
ViewResponder.hitTest
HostingScrollView.PlatformGroupContainer.hitTest
```

Then samples 2-12 move into the familiar transaction path:

```text
NSRunLoop.flushObservers
NSHostingView.beginTransaction
GraphHost.flushTransactions
AG::Subgraph::update
```

That makes hover-driven invalidation the best new candidate trigger. In current code, `TranscriptItemsView` mutates `hoveredItemID` and writes `.environment(\.transcriptTextSelection, hoveredItemID == node.id)` across every row. That is a plausible high-blast-radius invalidation: one hover change can change the environment value seen by all `ForEach` rows.

## 2. New ranked candidate list

| # | Fix | Hypothesis | Verification signal | Falsification signal | Trade-off | Effort | Confidence |
|---|---|---|---|---|---|---|---|
| 1 | Temporarily remove row `.onHover` and force `.transcriptTextSelection` false | Hover changes invalidate every transcript row and kick the lazy stack into a layout fix-point search | Next hang lacks `EventBindingManager.enqueueHoverUpdateIfNeeded`, `HoverEventDispatcher`, and row-wide environment churn | Same stack appears without hover frames | Loses hover-enabled text selection during test | Low | Medium-high |
| 2 | Replace row-wide environment with local per-row prop/state | The expensive part is not hover itself, but broadcasting hover state through environment to all rows | Hangs drop while hover UI behavior remains | No reduction | Slight row API churn | Medium | Medium |
| 3 | Remove `GeometryReader` / `PreferenceKey` feedback for `contentAreaHeight` in `ContentView` | A layout measurement writes SwiftUI state during layout and feeds overlay sizing, amplifying graph updates | Hangs no longer include `GeometryReaderLayout.placeSubviews` and repeated root geometry/flex-frame passes | `GeometryReaderLayout` remains common in new captures | Conductor overlay needs alternate sizing | Low-medium | Medium |
| 4 | Disable animated `proxy.scrollTo` | Even scoped scroll animation can force repeated content placement in lazy scroll containers | Hangs no longer show `LazyLayoutCacheItem.AllItemsPhaseMutation` / item phase updates near scroll events | Same cycle appears when idle/hovering | Autoscroll becomes abrupt | Low | Medium-low |
| 5 | Migrate transcript rendering from `ScrollView { LazyVStack }` to `List`/AppKit table | The structural issue is SwiftUI lazy stack measurement of heterogeneous rich rows on macOS 26 | Eliminates lazy-stack/flex-frame signatures | Migration reproduces equivalent hangs or breaks transcript UX | Larger behavior/design change | High | Medium |
| 6 | Keep chasing individual `.frame(maxWidth: .infinity)` and padding sites | The cycle is caused by one row/card layout modifier | Removing one card class eliminates hangs | Hangs persist across many row types | Many narrow tests | Medium-high | Low-medium |

## 3. Sample-10 AppKit bridge diagnosis

`freeze.1.log` sample 10 bottoms out in:

```text
PlatformViewLayoutEngine.sizeThatFits
ViewLeafView.sizeThatFits
AppKitPlatformViewHost.intrinsicLayoutTraits
NSView measureMin:max:ideal:stretchingPriority:
NSISEngine
```

I cannot identify the exact leaf from the stack alone, but ranked candidates are:

1. Markdown/rich text rows in the transcript cards, especially selectable text paths.
2. `TranscriptSelectableText` / AppKit-backed text measurement.
3. Embedded AppKit views from terminal/file/transcript panes if the active view is not only transcript.

`freeze.2.log` strengthens the "SwiftUI platform view / scroll view" diagnosis but does not name the app leaf. It shows hit-testing through `HostingScrollView.PlatformGroupContainer`, then later layout through `ScrollViewLayoutComputer.Engine.sizeThatFits`, `LazyLayoutComputer.Engine.sizeThatFits`, and `LazyVStackLayout`.

Implication: the next test should reduce broad invalidation before chasing a single bridge leaf. If hover/environment churn is removed and the AppKit bridge still dominates, instrument row identity/type around visible transcript nodes next.

## 4. Residual `estimatedCount` path

`freeze.1.log` has one residual `_ViewList_Node.estimatedCount` sample. That looks like known residual work, not the dominant regression PR #134 fixed. The dominant post-PR-#137 behavior is flex-frame/lazy-stack/layout transaction work, plus `LazyLayoutCacheItem.AllItemsPhaseMutation`.

`freeze.2.log` does not shift the ranking back toward `estimatedCount`. It instead adds hover hit-testing as a likely trigger and repeats lazy layout/flex-frame paths.

## 5. Recommended next falsification test

Smallest possible change:

```swift
TranscriptRow(node: node, terminalID: terminalID)
    .environment(\.transcriptTextSelection, false)
//  .onHover { ... }   // temporarily disabled
```

Where: `Sources/TBDApp/Panes/Transcript/TranscriptItemsView.swift`, inside the `ForEach(nodes)` row body.

Why this test: `freeze.2.log` sample 1 starts in SwiftUI hover event dispatch/hit-testing, and the current hover handler mutates state that changes an environment value across every transcript row. This is the cheapest way to test whether hover invalidation is the trigger for the subsequent AttributeGraph/layout storm.

Pass criteria from the next hang capture:

- No `EventBindingManager.enqueueHoverUpdateIfNeeded` / `HoverEventDispatcher` lead-in.
- Fewer or no `GraphHost.flushTransactions -> AG::Subgraph::update` samples during mouse movement over transcript rows.
- No repeated `LazyVStackLayout` / `ScrollViewLayoutComputer.Engine.sizeThatFits` / `_FlexFrameLayout` cycle under hover.

Fail criteria:

- Same 1s+ main-thread hang recurs with the same lazy layout/flex-frame stack while hover is disabled.
- Hang appears during autoscroll/new-message arrival instead of pointer movement.

## 6. Notes from `freeze.2.log`

`freeze.2.log` was captured on 2026-05-13 at 09:12:58 -0400. Target process:

```text
Command: TBDApp
PID: 69996
Event: hang
Duration: 1.13s
Steps: 12
CPU Time: 1.104s on main thread
```

It also includes other TBDApp processes in the system snapshot. Those are not the hang target. Some non-TBD system noise is present: Notes hit the dispatch thread hard limit, and Notes/Mail deadlocks were reported. The target TBDApp stack is still an on-CPU main-thread SwiftUI layout hang, so those external issues do not change the app-level diagnosis.

This log does not include the sidebar/titlebar branch changes. It also does not implicate `NSWindow`, `NSSplitViewItem`, titlebar separator, or `AppDelegate` chrome work.

## 7. Open questions

- Was the pointer moving over the transcript at the time of `freeze.2.log`? If yes, the hover test should be first.
- Was a new transcript item arriving at the same time? If yes, compare against disabling animated `proxy.scrollTo`.
- Do hangs reproduce with the file panel closed? If not, `FileViewerPanel`'s `LazyVStack` and `GeometryReader` paths need to enter the candidate list.

## 8. References consulted

- Local spindumps: `freeze.1.log`, `freeze.2.log`.
- Local code: `TranscriptItemsView.swift`, `LiveTranscriptPaneView.swift`, `ContentView.swift`, `AppState.swift`.
- Prior design notes in this directory, especially the post-PR-#137 brief and earlier transcript lazy-list performance research.
