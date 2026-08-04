import Foundation
import Testing
@testable import TBDApp

/// Locks in the role-dependent horizontal geometry of the table-based chat
/// bubble: assistant messages drop the 52pt opposite-side gutter and span the
/// full column, while user messages keep the gutter (right-anchored bubble).
@MainActor
struct TranscriptBubbleGeometryTests {
    private let columnWidth: CGFloat = 800

    @Test func assistantBodyWidthDropsGutter() {
        let g = TranscriptBubbleGeometry.self
        // 800 - 24 - 0 == 776 (assistant: no gutter, no body inset).
        let expected = columnWidth
            - g.outerHorizontal(for: .assistant, columnWidth: columnWidth)
            - g.bodyHorizontal(for: .assistant)
        #expect(g.bodyWidth(columnWidth: columnWidth, role: .assistant) == expected)
        #expect(g.bodyWidth(columnWidth: columnWidth, role: .assistant) == 776)
    }

    @Test func userBodyWidthKeepsGutter() {
        let g = TranscriptBubbleGeometry.self
        // 800 - 76 - 22 == 702 (user: gutter + 11pt-per-side bubble padding).
        let expected = columnWidth
            - g.outerHorizontal(for: .user, columnWidth: columnWidth)
            - g.bodyHorizontal(for: .user)
        #expect(g.bodyWidth(columnWidth: columnWidth, role: .user) == expected)
        #expect(g.bodyWidth(columnWidth: columnWidth, role: .user) == 702)
    }

    @Test func bodyHorizontalIsRoleDependent() {
        let g = TranscriptBubbleGeometry.self
        // Assistant content sits flush at the box edge (aligns with header + tool
        // rows); user keeps the visible 11pt-per-side chat-bubble padding.
        #expect(g.bodyHorizontal(for: .assistant) == 0)
        #expect(g.bodyHorizontal(for: .user) == 22)
    }

    @Test func assistantIsWiderThanUser() {
        let g = TranscriptBubbleGeometry.self
        let assistant = g.bodyWidth(columnWidth: columnWidth, role: .assistant)
        let user = g.bodyWidth(columnWidth: columnWidth, role: .user)
        // Assistant is wider by the 52pt gutter folded into the user's outer inset
        // (76 vs 24 == 52) PLUS the 22pt user bubble padding the assistant drops
        // (22 vs 0) == 74.
        #expect(assistant - user == 74)
    }

    @Test func outerHorizontalIsRoleDependent() {
        let g = TranscriptBubbleGeometry.self
        #expect(g.outerHorizontal(for: .assistant, columnWidth: columnWidth) == 24)
        #expect(g.outerHorizontal(for: .user, columnWidth: columnWidth) == 76)
    }

    @Test func narrowUserBubbleDropsOppositeSideGutter() {
        let g = TranscriptBubbleGeometry.self
        #expect(g.outerHorizontal(for: .user, columnWidth: 679) == 24)
        #expect(g.bodyWidth(columnWidth: 679, role: .user) == 633)
    }
}
