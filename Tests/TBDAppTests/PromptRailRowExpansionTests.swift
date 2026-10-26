import AppKit
import SwiftUI
import Testing
@testable import TBDApp
import TestSupport

// Tier 1 apart from the offscreen window the card is mounted in, which gives
// pointer events and hit-testing real window coordinates. The pointer is fed
// to the card by hand; the expansion's delay runs on `EventDrivenTestClock`.

/// A prompt rail card row's expansion: the 150ms rest before it shows, the
/// rows that never expand, what it shows, where it goes, that it takes no
/// events, and that it hides at once when the pointer changes rows or the list
/// scrolls. Every card takes the shipped delay, so the suite pins it.
@MainActor
@Suite("Prompt rail row expansion", .clockDriven)
struct PromptRailRowExpansionTests {
    /// The delay is a main-actor task, so it arms only once it has had a turn
    /// on the main actor; see the `timeout` note on
    /// `EventDrivenTestClock.sleeperArmed`.
    private static let mainActorHop = TestDeadlines.saturatedPass
    private static let delay = Duration.milliseconds(150)

    /// Far more than six lines at the card's 282pt text width, on one line.
    private static let longPrompt = String(repeating: "the rail and its card line up ", count: 20)
    /// Fits its row, and has a second line.
    private static let twoLinePrompt = "fix it\nthen ship"

    // MARK: Placement

    @Test("an expansion grows down when it fits below, up when it fits only above, and shows what fits in a short card")
    func placementGrowsDownThenUpThenClamps() {
        let visible = NSRect(x: 0, y: 0, width: 300, height: 600)
        let top = PromptRailCardMetrics.rowRect(0, width: 300)
        // 22 + 6 × 16 = 118pt below the row's top, of 594.
        #expect(PromptRailCardMetrics.expansionPlacement(row: top, visible: visible, wantedLines: 6, lineHeight: 16)
                    == PromptRailExpansionPlacement(lines: 6, growsUpward: false))

