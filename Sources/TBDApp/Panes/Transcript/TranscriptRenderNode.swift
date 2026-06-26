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

    /// Derived digest of `kind` + `badgeUsage`, computed once at construction.
    /// Folds the full payload into a single integer so `==` (called O(rows)
    /// times per view-graph pass during hover/reframe cascades — see issue
    /// #129) is an O(1) compare instead of a recursive walk over every
    /// associated value. Captures every payload mutation (e.g. a tool `result`
    /// going nil→populated under a stable id), so SwiftUI never skips a needed
    /// re-render. A 64-bit hash collision (≈2^-64) could theoretically
    /// coalesce two distinct payloads into one version and drop a single
    /// update; acceptable for UI diffing, and the next genuine change
    /// corrects it.
    let contentVersion: UInt64

    init(id: String, kind: Kind, badgeUsage: TokenUsage?) {
        self.id = id
        self.kind = kind
        self.badgeUsage = badgeUsage
        var hasher = Hasher()
        hasher.combine(kind)
        hasher.combine(badgeUsage)
        self.contentVersion = UInt64(bitPattern: Int64(hasher.finalize()))
    }

    /// O(1) equality: compares identity then a precomputed content version.
    /// The synthesized `==` previously did a full recursive walk over all
    /// associated values (`__derived_struct_equals` / `__derived_enum_equals`
    /// in the issue #129 freeze at 163 nodes). This replaces that walk with
    /// two integer compares per node.
    static func == (lhs: TranscriptRenderNode, rhs: TranscriptRenderNode) -> Bool {
        let state = TranscriptSignposts.signposter.beginInterval("transcript.equatable")
        defer { TranscriptSignposts.signposter.endInterval("transcript.equatable", state) }
        return lhs.id == rhs.id && lhs.contentVersion == rhs.contentVersion
    }

    enum Kind: Hashable {
        case chatBubble(TranscriptItem)
        case systemReminder(id: String, kind: SystemKind, text: String, timestamp: Date?)
        case skillBody(id: String, text: String, timestamp: Date?)
        case toolCall(id: String, name: String, inputJSON: String,
                      inputTruncatedTo: Int?, result: ToolResult?, timestamp: Date?)
        case subagentSummary(parentItemID: String, count: Int, agentType: String?)

        /// Hand-written structural `==` replaces the compiler-synthesized
        /// `__derived_enum_equals` that appeared high in the issue #129 freeze.
        /// Semantics are identical to synthesis but explicit. This is NOT on
        /// the hot path — `TranscriptRenderNode.==` uses `contentVersion` and
        /// never calls `Kind.==` during SwiftUI diffing. It exists for
        /// completeness and test coverage.
        static func == (lhs: Kind, rhs: Kind) -> Bool {
            switch (lhs, rhs) {
            case (.chatBubble(let l), .chatBubble(let r)):
                return l == r
            case (.systemReminder(let li, let lk, let lt, let lts),
                  .systemReminder(let ri, let rk, let rt, let rts)):
                return li == ri && lk == rk && lt == rt && lts == rts
            case (.skillBody(let li, let lt, let lts),
                  .skillBody(let ri, let rt, let rts)):
                return li == ri && lt == rt && lts == rts
            case (.toolCall(let li, let ln, let lj, let liu, let lr, let lts),
                  .toolCall(let ri, let rn, let rj, let riu, let rr, let rts)):
                return li == ri && ln == rn && lj == rj && liu == riu && lr == rr && lts == rts
            case (.subagentSummary(let lp, let lc, let la),
                  .subagentSummary(let rp, let rc, let ra)):
                return lp == rp && lc == rc && la == ra
            default:
                return false
            }
        }
        // hash(into:) is synthesized by the compiler — a custom == does not
        // suppress hash synthesis, only == synthesis. Confirmed: build succeeds
        // with only the custom == present.
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

        case .toolCall(let id, let name, let inputJSON, let inputTruncatedTo, let result, _, let ts, _):
            // Task/Agent tool calls render as ordinary tool cards. The subagent
            // timeline is intentionally NOT surfaced in the transcript, so no
            // `.subagentSummary` node is emitted and the `subagent` payload is
            // ignored.
            out.append(TranscriptRenderNode(
                id: id,
                kind: .toolCall(id: id, name: name, inputJSON: inputJSON,
                                inputTruncatedTo: inputTruncatedTo, result: result, timestamp: ts),
                badgeUsage: badge
            ))

        case .thinking, .slashCommand:
            // .thinking is filtered earlier by isHiddenInTranscript;
            // .slashCommand reaches here (TranscriptParser folds it into
            // .userPrompt in practice, so this branch is effectively dead).
            // Both are dropped from the render list.
            continue
        }
    }
    return out
}

/// Returns the id of the *last rendered* TranscriptRenderNode for these items
/// without materializing the full node array. Walks `items` from the end,
/// skipping hidden items. Each visible item maps to exactly one render node
/// sharing its id (`.toolCall` no longer emits a trailing subagent node).
///
/// Use this anywhere a scroll target previously read `items.last?.id`. With
/// the render-node flattening the trailing rendered row is no longer
/// guaranteed to share an id with the trailing TranscriptItem.
nonisolated func lastRenderedNodeID(for items: [TranscriptItem]) -> String? {
    for item in items.reversed() {
        if isHiddenInTranscript(item) { continue }
        switch item {
        case .toolCall(let id, _, _, _, _, _, _, _),
             .userPrompt(let id, _, _),
             .assistantText(let id, _, _, _),
             .systemReminder(let id, _, _, _):
            return id
        case .thinking, .slashCommand:
            continue
        }
    }
    return nil
}
