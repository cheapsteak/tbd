# Research brief: SwiftUI transcript pane hang — find the next fix

**Date:** 2026-05-11
**Author:** Claude (investigating issue cheapsteak/tbd#129)
**Audience:** Reviewer LLMs being asked to **research and propose fix options** for a SwiftUI bug. This is NOT a decision-vote brief — it's an open-ended exploration request.

> Sibling doc — if you're looking to pick between three already-defined options instead, read [`2026-05-11-transcript-hang-decision-brief.md`](2026-05-11-transcript-hang-decision-brief.md).

## What we want from you

Given the breadcrumbs below — what we've tried, what the hangs look like, what the code looks like — find the next thing worth trying. Specifically:

1. **A candidate fix we haven't considered.** Be creative. Browse Swift Forums / Apple Developer Forums / GitHub / WWDC notes. Surface anything we haven't enumerated.
2. **A way to *prove* root cause** before fixing — instrumentation, signpost markers, alternative measurement (`SignpostInterval`, `MetricKit`, `os_signpost` regions), an Xcode 17 `View body` Instrument lane usage, etc.
3. **A hypothesis test we could run locally in <1 day** that would falsify or confirm a specific theory about why the recursion is so deep.
4. **A code smell or anti-pattern we missed in the snippets below** that would make a SwiftUI compiler engineer wince.

We *do* have an existing migration plan (LazyVStack → List) as the structural-fix fallback. We're not asking you to evaluate it; we're asking what else is on the table.

Output guidance: each candidate fix or test as a numbered section with (a) the hypothesis, (b) the test or change in concrete terms, (c) what evidence would tell you it worked. Cite sources with URLs. Aim for 1500–3000 words total.

---

## The bug class

`Sources/TBDApp/Panes/Transcript/TranscriptItemsView.swift` renders a SwiftUI chat-style transcript inside `ScrollView { LazyVStack { ForEach(items) { rowFor($0) } } }` on macOS 15 (Sequoia, arm64, Swift 6, Xcode 16). Items are heterogeneous: user prompts, assistant chat bubbles (MarkdownUI rich rendering), and 9 kinds of tool-call cards. Recurring main-thread UI hangs of 1s–17s during layout/scroll. Each fix we ship closes one specific stack signature; a new signature appears days later.

Issue tracker: <https://github.com/cheapsteak/tbd/issues/129>.

## What we've already tried (do not re-suggest)

| When | What | Outcome |
|---|---|---|
| 2026-04 | Hoisted ScrollView out of recursive TranscriptItemsView calls (`2da779c`). | Closed one signature; bug class survived. |
| 2026-04 | Deferred `onPreferenceChange` writes to avoid reentrant layout (`29348d3`). | Closed one signature. |
| 2026-04 | Persisted `NSHostingView` in expanding row panel to break layout-update loop (`3fa2cc6`). | Closed one signature. |
| 2026-05-04 | Capped daemon-emitted transcript-body to 20 lines initial render (`dd6c1cf`). | Reduced first-paint cost. |
| 2026-05-09 | Gated `.textSelection(.enabled)` on hover via env latch — was creating per-row `NSTextField`s (PR #120, `a41f716`). | Closed the 17s `StyledTextLayoutEngine` storm. |
| 2026-05-10 | Shipped `HangWatchdog` telemetry at 1500ms threshold (`5e10ba8`). | Diagnostic only. Later tightened to 1000ms. |
| 2026-05-11 (today) | Capped `BashCard`/`WriteCard` inner ScrollView heights at 600pt (was `.infinity`) — PR #130 (`937c1c4`). | Closed the 5/10 hang signature. New signature appeared the same day. |
| Already done | Removed `.scrollTargetLayout()` from transcript code. | Closed one signature pre-#129. |

Each fix was correct for the signature it targeted. The pattern is "fix one, new one appears."

## Today's hang (post-PR-#130, 2026-05-11 12:18)

1.20s main-thread stall, sampled by macOS hang reporter (`/Users/chang/projects/tbd/freeze.2.log`, 18MB). 1.097s of CPU on main thread. 67% of that CPU sits in `LazyStack.sizeThatFits → ForEachList.estimatedCount → _ViewList_Group.estimatedCount` recursion.

### Stack excerpt (verbatim, top frames)

```
Thread 0x377b3c1  DispatchQueue "com.apple.main-thread"  12 samples (1-12)
priority 46 (base 46)   cpu time 1.097s (4.4G cycles, 17.2G instructions, 0.26c/i)

12  start
12  TBDApp_main
12  static App.main()
12  NSApplicationMain
12  -[NSApplication run]
12  -[NSApplication(NSEventRouting) nextEventMatchingMask:...]
12  _DPSNextEvent
12  CFRunLoopRunSpecificWithOptions
12  __CFRunLoopDoObservers
12  @objc closure #1 in static NSRunLoop.addObserver(_:)
12  static NSRunLoop.flushObservers()
12  NSHostingView.beginTransaction()
12  static Update.ensure<A>(_:)
12  ViewGraphRootValueUpdater.updateGraph<A>(body:)
12  ViewGraphRootValueUpdater._updateViewGraph<A>(body:)
12  closure #1 in NSHostingView.beginTransaction()
12  GraphHost.flushTransactions()
12  GraphHost.runTransaction(_:do:id:)
12  AG::Subgraph::update(unsigned int)
12  AG::Graph::UpdateStack::update()

(splits at 8/12 below — 67% of CPU is in this branch)

 8  closure #1 in Attribute.init<A>(_:)
 8  LayoutChildGeometries.value.getter
 8  ViewLayoutEngine.childGeometries(at:origin:)
 8  GeometryReaderLayout.placeSubviews(in:proposal:subviews:cache:)
 8  LayoutEngineBox.sizeThatFits(_:)
 8  ViewLayoutEngine.sizeThatFits(_:)
 8  closure #1 in StackLayout.sizeThatFits(_:)
 8  StackLayout.UnmanagedImplementation.placeChildren1(in:minorProposalForChild:)
 8  StackLayout.UnmanagedImplementation.sizeChildrenGenerallyWithConcreteMajorProposal(...)
 8  StackLayout.UnmanagedImplementation.prioritize(_:proposedSize:)
 8  LayoutEngine.lengthThatFits(_:in:)
 8  UnaryLayoutEngine.sizeThatFits(_:)
 8  _FrameLayout.sizeThatFits(in:context:child:)
 8  LayoutProxy.size(in:)
 8  LayoutEngineBox.sizeThatFits(_:)
 8  ViewLayoutEngine.sizeThatFits(_:)
 8  closure #1 in StackLayout.sizeThatFits(_:)
 8  StackLayout.UnmanagedImplementation.placeChildren1(...)
 8  StackLayout.UnmanagedImplementation.sizeChildrenGenerallyWithConcreteMajorProposal(...)
 8  StackLayout.UnmanagedImplementation.prioritize(...)
 8  LayoutEngine.lengthThatFits(_:in:)
 8  UnaryLayoutEngine.sizeThatFits(_:)
 8  protocol witness for UnaryLayout.sizeThatFits(...) in conformance _FlexFrameLayout
 8  _FlexFrameLayout.sizeThatFits(in:context:child:)
 8  LayoutProxy.size(in:)
 8  LayoutEngineBox.sizeThatFits(_:)
 8  protocol witness for LayoutEngine.sizeThatFits(_:) in conformance ScrollViewLayoutComputer.Engine
 8  ViewSizeCache.get(_:makeValue:)
 8  closure #1 in ScrollViewLayoutComputer.Engine.sizeThatFits(_:)
 8  static ScrollViewUtilities.sizeThatFits(in:contentComputer:axes:)
 8  LayoutComputer.sizeThatFits(_:)
 8  LayoutEngineBox.sizeThatFits(_:)
 8  ViewLayoutEngine.sizeThatFits(_:)
 8  closure #1 in StackLayout.sizeThatFits(_:)
 8  StackLayout.UnmanagedImplementation.placeChildren1(...)
 8  StackLayout.UnmanagedImplementation.sizeChildrenIdeally(...)
 8  LayoutProxy.dimensions(in:)
 8  LayoutEngineBox.sizeThatFits(_:)
 8  UnaryLayoutEngine.sizeThatFits(_:)
 8  protocol witness for UnaryLayout.sizeThatFits(...) in conformance _PaddingLayout
 8  _PaddingLayout.sizeThatFits(in:context:child:)
 8  LayoutProxy.size(in:)
 8  LayoutEngineBox.sizeThatFits(_:)
 8  LazyLayoutComputer.Engine.sizeThatFits(_:)
 8  closure #1 in LazyLayoutComputer.Engine.sizeThatFits(_:)
 8  AG::Graph::with_update(...)
 8  closure #1 in SizeAndSpacingContext.update<A>(_:)
 8  protocol witness for LazyLayout.sizeThatFits(...) in conformance LazyVStackLayout
 8  protocol witness for LazyLayout.sizeThatFits(...) in conformance LazyHStackLayout

 4  LazyStack<>.sizeThatFits(proposedSize:subviews:context:cache:)
 4  _ViewList_Node.estimatedCount(style:)
 4  protocol witness for ViewList.count(style:) in conformance ForEachList<A, B, C>
 4  ForEachList.estimatedCount(style:)
 3  ForEachState.estimatedCount(style:)
 2  _ViewList_Group.estimatedCount(style:)        ← recursive entry point
 2  <deduplicated_symbol>
 2  <deduplicated_symbol>
 1  <deduplicated_symbol>
```

(Then `_ViewList_Group.estimatedCount` recurses through child `_ViewList_Node.estimatedCount` → `ForEachList.estimatedCount` → `ForEachState.estimatedCount` → `_ViewList_Group.estimatedCount` repeatedly. The deepest call-tree branches in the spindump nest >40 levels of these recursive frames.)

### Reading the stack

- The outer container (`ScrollView`) is asking `LazyVStackLayout` for an intrinsic size.
- `LazyVStackLayout` calls `estimatedCount` on its `ForEachList` to plan placement.
- `_ViewList_Group.estimatedCount` walks through every conditional branch of every row to determine the row count contribution.
- Because the `ForEach` body is heterogeneous (Group → switch over 5 cases × inner switch over 9 tool names × sibling conditional badge × any expanded subagent containing another `LazyVStack` ForEach), the recursion descends through dozens of levels.

### Prior hangs (different signatures)

- **2026-05-10, 1.05s sample.** Stack: `LazyVStack.place → ForEach → ChatBubble row → ScrollViewLayoutComputer.Engine.sizeThatFits → StyledTextLayoutEngine`. Suspect at the time: `BashCard.swift:71/105` — `.frame(maxHeight: containerExpanded ? .infinity : 120)`. Fix: PR #130 capped at 600pt finite. The 12:18 hang above is post-fix.
- **2026-05-09, 17s storm.** Per-row `NSTextField` creation from `.textSelection(.enabled)` on every visible row simultaneously. Fix: gate textSelection on hover via env latch. PR #120.

## HangWatchdog telemetry

`Sources/TBDApp/Diagnostics/HangWatchdog.swift`. A `DispatchSourceTimer` at `.utility` QoS fires every 250ms on a background queue; each tick checks how long since the main thread drained its queue. If > 1000ms, logs:

```
hang detected stallMs=<N> terminalID=<short> itemCount=<N> pane=<label>
```

Subsystem `com.tbd.app`, category `hang-watchdog`. Query:

```bash
log show --last 1h --predicate 'subsystem == "com.tbd.app" AND eventMessage CONTAINS "hang"' --info --style compact
```

`perf-transcript` category timestamps body re-evaluations, poll cycles, message-equality checks, and >100-item body markers. Used to validate that fixes actually reduce work, not just shuffle it.

## The actual code (so you can reason about it without cloning)

### `TranscriptItemsView.swift` — the inner LazyVStack

```swift
struct TranscriptItemsView: View {
    let items: [TranscriptItem]
    let terminalID: UUID?
    var depth: Int = 0

    @State private var hoveredItemID: TranscriptItem.ID? = nil

    var body: some View {
        if depth >= 8 {
            Text("… nested too deep")
        } else if depth == 0 {
            let latestUsageItemID = items.reversed().first {
                $0.usage != nil && !isHiddenInTranscript($0)
            }?.id
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    rowFor(item)
                        .environment(\.transcriptTextSelection, hoveredItemID == item.id)
                        .onHover { hovering in
                            if hovering { hoveredItemID = item.id }
                        }
                    if item.id == latestUsageItemID, let usage = item.usage {
                        ContextUsageBadge(total: usage.contextTotal)
                            .padding(.leading, 12).padding(.top, 2)
                    }
                }
            }
            .padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in rowFor(item) }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func rowFor(_ item: TranscriptItem) -> some View {
        Group {
            switch item {
            case .userPrompt, .assistantText:
                ChatBubbleView(item: item)
            case .thinking:
                EmptyView()
            case .systemReminder(let id, let kind, let text, let ts):
                if kind == .skillBody { SkillBodyRow(id: id, text: text, timestamp: ts) }
                else { SystemReminderRow(id: id, kind: kind, text: text, timestamp: ts) }
            case .slashCommand:
                EmptyView()
            case .toolCall(let id, let name, let inputJSON, let inputTruncatedTo, let result, let subagent, let ts, _):
                if hiddenToolNames.contains(name) {
                    EmptyView()
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        toolCardFor(name: name, id: id, inputJSON: inputJSON,
                                    inputTruncatedTo: inputTruncatedTo, result: result, timestamp: ts)
                        if let subagent {
                            SubagentDisclosure(subagent: subagent, terminalID: terminalID, depth: depth)
                                .padding(.leading, 32)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func toolCardFor(name: String, ...) -> some View {
        switch name {
        case "Read":            ReadCard(...)
        case "Edit", "MultiEdit": EditCard(...)
        case "Write":           WriteCard(...)
        case "Bash":            BashCard(...)
        case "Grep":            GrepCard(...)
        case "Glob":            GlobCard(...)
        case "Task", "Agent":   AgentCard(...)
        case "AskUserQuestion": AskUserQuestionCard(...)
        default:                GenericToolCard(...)
        }
    }
}
```

### `LiveTranscriptPaneView.swift` — the outer ScrollView and scroll controls

```swift
ScrollViewReader { proxy in
    ScrollView {
        TranscriptItemsView(items: messages, terminalID: terminalID)
    }
    .defaultScrollAnchor(.bottom)
    .scrollPosition(id: $visibleID, anchor: .bottom)
    .onScrollGeometryChange(for: AtBottomGeometry.self) { geometry in
        AtBottomGeometry(contentHeight: geometry.contentSize.height,
                         viewportBottom: geometry.contentOffset.y + geometry.containerSize.height)
    } action: { _, new in
        atBottom = new.contentHeight - new.viewportBottom < 50
    }
    .overlay(alignment: .bottomTrailing) { jumpToBottomButton(proxy: proxy) }
    .onAppear { ... HangWatchdog.shared.recordContext { ... }; proxy.scrollTo(visibleID, anchor: .bottom) }
    .onChange(of: messages.last?.id) { _, newID in
        if atBottom, let id = newID {
            withAnimation(.easeOut(duration: 0.15)) { visibleID = id }
        }
    }
}
```

### `SubagentDisclosure.swift` — the recursive nested ForEach

```swift
struct SubagentDisclosure: View {
    let subagent: Subagent
    let terminalID: UUID?
    let depth: Int
    @State private var expanded = false

    var body: some View {
        let visible = subagent.items.filter { !isHiddenInTranscript($0) }
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { expanded.toggle() }) { ... }
            if expanded && !visible.isEmpty {
                HStack(spacing: 0) {
                    Rectangle().fill(Color(...)).frame(width: 1)
                    TranscriptItemsView(items: subagent.items, terminalID: terminalID, depth: depth + 1)
                        .padding(.leading, 23)
                }
            }
        }
    }
}
```

### `BashCard.swift` — representative tool-call card (most have similar shape)

```swift
struct BashCard: View {
    @State private var expanded = false
    @State private var containerExpanded = false
    @State private var commandContainerExpanded = false
    @EnvironmentObject var appState: AppState   // <-- shared object, NOT @Observable
    // ... ~150 lines: ActivityRowChrome { header } body: {
    //   VStack { ScrollView with Text capped at 600pt; ScrollView with Text capped at 600pt }
    // }
}
```

### `ChatBubbleView.swift` — MarkdownUI rich-text body

Uses `gonzalezreal/swift-markdown-ui` (in maintenance mode as of Jan 2026; maintainer moved to `Textual`). The body partitions into prose/code segments and renders each Markdown segment with a custom `Theme.chatBubble`. The theme intentionally removes `.fixedSize(horizontal: false, vertical: true)` calls that the maintainer's docs recommend (commit `2b890ef` removed them when chasing a different bug).

## Codebase facts that might matter

- macOS 15 (Sequoia), arm64, Swift 6, Xcode 16. Target macOS 14+.
- TBDApp runs as a bare SPM executable (not a `.app` bundle until assembled by `scripts/restart.sh`). Some Apple APIs that require `CFBundleIdentifier` crash if used.
- `AppState` is an `ObservableObject` (not `@Observable`). Row views inject `@EnvironmentObject var appState: AppState`.
- The transcript is bottom-anchored chat (newest at bottom, scroll up for history). Not a Mastodon-style feed.
- Items can be ~hundreds in a long session; we've observed hangs as low as ~50 items in some cases.
- `TranscriptItem` is an enum with `Identifiable` IDs derived from the underlying JSONL line; stable across polls. We poll the daemon every 1.5s and replace the `appState.sessionTranscripts[sid]` array entirely (only when content differs by `==`).
- `MarkdownUI` library: known unfixed perf issues in deep nesting / long markdown ([#310](https://github.com/gonzalezreal/swift-markdown-ui/issues/310), [#426](https://github.com/gonzalezreal/swift-markdown-ui/issues/426), [#445](https://github.com/gonzalezreal/swift-markdown-ui/issues/445)). Maintainer comment on #426 (Nov 2025): freeze is *"excessive nesting … related to how environment variables are set,"* fixable via `@Observable`.

## Reference docs already in the repo

(All relative to repo root.)

- `docs/superpowers/specs/research-2026-05-06-swiftui-long-list-perf.md` — ~30 prior-art sources collected when this bug class first triggered investigation. Covers IceCubesApp, Apple Developer Forums threads, Fatbobman, cmux #2327, LazyVStackStutter, `SwiftUILazyContainer`, `NSCollectionView` + `NSHostingConfiguration`, etc.
- `docs/superpowers/specs/2026-05-06-transcript-list-migration-design.md` — the LazyVStack → List migration plan. We're treating this as the fallback; reviewers don't need to evaluate it.
- `docs/superpowers/specs/2026-05-06-transcript-perf-instrumentation.md` — what the `perf-transcript` telemetry covers.
- `docs/superpowers/specs/2026-05-11-transcript-hang-decision-brief.md` — sibling brief, three options (A/B/C); orthogonal to this research request.

## What we ARE NOT looking for

- "Migrate to List" — already on the table as the fallback.
- "Migrate to UIKit/AppKit NSCollectionView" — covered as Phase 3 in the migration doc.
- "Migrate off MarkdownUI to Textual" — covered, deferred.
- Re-validation of the prior fixes in the "what we've tried" table.

## What we ARE looking for

- A *specific* candidate fix that hasn't been listed.
- A *specific* test that would prove or disprove a hypothesis about why the recursion is so deep.
- A pointer to a SwiftUI internal that explains why `_ViewList_Group.estimatedCount` recurses ≥ 40 deep on our specific view shape — or an example codebase that demonstrably avoids this recursion with a heterogeneous ForEach body.
- A heuristic for "this row shape is the culprit" we could instrument and pin down.

## Coordination

If you want to leave findings: append to `docs/superpowers/specs/2026-05-11-transcript-hang-research-discussion.md` (sibling file). Template inside.
