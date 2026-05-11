# Transcript pane: flatten the `ForEach` body via `TranscriptRenderNode`

**Date:** 2026-05-11
**Status:** Approved for implementation (pending sign-off).
**Goal:** Eliminate the `_ViewList_Group.estimatedCount` recursion driving recurring main-thread hangs (issue cheapsteak/tbd#129), by making the transcript `ForEach` body satisfy Apple's documented constant-view-count rule.

## Why

The 12:18 and 13:xx hangs both bottom out in:

```
LazyVStack.sizeThatFits → LazyStack.measureEstimates / sizeThatFits
  → _ViewList_Node.estimatedCount → ForEachList.estimatedCount
  → ForEachState.estimatedCount ↔ _ViewList_Group.estimatedCount  (deep recursion)
```

SwiftUI's lazy containers need to know "how many rows is this `ForEach` going to produce?" before measuring. When the body produces a constant number of views per element, this is O(1). When the body's child count varies per element — via `if`/`switch`/sibling conditionals/nested `ForEach` — SwiftUI must walk the conditional view tree per element to count, and that walk recurses through `_ViewList_Group` for nested cases. Apple [ForEach docs](https://developer.apple.com/documentation/swiftui/foreach) + WWDC23 ["Demystify SwiftUI Performance"](https://developer.apple.com/videos/play/wwdc2023/10160/) call this out explicitly: *each collection element should produce a constant number of views.*

Our current `ForEach` body in `TranscriptItemsView` violates the rule in three documented ways:

1. **Variable cardinality per element.** `rowFor` returns `EmptyView` for hidden items (`.thinking`, `.slashCommand`, hidden tool names) and a deep `VStack` for visible tool calls — so the per-element child count is 0 or 1+.
2. **Sibling conditional.** `if item.id == latestUsageItemID { ContextUsageBadge(...) }` adds an optional second child to the body, per element.
3. **Nested `ForEach`.** Expanded `SubagentDisclosure` recursively renders a child `TranscriptItemsView` with its own `ForEach`.

This spec flattens all three.

## Out of scope (descoped from this fix)

- **Subagent expansion is removed.** Subagent activity will be summarized as a single non-interactive row; the inline disclosure (`SubagentDisclosure`) goes away. A pop-out viewer for subagent activity will be added later as a separate feature. This decision lets us drop the nested `ForEach` outright instead of lifting expansion state.
- **Migration to `List`.** Stays the fallback path if measurement after this fix shows the recursion didn't actually shrink. See [`2026-05-06-transcript-list-migration-design.md`](2026-05-06-transcript-list-migration-design.md).
- **`@Observable` migration of `AppState`.** Larger refactor; deferred. Codex flagged `@EnvironmentObject AppState` injection as an invalidation amplifier, but today's hang is dominated by *sizing*, not invalidation, so this is a follow-up if needed.
- **`.equatable()` on `TranscriptRow`.** Cheap follow-up commit *after* the flattening lands and we've confirmed the structural fix worked; not in this PR.

## Model

```swift
/// A pre-computed render entry for the transcript pane. Built once outside
/// `body` from `[TranscriptItem]`; consumed by `TranscriptItemsView`'s
/// `ForEach`. Constant view-shape per node: every node renders as a single
/// `TranscriptRow` view, giving the outer `LazyVStack`'s ForEach a
/// homogeneous body.
struct TranscriptRenderNode: Identifiable, Equatable {
    /// Stable across polls. Derived from the underlying TranscriptItem.id;
    /// the `subagentSummary` kind uses the parent toolCall's id with a
    /// `#subagent` suffix.
    let id: String

    /// The visible content classification.
    let kind: Kind

    /// Inlined ContextUsageBadge. When non-nil, the owning row renders the
    /// badge below its primary content. Inlined (not a sibling node) so
    /// that the ForEach body's per-element view count stays constant at 1.
    let badgeUsage: TokenUsage?

    enum Kind: Equatable {
        case chatBubble(TranscriptItem)                                   // .userPrompt, .assistantText
        case systemReminder(id: String, kind: SystemReminderKind, text: String, timestamp: Date?)
        case skillBody(id: String, text: String, timestamp: Date?)
        case toolCall(id: String, name: String, inputJSON: String,
                      inputTruncatedTo: Int?, result: ToolResult?, timestamp: Date?)
        case subagentSummary(parentItemID: String, count: Int, agentType: String?)
    }
}
```

Notes:

- **Hidden items don't get nodes.** `.thinking`, `.slashCommand`, and tool calls whose names are in `hiddenToolNames` (`TodoWrite`, `TaskUpdate`, `TaskCreate`, `Skill`) are filtered upstream — they don't appear in the node array.
- **Badge is a field, not a node.** `ContextUsageBadge` becomes a side effect of the owning row rather than a sibling list entry.
- **Subagent → single summary row.** Each toolCall with a subagent emits *two* nodes (the toolCall + a `subagentSummary`), both with constant shape.

## Pure rendering function

```swift
// In TranscriptItemsView.swift (or a sibling file)
nonisolated func transcriptRenderNodes(from items: [TranscriptItem]) -> [TranscriptRenderNode] {
    // 1. Find the most-recent visible item carrying a TokenUsage, for badge attachment.
    let latestUsageItemID: String? = items.reversed().first {
        $0.usage != nil && !isHiddenInTranscript($0)
    }?.id

    // 2. Build nodes, skipping hidden items, inlining badge, emitting subagent summaries.
    var out: [TranscriptRenderNode] = []
    out.reserveCapacity(items.count)
    for item in items {
        if isHiddenInTranscript(item) { continue }

        let badge: TokenUsage? = (item.id == latestUsageItemID) ? item.usage : nil

        switch item {
        case .userPrompt, .assistantText:
            out.append(.init(id: item.id, kind: .chatBubble(item), badgeUsage: badge))

        case .systemReminder(let id, let kind, let text, let ts):
            if kind == .skillBody {
                out.append(.init(id: id, kind: .skillBody(id: id, text: text, timestamp: ts), badgeUsage: badge))
            } else {
                out.append(.init(id: id, kind: .systemReminder(id: id, kind: kind, text: text, timestamp: ts), badgeUsage: badge))
            }

        case .toolCall(let id, let name, let inputJSON, let inputTruncatedTo, let result, let subagent, let ts, _):
            out.append(.init(
                id: id,
                kind: .toolCall(id: id, name: name, inputJSON: inputJSON,
                                inputTruncatedTo: inputTruncatedTo, result: result, timestamp: ts),
                badgeUsage: badge
            ))
            if let subagent {
                let visibleCount = subagent.items.filter { !isHiddenInTranscript($0) }.count
                if visibleCount > 0 {
                    out.append(.init(
                        id: "\(id)#subagent",
                        kind: .subagentSummary(parentItemID: id, count: visibleCount, agentType: subagent.agentType),
                        badgeUsage: nil
                    ))
                }
            }

        case .thinking, .slashCommand:
            continue  // filtered above; kept here for switch exhaustiveness
        }
    }
    return out
}
```

`isHiddenInTranscript` already exists in `TranscriptItemsView.swift` — keep it there.

## View structure

### `TranscriptItemsView` (shrunk dramatically)

```swift
struct TranscriptItemsView: View {
    let items: [TranscriptItem]
    let terminalID: UUID?

    @State private var hoveredItemID: String? = nil

    var body: some View {
        let nodes = transcriptRenderNodes(from: items)
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(nodes) { node in
                TranscriptRow(node: node, terminalID: terminalID)
                    .environment(\.transcriptTextSelection, hoveredItemID == node.id)
                    .onHover { if $0 { hoveredItemID = node.id } }
            }
        }
        .padding(.vertical, 8)
    }
}
```

- `depth` parameter removed.
- Recursive depth=8 cap removed.
- The `VStack`-vs-`LazyVStack` structural pivot (Gemini's flag) removed — there's only one branch now.
- `let _ = { ... }` perf-transcript marker hoisted into a `.task(id: items)` modifier or kept on the parent. (Cosmetic; subagent will decide.)

### `TranscriptRow` (new concrete View struct)

```swift
/// One row of the transcript. Constant view-shape: always a VStack with a
/// content subview and an optional inlined ContextUsageBadge. Internal
/// switch on `node.kind` lives behind this struct's type boundary so the
/// parent ForEach's body is homogeneous.
struct TranscriptRow: View {
    let node: TranscriptRenderNode
    let terminalID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            content
            if let usage = node.badgeUsage {
                ContextUsageBadge(total: usage.contextTotal)
                    .padding(.leading, 12)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch node.kind {
        case .chatBubble(let item):
            ChatBubbleView(item: item)
        case .systemReminder(let id, let kind, let text, let ts):
            SystemReminderRow(id: id, kind: kind, text: text, timestamp: ts)
        case .skillBody(let id, let text, let ts):
            SkillBodyRow(id: id, text: text, timestamp: ts)
        case .toolCall(let id, let name, let inputJSON, let inputTruncatedTo, let result, let ts):
            toolCard(id: id, name: name, inputJSON: inputJSON,
                     inputTruncatedTo: inputTruncatedTo, result: result, timestamp: ts)
        case .subagentSummary(_, let count, let agentType):
            SubagentSummaryRow(count: count, agentType: agentType)
        }
    }

