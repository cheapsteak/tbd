# Research brief: SwiftUI transcript pane hang, post-PR-#137 — flex-frame cycle still dominant

**Date:** 2026-05-12
**Author:** Claude (investigating issue cheapsteak/tbd#129, reopened 2026-05-12)
**Audience:** Codex (or other reviewer LLM/human) being asked to **investigate why the StackLayout ↔ _FlexFrameLayout cycle survived the PR #137 fix** and recommend next concrete steps.

This is the third research-brief in the #129 series. The first two led to landed fixes (PR #134, PR #137). Both were grounded in the prior brief's hypothesis. The current freeze is the first longitudinal data point after the latest fix, and **it shows the bug class is still alive**. The previous brief proposed `.scrollPosition(id:)` removal as the falsification test for the leading hypothesis; PR #137 executed that test. The test came back negative — the cycle is largely unchanged.

This brief asks: **given that the prior hypothesis was falsified, what should be tried next?**

## TL;DR

- **PR #137 (`261681b`, merged 2026-05-12 08:46)** removed all three contributors the prior brief identified: `.animation(.easeInOut, value: atBottom)` wrapping the `ScrollView`, `.scrollPosition(id: $visibleID, anchor: .bottom)`, and un-role-scoped `.defaultScrollAnchor(.bottom)`. Plus dead `visibleID` state cleanup.
- **A new freeze was captured ~7 hours later** (2026-05-12 15:41:00 -0400, TBDApp PID 36142, 1.14s hang, 1.098s main-thread CPU, 12 samples × 100ms). The `StackLayout ↔ _FlexFrameLayout ↔ ScrollViewLayoutComputer.Engine.sizeThatFits` recursion is still dominant.
- **Implication**: the prior brief's leading hypothesis ("`.scrollPosition(id:)` forces continuous content-height accounting, which drives the per-row layout fix-point search") was not the dominant cause. Removing it did not break the cycle.
- **What we want from you**: investigate what *is* driving the cycle, given that the most-suspected modifier is now gone. Propose a new ranked candidate list with a falsification test for the top option.

## Bug class history (extended from prior briefs)

`TranscriptItemsView` (`Sources/TBDApp/Panes/Transcript/`) renders a SwiftUI chat-style transcript inside `ScrollView { LazyVStack { ForEach } }` on macOS 26.1. Heterogeneous rows: user prompts, MarkdownUI chat bubbles, ~9 kinds of tool-call cards. Long sessions (50–1000+ items). Recurring 1s–17s main-thread hangs for weeks. Each fix closes one stack signature; a new one appears. Prior fixes (do not re-propose):

| When | What | Outcome |
|---|---|---|
| 2026-05-09 | Gated `.textSelection(.enabled)` on hover (PR #120, `a41f716`). | Closed 17s `StyledTextLayoutEngine` storm. |
| 2026-05-11 morning | Capped `BashCard`/`WriteCard` inner-ScrollView heights at 600pt (PR #130, `937c1c4`). Centralized in `TranscriptCardLayout.{expandedMaxHeight, collapsedMaxHeight}`. | Closed `.frame(maxHeight: .infinity)` recursion. |
| 2026-05-11 afternoon | PR #134 (`2a57ac7`): pre-flattened `[TranscriptRenderNode]` outside `body`, dropped `.onScrollGeometryChange(... contentSize.height ...)`, collapsed `SubagentDisclosure` to single non-interactive row, added `OSSignposter` (`TranscriptSignposts`). | Closed `_ViewList_Group.estimatedCount` recursion (≥40 deep → 0 frames). |
| **2026-05-12 morning** | **PR #137 (`261681b`)**: dropped `.scrollPosition(id: $visibleID, anchor: .bottom)`, scoped `.animation(.easeInOut, value: atBottom)` to the jump-button overlay only, role-scoped `.defaultScrollAnchor(.bottom, for: .initialOffset)`, rewired autoscroll to `proxy.scrollTo(lastRenderedNodeID, anchor: .bottom)`. Trade-off accepted: scroll-position-preservation on pane re-entry. | **Targeted the StackLayout ↔ _FlexFrameLayout cycle. Validation: longitudinal HangWatchdog.** |

Full research-doc prior art at `docs/superpowers/specs/research-2026-05-06-swiftui-long-list-perf.md`. The `List` migration design (`docs/superpowers/specs/2026-05-06-transcript-list-migration-design.md`) remains the structural fallback.

## New hang capture (post-PR-#137)

Captured **2026-05-12 15:41:00 -0400**, ~7 hours after PR #137 merged.
Spindump: **`/Users/chang/tbd/worktrees/tbd/20260512-juicy-swordfish/freeze.1.log`** (234,755 lines).
TBDApp PID 36142, time-since-fork 20,849s (~5.8h uptime), footprint 390 MB, 10 threads.
Duration **1.14s, 12 samples × 100ms**, **1.098s main-thread CPU** (≈100% on-CPU — actively spinning, not blocked).

All 12 samples share the same prefix (lines 198–230):
```
NSApplication.run
  → CFRunLoop observer
  → NSHostingView.beginTransaction
  → Update.ensure
  → ViewGraphRootValueUpdater.updateGraph
  → GraphHost.flushTransactions
```

Sample-by-sample breakdown of the inner work (line numbers in `freeze.1.log`):

| Sample | Inner work | Lines |
|---|---|---|
| 1 | `GraphHost.runTransaction` → `LazyLayoutCacheItem.AllItemsPhaseMutation.apply` → `LazyLayoutViewCache.updateItemPhase` → `AG::Graph::propagate_dirty` | 231–236 |
| 2 | `GraphHost.runTransaction` → `AG::Subgraph::update` → `AG::Graph::UpdateStack::push` | 237–239 |
| 3 | Same as sample 1 | 240–245 |
| 4 | `AG::Graph::UpdateStack::update` (running) | 246–248 |
| 5 | `AG::Graph::UpdateStack::update` (running) | 249 |
| **6** | **`StackLayout` ↔ `_FlexFrameLayout` ↔ `ScrollViewLayoutComputer.Engine.sizeThatFits` cycle, ~25 frames deep, then `LazyVStackLayout` ↔ `LazyHStackLayout` → `LazyStack.measureEstimates` → `_LazyLayout_Subviews.apply` → `ForEachList.applyNodes` → `<deduplicated_symbol>` (libswiftCore)** | 250–317 |
| 7 | `DynamicBody.updateValue` → `swift_retain` | 318–320 |
| 8 | `AG::Graph::UpdateStack::update` (running) | 321 |
| **9** | **Same recursive cycle as sample 6, fully expanded for ~70 frames, bottoming out in `LazyStack.measureEstimates` → `ForEachList.applyNodes` → `_PaddingLayout.sizeThatFits` × N → `StackLayout.UnmanagedImplementation.sizeChildrenGenerallyWithConcreteMajorProposal`** | 322–433 |
| **10** | **Same recursive cycle, bottoming out in `PlatformViewLayoutEngine.sizeThatFits` → `ViewLeafView.sizeThatFits` → `Update.syncMain` → `AppKitPlatformViewHost.intrinsicLayoutTraits` → `-[NSView measureMin:max:ideal:stretchingPriority:]` → `-[NSISEngine withBehaviors:performModifications:]` → `NSISLinExpEnumerateVarsAndCoefficientsUntil` → `NSBitSetCount`** | 434–533 |
| **11** | **`LazySubviewPlacements.updateValue` → `LazySubviewPlacements.placeSubviews` → `LazyStack.place` → `_ViewList_Node.estimatedCount` → `<deduplicated_symbol>`** — residual `estimatedCount` path that PR #134 mostly killed | 534–544 |
| 12 | `AG::Subgraph::update` (running) | 545 |

### Frame counts vs prior captures

| Frame | 2026-05-11 12:18 (pre-PR-#134) | 2026-05-11 16:37 (post-PR-#134, pre-PR-#137) | **2026-05-12 15:41 (post-PR-#137)** |
|---|---|---|---|
| `_ViewList_Group.estimatedCount` / `ForEachList.estimatedCount` | ≥40 deep, ~67% CPU | 0 | **1 sample × 1 frame (sample 11)** |
| `_ViewList_Node.estimatedCount` | n/a (folded above) | 0 | **1 sample × 1 frame (sample 11)** |
| `StackLayout.placeChildren1` | secondary | 7 | **dominant (samples 6, 9, 10) — ~30 frames per sample** |
| `_FlexFrameLayout.sizeThatFits` | 12/12 (masked) | 12/12 (dominant) | **3/12 samples directly, but cycle-defining when present** |
| `_PaddingLayout.sizeThatFits` | 12/12 (masked) | 12/12 | **3/12 samples directly** |
| `ScrollViewLayoutComputer.Engine.sizeThatFits` | not noted | 7 | **3/12 samples (samples 6, 9, 10)** |
| `AppKitPlatformViewHost.intrinsicLayoutTraits` → `NSView measureMin` → `NSISEngine` | not noted | not noted | **1/12 sample (sample 10) — new, deeper into AppKit bridge** |
| `LazyLayoutCacheItem.AllItemsPhaseMutation.apply` → `propagate_dirty` | not noted | not noted | **2/12 samples (samples 1, 3) — new** |

### Verbatim deepest cycle (sample 9, lines 369–432 of `freeze.1.log`, condensed)

```
ScrollViewLayoutComputer.Engine.sizeThatFits           ← ScrollView inner content sizing
  → ViewSizeCache.get
    → static ScrollViewUtilities.sizeThatFits
      → LayoutComputer.sizeThatFits
        → LazyLayoutComputer.Engine.sizeThatFits        ← outer LazyVStack
          → LazyVStackLayout.sizeThatFits
            → LazyStack.sizeThatFits
              → LazyStack.measureEstimates
                → _LazyLayout_Subviews.apply
                  → _ViewList_Node.applyNodes
                    → _ViewList_Group.applyNodes
                      → ForEachList.applyNodes
                        → ForEachState.forEachItem
                          → ModifiedViewList.applyNodes  ← .onHover + .environment
                            → SubgraphList.applyNodes
                              → BaseViewList.applyNodes
                                → LazyStack.measureEstimates  ← inner LazyHVStack
                                  → LazyHVStack.lengthAndSpacing
                                    → StackLayout.placeChildren1
                                      → StackLayout.sizeChildrenIdeally / sizeChildrenGenerallyWithConcreteMajorProposal
                                        → _FlexFrameLayout.sizeThatFits        ← .frame(maxWidth: .infinity)
                                          → ViewLayoutEngine.sizeThatFits
                                            → StackLayout.placeChildren1       ← cycle continues
                                              → _PaddingLayout.sizeThatFits    ← .padding(...)
                                                → _PaddingLayout.sizeThatFits  ← stacked padding
                                                  → StackLayout.placeChildren1 ← cycle 3-deep
                                                    → ...
```

The pre-/post-#137 cycle shape is **structurally identical**. PR #137 removed three contributors that the prior brief identified as cycle drivers; the cycle is still there.

### One notable new wrinkle (sample 10, lines 506–533)

For the first time, a sample bottoms out **all the way through the SwiftUI → AppKit bridge**:

```
PlatformViewLayoutEngine.sizeThatFits
  → ViewLeafView.sizeThatFits
    → Update.syncMain  ← synchronously hopping to main thread (we are on main thread)
      → ViewLeafView.layoutTraits
        → AppKitPlatformViewHost.coreLayoutTraits
          → AppKitPlatformViewHost.intrinsicLayoutTraits
            → -[NSView(NSConstraintBasedLayoutInternal) measureMin:max:ideal:stretchingPriority:]
              → -[NSISEngine withBehaviors:performModifications:]
                → -[NSView addConstraints:]
                  → -[NSView _withAutomaticEngineOptimizationDisabled:]
                    → -[NSISEngine withBehaviors:performModifications:]
                      → -[NSView _tryToAddConstraint:...]
                        → -[NSLayoutConstraint _addToEngine:...]
                          → -[NSISEngine tryToAddConstraintWithMarker:expression:...]
                            → -[NSISEngine _tryToAddConstraintWithMarkerEngineVar:row:...]
                              → -[NSISEngine tryAddingDirectly:]
                                → -[NSISEngine chooseHeadForRow:chosenCol:outNewToEngine:]
                                  → NSISLinExpEnumerateVarsAndCoefficientsUntil
                                    → NSBitSetCount   ← actively running
```

A SwiftUI leaf view is being bridged into an `NSView` and measured via the Auto Layout (NSISEngine) solver. Candidates for that bridge in the transcript pane:

- **MarkdownUI** — `swift-markdown-ui` renders selectable text via an `NSTextView`-backed bridge for the `.textSelection(.enabled)` branch.
- **AttributedString / SwiftUI `Text` with rich attributes** — uses `NSAttributedString` and `TextKit`, can re-enter NSView measurement.
- **An `NSHostingView` we instantiate ourselves** — we use this for worktree keep-alive at the terminal level (`KeepAliveHost`, `TerminalContainerView`) but I'm not aware of one inside transcript rows. Worth verifying.

This is the first capture where the cycle drives all the way into the AppKit measurement path. May be a new contributor exposed by PR #137 (the removal of `.scrollPosition(id:)` may have unblocked more layout passes per frame, increasing the chance of hitting this branch in a sample).

## Current code state (post-PR-#137)

### `LiveTranscriptPaneView.swift:62–87` (transcriptWithAutoscroll)

```swift
@ViewBuilder
private var transcriptWithAutoscroll: some View {
    ScrollViewReader { proxy in
        ScrollView {
            TranscriptItemsView(items: messages, terminalID: terminalID, atBottom: $atBottom)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)          // role-scoped (was un-scoped pre-#137)
        .overlay(alignment: .bottomTrailing) {
            jumpToBottomButton(proxy: proxy)
                .animation(.easeInOut(duration: 0.2), value: atBottom)  // scoped to overlay (was wrapping ScrollView pre-#137)
        }
        // .scrollPosition(id: $visibleID, anchor: .bottom)         // ← removed in PR #137
        .onAppear { ... HangWatchdog context ... }
        .onChange(of: messages.last?.id) { oldID, newID in
            guard let _ = oldID, let _ = newID, atBottom else { return }
            guard let targetID = lastRenderedNodeID(for: messages) else { return }
            let scrollInterval = TranscriptSignposts.signposter.beginInterval("transcript.scrollTo")
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(targetID, anchor: .bottom)            // rewired in PR #137
            }
            TranscriptSignposts.signposter.endInterval("transcript.scrollTo", scrollInterval)
        }
        .onChange(of: messages.count) { ... HangWatchdog context ... }
        .onDisappear { ... HangWatchdog clear ... }
    }
}
```

### `TranscriptItemsView.swift:64–113`

```swift
var body: some View {
    let intervalState = TranscriptSignposts.signposter.beginInterval("transcript.items.body")
    defer { TranscriptSignposts.signposter.endInterval("transcript.items.body", intervalState) }
    return bodyView
}

@ViewBuilder
private var bodyView: some View {
    let nodes = transcriptRenderNodes(from: items)
    let _ = { /* debug log when >100 nodes */ }()
    LazyVStack(alignment: .leading, spacing: 4) {
        ForEach(nodes) { node in
            TranscriptRow(node: node, terminalID: terminalID)
                .environment(\.transcriptTextSelection, hoveredItemID == node.id)
                .onHover { hovering in
                    if hovering { hoveredItemID = node.id }  // latch on enter, no clear on exit
                }
        }
        Color.clear                                          // 1pt at-bottom sentinel
            .frame(height: 1)
            .onAppear { atBottom?.wrappedValue = true }
            .onDisappear { atBottom?.wrappedValue = false }
    }
    .padding(.vertical, 8)
}
```

### `TranscriptRow.swift` (unchanged from PR #134)

```swift
struct TranscriptRow: View {
    let node: TranscriptRenderNode
    let terminalID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {     // wrapper added in PR #134
            content
            if let usage = node.badgeUsage {
                ContextUsageBadge(total: usage.contextTotal)
                    .padding(.leading, 12).padding(.top, 2)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch node.kind {
        case .chatBubble(let item):       ChatBubbleView(item: item)
        case .systemReminder(...):        SystemReminderRow(...)
        case .skillBody(...):             SkillBodyRow(...)
        case .toolCall(...):              toolCard(...)
        case .subagentSummary(...):       SubagentSummaryRow(...)
        }
    }
    // ... toolCard switch over 9 tool names ...
}
```

### `.frame(maxWidth: .infinity)` cardinality (unchanged)

Still **21 callsites** across 12 files in `Sources/TBDApp/Panes/Transcript/`:
`ActivityRowChrome.swift`, `AgentCard.swift`, `AskUserQuestionCard.swift`, `BashCard.swift`, `ChatBubbleView.swift`, `EditCard.swift`, `GenericToolCard.swift`, `GlobCard.swift`, `GrepCard.swift`, `ReadCard.swift`, `SkillBodyRow.swift`, `WriteCard.swift`.

`.frame(maxHeight: .infinity)` has been replaced with finite caps (`TranscriptCardLayout.expandedMaxHeight = 600`, `collapsedMaxHeight = 120`) — see `BashCard.swift:73,109`, `WriteCard.swift:66`. The horizontal axis is the open question.

## What the previous brief proposed and what shipped

| Fix from 2026-05-11 brief | Confidence ranked | Shipped in PR #137? |
|---|---|---|
| **A**: Drop `.scrollPosition(id:)`, keep `.defaultScrollAnchor` | High | **Yes (+ also role-scoped `.defaultScrollAnchor` and removed animation wrapping)** |
| B: `.fixedSize(horizontal: false, vertical: true)` on `TranscriptRow` outer VStack | Medium | No |
| C: Hoist `.frame(maxWidth: .infinity)` from per-row to LazyVStack level + remove from 21 callsites | Med-high | No (riskier — visual regressions, esp. `ChatBubbleView` right-alignment) |
| D: `TranscriptRow: Equatable + .equatable()` | Med | No |
| E: `List` migration (structural fix) | High that it works | No |
| F: Always-render `ContextUsageBadge` with opacity instead of conditional | Low-Med | No |

The PR #137 commit message confirms the team picked Fix A but also folded in the animation-wrapping removal and `.defaultScrollAnchor` role-scoping, so it's slightly more aggressive than just Fix A. The cycle survived all three changes.

## What we want from you (Codex)

### 1. Re-evaluate the leading hypothesis

The prior brief said `.scrollPosition(id:)` was "forcing continuous content-height accounting, which drives the per-row layout fix-point search". That's now falsified — its removal didn't break the cycle. Two possibilities:

- **(a)** The hypothesis was wrong: `.scrollPosition(id:)` doesn't actually force continuous accounting; the cycle was always driven by something else.
- **(b)** The hypothesis was right *for that modifier* but the cycle has multiple drivers, and `.scrollPosition(id:)` was a small one; removing it didn't move the needle.

Which is it, and what's the evidence? (Specifically: is there a SwiftUI internals reference, a WWDC talk, or an Apple DTS thread that documents what *does* force continuous content-height accounting on `LazyVStack` inside a `ScrollView`?)

### 2. Propose a new ranked candidate list

Given the cycle is still 30+ frames deep across 3/12 samples, what are the next candidate fixes to investigate? **Constraints:**

- No `.scrollPosition(id:)`-equivalent re-introduction (we accepted that trade-off in PR #137).
- Prefer single-line / single-file experiments before structural refactors.
- For each candidate: state the hypothesis, the verification signal (frame count change in spindump grep), the falsification signal, and the trade-off.
- Include `List` migration as the last-resort structural option, but only after cheaper options are exhausted or determined infeasible.

Specific candidates to evaluate (consider, then accept/reject/refine):

- **C** (hoist `.frame(maxWidth: .infinity)` from per-row to LazyVStack). The 21 callsites mean the per-row flex frame is the structural anchor of every cycle bottom. Hoisting *might* break alignment guarantees in `ChatBubbleView` (which uses `maxWidth: .infinity, alignment: .trailing` for user-bubbles). What's the actual impact?
- **B** (`.fixedSize(horizontal: false, vertical: true)` on `TranscriptRow`). The prior brief rated this medium because "the cycle is width-shaped, not height-shaped". Reconsider: does the cycle now look height-shaped given samples 9 and 10 walk through `_FlexFrameLayout.sizeThatFits` for height, not width? Could `.fixedSize(horizontal: false, vertical: true)` short-circuit the flex-frame's contribution to the recursion?
- **G** (new candidate): **kill the inner LazyHVStack invocation.** Sample 9 shows `LazyStack.measureEstimates → ForEachList.applyNodes → … → LazyStack.measureEstimates` — there's a *second* LazyStack instance inside the outer one. Is `TranscriptRow`'s `VStack` lowering to a `LazyHVStack` under the hood, or is this the outer LazyVStack re-entering itself? The 4960199 commit added the row wrapper — could a plain `Group` instead of `VStack` avoid the inner stack-layout entirely?
- **H** (new candidate): **investigate the sample-10 AppKit bridge.** Which view is being measured via `NSView measureMin → NSISEngine`? MarkdownUI selectable text? Something else? Is there a config we can pass to disable the AppKit-side measurement?

### 3. Diagnose sample 10's AppKit bridge

Sample 10 (lines 506–533 of `freeze.1.log`) is the first capture showing the cycle walks all the way into `-[NSISEngine chooseHeadForRow:chosenCol:outNewToEngine:]`. **Identify which transcript view is the source.** Hypotheses:

- `swift-markdown-ui` `MarkdownTextView` (NSTextView-backed, used in `ChatBubbleView`)
- A `Text` with attributed content + selection
- An accidental `NSHostingView` we don't know about

If it's MarkdownUI: is the upcoming `Textual` migration (the maintainer's successor library) likely to remove this bridge? Worth coupling Phase 2 of the fix?

### 4. Sanity-check the residual `estimatedCount` path

Sample 11 (line 543) shows `_ViewList_Node.estimatedCount + 136` — exactly the path PR #134 was designed to eliminate. PR #134 reduced it from "≥40 deep, ~67% CPU" to "0 occurrences" in the 2026-05-11 16:37 capture. It's now back to 1/12 samples × 1 frame in the 2026-05-12 15:41 capture.

- Is this a regression introduced by PR #137 (animation removal exposing a code path that was previously masked)?
- Or is it the always-residual `estimatedCount` path that PR #134's design doc said couldn't be fully eliminated without `List`?
- Reference: `docs/superpowers/specs/2026-05-11-transcript-render-node-design.md`, the PR #134 impl spec.

### 5. Recommend the next falsification test

Given the new evidence, what's the **single-line or smallest-possible change** that would best discriminate between the remaining hypotheses?

## Reference docs (prior work)

- `docs/superpowers/specs/2026-05-11-transcript-flex-frame-research-brief.md` — the **prior brief** that produced PR #137. Its Fix A was implemented; its central hypothesis is now falsified by this freeze.
- `docs/superpowers/specs/2026-05-11-transcript-flex-frame-research-discussion.md` — the Codex/Gemini reviewer convergence on the prior brief.
- `docs/superpowers/specs/2026-05-11-transcript-hang-research-brief.md` — the earlier brief about `_ViewList_Group.estimatedCount` recursion. PR #134 closed that signature.
- `docs/superpowers/specs/2026-05-11-transcript-hang-research-discussion.md` — its reviewer convergence.
- `docs/superpowers/specs/2026-05-11-transcript-render-node-design.md` — the PR #134 impl spec (introduces `TranscriptRenderNode`, `TranscriptRow`).
- `docs/superpowers/specs/2026-05-12-transcript-scroll-bounds-design.md` — the PR #137 impl spec.
- `docs/superpowers/specs/2026-05-06-transcript-list-migration-design.md` — the structural-fallback `List`-migration design (IceCubesApp pattern).
- `docs/superpowers/specs/research-2026-05-06-swiftui-long-list-perf.md` — collected prior art (~30 sources, IceCubes/cmux #2327, MarkdownUI maintenance trajectory).

## Reference commits

- `261681b` — PR #137 — "perf(transcript): drop declarative scroll-bounds + animation wrapping (#129)" — merged 2026-05-12 08:46.
- `2a57ac7` — PR #134 — "Perf: flatten transcript ForEach body to kill estimatedCount recursion (#129)" — merged 2026-05-11.
- `937c1c4` — PR #130 — "Fix: Stop expanded transcript cards from freezing the UI" — merged 2026-05-11.
- `a41f716` — PR #120 — "Fix: 17s transcript hang from per-row text-selection storm" — merged 2026-05-09.

## Constraints

- **Read-only investigation. No code changes.**
- Reference files by `path:line` when relevant.
- Use `grep`/`awk` on `freeze.1.log` rather than reading the whole 235k-line file. The main thread is at lines 198–545 (see Sample-by-sample table above for which inner-work is where).
- Working directory: `/Users/chang/tbd/worktrees/tbd/20260512-juicy-swordfish/`.
- Issue tracker: <https://github.com/cheapsteak/tbd/issues/129> (reopened 2026-05-12).
- The main session's previous reasoning is in this brief — feel free to disagree with any of it. Cite evidence.

## Coordination

**Write your findings into the sibling blank file:**
`docs/superpowers/specs/2026-05-12-transcript-flex-frame-post-pr137-findings.md`

That file contains a suggested template. The main session will read your findings before deciding whether to open a follow-up implementation PR or kick off the `List` migration.
