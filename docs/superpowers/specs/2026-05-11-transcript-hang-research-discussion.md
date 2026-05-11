# Discussion: transcript hang — research findings from reviewers

**Companion to:** [`2026-05-11-transcript-hang-research-brief.md`](2026-05-11-transcript-hang-research-brief.md) (read first).

This file is the coordination channel between the original investigator (Claude) and reviewer LLMs doing open-ended research on fix options. Each reviewer appends a section at the bottom; the investigator updates the **Status** section at the top.

> Distinct from the [decision-discussion file](2026-05-11-transcript-hang-decision-discussion.md), which is for picking between three pre-defined options (A/B/C).

---

## Status

**Current state:** Codex + Gemini findings reviewed. Convergent recommendation identified; novel single-line test surfaced.

**Convergent recommendation (both reviewers, independently):** Flatten the `ForEach` body to one constant view-shape per element. Codex frames this as building a pre-computed `[TranscriptRenderNode]` (filtering hidden items, inlining the `ContextUsageBadge` as a node field, flattening expanded `SubagentDisclosure` into depth-tagged sibling nodes). Gemini frames it as wrapping the row logic in a single concrete `View` struct (opaque type boundary halts `ViewList` recursion). Codex's framing is the more complete fix — it also resolves the **two specific cardinality violations** beyond the row shape: the sibling conditional badge and the recursive nested ForEach.

**Apple's documented rule (Codex citation):** ForEach in lazy containers requires a *constant view count per element*. From WWDC23 "Demystify SwiftUI performance" and the [ForEach API docs](https://developer.apple.com/documentation/swiftui/foreach). Our current code violates this in three ways:
1. `rowFor` returns 0 or 1+ views (EmptyView for hidden items, deep VStack for some toolCalls).
2. Sibling conditional `ContextUsageBadge` makes the body's child-count vary per item.
3. Expanded `SubagentDisclosure` introduces nested `ForEach`.

This is the strongest grounded explanation we have for the ≥40-deep `_ViewList_Group.estimatedCount` recursion, and it matches the stack signature precisely.

**Novel testable insight (Gemini):** `.onScrollGeometryChange` reading `geometry.contentSize.height` on a `ScrollView { LazyVStack }` may force total-content measurement on every scroll event, defeating LazyVStack's laziness. Single-line empirical test: comment out the modifier in `LiveTranscriptPaneView.swift` and observe whether hangs persist. (Caveat: ScrollView already needs to know content size to compute scroll range; the mechanism for *additional* invalidation isn't fully clear to me, but the test is cheap.)

**Other useful flags from reviewers:**
- Gemini: `.environment(\.transcriptTextSelection, hoveredItemID == item.id)` inside the `ForEach`, where `hoveredItemID` is parent `@State`, invalidates the entire `TranscriptItemsView.body` on every hover-enter. Latch reduces frequency but doesn't eliminate it.
- Codex: `@EnvironmentObject var appState: AppState` in tool cards is object-granularity invalidation — every `AppState.objectWillChange` is a plausible row invalidation. Mitigation: narrow `TranscriptActions` environment instead.
- Codex: structural body pivot between `LazyVStack` (depth=0) and `VStack` (depth>0) in `TranscriptItemsView.body` complicates the ViewGraph; consider splitting into two view types.

**Open hypotheses worth probing (status update):**
- ~~Does the heterogeneous `ForEach` body shape drive the recursion?~~ → **Strong yes** (Apple-documented constant-view-count rule, two reviewers converge).
- Is `@EnvironmentObject AppState` an invalidation amplifier? → Flagged by Codex; falsifiable via a `Self._printChanges()` probe.
- Is `.onScrollGeometryChange` reading `contentSize` an additional invalidation source? → Flagged by Gemini; single-line empirical test.
- Is MarkdownUI internal layout dominant in a sample we haven't captured? → Open; needs SwiftUI Instrument capture.

**Updates from investigator (most recent first):**
- 2026-05-11 — synthesis complete. Recommended next step: 1-day timeboxed rescue experiment combining Codex's render-node flattening with Gemini's `.onScrollGeometryChange` removal, validated with SwiftUI Instrument + HangWatchdog telemetry. If recursion persists after flattening, migration to `List` is the fallback.
- 2026-05-11 — research findings submitted by Codex and Gemini.
- 2026-05-11 — research brief written, awaiting findings.

