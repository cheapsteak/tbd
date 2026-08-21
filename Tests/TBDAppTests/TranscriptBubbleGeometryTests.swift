import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// Locks in the role-dependent horizontal geometry of the table-based chat
/// bubble: assistant messages drop the 52pt opposite-side gutter and span the
/// full column, while user messages keep the gutter (right-anchored bubble).
/// Also pins the VERTICAL chrome, which carries no role/timestamp header line.
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

    // MARK: - Vertical chrome carries no attribution header

    /// A bubble shows no "Claude · 5:33 PM" header — position and tint say who
    /// spoke — so the row's fixed chrome budgets NOTHING for a header line or a
    /// header→body gap. If either crept back into `rowHeight`, every row would
    /// reserve dead space above its prose and this goes red.
    @Test func rowHeightChromeBudgetsNoHeaderLine() {
        let g = TranscriptBubbleGeometry.self
        #expect(g.rowHeight(blocksHeight: 0) == g.bodyVertical + g.outerVertical * 2)
        #expect(g.rowHeight(blocksHeight: 100) == 132)
        // With no header between them, `outerVertical` is the ONLY separation
        // between adjacent bubbles — a 16pt gutter.
        #expect(g.outerVertical == 8)
        #expect(g.bodyVertical == 16)
    }

    /// The attribution string still exists, but only as spoken text: the native
    /// cell draws none of it, and carries it as the cell's accessibility label so
    /// VoiceOver users keep speaker identity.
    @Test func nativeBubbleCellDrawsNoHeaderButSpeaksTheAttribution() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let item = TranscriptItem.assistantText(id: "a", text: "hello", timestamp: date, usage: nil)
        let attribution = TranscriptBubbleGeometry.accessibilityAttribution(for: item)
        #expect(attribution.hasPrefix("Claude · "))

        let blocks = TranscriptBubbleGeometry.composedBlocks(
            for: item, badgeUsage: nil, linkResolver: nil)
        let bodyWidth = TranscriptBubbleGeometry.bodyWidth(columnWidth: columnWidth, role: .assistant)
        let measurer = MessageBlockMeasurer()
        let heights = measurer.blockHeights(blocks, bodyWidth: bodyWidth)
        let rowHeight = TranscriptBubbleGeometry.rowHeight(
            blocksHeight: measurer.blocksHeight(fromBlockHeights: heights))

        let cell = TranscriptBubbleCellView()
        cell.configure(
            blocks: blocks, blockHeights: heights, sourceText: "hello",
            role: .assistant, accessibilityAttribution: attribution,
            bodyWidth: bodyWidth, columnWidth: columnWidth, cachedHeight: rowHeight)
        cell.layoutSubtreeIfNeeded()

        // Spoken, not drawn.
        #expect(cell.accessibilityLabel() == attribution)
        let drawn = Self.drawnStrings(in: cell)
        #expect(drawn == ["hello"], "the bubble must draw its prose and nothing else, got \(drawn)")

        // …and no dead space is left where the header used to be: the realized
        // subtree is exactly the row height the table reserved.
        #expect(abs(cell.realizedRowHeight - rowHeight) <= 1.0,
                "realized=\(cell.realizedRowHeight) reserved=\(rowHeight)")
    }

    /// The SwiftUI bubble must not grow a header the native cell dropped (this
    /// repo's standing two-renderer trap). Both paths lay the same one-line
    /// message out, so their heights agree to well under one caption2 line — the
    /// header the two used to share was a caption2 line plus a 3pt gap, so its
    /// return on either side breaks this.
    @Test func swiftUIBubbleMatchesTheNativeHeaderlessHeight() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let item = TranscriptItem.assistantText(id: "a", text: "hello", timestamp: date, usage: nil)

        let controller = NSHostingController(rootView: ChatBubbleView(item: item))
        controller.sizingOptions = [.preferredContentSize]
        let swiftHeight = controller.sizeThatFits(
            in: NSSize(width: columnWidth, height: .greatestFiniteMagnitude)).height
        // DEFENSIVE SKIP: SwiftUI measurement collapses to 0 in a fully headless
        // environment (same posture as TranscriptRowLayoutTests).
        guard swiftHeight > 0 else { return }

        let blocks = TranscriptBubbleGeometry.composedBlocks(
            for: item, badgeUsage: nil, linkResolver: nil)
        let bodyWidth = TranscriptBubbleGeometry.bodyWidth(columnWidth: columnWidth, role: .assistant)
        let nativeHeight = TranscriptBubbleGeometry.rowHeight(
            blocksHeight: MessageBlockMeasurer().blocksHeight(blocks, bodyWidth: bodyWidth))

        let caption = NSFont.preferredFont(forTextStyle: .caption2)
        let captionLine = ceil(caption.ascender - caption.descender + caption.leading)
        #expect(abs(swiftHeight - nativeHeight) < captionLine,
                Comment(rawValue: "SwiftUI bubble (\(swiftHeight)) and native row (\(nativeHeight)) "
                    + "differ by at least a caption2 line (\(captionLine)) — one is drawing a header"))
    }

    /// Every string actually drawn by `view`'s subtree (label fields + prose text
    /// views), trimmed, in tree order.
    private static func drawnStrings(in view: NSView) -> [String] {
        var found: [String] = []
        func walk(_ v: NSView) {
            if let field = v as? NSTextField {
                found.append(field.stringValue)
            } else if let text = v as? NSTextView {
                found.append(text.string)
            }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