    @ViewBuilder
    private func toolCard(id: String, name: String, inputJSON: String,
                          inputTruncatedTo: Int?, result: ToolResult?, timestamp: Date?) -> some View {
        switch name {
        case "Read":              ReadCard(...)
        // ... unchanged tool dispatch ...
        default:                  GenericToolCard(...)
        }
    }
}
```

### `SubagentSummaryRow` (replaces `SubagentDisclosure`)

```swift
/// Non-interactive single-row summary of a subagent's activity. Replaces
/// the prior expandable SubagentDisclosure. A future pop-out viewer
/// (descoped from #129) will let users inspect subagent activity in
/// detail without inlining a recursive transcript.
struct SubagentSummaryRow: View {
    let count: Int
    let agentType: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.2")
            if let agentType {
                Text("\(count) subagent \(count == 1 ? "activity" : "activities") · \(agentType)")
            } else {
                Text("\(count) subagent \(count == 1 ? "activity" : "activities")")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.leading, 32)
    }
}
```

## Files touched

| File | Change |
|---|---|
| `Sources/TBDApp/Panes/Transcript/TranscriptItemsView.swift` | Add `TranscriptRenderNode`, `transcriptRenderNodes(from:)`. Shrink `body`. Remove `depth`, `rowFor`, `toolCardFor`. |
| `Sources/TBDApp/Panes/Transcript/TranscriptRow.swift` | **NEW.** Concrete row View per spec above. |
| `Sources/TBDApp/Panes/Transcript/SubagentSummaryRow.swift` | **NEW.** Replaces `SubagentDisclosure`. |
| `Sources/TBDApp/Panes/Transcript/SubagentDisclosure.swift` | **DELETE.** |
| `Sources/TBDApp/Panes/LiveTranscriptPaneView.swift` | Drop `.onScrollGeometryChange` reading `geometry.contentSize.height`; replace at-bottom detection with sentinel `.onAppear`/`.onDisappear` on a footer view (see "At-bottom detection" below). |
| `Sources/TBDApp/Panes/HistoryPaneView.swift` | No structural change; verify it still compiles after `depth` removal. |
| `Sources/TBDApp/Diagnostics/TranscriptSignposts.swift` | **NEW.** `OSSignposter` regions (see "Signpost taxonomy" below). |

## At-bottom detection (replacing `.onScrollGeometryChange`)

Drop the `AtBottomGeometry` reader entirely. Replace with a 1pt-tall sentinel view at the end of the `LazyVStack` content:

```swift
// In TranscriptItemsView.body, after the ForEach:
Color.clear.frame(height: 1)
    .onAppear { atBottom = true }
    .onDisappear { atBottom = false }