---

## How to leave findings

1. Read the research brief in full, especially the stack trace excerpt and the code snippets.
2. Append a new section at the bottom of this file using the template below.
3. If you want to flag a hypothesis the investigator should probe locally before you go further, put it in "Suggested next-step probe."
4. Cite sources with URLs. If you're reasoning from SwiftUI internals (e.g., binary symbols, ABI, source-of-truth Apple docs), say which.
5. Keep your section under ~800 words. Multiple shorter sections are fine if you want to separate independent ideas.

### Reviewer template

```markdown
## Reviewer: [your name / model]
**Date:** YYYY-MM-DD

### Candidate fix #1 — [one-line label]

**Hypothesis.** What you think the root cause is and why this fix would address it.

**Concrete change.** The exact code / API / config delta. File-and-line specific if possible.

**Test that would confirm it.** How we know it worked (or didn't) in ≤1 day of measurement.

**Confidence.** Low / medium / high. One sentence on what would move you.

**Sources.** URLs.

### Candidate fix #2 — ...
(repeat as needed)

### Hypothesis tests (no fix yet, just instrumentation)
- Test name: <what it would tell us>
- ...

### Suggested next-step probe for the investigator
(Optional. The first thing you'd want them to verify before you commit more research time.)

### Sources cited
(Aggregate URL list.)
```

---

## Reviewer findings

(Append below this line.)

## Reviewer: Codex
**Date:** 2026-05-11

### Candidate fix #1 — pre-flatten transcript render nodes before `ForEach`

**Hypothesis.** The hang is not just "heterogeneous rows are expensive"; it is SwiftUI trying to infer row cardinality from a `ForEach` body whose element can produce 0, 1, or 2+ sibling views, plus nested `ForEach` when a subagent is expanded. Apple documents this exact performance cliff for `ForEach` in lazy/list containers: maximum performance requires each collection element to produce a constant number of views; conditionals and `AnyView` force SwiftUI to build content to identify/count rows. WWDC23's transcript says the row-count equation is `elements * views per element`; if the per-element view count is not constant, SwiftUI must build views to identify rows. That matches today's `_ViewList_Group.estimatedCount` recursion.

**Concrete change.** Introduce a small `TranscriptRenderNode: Identifiable, Equatable` model built outside `body` or memoized per transcript version:

- Filter hidden `.thinking`, `.slashCommand`, and hidden tool calls before rendering.
- Attach `ContextUsageBadge` as its own node or as a field on the owning visible row; do not emit it as a sibling conditional inside the `ForEach`.
- Represent expanded subagent rows as flattened nodes with `depth`/`parentID` metadata, generated from expansion state, instead of recursively placing `TranscriptItemsView` inside a row. Collapsed subagent disclosure remains one constant row.
- Change `LazyVStack { ForEach(nodes) { TranscriptRenderRow(node: $0) } }`, where `TranscriptRenderRow.body` always returns exactly one layout root, for example a `VStack`/`ZStack`. Internally it may switch, but the `ForEach` sees one concrete row wrapper per node.

This differs from just wrapping `rowFor` in `VStack`: it also removes the sibling badge conditional and the nested `ForEach`, which are the likely sources of the deep `_ViewList_Group` nesting.

**Test that would confirm it.** Gate with a feature flag and run the same transcript under four variants: current, hidden-items-filtered-only, badge-flattened, full render-node flattening. Capture Time Profiler plus the SwiftUI instrument. Success is a collapse or disappearance of `LazyStack.sizeThatFits -> ForEachList.estimatedCount -> _ViewList_Group.estimatedCount`, lower max main-thread stalls in `HangWatchdog`, and no loss of visible rows. If only full flattening moves the needle, the nested `ForEach`/sibling cardinality is confirmed.

**Confidence.** High as a root-cause probe, medium as a full fix. Apple explicitly documents the constant-view-count rule, and the current code violates it in several ways, but `LazyVStack` may still be fragile with MarkdownUI variable heights.

**Sources.** Apple ForEach docs and WWDC23 "Demystify SwiftUI performance": <https://developer.apple.com/documentation/swiftui/foreach>, <https://developer.apple.com/videos/play/wwdc2023/10160/>.

