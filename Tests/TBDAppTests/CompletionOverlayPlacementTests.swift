import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// **Where the completion list lands.** The one thing about the menu that no
/// pure function can state: it is an alignment guide on an overlay, and the
/// difference between opening upward and opening downward over the text field
/// is one edge name.
///
/// So this suite mounts the real `MessageComposerView` in a real window through
/// `ComposerHarness`, opens the menu, and measures the two frames in window
/// coordinates. The first shipped guide anchored the overlay's top to the
/// composer's bottom — a list that covered the words being typed and ran off the
/// bottom of the pane — and every assertion here fails against it.
@MainActor
@Suite("completion overlay placement")
struct CompletionOverlayPlacementTests {

    /// Mount a composer whose draft is `/comp`, and wait for its list to reach
    /// full height.
    ///
    /// The wait is bounded by a pump count, so a list that never arrives fails
    /// with the tree it gave up on rather than hanging — `openMenu(typing:)`
    /// returns whether it settled and `diagnostics()` says what was there.
    private func openMenu(
        backdrop: ComposerHarness.Backdrop = .empty
    ) async throws -> (ComposerHarness, NSVisualEffectView, ComposerTextView) {
        let harness = try ComposerHarness(
            name: "CompletionOverlayPlacementTests", backdrop: backdrop)
        let settled = await harness.openMenu(typing: "/comp")
        try #require(settled, .init(rawValue: """
            the completion list never reached its full height. \(harness.diagnostics())
            """))
        let overlay = try #require(harness.completionList)
        let field = try #require(harness.textView)
        try #require(field.string == "/comp", "the draft never reached the text view")
        return (harness, overlay, field)
    }

    // MARK: - Placement

    /// **The bug.** The list must sit entirely above the text field: its bottom
    /// edge at or above the field's top edge, so not one pixel of what is being
    /// typed is covered.
    @Test func theListOpensAboveTheTextField() async throws {
        let (harness, overlay, field) = try await openMenu()
        defer { harness.tearDown() }

        let listFrame = harness.host.flippedWindowFrame(overlay)
        let fieldFrame = harness.host.flippedWindowFrame(field)

        #expect(
            listFrame.maxY <= fieldFrame.minY,
            """
            the list runs to y=\(listFrame.maxY) and the field starts at \
            y=\(fieldFrame.minY) — it is covering the text being typed
            """)
    }

    /// The other half of opening downward: a list anchored below the composer
    /// runs off the bottom of the pane and shows fewer rows than it has. Growing
    /// upward, all eight fit inside the window.
    @Test func theWholeListFitsInsideTheWindow() async throws {
        let (harness, overlay, _) = try await openMenu()
        defer { harness.tearDown() }

        let listFrame = harness.host.flippedWindowFrame(overlay)
        let content = try #require(harness.host.window.contentView).bounds

        #expect(listFrame.minY >= 0, "the list is clipped at the top of the pane")
        #expect(listFrame.maxY <= content.height, "the list is clipped at the bottom")
        #expect(
            listFrame.height == CompletionOverlayView.maxHeight,
            "eight rows and no more: \(listFrame.height)")
        #expect(listFrame.width == CompletionOverlayView.width)
    }

    // MARK: - The height itself

    /// The arithmetic behind the frame, without a window: as many rows as there
    /// are, up to eight, and never zero — a list showing its one-line "loading"
    /// or "no commands match" message still needs a row's worth of box.
    @Test func theListIsAsTallAsItsRowsUpToEight() {
        #expect(CompletionOverlayView.listHeight(rowCount: 3)
            == CompletionOverlayView.rowHeight * 3)
        #expect(CompletionOverlayView.listHeight(rowCount: 8)
            == CompletionOverlayView.maxHeight)
        #expect(CompletionOverlayView.listHeight(rowCount: 40)
            == CompletionOverlayView.maxHeight)
        #expect(CompletionOverlayView.listHeight(rowCount: 0)
            == CompletionOverlayView.rowHeight)
    }

    // MARK: - Paint order

    /// **The list paints over the AppKit view beside it.** The other tests in
    /// this suite measure frames, and a frame is the same whether the list paints
    /// over its neighbour or under it. This one renders instead: a real
    /// `NSViewRepresentable` sibling — the shape of `TableTranscriptView` — fills
    /// the region the list grows into with solid red, the menu is opened the same
    /// way, and the list's own interior is read back out of a bitmap. Painting
    /// under the AppKit view would leave that interior red.
    ///
    /// The control pixel beside the list is asserted red FIRST, so a capture in
    /// which nothing painted at all fails as the harness problem it is rather
    /// than passing as a clean list.
    ///
    /// **What it does not prove.** It is a guard on the outcome, not a test that
    /// discriminates the pane's `.zIndex(1)`: with that modifier removed, this
    /// capture comes back pixel-for-pixel identical (interior 0.94 grey, the
    /// selected row's accent tint at the top, 0% of it the sibling's red). In an
    /// offscreen `cacheDisplay` of an `NSHostingView`, SwiftUI already orders the
    /// composer's overlay above a representable sibling declared before it, so
    /// the stacking the modifier states is not the stacking this route exercises.
    /// The modifier stays because the live pane's sibling is a layer-backed
    /// scrolling table rather than a solid-color `NSView`, and stating the order
    /// is cheaper than depending on declaration order there; the test stays
    /// because it fails loudly if the list ever stops painting over its
    /// neighbour at all. `OffscreenHost`'s own doc comment records the same
    /// limitation for every future caller.
    @Test func theListPaintsOverTheAppKitViewBesideIt() async throws {
        let (harness, overlay, _) = try await openMenu(
            backdrop: .custom(AnyView(SolidRedRepresentable())))
        defer { harness.tearDown() }
        // A few more turns of both pumps so the sibling has been asked to draw.
        await harness.host.pump(times: Self.extraDrawPumps)

        let shot = try harness.host.capture()
        let list = shot.pixelFrame(of: overlay)

        // The control sits BESIDE the list, at the same height: the list is 460pt
        // of a 720pt-wide pane, so everything to its right is untouched sibling,
        // clear of the list's own shadow.
        let controlX = Int(min(
            list.maxX + Self.controlProbeInset * shot.scale,
            CGFloat(shot.rep.pixelsWide - 1)))
        let controlY = Int(list.midY)
        let control = try #require(shot.color(x: controlX, y: controlY))
        guard Self.isRed(control) else {
            Issue.record("""
                the AppKit sibling never painted, so this capture proves nothing: \
                the control pixel at (\(controlX), \(controlY)), beside the list at \
                \(list), is \(Self.describe(control))
                """)
            return
        }

        // Inset past the rounded corners and the hairline stroke; the shadow
        // falls outside the frame already.
        let interior = list.insetBy(
            dx: Self.interiorInset * shot.scale, dy: Self.interiorInset * shot.scale)
        let redFraction = shot.fraction(in: interior, matching: control)
        #expect(
            redFraction < Self.maximumRedFraction,
            """
            the completion list is painting UNDER the AppKit view beside it: \
            \(Int(redFraction * 100))% of its interior \(interior) came back the \
            sibling's \(Self.describe(control))
            """)
    }

    /// Pumps spent after the list has settled, purely so the sibling has been
    /// asked to draw before the bitmap is taken.
    private static let extraDrawPumps = 6
    /// How far to the right of the list the control pixel is read, in points.
    private static let controlProbeInset: CGFloat = 40
    /// How far inside the list's frame the interior sample starts, in points —
    /// past the rounded corners and the hairline stroke.
    private static let interiorInset: CGFloat = 10
    /// The share of the list's interior that may come back the sibling's colour
    /// before the list counts as painting under it.
    private static let maximumRedFraction = 0.05

    /// Unmistakably the sibling's red rather than an empty capture: a strong red
    /// channel dominating both of the others.
    private static func isRed(_ color: NSColor) -> Bool {
        color.redComponent > 0.7
            && color.redComponent > color.greenComponent * 2
            && color.redComponent > color.blueComponent * 2
    }

    private static func describe(_ color: NSColor) -> String {
        String(
            format: "rgba(%.2f, %.2f, %.2f, %.2f)",
            color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent)
    }
}

/// Fills itself with the one color nothing else in the mounted hierarchy paints.
/// Layer-backed *and* drawing in `draw(_:)`, so it is opaque whichever of the two
/// routes the capture takes.
private final class SolidRedView: NSView {
    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
        dirtyRect.fill()
    }
}

/// A real `NSViewRepresentable` sibling for the composer, the shape of its
/// actual neighbour `TableTranscriptView`. Ordering a SwiftUI overlay against a
/// HOSTED AppKit view is precisely what the pane's `.zIndex(1)` states, and a
/// SwiftUI-only sibling cannot pose that question: SwiftUI orders its own layers
/// among themselves either way.
private struct SolidRedRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> SolidRedView { SolidRedView() }
    func updateNSView(_ nsView: SolidRedView, context: Context) {}
}
