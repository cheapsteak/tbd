import CoreGraphics
import Testing
@testable import TBDApp

// Tier 1: the pure geometry behind where a hover card's panel lands. No panel,
// no window, no screen — AppKit screen coordinates (y grows upward) in, a frame
// out.
@Suite("HoverCard placement")
struct HoverCardPlacementTests {

    /// A window floating in the middle of a tall screen: there is desktop both
    /// above and below it, so the *window* is what decides which side a card
    /// goes on. `visibleFrame` excludes the menu bar and the Dock, as AppKit's
    /// does.
    private let screen = CGRect(x: 0, y: 70, width: 1440, height: 830)
    private let window = CGRect(x: 100, y: 400, width: 1200, height: 400)
    private let inset = HoverCardView.shadowInset

    /// The visible card inside the panel — what the gap and the alignment are
    /// measured against, since the panel carries a transparent shadow margin.
    private func card(_ frame: CGRect) -> CGRect {
        frame.insetBy(dx: inset, dy: inset)
    }

    private func place(anchor: CGRect,
                       cardSize: CGSize = CGSize(width: 260, height: 120),
                       window: CGRect?,
                       screen: CGRect?) -> CGRect {
        HoverCardPlacement.panelFrame(
            anchor: anchor,
            panelSize: CGSize(width: cardSize.width + inset * 2,
                              height: cardSize.height + inset * 2),
            shadowInset: inset,
            window: window,
            screenVisibleFrame: screen
        )
    }

    // MARK: - Which side of the anchor

    @Test("an anchor with room beneath it inside the window keeps its card below, hugging it")
    func belowIsThePreferredSide() {
        // A tab-bar item: near the top of the window, plenty of window below it.
        let anchor = CGRect(x: 260, y: 770, width: 90, height: 28)
        let visible = card(place(anchor: anchor, window: window, screen: screen))
        #expect(visible.maxY == anchor.minY - HoverCardPlacement.anchorGap)
        #expect(visible.minX == anchor.minX)
        // A card hanging under its anchor should read as attached to it, so
        // this gap stays small — and much smaller than the one a flipped card
        // needs to escape the bar it was pushed off.
        #expect(HoverCardPlacement.anchorGap <= 8)
    }

    /// The status-bar chip: the card would fit on screen below it — there is a
    /// whole desktop down there — but it would leave the window and land on the
    /// strip it describes.
    @Test("an anchor at the bottom of its window flips above, even with screen room below")
    func windowBottomFlipsAboveDespiteScreenRoom() {
        let anchor = CGRect(x: 300, y: 414, width: 22, height: 14)
        let frame = place(anchor: anchor, window: window, screen: screen)
        let visible = card(frame)
        #expect(visible.minY == anchor.maxY + HoverCardPlacement.flippedBarClearance)
        // The whole card is above the anchor, so the bar it is anchored to —
        // the chip included — stays readable underneath it.
        #expect(visible.minY > anchor.maxY)
        // Below would have fitted the screen, which is exactly why the screen
        // cannot be the only test.
        let below = anchor.minY - HoverCardPlacement.anchorGap - visible.height
        #expect(below > screen.minY)
        #expect(below < window.minY)
        // The chip sits a dozen points off the bottom of the window, so no card
        // small enough to matter fits beneath it: the flip is a property of the
        // anchor, not of how tall this particular card happens to be.
        let short = card(place(anchor: anchor,
                               cardSize: CGSize(width: 200, height: 40),
                               window: window,
                               screen: screen))
        #expect(short.minY == anchor.maxY + HoverCardPlacement.flippedBarClearance)
    }

    /// The reader is looking at the *bar*, not at the chip. A chip is a 14pt
    /// row inside a strip that pads it, sits it beside taller controls and
    /// draws its own background, so the flip has to clear the strip's top edge
    /// with a gap wide enough to see — clearing the anchor by a hair leaves the
    /// card glued to the row it is describing.
    @Test("a flipped card clears the whole bar its anchor sits in, with room to spare")
    func flippedCardClearsTheWholeBar() {
        // Modelled generously: the strip's own 4pt padding plus the difference
        // between the chip and the tallest control sharing the row with it.
        let barTopAboveChip: CGFloat = 8
        // A band that is unmistakable rather than merely measurable — the whole
        // strip stays legible with window content visible above it.
        let breathingRoom: CGFloat = 16
        let anchor = CGRect(x: 300, y: 414, width: 22, height: 14)
        let barTop = anchor.maxY + barTopAboveChip
        let visible = card(place(anchor: anchor, window: window, screen: screen))
        #expect(visible.minY >= barTop + breathingRoom)
        // And the asymmetry is structural rather than a nudge: a flipped card
        // is escaping something, a card below its anchor is attached to it.
        #expect(HoverCardPlacement.flippedBarClearance >= HoverCardPlacement.anchorGap * 2)
    }