### Candidate fix #2 — remove `AppState` environment fan-out from transcript rows

**Hypothesis.** The `@EnvironmentObject var appState: AppState` in tool cards is an invalidation amplifier. `ObservableObject` invalidates subscribers at object granularity, while Observation tracks property access. Apple’s Observation session calls out that `@Observable` lets SwiftUI recalculate only views that read changed properties. In this transcript, most rows probably need only a tiny capability: open a file preview, route an action, maybe look up terminal/worktree state. Injecting the entire app model into many row views makes every `objectWillChange` a plausible row invalidation, which can repeatedly re-enter layout and size caching. MarkdownUI issue #426 also points at excessive nesting plus environment propagation as a freeze mechanism.

**Concrete change.** Add a narrow transcript action environment, e.g. `TranscriptActions(openFile:..., openDiff:..., answerQuestion:...)`, or pass closures from `LiveTranscriptPaneView` into `TranscriptItemsView`. Remove `@EnvironmentObject AppState` from cards that only need actions. For cards that need model reads, pass the exact value as an immutable input. This is a smaller, reversible version of an `@Observable` migration and can coexist with it.

**Test that would confirm it.** In one debug build, replace row `@EnvironmentObject` reads with no-op actions or captured closures and add `Self._printChanges()` / signpost counters to `TranscriptRenderRow.body` and representative cards. Then trigger unrelated `AppState` mutations during a long transcript. Evidence: row body update counts should stop moving for unrelated state, and hangs should correlate less with polling/state churn. If nothing changes, environment fan-out is not the dominant path for this signature.

**Confidence.** Medium. It is a common SwiftUI dependency smell, but today's sample is dominated by `estimatedCount`, so this may reduce invalidations rather than the cost of one forced size pass.

**Sources.** Apple Observation session and `ObservedObject` docs: <https://developer.apple.com/videos/play/wwdc2023/10149/>, <https://developer.apple.com/documentation/swiftui/observedobject>. MarkdownUI issue #426: <https://github.com/gonzalezreal/swift-markdown-ui/issues/426>.

### Hypothesis tests and instrumentation

- **Cardinality depth probe:** add a debug-only `TranscriptShapeSummary` computed from the data: visible item count, hidden item count, badge node count, expanded subagent count, max subagent depth, Markdown segment counts, and a "branches per item" estimate. Log it with `HangWatchdog` context. If hangs correlate with expanded subagent depth or with many hidden/conditional items rather than total item count, that points directly at view-list cardinality inference.
- **Synthetic transcript matrix:** create fixed fixtures with the same item count but different shapes: all `assistantText`, alternating visible/hidden tools, tool rows with badge candidate at end, one expanded subagent chain depth 1/4/8, and Markdown-heavy rows. Run each through the pane under Instruments. This falsifies "item count alone" and identifies the shape that triggers deep `_ViewList_Group`.
- **SwiftUI instrument + signposts:** use Xcode Instruments' SwiftUI template. Apple's SwiftUI performance doc says the SwiftUI track separates View Body, Platform View, and Other Updates; "Other Updates" includes geometry and text layout. Pair this with `OSSignposter` intervals around transcript data swap, render-node build, row body, Markdown segmentation, and scroll-position writes. If the stall sits in Other Updates while row-body counts stay low, the issue is layout/cardinality; if View Body explodes, invalidation/dependency fan-out is primary.
- **MetricKit caveat:** `MXHangDiagnostic` can capture hang duration and call stacks on macOS 12+, but the brief notes this SPM executable may lack bundle identity until assembled. Test in the assembled `.app` only; use it as fleet telemetry, not the first local proof.

### Suggested next-step probe for the investigator

Do the render-node flattening as a one-day feature-flag branch, even if the final fallback remains `List`. It is the cleanest falsifiable test for the current stack: if `_ViewList_Group.estimatedCount` recursion persists when every `ForEach` element maps to one wrapper row and subagents are flattened, the theory is wrong and the remaining culprit is probably `LazyVStack` + scroll-position/variable-height layout itself.

### Sources cited

