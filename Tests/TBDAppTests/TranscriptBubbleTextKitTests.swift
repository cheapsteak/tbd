import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The chat bubble's prose text views must be TextKit 1.
///
/// Two things rest on it. The row height comes from `TranscriptBubbleMeasurer`,
/// a TextKit 1 `NSLayoutManager` stack, so a TextKit 2 text view breaks the
/// measure == render invariant. And TextKit 2's `NSTextView.mouseDown(with:)`
/// tracking path was recorded spinning on the main thread for minutes after a
/// click on an inline-code link in a bubble, never dequeuing the mouse-up.
///
/// The cell is built through its production `configure`, from the same blocks and
/// heights `TableTranscriptView` would hand it. `textLayoutManager` is read BEFORE
/// anything touches `layoutManager`, because touching `layoutManager` on a
/// TextKit 2 view makes AppKit downgrade it and would hide the defect.
@Suite("Transcript bubble TextKit")
@MainActor
struct TranscriptBubbleTextKitTests {
    private let columnWidth: CGFloat = 800

    /// Inline code naming a path the resolver knows, so the prose carries a
    /// `tbd-file:` link like the one whose click hung the app; a fenced block, so
    /// the async highlight path runs; and enough text to wrap at 800pt.
    private let text = """
        The queue decisions are written up in `.context/deploy-queue-decisions.md`, \
        and the rollout notes beside them cover each environment in turn, starting \
        with `acme-prod` and ending with the staging mirror that nobody reads.

        ```swift
        let answer = 42
        ```

        That is everything.
        """

    private let resolver: TranscriptPathResolver = {
        $0 == ".context/deploy-queue-decisions.md" ? "/w/.context/deploy-queue-decisions.md" : nil
    }

    private struct Built {
        let cell: TranscriptBubbleCellView
        let blocks: [MessageBlock]
        let heights: [CGFloat]
    }

    private func build(_ item: TranscriptItem) -> Built {
        let role = TranscriptBubbleGeometry.role(for: item)
        let blocks = TranscriptBubbleGeometry.composedBlocks(
            for: item, badgeUsage: nil, linkResolver: resolver)
        let bodyWidth = TranscriptBubbleGeometry.bodyWidth(columnWidth: columnWidth, role: role)
        let measurer = MessageBlockMeasurer()
        let heights = measurer.blockHeights(blocks, bodyWidth: bodyWidth)
        let rowHeight = TranscriptBubbleGeometry.rowHeight(
            blocksHeight: measurer.blocksHeight(fromBlockHeights: heights), role: role)
        let cell = TranscriptBubbleCellView()
        cell.configure(
            blocks: blocks,
            blockHeights: heights,
            sourceText: TranscriptBubbleGeometry.text(for: item),
            role: role,
            peerHeader: nil,
            accessibilityAttribution: TranscriptBubbleGeometry.accessibilityAttribution(for: item),
            bodyWidth: bodyWidth,
            columnWidth: columnWidth,
            cachedHeight: rowHeight,
            onLinkClicked: { _ in },
            onShowDelivered: nil)
        cell.layoutSubtreeIfNeeded()
        return Built(cell: cell, blocks: blocks, heights: heights)
    }

    private static func proseViews(in view: NSView) -> [TranscriptBubbleTextView] {
        var found: [TranscriptBubbleTextView] = []
        func walk(_ v: NSView) {
            if let text = v as? TranscriptBubbleTextView { found.append(text) }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return found
    }

    private func items() -> [TranscriptItem] {
        [
            .assistantText(id: "a1", text: text, timestamp: nil, usage: nil),
            .userPrompt(id: "u1", text: text, timestamp: nil)
        ]
    }

    /// The fixture's premise: the prose really carries a link, so the view under
    /// test is the kind that was clicked.
    @Test("the fixture's prose carries a file link")
    func fixtureCarriesALink() {
        let blocks = TranscriptBubbleGeometry.composedBlocks(
            for: items()[0], badgeUsage: nil, linkResolver: resolver)
        var linked = false
        for case .prose(let string) in blocks {
            string.enumerateAttribute(
                .link, in: NSRange(location: 0, length: string.length), options: []
            ) { value, _, stop in
                if value != nil { linked = true; stop.pointee = true }
            }
        }
        #expect(linked)
    }

    @Test("every prose text view in a configured bubble is TextKit 1")
    func proseViewsAreTextKit1() {
        for item in items() {
            let built = build(item)
            let views = Self.proseViews(in: built.cell)
            #expect(!views.isEmpty, "a bubble with prose must realize a prose text view")
            for view in views {
                // Read first: touching `layoutManager` would downgrade a TK2 view.
                #expect(view.textLayoutManager == nil,
                        "bubble prose must not be built on TextKit 2")
                #expect(view.layoutManager != nil)
            }
        }
    }

    /// Measure == render at the text level: the measurer's height for each prose
    /// block equals the used height of the text view that draws it.
    @Test("each prose block's measured height equals its text view's used height")
    func measuredHeightMatchesRenderedUsedHeight() {
        for item in items() {
            let built = build(item)
            let views = Self.proseViews(in: built.cell)
            let proseHeights: [CGFloat] = zip(built.blocks, built.heights).compactMap { block, height in
                if case .prose = block { return height }
                return nil
            }
            #expect(views.count == proseHeights.count)
            for (view, measured) in zip(views, proseHeights) {
                guard view.textLayoutManager == nil,
                      let layoutManager = view.layoutManager,
                      let container = view.textContainer else {
                    Issue.record("prose text view is not TextKit 1")
                    continue
                }
                layoutManager.ensureLayout(for: container)
                let rendered = ceil(layoutManager.usedRect(for: container).height)
                #expect(abs(rendered - measured) <= 0.5,
                        "measured \(measured) vs rendered \(rendered)")
            }
        }
    }
}
