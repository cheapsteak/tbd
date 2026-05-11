import Foundation
import TBDShared

/// Pre-computed, denormalized render-list entries for the transcript pane.
/// Built once outside `body` from `[TranscriptItem]`; consumed by
/// `TranscriptItemsView`'s `ForEach`. Constant view-shape per node — every
/// node renders as a single `TranscriptRow` view — so the outer
/// `LazyVStack`'s `ForEach` body becomes homogeneous, satisfying SwiftUI's
/// documented constant-view-count rule and eliminating the
/// `_ViewList_Group.estimatedCount` recursion driving issue #129.
/// Hidden items are filtered upstream by `transcriptRenderNodes(from:)`,
/// `ContextUsageBadge` is inlined as a node field rather than a sibling
/// list entry, and subagent disclosure collapses into a single summary kind.
struct TranscriptRenderNode: Identifiable, Equatable {
    /// Stable across polls. Derived from the underlying `TranscriptItem.id`;
    /// the `subagentSummary` kind uses the parent toolCall's id with a
    /// `#subagent` suffix.
    let id: String

    /// The visible content classification.
    let kind: Kind

    /// Inlined `ContextUsageBadge`. When non-nil, the owning row renders the
    /// badge below its primary content. Inlined (not a sibling node) so that
    /// the `ForEach` body's per-element view count stays constant at 1.
    let badgeUsage: TokenUsage?

    enum Kind: Equatable {
        case chatBubble(TranscriptItem)
        case systemReminder(id: String, kind: SystemKind, text: String, timestamp: Date?)
        case skillBody(id: String, text: String, timestamp: Date?)
        case toolCall(id: String, name: String, inputJSON: String,
                      inputTruncatedTo: Int?, result: ToolResult?, timestamp: Date?)
        case subagentSummary(parentItemID: String, count: Int, agentType: String?)
    }
}

/// Pure, deterministic, side-effect-free builder. Walks `items` once,
/// dropping hidden entries, attaching `badgeUsage` to the most-recent
/// visible usage-carrying item, and emitting a `subagentSummary` node
/// after any toolCall that has a non-empty subagent timeline. Safe to call
/// off the main actor.
nonisolated func transcriptRenderNodes(from items: [TranscriptItem]) -> [TranscriptRenderNode] {
    // 1. Find the most-recent visible item carrying a TokenUsage, for badge
    //    attachment. Hidden items (`.thinking`, `.slashCommand`, hidden tool
    //    names) are excluded so the badge never floats below an EmptyView.
    let latestUsageItemID: String? = items.reversed().first {
        $0.usage != nil && !isHiddenInTranscript($0)
    }?.id

    // 2. Build nodes, skipping hidden items, inlining badge, emitting
    //    subagent summaries.
    var out: [TranscriptRenderNode] = []
    out.reserveCapacity(items.count)
    for item in items {
        if isHiddenInTranscript(item) { continue }

        let badge: TokenUsage? = (item.id == latestUsageItemID) ? item.usage : nil

        switch item {
        case .userPrompt, .assistantText:
            out.append(TranscriptRenderNode(id: item.id, kind: .chatBubble(item), badgeUsage: badge))

        case .systemReminder(let id, let kind, let text, let ts):
            if kind == .skillBody {
                out.append(TranscriptRenderNode(
                    id: id,
                    kind: .skillBody(id: id, text: text, timestamp: ts),
                    badgeUsage: badge
                ))
            } else {
                out.append(TranscriptRenderNode(
                    id: id,
                    kind: .systemReminder(id: id, kind: kind, text: text, timestamp: ts),
                    badgeUsage: badge
                ))
            }

        case .toolCall(let id, let name, let inputJSON, let inputTruncatedTo, let result, let subagent, let ts, _):
            out.append(TranscriptRenderNode(
                id: id,
                kind: .toolCall(id: id, name: name, inputJSON: inputJSON,
                                inputTruncatedTo: inputTruncatedTo, result: result, timestamp: ts),
                badgeUsage: badge
            ))
            if let subagent {
                let visibleCount = subagent.items.filter { !isHiddenInTranscript($0) }.count
                if visibleCount > 0 {
                    out.append(TranscriptRenderNode(
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