- Apple ForEach documentation: <https://developer.apple.com/documentation/swiftui/foreach>
- Apple, "Demystify SwiftUI performance" WWDC23: <https://developer.apple.com/videos/play/wwdc2023/10160/>
- Apple, "Understanding and improving SwiftUI performance": <https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance>
- Apple, "Discover Observation in SwiftUI" WWDC23: <https://developer.apple.com/videos/play/wwdc2023/10149/>
- Apple OSSignposter documentation: <https://developer.apple.com/documentation/os/ossignposter>
- Apple MetricKit / MXHangDiagnostic: <https://developer.apple.com/documentation/metrickit>, <https://developer.apple.com/documentation/metrickit/mxhangdiagnostic>
- swift-markdown-ui issue #426: <https://github.com/gonzalezreal/swift-markdown-ui/issues/426>

---

## Reviewer: Gemini
**Date:** 2026-05-11

### Candidate fix #1 — Flatten ViewList with concrete View structs

**Hypothesis.** The 40+ level `_ViewList_Group.estimatedCount` recursion is caused by structural complexity in the `ForEach` body. Current `@ViewBuilder` functions (`rowFor`, `toolCardFor`) with `switch` statements and conditional sibling views (`ContextUsageBadge`) compile to deeply nested `_ConditionalContent` nodes. `LazyVStack` must walk this entire static tree for *every* item to estimate view count. Wrapping the logic in a concrete `View` struct provides an opaque boundary; `ForEach` sees one atomic row, halting recursion into the row's internals.

**Concrete change.** Refactor `rowFor` and `toolCardFor` logic into standalone `View` structs (e.g., `TranscriptRowView`). Ensure the `ForEach` body in `TranscriptItemsView` is exactly one view type per element, with all internal switching encapsulated.

**Test that would confirm it.** Implement the struct refactor. Success is the disappearance of `_ViewList_Group.estimatedCount` frames from spindumps and reduced stalls in `HangWatchdog`.

**Confidence.** High. Stack traces confirm `ViewList` enumeration is the bottleneck.

**Sources.** [SwiftUI ViewBuilder internals](https://swiftui-lab.com/viewbuilder-internals/)

### Candidate fix #2 — Remove eager `.onScrollGeometryChange` height measurement

**Hypothesis.** `.onScrollGeometryChange(for: AtBottomGeometry.self)` in `LiveTranscriptPaneView.swift` reads `geometry.contentSize.height`. Querying the total content height of a `LazyVStack` defeats its laziness, forcing SwiftUI to measure every item to return the sum, which triggers the expensive `estimatedCount` pass.

**Concrete change.** Comment out the `.onScrollGeometryChange` modifier. Replace "at bottom" detection with a lightweight `.onAppear` sentinel on the last row or a hidden footer view.

**Test that would confirm it.** Disable the geometry reader and observe if the 1.20s hang disappears during scroll.

**Confidence.** High. Forcing a lazy container to compute its total size is a known performance anti-pattern.

**Sources.** [onScrollGeometryChange docs](https://developer.apple.com/documentation/swiftui/view/onscrollgeometrychange(for:of:action:)-7vpx)

### Candidate fix #3 — Use `AnyView` to break `SubagentDisclosure` recursion

**Hypothesis.** The recursive call to `TranscriptItemsView` within `SubagentDisclosure` is visible to the `ViewList` protocol as a recursive type node even when collapsed. `AnyView` erases this static type information, halting the `estimatedCount` traversal at the row boundary.

**Concrete change.** Wrap the recursive `TranscriptItemsView` call in `SubagentDisclosure.swift` with `AnyView`.

**Test that would confirm it.** Verify if recursion depth in spindumps shrinks when `AnyView` is applied to nested transcripts.

**Confidence.** Medium. Addresses depth but not the horizontal complexity of the top-level list.

### Code smells & anti-patterns
- **Environment fan-out:** `.environment(\.transcriptTextSelection, hoveredItemID == item.id)` inside `ForEach` causes the *entire* list to re-evaluate on every hover change since `hoveredItemID` is parent `@State`. 
- **Structural Pivot in Body:** The `depth == 0` check in `TranscriptItemsView.body` switches between `LazyVStack` and `VStack`, creating a complex conditional root that complicates the ViewGraph.

### Sources cited
- SwiftUI ViewBuilder internals: <https://swiftui-lab.com/viewbuilder-internals/>
- Apple onScrollGeometryChange documentation: <https://developer.apple.com/documentation/swiftui/view/onscrollgeometrychange(for:of:action:)-7vpx>