```

(`atBottom` becomes an upward-flowing `@Binding` from `LiveTranscriptPaneView`, or stays in `LiveTranscriptPaneView` via a `PreferenceKey` if a binding is awkward — implementation detail.)

This trades absolute precision (50pt threshold) for laziness preservation. Acceptable for jump-to-bottom button visibility.

## Signpost taxonomy

`Sources/TBDApp/Diagnostics/TranscriptSignposts.swift`:

```swift
import os.signpost
@MainActor enum TranscriptSignposts {
    static let signposter = OSSignposter(subsystem: "com.tbd.app", category: "perf-transcript")
}
```

Wrap these regions:

| Region name | Where | What it measures |
|---|---|---|
| `transcript.swap` | `LiveTranscriptPaneView.pollOnce` mainActor block, around the array-replace. | Time to swap `sessionTranscripts[sid]` and propagate to SwiftUI. |
| `transcript.nodes.build` | `TranscriptItemsView.body`, around `transcriptRenderNodes(from:)`. | Render-node build cost per body re-eval. |
| `transcript.row.body` | `TranscriptRow.body` getter. | Per-row body cost. |
| `transcript.markdown.segment` | `MarkdownSegments.split` invocation in `ChatBubbleView`. | Markdown-parsing cost per bubble. |
| `transcript.scrollTo` | `proxy.scrollTo` calls in `LiveTranscriptPaneView`. | Frequency + duration of explicit scroll commands. |

These are debug-build-only via `#if DEBUG` if they cost anything; OSSignposter is generally cheap, but the markdown one fires per visible bubble and we want zero overhead in Release.

