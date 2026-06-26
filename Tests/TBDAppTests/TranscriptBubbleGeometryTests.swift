import Foundation
import Testing
@testable import TBDApp

/// Locks in the role-dependent horizontal geometry of the table-based chat
/// bubble: assistant messages drop the 52pt opposite-side gutter and span the
/// full column, while user messages keep the gutter (right-anchored bubble).
@MainActor
struct TranscriptBubbleGeometryTests {
    private let columnWidth: CGFloat = 600

    @Test func assistantBodyWidthDropsGutter() {
        let g = TranscriptBubbleGeometry.self
        let expected = columnWidth - g.outerHorizontal(for: .assistant) - g.bodyHorizontal
        #expect(g.bodyWidth(columnWidth: columnWidth, role: .assistant) == expected)
    }

    @Test func userBodyWidthKeepsGutter() {
        let g = TranscriptBubbleGeometry.self
        let expected = columnWidth - g.outerHorizontal(for: .user) - g.bodyHorizontal
        #expect(g.bodyWidth(columnWidth: columnWidth, role: .user) == expected)
    }

    @Test func assistantIsWiderThanUserByTheRemovedGutter() {
        let g = TranscriptBubbleGeometry.self
        let assistant = g.bodyWidth(columnWidth: columnWidth, role: .assistant)
        let user = g.bodyWidth(columnWidth: columnWidth, role: .user)
        // The only difference between the two is the 52pt gutter folded into the
        // user bubble's outer inset (76 vs 24 == 52).
        #expect(assistant - user == 52)
    }

    @Test func outerHorizontalIsRoleDependent() {
        let g = TranscriptBubbleGeometry.self
        #expect(g.outerHorizontal(for: .assistant) == 24)
        #expect(g.outerHorizontal(for: .user) == 76)
    }
}