        // 40pt below the row's top, 522 above its bottom.
        let low = NSRect(x: 0, y: 500, width: 300, height: 22)
        let card = NSRect(x: 0, y: 0, width: 300, height: 540)
        #expect(PromptRailCardMetrics.expansionPlacement(row: low, visible: card, wantedLines: 6, lineHeight: 16)
                    == PromptRailExpansionPlacement(lines: 6, growsUpward: true))

        // A 100pt card: 72pt below the row's top, 50 above its bottom. Three
        // lines fit below: 22 + 3 × 16 = 70.
        let short = NSRect(x: 0, y: 0, width: 300, height: 100)
        let second = NSRect(x: 0, y: 28, width: 300, height: 22)
        #expect(PromptRailCardMetrics.expansionPlacement(row: second, visible: short, wantedLines: 6, lineHeight: 16)
                    == PromptRailExpansionPlacement(lines: 3, growsUpward: false))
        // With more room above, it grows up instead.
        let third = NSRect(x: 0, y: 50, width: 300, height: 22)
        #expect(PromptRailCardMetrics.expansionPlacement(row: third, visible: short, wantedLines: 6, lineHeight: 16)
                    == PromptRailExpansionPlacement(lines: 3, growsUpward: true))

        // A one-row card has no room for a line beside the tool-call line.
        let oneRow = NSRect(x: 0, y: 0, width: 300, height: 34)
        #expect(PromptRailCardMetrics.expansionPlacement(row: top, visible: oneRow, wantedLines: 6, lineHeight: 16) == nil)
        #expect(PromptRailCardMetrics.expansionPlacement(row: top, visible: visible, wantedLines: 0, lineHeight: 16) == nil)
        // Fewer lines than six are all shown when they fit.
        #expect(PromptRailCardMetrics.expansionPlacement(row: top, visible: visible, wantedLines: 2, lineHeight: 16)
                    == PromptRailExpansionPlacement(lines: 2, growsUpward: false))
    }

    // MARK: Which rows expand

    @Test("a row shows part of its prompt when its first line is cut off or the prompt runs past it")
    func rowsThatShowPartOfTheirPrompt() {
        let scene = Self.scene([Self.entry(0, "fix it"), Self.entry(1, Self.longPrompt), Self.entry(2, Self.twoLinePrompt)])
        defer { scene.host.tearDown() }

        #expect(scene.card.showsPartOfPrompt(entry: 0) == false, "a short one-line prompt shows whole")
        #expect(scene.card.showsPartOfPrompt(entry: 1) == true, "a first line cut off at the row's width")
        #expect(scene.card.showsPartOfPrompt(entry: 2) == true, "a prompt running past a first line that fits")
        #expect(scene.card.showsPartOfPrompt(entry: 3) == nil)
    }

    @Test("a row expands 150ms after the pointer comes to rest on it, and not before")
    func expandsAfterTheDelay() async throws {
        let scene = Self.scene((0..<10).map { Self.entry($0, Self.longPrompt) })
        defer { scene.host.tearDown() }

        try scene.movePointer(toRow: 0)
        try await scene.clock.requireAdvanceWhenArmed(by: .milliseconds(149), timeout: Self.mainActorHop)
        #expect(scene.clock.hasSleeper, "the delay ended before 150ms")
        #expect(scene.card.expandedRow == nil, "the row expanded before 150ms")

        await scene.clock.advance(by: .milliseconds(1))
        try #require(!scene.clock.hasSleeper, "the delay outlasted 150ms")
        await scene.card._drainRowDwellForTesting()
        #expect(scene.card.expandedRow == 0)
        #expect(!scene.card.expansionView.isHidden)
    }

    @Test("a row that shows its whole prompt never expands")
    func wholeRowNeverExpands() async throws {
        let scene = Self.scene([Self.entry(0, "fix it"), Self.entry(1, Self.longPrompt)])
        defer { scene.host.tearDown() }

        try scene.movePointer(toRow: 0)
        #expect(await watchForSleeper(on: scene.clock) == false, "a row showing its whole prompt armed the delay")
        await scene.clock.advance(by: Self.delay)
        await scene.card._drainRowDwellForTesting()
        #expect(scene.card.expandedRow == nil)
        #expect(scene.card.expansionView.isHidden)
    }

    // MARK: What it shows and where

    @Test("an expansion shows six lines ending in an ellipsis, then the tool-call line, growing down from its row")
    func showsSixLinesAndTheCount() async throws {
        // Ten rows, a 232pt card: room below the first two for six lines.
        let dated = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"), year: 2020, month: 1, day: 2, hour: 12)))
        let scene = Self.scene(
            [Self.entry(0, Self.longPrompt, timestamp: dated), Self.entry(1, Self.twoLinePrompt)]
                + (2..<10).map { Self.entry($0, "fix it") },
            workCounts: [40, 1] + Array(repeating: 0, count: 8))
        defer { scene.host.tearDown() }
        let expansion = scene.card.expansionView

        try scene.movePointer(toRow: 0)
        try await Self.fire(scene)
        try #require(scene.card.expandedRow == 0)
        #expect(expansion.lineCount == 6, "the prompt took \(expansion.lineCount) lines")
        #expect(expansion.text.hasSuffix("…"), "the sixth line does not end in an ellipsis: \(expansion.text)")
        #expect(expansion.text.hasPrefix("the rail and its card"))
        #expect(expansion.countText == "40 tool calls")
        let row = PromptRailCardMetrics.rowRect(0, width: scene.card.frame.width)
        #expect(!expansion.growsUpward)
        #expect(abs(expansion.frame.minY - row.minY) < 0.5, "the expansion starts at \(expansion.frame.minY), its row at \(row.minY)")
        #expect(expansion.frame.minX == row.minX && expansion.frame.width == row.width, "the expansion is not as wide as its row")
        #expect(expansion.frame.height > row.height * 4, "the expansion is \(expansion.frame.height)pt tall")
        // The row's dash and time, where the row draws them.
        #expect(Self.sameRect(Self.inList(expansion.content?.dash, of: expansion), scene.card.dashRect(forEntry: 0)),
                "the expansion's dash left its row's")
        let time = PromptOutline.timeLabel(dated, now: Date(), calendar: .current, locale: .current)
        #expect(expansion.content?.time?.string == time)

        // A prompt that ends within six lines shows them all, with no
        // ellipsis, and a single tool call reads in the singular.
        try scene.movePointer(toRow: 1)
        try await Self.fire(scene)
        try #require(scene.card.expandedRow == 1)
        #expect(expansion.lineCount == 2)
        #expect(expansion.text == "fix it\nthen ship")
        #expect(expansion.countText == "1 tool call")
    }

    @Test("near the card's bottom an expansion grows up, ending on its row")
    func growsUpNearTheBottom() async throws {
        // Ten rows: a 232pt card, whose last row starts 28pt above its bottom.
        let scene = Self.scene((0..<10).map { Self.entry($0, Self.longPrompt) })
        defer { scene.host.tearDown() }
        let expansion = scene.card.expansionView
        let visible = scene.card.listScrollView.contentView.bounds
        try #require(visible.height == 232, "precondition: the card is 232pt tall (\(visible.height))")

        try scene.movePointer(toRow: 9)
        try await Self.fire(scene)
        try #require(scene.card.expandedRow == 9)
        let row = PromptRailCardMetrics.rowRect(9, width: scene.card.frame.width)
        #expect(expansion.growsUpward)
        #expect(abs(expansion.frame.maxY - row.maxY) < 0.5, "the expansion ends at \(expansion.frame.maxY), its row at \(row.maxY)")
        #expect(expansion.lineCount == 6)
        #expect(expansion.frame.minY >= visible.minY - 0.5, "the expansion rises past the list's top")
        // Growing up, the dash stays on the row, beside the tool-call line.
        #expect(Self.sameRect(Self.inList(expansion.content?.dash, of: expansion), scene.card.dashRect(forEntry: 9)),
                "the expansion's dash left its row's")
    }

    @Test("in a card too short for six lines an expansion shows as many as fit")
    func clampsInAShortCard() async throws {
        // Four rows: a 100pt card, too short for six lines either way.
        let scene = Self.scene((0..<4).map { Self.entry($0, Self.longPrompt) })
        defer { scene.host.tearDown() }
        let expansion = scene.card.expansionView
        let visible = scene.card.listScrollView.contentView.bounds
        try #require(visible.height == 100, "precondition: the card is 100pt tall (\(visible.height))")

        try scene.movePointer(toRow: 1)
        try await Self.fire(scene)
        try #require(scene.card.expandedRow == 1, "no line fit")
        #expect(expansion.lineCount >= 1 && expansion.lineCount < 6, "\(expansion.lineCount) lines in a 100pt card")
        #expect(expansion.text.hasSuffix("…"))
        #expect(expansion.frame.minY >= visible.minY - 0.5 && expansion.frame.maxY <= visible.maxY + 0.5,
                Comment(rawValue: "the expansion spans \(expansion.frame.minY)…\(expansion.frame.maxY) in a "
                    + "\(visible.minY)…\(visible.maxY) list"))
    }

    // MARK: Events

    @Test("an expansion takes no events: a click on its row jumps, and the wheel reaches the list")
    func expansionIsTransparentToEvents() async throws {
        let scene = Self.scene((0..<10).map { Self.entry($0, Self.longPrompt) })
        defer { scene.host.tearDown() }
        let expansion = scene.card.expansionView
        try scene.movePointer(toRow: 1)
        try await Self.fire(scene)
        try #require(scene.card.expandedRow == 1)

        #expect(expansion.hitTest(NSPoint(x: expansion.frame.midX, y: expansion.frame.midY)) == nil)
        #expect(!expansion.isAccessibilityElement())

        let list = try #require(scene.card.listScrollView.documentView)
        let superview = try #require(scene.card.superview)
        let row = PromptRailCardMetrics.rowRect(1, width: scene.card.frame.width)
        let onRow = NSPoint(x: row.midX, y: row.midY)
        try #require(expansion.frame.contains(onRow), "precondition: the expansion covers its row")
        let hit = scene.card.hitTest(list.convert(onRow, to: superview))
        #expect(hit === list, "a click over the expansion reached \(String(describing: hit))")
        #expect(hit?.enclosingScrollView === scene.card.listScrollView, "the wheel over the expansion misses the list")

        let location = list.convert(onRow, to: nil)
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: scene.host.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: scene.host.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        hit?.mouseDown(with: down)
        hit?.mouseUp(with: up)
        #expect(scene.jumps.ids == ["p-1"], "the click over the expansion did not jump to its row")
    }

    // MARK: Hiding

    @Test("moving to another row hides the expansion at once, and that row waits its own 150ms")
    func changingRowsHidesAtOnce() async throws {
        let scene = Self.scene((0..<10).map { Self.entry($0, Self.longPrompt) })
        defer { scene.host.tearDown() }
        try scene.movePointer(toRow: 0)
        try await Self.fire(scene)
        try #require(scene.card.expandedRow == 0)

        // Moving within the row neither hides nor restarts it.
        let first = PromptRailCardMetrics.rowRect(0, width: scene.card.frame.width)
        try scene.movePointer(toListPoint: NSPoint(x: first.minX + 40, y: first.maxY - 2))
        #expect(scene.card.expandedRow == 0, "a move within the row hid its expansion")
        #expect(!scene.clock.hasSleeper, "a move within the row restarted the delay")

        try scene.movePointer(toRow: 1)
        #expect(scene.card.expandedRow == nil, "the expansion outlived the pointer leaving its row")
        #expect(scene.card.expansionView.isHidden)
        try await scene.clock.requireAdvanceWhenArmed(by: .milliseconds(149), timeout: Self.mainActorHop)
        #expect(scene.card.expandedRow == nil, "the next row expanded before its own 150ms")
        await scene.clock.advance(by: .milliseconds(1))
        try #require(!scene.clock.hasSleeper, "the next row's delay outlasted 150ms")
        await scene.card._drainRowDwellForTesting()
        #expect(scene.card.expandedRow == 1)
    }

    @Test("scrolling the list or closing the card hides the expansion at once")
    func scrollingHidesAtOnce() async throws {
        // Forty rows in a 300pt pane: a 240pt card whose list scrolls.
        let scene = Self.scene((0..<40).map { Self.entry($0, Self.longPrompt) }, pane: NSSize(width: 680, height: 300))
        defer { scene.host.tearDown() }
        try scene.movePointer(toRow: 2)
        try await Self.fire(scene)
        try #require(scene.card.expandedRow == 2)

        let clip = scene.card.listScrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 22))
        scene.card.listScrollView.reflectScrolledClipView(clip)
        try #require(clip.bounds.minY == 22, "the list did not scroll (offset \(clip.bounds.minY))")
        #expect(scene.card.expandedRow == nil, "the expansion outlived a scroll")
        #expect(scene.card.expansionView.isHidden)

        clip.scroll(to: .zero)
        scene.card.listScrollView.reflectScrolledClipView(clip)
        try scene.movePointer(toRow: 3)
        try await Self.fire(scene)
        try #require(scene.card.expandedRow == 3)
        scene.card.close()
        #expect(scene.card.expandedRow == nil, "the expansion outlived its card")
    }

    // MARK: Helpers

    private static func entry(_ index: Int, _ text: String, timestamp: Date? = nil) -> PromptOutlineEntry {
        PromptOutlineEntry(
            id: "p-\(index)", rowIndex: index * 2, kind: .prompt,
            firstLine: PromptOutline.firstLine(of: text), excerpt: PromptOutline.excerpt(of: text),
            timestamp: timestamp)
    }

    /// `rect`, in `expansion`'s coordinates, in the list's.
    private static func inList(_ rect: NSRect?, of expansion: PromptRailRowExpansionView) -> NSRect? {
        rect?.offsetBy(dx: expansion.frame.minX, dy: expansion.frame.minY)
    }

    /// Within a hundredth of a point on every edge; both present.
    private static func sameRect(_ lhs: NSRect?, _ rhs: NSRect?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs.minX - rhs.minX) < 0.01 && abs(lhs.minY - rhs.minY) < 0.01
            && abs(lhs.width - rhs.width) < 0.01 && abs(lhs.height - rhs.height) < 0.01
    }

    /// An open card in an offscreen window, its row expansion on a virtual
    /// clock of its own.
    private static func scene(
        _ entries: [PromptOutlineEntry], workCounts: [Int] = [],
        pane: NSSize = NSSize(width: 680, height: 600)
    ) -> ExpansionScene {
        let host = OffscreenHost(root: EmptyView(), size: pane)
        let clock = EventDrivenTestClock()
        let jumps = ExpansionJumps()
        let hover = PromptRailHoverModel(notificationCenter: NotificationCenter(), clock: EventDrivenTestClock())
        let card = PromptRailCardNSView(hover: hover, onJump: { jumps.ids.append($0) }, clock: clock)
        host.contentView.addSubview(card)
        card.update(entries: entries, workCounts: workCounts, activeIndex: nil, earlier: nil)
        card.open(pointedIndex: nil, pointerY: 0, maxSize: pane)
        return ExpansionScene(host: host, card: card, clock: clock, jumps: jumps)
    }

    /// Waits for the delay to arm, advances past it, and joins the task it
    /// woke. The `#require` turns a delay longer than 150ms into a failure
    /// here.
    private static func fire(_ scene: ExpansionScene) async throws {
        try await scene.clock.requireAdvanceWhenArmed(by: delay, timeout: mainActorHop)
        try #require(!scene.clock.hasSleeper, "the delay outlasted 150ms")
        await scene.card._drainRowDwellForTesting()
    }
}

/// A mounted card and what drives it.
@MainActor
private struct ExpansionScene {
    let host: OffscreenHost<EmptyView>
    let card: PromptRailCardNSView
    let clock: EventDrivenTestClock
    let jumps: ExpansionJumps

    /// Moves the pointer to `point` in the list's coordinates, as the card's
    /// tracking area reports a move.
    func movePointer(toListPoint point: NSPoint) throws {
        let list = try #require(card.listScrollView.documentView)
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: list.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: host.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        card.mouseMoved(with: event)
    }

    /// Moves the pointer to the centre of list row `row`.
    func movePointer(toRow row: Int) throws {
        let rect = PromptRailCardMetrics.rowRect(row, width: card.frame.width)
        try movePointer(toListPoint: NSPoint(x: rect.midX, y: rect.midY))
    }
}

@MainActor
private final class ExpansionJumps {
    var ids: [String] = []
}