## Success criteria

After the change, capturing a fresh Instruments Time Profiler trace under the same workload (a long session, scroll + new-message arrivals) should show:

1. **`_ViewList_Group.estimatedCount` recursion gone or collapsed** to ≤2 frames deep (vs ≥40 today). Primary success criterion.
2. **`LazyStack.measureEstimates` per-transaction cost reduced by ≥50%.** Secondary.
3. **No new top-1 hot frame** to compensate (e.g., we don't accidentally shift cost into `Markdown` rendering).
4. **`HangWatchdog` log shows zero >1000ms hangs** during a scripted scroll-through of the same session that previously produced the 12:18 hang.
5. **Visual parity:** all row types render identically except subagent-disclosure (which is now a single static summary row).

If criterion 1 doesn't hold, the flattening theory is wrong → fall back to the List migration with the captured trace as evidence.

## Implementation phasing (commits)

Each row = one commit. Ship in this order so each is independently verifiable.

1. **Add `TranscriptSignposts` + signpost regions.** Pure instrumentation, no behavior change. Captures baseline before the structural fix.
2. **Drop `.onScrollGeometryChange` + footer sentinel for at-bottom.** Gemini's single-variable test. If this alone fixes the hang (unlikely but cheap), great — measure and decide whether to continue.
3. **Add `TranscriptRenderNode` model + `transcriptRenderNodes(from:)`. Add `TranscriptRow` + `SubagentSummaryRow`.** New types only; not yet wired into `TranscriptItemsView`. Compiles, ships, does nothing.
4. **Rewire `TranscriptItemsView.body` to use `LazyVStack { ForEach(nodes) { TranscriptRow(...) } }`. Delete `SubagentDisclosure`, `rowFor`, `toolCardFor`, `depth`.** The actual fix. After this commit, capture a fresh trace.
5. **(Optional follow-up commit) Make `TranscriptRenderNode` and `TranscriptRow` Equatable; apply `.equatable()`.** Only if criterion 1 held in step 4.

Commit-message convention: conventional prefixes (`feat:` / `fix:` / `refactor:` / `perf:`).

## Risks

- **Visual parity for subagent rows.** Users with active subagent disclosures may notice the change. Mitigate via release notes; the descoped pop-out viewer is the long-term answer.
- **Hover-latch identity change.** `hoveredItemID` is now `String` (node.id) not `TranscriptItem.ID`. They're the same string today; verify nothing breaks downstream.
- **Markdown table layout cost** (TableBounds in the new freeze log's stack) is *not* addressed by this fix. If criterion 3 fails because table layout becomes the new top hot frame, we revisit — Markdown table rendering options are: drop `MarkdownUI`'s table support, render tables as code blocks, or migrate to `Textual` (deferred).
- **Test coverage for `transcriptRenderNodes(from:)`.** Pure function, table-driven tests are trivial. Add tests for: hidden item filtering, badge attachment, subagent summary emission, ordering preservation.

## Verification plan

After step 4 (the main fix commit):

1. `swift build` clean.
2. `swift test` clean.
3. `scripts/restart.sh` (full restart, not `--app`).
4. Open a known-laggy session in the live transcript pane. Scroll up to the top, back down. Send a new message; observe streaming.
5. Capture Instruments trace for ~10s of scroll. Compare `_ViewList_Group.estimatedCount` frame count and `LazyStack.measureEstimates` duration to baseline (step 1 trace).
6. `log show --last 5m --predicate 'subsystem == "com.tbd.app" AND category == "hang-watchdog"' --info --style compact` — should show zero `hang detected` lines.
7. Capture before/after numbers in a brief comment on issue #129.

## Coordination

Implementation work is split into commits per "Implementation phasing." Delegate each commit to a subagent. Main session reviews diffs and coordinates measurement after each commit.
