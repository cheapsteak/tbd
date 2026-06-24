import AppKit
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// Covers both branches of `TranscriptRow.rowBody` (issue #129 per-row
/// layout-depth flattening): a badge-less node returns `content` bare, while a
/// node carrying `badgeUsage` wraps `content` in a `VStack` above the inlined
/// `ContextUsageBadge`. Both legs are constructed and measured via
/// `NSHostingView` at the same width (560); the badge branch must reserve extra
/// vertical space, proving the badge is actually rendered AND that the two
/// `_ConditionalContent` legs differ (a dropped-badge regression would make
/// them equal).
@Suite("Transcript row layout")
@MainActor
struct TranscriptRowLayoutTests {
    @Test("badge branch reserves more height than badge-less branch")
    func badgeBranchIsTallerThanBadgeless() {
        // Badge-LESS leg: assistantText chat bubble, no usage badge.
        let badgelessNode = TranscriptRenderNode(
            id: "a",
            kind: .chatBubble(.assistantText(id: "a", text: "hello", timestamp: nil, usage: nil)),
            badgeUsage: nil
        )
        #expect(badgelessNode.badgeUsage == nil)

        // Badge-PRESENT leg: same kind, non-nil TokenUsage → VStack-wrapped
        // content above an inlined ContextUsageBadge.
        let usage = TokenUsage(inputTokens: 1000, cacheCreationTokens: 2000, cacheReadTokens: 3000)
        let badgeNode = TranscriptRenderNode(
            id: "b",
            kind: .chatBubble(.assistantText(id: "b", text: "hello", timestamp: nil, usage: usage)),
            badgeUsage: usage
        )
        #expect(badgeNode.badgeUsage != nil)

        let badgelessHeight = fittingHeight(for: badgelessNode)
        let badgeHeight = fittingHeight(for: badgeNode)

        // DEFENSIVE SKIP: NSHostingView.fittingSize collapses to 0 in a
        // non-rendering / headless environment (the same failure mode the
        // repo's TabBarHitAreaTests hits). Treat that as inconclusive rather
        // than a failure.
        guard badgelessHeight > 0 else { return }

        // The badge branch wraps `content` in a VStack with an extra inlined
        // ContextUsageBadge, so it must measure taller. Equal heights would
        // mean the badge was dropped (regression).
        #expect(
            badgeHeight > badgelessHeight,
            "badge branch (\(badgeHeight)) must reserve more vertical space than badge-less branch (\(badgelessHeight)); equal heights indicate a dropped badge"
        )
    }

    private func fittingHeight(for node: TranscriptRenderNode) -> CGFloat {
        let host = NSHostingView(rootView: TranscriptRow(node: node, terminalID: nil))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 200)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}