    @Test("a card with no room below on screen flips above")
    func screenBottomStillFlips() {
        // A window whose bottom edge sits on the screen's visible bottom.
        let bottomed = CGRect(x: 100, y: screen.minY, width: 1200, height: 700)
        let anchor = CGRect(x: 300, y: screen.minY + 14, width: 22, height: 14)
        let visible = card(place(anchor: anchor, window: bottomed, screen: screen))
        #expect(visible.minY == anchor.maxY + HoverCardPlacement.flippedBarClearance)
    }

    /// The window is a preference, not a hard constraint. A card anchored in a
    /// short floating panel fits inside it on neither side, and the screen — the
    /// rule that always applied — decides instead of the card being clamped over
    /// its own anchor.
    @Test("a window too short for either side falls back to the screen rule")
    func shortWindowFallsBackToTheScreen() {
        let panel = CGRect(x: 300, y: 500, width: 260, height: 60)
        let anchor = CGRect(x: 310, y: 515, width: 200, height: 20)
        let visible = card(place(anchor: anchor, window: panel, screen: screen))
        #expect(visible.maxY == anchor.minY - HoverCardPlacement.anchorGap)
        #expect(visible.minY > screen.minY)
    }

    @Test("with no window at all the screen rule stands on its own")
    func noWindowUsesTheScreenRule() {
        let anchor = CGRect(x: 300, y: 414, width: 22, height: 14)
        let visible = card(place(anchor: anchor, window: nil, screen: screen))
        #expect(visible.maxY == anchor.minY - HoverCardPlacement.anchorGap)
    }

    // MARK: - Staying on screen

    @Test("a card is clamped into the screen rather than running off its right edge")
    func clampsToTheRightEdge() {
        let anchor = CGRect(x: 1400, y: 600, width: 22, height: 14)
        let visible = card(place(anchor: anchor, window: window, screen: screen))
        #expect(visible.maxX == screen.maxX - HoverCardPlacement.screenMargin)
        #expect(visible.minX < anchor.minX)
    }

    @Test("a card is clamped into the screen rather than running off its left edge")
    func clampsToTheLeftEdge() {
        let anchor = CGRect(x: -20, y: 600, width: 22, height: 14)
        let visible = card(place(anchor: anchor, window: window, screen: screen))
        #expect(visible.minX == screen.minX + HoverCardPlacement.screenMargin)
    }

    @Test("a card taller than the screen is pinned to the top of it, not pushed under it")
    func clampsATooTallCard() {
        let anchor = CGRect(x: 300, y: 600, width: 22, height: 14)
        let visible = card(place(anchor: anchor,
                                 cardSize: CGSize(width: 260, height: 2000),
                                 window: window,
                                 screen: screen))
        #expect(visible.minY == screen.minY + HoverCardPlacement.screenMargin)
    }

    // MARK: - The shadow margin

    /// The panel is bigger than the card by the transparent margin the card's
    /// own shadow draws into. Every measurement above is against the card; the
    /// panel is offset out from it by exactly one inset on each side, so the
    /// shadow costs the card no position.
    @Test("the panel wraps the card by one shadow inset on every side")
    func panelWrapsTheCard() {
        let anchor = CGRect(x: 260, y: 770, width: 90, height: 28)
        let frame = place(anchor: anchor, window: window, screen: screen)
        #expect(frame.width == 260 + inset * 2)
        #expect(frame.height == 120 + inset * 2)
        #expect(frame.minX == anchor.minX - inset)
        #expect(frame.maxY == anchor.minY - HoverCardPlacement.anchorGap + inset)
        #expect(inset > 0)
    }
}
