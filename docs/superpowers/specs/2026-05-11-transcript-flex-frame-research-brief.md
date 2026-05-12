# Research brief: SwiftUI transcript pane hang, post-PR-#134 — flex-frame layout cycle

**Date:** 2026-05-11
**Author:** Claude (investigating issue cheapsteak/tbd#129)
**Audience:** Reviewer LLM/human being asked to **critique an existing analysis and propose alternatives** for a SwiftUI hang in the TBD transcript pane.

This is a peer-review brief, not a cold-start research request. A Claude general-purpose agent has already produced an analysis (summarized below). We want a second opinion that **challenges, refines, or extends** that analysis. If you think the leading hypothesis is wrong, say so concretely and propose what's right.

> Sibling: a similar brief was produced for the prior signature (`_ViewList_Group.estimatedCount` recursion); see [`2026-05-11-transcript-hang-research-brief.md`](2026-05-11-transcript-hang-research-brief.md). PR #134 — born from that brief — landed today and successfully killed that signature. This brief is about what's left.

## TL;DR

- **PR #134 worked for its targeted signature** (`_ViewList_Group.estimatedCount` recursion: ≥40 deep / 67% CPU → **0 occurrences**).
- **A different signature is now dominant**: `StackLayout.placeChildren1 ↔ _FlexFrameLayout.sizeThatFits ↔ _PaddingLayout.sizeThatFits` cycle, ~4 layers deep × 12/12 samples.
- **Claude's leading hypothesis**: `.scrollPosition(id: $visibleID, anchor: .bottom)` on a `ScrollView { LazyVStack }` is forcing continuous content-height accounting, which drives the per-row layout fix-point search. Single-line removal as the falsification test.
- **What we want from you**: is that hypothesis right? Is there a cheaper or more diagnostic test? Anything Claude missed?

## Bug class history (compressed)

`TranscriptItemsView` (`Sources/TBDApp/Panes/Transcript/`) renders a SwiftUI chat-style transcript inside `ScrollView { LazyVStack { ForEach } }` on macOS 15. Heterogeneous rows: user prompts, MarkdownUI chat bubbles, ~9 kinds of tool-call cards. Long sessions (50–1000+ items). Recurring 1s–17s main-thread hangs for weeks. Each fix closes one stack signature; a new one appears. Prior fixes (do not re-propose):

| When | What | Outcome |
|---|---|---|
| 2026-05-09 | Gated `.textSelection(.enabled)` on hover (PR #120). | Closed 17s `StyledTextLayoutEngine` storm. |
| 2026-05-11 morning | Capped `BashCard`/`WriteCard` inner-ScrollView heights at 600pt (PR #130). | Closed 5/10 signature. |
| 2026-05-11 today | **PR #134 (merged):** pre-flattened `[TranscriptRenderNode]` outside `body`, dropped `.onScrollGeometryChange(... contentSize.height ...)`, collapsed `SubagentDisclosure` to single non-interactive row, added `OSSignposter`. | Closed `_ViewList_Group.estimatedCount` recursion entirely. |

Full research-doc prior art collected at `docs/superpowers/specs/research-2026-05-06-swiftui-long-list-perf.md`. The `List` migration is documented as the structural fallback (`docs/superpowers/specs/2026-05-06-transcript-list-migration-design.md`) and explicitly still on the table for this round, but only if cheaper options don't work — `List` costs us `.defaultScrollAnchor(.bottom)` flash-free first paint and contiguous drag-select across rows.

## New hang signature (post-PR-#134)

Captured 2026-05-11 16:37, **1.18s hang, 1.100s main-thread CPU, 12 stackshots, ~23 min into a session.** Full spindump at `/Users/chang/tbd/worktrees/tbd/20260511-patient-tarantula/freeze.2.log` (18MB).

### Frame counts

- `_ViewList_Group.estimatedCount` / `ForEachList.estimatedCount`: **0 occurrences.** (Pre-#134: ≥40 deep, dominant.)
- `StackLayout.placeChildren1`: 7 occurrences.
- `_FlexFrameLayout.sizeThatFits` + `_PaddingLayout.sizeThatFits`: 12/12 samples each.
- `GeometryReader.Child.updateValue → TBDApp + 1464048`: 1/12 sample. **Claude located this** — `Sources/TBDApp/Terminal/TerminalContainerView.swift:215` (`.background(GeometryReader { ... preference(MainAreaSizeKey) })`). Claude characterized it as **noise**, not cause: it's downstream of the transcript layout cycle dirtying ancestors, not driving it. Worth verifying.

### Verbatim stack (deepest cycle path, lines 275–360 of freeze.2.log; ~12 deep in some samples)

```
NSHostingView.beginTransaction
  → GraphHost.flushTransactions
  → AG::Subgraph::update / AG::Graph::UpdateStack::update
  →   _LazyLayout_Subviews.applyNodes
  →     ForEachList.applyNodes → ForEachState.applyNodes
  →       StackPlacement.placeSection
  →         LazyHVStack<>.lengthAndSpacing                   ← outer LazyVStack
  →           ViewLayoutEngine.sizeThatFits
  →             StackLayout.placeChildren1                   ← TranscriptRow's VStack
  →               StackLayout.sizeChildrenIdeally
  →                 _FlexFrameLayout.sizeThatFits            ← .frame(maxWidth: .infinity)
  →                   StackLayout.placeChildren1             ← inner VStack (ActivityRowChrome)
  →                     _PaddingLayout.sizeThatFits          ← .padding(.horizontal, 12)
  →                       _PaddingLayout.sizeThatFits        ← .padding(.vertical, 4)
  →                         ViewLayoutEngine.sizeThatFits
  →                           StackLayout.placeChildren1     ← cycle continues ~4 layers
```

Same recursion family as **[cmux #2327](https://github.com/manaflow-ai/cmux/issues/2327)** documented in the research doc: nested flex-frame interactions inside a parent stack layout producing a place-children/size-children/re-place-children cycle.

## Current code state (post-merge)

### `TranscriptItemsView.swift` body (lines ~67–110, abridged)

```swift
struct TranscriptItemsView: View {
    let items: [TranscriptItem]
    let terminalID: UUID?
    var atBottom: Binding<Bool>? = nil
    @State private var hoveredItemID: String? = nil

    var body: some View {
        let intervalState = TranscriptSignposts.signposter.beginInterval("transcript.items.body")
        defer { TranscriptSignposts.signposter.endInterval("transcript.items.body", intervalState) }
        return bodyView
    }

    @ViewBuilder private var bodyView: some View {
        let nodes = transcriptRenderNodes(from: items)
        // ... bodyLogged perf marker ...
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(nodes) { node in
                TranscriptRow(node: node, terminalID: terminalID)
                    .environment(\.transcriptTextSelection, hoveredItemID == node.id)
                    .onHover { if $0 { hoveredItemID = node.id } }
            }
            // 1pt sentinel — replaces old onScrollGeometryChange 50pt threshold
            Color.clear
                .frame(height: 1)
                .onAppear { atBottom?.wrappedValue = true }
                .onDisappear { atBottom?.wrappedValue = false }
        }
        .padding(.vertical, 8)
    }
}
```

### `TranscriptRow.swift` (the new PR #134 wrapper)

```swift
struct TranscriptRow: View {
    let node: TranscriptRenderNode
    let terminalID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {     // ← new wrapper added by #134
            content
            if let usage = node.badgeUsage {
                ContextUsageBadge(total: usage.contextTotal)
                    .padding(.leading, 12).padding(.top, 2)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch node.kind {
        case .chatBubble(let item):                   ChatBubbleView(item: item)
        case .systemReminder(let id, let kind, let text, let ts):
            SystemReminderRow(id: id, kind: kind, text: text, timestamp: ts)
        case .skillBody(let id, let text, let ts):
            SkillBodyRow(id: id, text: text, timestamp: ts)
        case .toolCall(...):                          toolCard(...)
        case .subagentSummary(_, let count, let agentType):
            SubagentSummaryRow(count: count, agentType: agentType)
        }
    }
    // ... toolCard internal switch over 9 tool names ...
}
```

### `LiveTranscriptPaneView.swift` outer (lines ~127–135)

```swift
ScrollViewReader { proxy in
    ScrollView {
        TranscriptItemsView(items: messages, terminalID: terminalID, atBottom: $atBottom)
    }
    .defaultScrollAnchor(.bottom)
    .scrollPosition(id: $visibleID, anchor: .bottom)    // ← Claude's leading suspect
    .overlay(alignment: .bottomTrailing) {
        jumpToBottomButton(proxy: proxy)
    }
    .animation(.easeInOut(duration: 0.2), value: atBottom)
    .onAppear {
        // ... HangWatchdog.recordContext ...
        if let id = visibleID {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }
    .onChange(of: messages.last?.id) { _, newID in
        guard let _ = oldID, let _ = newID, atBottom else { return }
        guard let targetID = lastRenderedNodeID(for: messages) else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            visibleID = targetID
        }
    }
}
```

`.scrollPosition(id:)` writes the user's anchored row into `visibleID`; `.defaultScrollAnchor(.bottom)` provides the initial-position hint. **Both currently coexist.**

### `.frame(maxWidth: .infinity)` cardinality

Claude grepped `Panes/Transcript/` and found **21 callsites** — every chat bubble, every tool-card body, every `ActivityRowChrome.body`, every `AskUserQuestionCard` panel — each one a `_FlexFrameLayout` node that appears as a frame in the cycle. Stacked `.padding(...)` modifiers on top add one round-trip per layer to the fix-point search.

## Claude's analysis (summary)

### Root-cause hypothesis

**Layout fixed-point search inside LazyVStack.** SwiftUI's `LazyVStack` (a `StackLayout`) sizes a child by (1) proposing a width, (2) asking the child to fit, (3) reconciling alignment. A child rooted in `VStack { ... }.frame(maxWidth: .infinity)` is a `_FlexFrameLayout` containing another `StackLayout`. With `maxWidth: .infinity`, the child can't commit a width until its own children fit — so each `.padding(...)` wrapper introduces another round-trip. With 21 per-row flex frames, each row's layout pass bounces through `StackLayout ↔ _FlexFrameLayout ↔ _PaddingLayout` repeatedly. `.scrollPosition(id:, anchor: .bottom)` then *forces SwiftUI to know the anchored row's exact y-position*, which requires sizing every row from `visibleID` to end on every transaction. That sizing cost is what's hanging.

### PR #134 culpability

**~75% pre-existing, ~25% amplified by the new `TranscriptRow` `VStack` wrapper.** Evidence:
- `_FlexFrameLayout.sizeThatFits` and `_PaddingLayout.sizeThatFits` were *visible* in the pre-#134 12:18 freeze (~8/12 samples each), just masked by the dominant `estimatedCount` work. Now they're the top remaining cost.
- The new wrapper adds 1 `StackLayout` layer per row; the cycle was always there, now it's 4-deep instead of 3-deep.
- `.scrollPosition(id:)` and the 21 `.frame(maxWidth:.infinity)` callsites all predate #134.

So #134 didn't cause this — it exposed the always-latent cycle by removing the bigger cost on top. (The row-wrapper amplification is a small *bonus* fix-back opportunity if Fix A doesn't fully clear the cycle.)

### Candidate fixes (ranked)

| # | Fix | Confidence | Effort |
|---|---|---|---|
| **A** | **Drop `.scrollPosition(id:)`, keep `.defaultScrollAnchor(.bottom)`** + remove `visibleID` state and its two `onChange` writers. Use `ScrollViewReader.proxy.scrollTo` for autoscroll (already in place). | **High** | 1-line removal + dead-state cleanup |
| B | Add `.fixedSize(horizontal: false, vertical: true)` on `TranscriptRow.body`'s outer `VStack`. | Medium (cycle is width-shaped, not height-shaped) | 1 line |
| C | Hoist `.frame(maxWidth: .infinity)` from per-row to LazyVStack level + remove from 21 callsites. | Med-high impact, med-high risk (visual regressions, esp. ChatBubbleView right-alignment) | 21-callsite refactor |
| D | `TranscriptRow: Equatable` + `.equatable()`. | Medium for re-render churn, low for layout cycle (skips `body`, not `sizeThatFits`) | 5 lines |
| E | `List` migration (structural fix). | High that it works; existing design doc has the plan. | Medium (1 commit per design doc) |
| F | Replace `if usage { Badge }` conditional with always-rendered + opacity/overlay (kills `_ConditionalContent` row-shape flips on every new message). | Low-Medium | 5 lines |

### Proposed 1-day test (Fix A)

1. Baseline spindump on a 500+ item transcript scrolled up.
2. Remove `.scrollPosition(id:)` + dead `visibleID` state + 2 `onChange` writers.
3. Verification spindump after restart.
4. **Pass**: `grep -c "StackLayout.UnmanagedImplementation" freeze.*.log` drops ≥50%, recursion depth from ~4 to ≤2.
5. Functional: re-entry behavior (loses "remembered scroll position" — re-opens at bottom), autoscroll on new message, jump-to-bottom button. **Trade-off acceptable.**

## What we want from you (the reviewer)

Critique Claude's analysis. Specifically:

1. **Is Fix A the leading candidate, or should something else be first?** Cite reasoning. If Claude's hypothesis about `.scrollPosition(id:)` forcing continuous content-height accounting is wrong or oversimplified, explain why. (Apple DTS reply on [forums #770682](https://developer.apple.com/forums/thread/770682) confirms `.scrollPosition` doesn't work on `List` — does it actually force *continuous* size accounting on `LazyVStack`, or only on initial position resolution? Cite SwiftUI internals or Apple docs.)

2. **Is there a cheaper or more diagnostic test than Fix A?** The frame-count + recursion-depth grep is rough — would a more precise instrument (Instruments, SwiftUI track, `OSSignposter` overlap with one of our existing regions) tell us more without code change first?

3. **Is the `TranscriptRow` wrapper's ~25% amplification estimate plausible?** Could the new `VStack(alignment: .leading, spacing: 2)` actually be the *primary* contributor, not a secondary one? Falsifying test?

4. **Anything Claude missed?** Specifically:
   - A SwiftUI internals nuance about `_FlexFrameLayout` + `_PaddingLayout` interaction that would short-circuit the cycle differently than removing `.scrollPosition`.
   - A WWDC24/25 API or recent macOS 15.x update that changes the calculus.
   - A non-obvious code path (e.g., `MarkdownUI`'s internal `Table` rendering via `TableBounds.init`, which appeared in the prior freeze) that's a co-contributor we should investigate before assuming the row chrome is the only flex-frame source.

5. **Is the GeometryReader hit at `TerminalContainerView.swift:215` definitely noise, or worth investigating?** Claude said "downstream of the transcript layout cycle dirtying ancestors" — verify or refute. If it could be a partial contributor, what's the test?

## Reference docs

- `docs/superpowers/specs/research-2026-05-06-swiftui-long-list-perf.md` — collected prior art (~30 sources, IceCubes pattern, MarkdownUI maintenance-mode story, etc.).
- `docs/superpowers/specs/2026-05-06-transcript-list-migration-design.md` — the structural-fallback migration design.
- `docs/superpowers/specs/2026-05-11-transcript-render-node-design.md` — the PR #134 implementation spec.
- `docs/superpowers/specs/2026-05-11-transcript-hang-research-{brief,discussion}.md` — the prior research pair for the `estimatedCount` signature (now resolved).

## Constraints

- Read-only investigation. No code changes.
- Reference files by `path:line` when relevant.
- Use grep/awk on `freeze.2.log` rather than reading the whole 18MB.
- Working directory: `/Users/chang/tbd/worktrees/tbd/20260511-patient-tarantula/`.
- Issue tracker: <https://github.com/cheapsteak/tbd/issues/129> (still open).

## Coordination

If you want to leave findings: append to `docs/superpowers/specs/2026-05-11-transcript-flex-frame-research-discussion.md` (sibling file). Template inside.
