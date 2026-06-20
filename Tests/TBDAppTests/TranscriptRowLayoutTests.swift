import AppKit
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// Covers both branches of `TranscriptRow.rowBody` (issue #129 per-row
/// layout-depth flattening): a badge-less node returns `content` bare, while a
/// node carrying `badgeUsage` wraps `content` in a `VStack` above the inlined
/// `ContextUsageBadge`. Each branch is hosted in an `NSHostingView`, laid out,
/// and asserted to produce a positive fitting height — a smoke proof that both
/// `_ConditionalContent` legs build and lay out under AppKit.
@Suite("Transcript row layout")
@MainActor
struct TranscriptRowLayoutTests {
    @Test("badge-less row (content returned bare) builds and lays out")
    func badgeLessRowLaysOut() {
        let node = TranscriptRenderNode(
            id: "a",
            kind: .chatBubble(.assistantText(id: "a", text: "hello", timestamp: nil, usage: nil)),
            badgeUsage: nil
        )
        #expect(node.badgeUsage == nil)
        #expect(fittingHeight(for: node) > 0)
    }

    @Test("badge row (VStack-wrapped) builds and lays out")
    func badgeRowLaysOut() {
        let usage = TokenUsage(inputTokens: 1000, cacheCreationTokens: 2000, cacheReadTokens: 3000)
        let node = TranscriptRenderNode(
            id: "b",
            kind: .chatBubble(.assistantText(id: "b", text: "hello", timestamp: nil, usage: usage)),
            badgeUsage: usage
        )
        #expect(node.badgeUsage != nil)
        #expect(fittingHeight(for: node) > 0)
    }

    private func fittingHeight(for node: TranscriptRenderNode) -> CGFloat {
        let host = NSHostingView(rootView: TranscriptRow(node: node, terminalID: nil))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 200)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}
