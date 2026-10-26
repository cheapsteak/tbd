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
/// events, that it follows the pointer rather than the row a card opened
/// with, that it hides at once when the pointer changes rows or the list
/// scrolls or resizes, and how new outlines reach one on screen. Every card
/// takes the shipped delay, so the suite pins it.
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

    @Test("an expansion keeps clear of each edge fade that is on")
    func roomLeavesOutTheFades() {
        let clip = NSRect(x: 0, y: 100, width: 300, height: 240)
        #expect(PromptRailCardMetrics.expansionRoom(clip: clip, fadesTop: false, fadesBottom: false) == clip)
        // 24pt fades on a 240pt clip.
        #expect(PromptRailCardMetrics.expansionRoom(clip: clip, fadesTop: true, fadesBottom: false)
                    == NSRect(x: 0, y: 124, width: 300, height: 216))
        #expect(PromptRailCardMetrics.expansionRoom(clip: clip, fadesTop: false, fadesBottom: true)
                    == NSRect(x: 0, y: 100, width: 300, height: 216))
        #expect(PromptRailCardMetrics.expansionRoom(clip: clip, fadesTop: true, fadesBottom: true)
                    == NSRect(x: 0, y: 124, width: 300, height: 192))
        // Under 48pt each fade covers half the clip, which leaves no room.
        let thin = NSRect(x: 0, y: 0, width: 300, height: 40)
        #expect(PromptRailCardMetrics.expansionRoom(clip: thin, fadesTop: true, fadesBottom: true).height == 0)
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

        // Nothing inside it reaches accessibility, even a control.
        let probe = NSButton(title: "probe", target: nil, action: nil)
        expansion.addSubview(probe)
        #expect((expansion.accessibilityChildren() ?? []).isEmpty, "the expansion exposed what it holds")
        probe.removeFromSuperview()
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
        #expect(await watchForSleeper(on: scene.clock) == false, "a move within the row restarted the delay")
        #expect(scene.card.expandedRow == 0)

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

    @Test("an expansion near a faded bottom edge grows up rather than into the fade")
    func keepsClearOfTheBottomFade() async throws {
        // Forty rows in a 300pt pane: a 240pt card, its bottom 24pt fading.
        let scene = Self.scene((0..<40).map { Self.entry($0, Self.longPrompt) }, pane: NSSize(width: 680, height: 300))
        defer { scene.host.tearDown() }
        let expansion = scene.card.expansionView
        // Row 5 starts 124pt above the clip's bottom: room for six lines
        // there, but only 100pt above the fade.
        try scene.movePointer(toRow: 5)
        try await Self.fire(scene)
        try #require(scene.card.expandedRow == 5)
        let row = PromptRailCardMetrics.rowRect(5, width: scene.card.frame.width)
        #expect(expansion.growsUpward, "the expansion grew down into the fade")
        #expect(abs(expansion.frame.maxY - row.maxY) < 0.5)
        #expect(expansion.lineCount == 6)
    }

    // MARK: The pointer, not the opening row

    /// Notches sit at most 8pt apart and rows 22pt, so with a list that fits,
    /// the row a card opens with highlighted lies below the pointer: notch 5
    /// is at y 56 on the rail, over row 2 of the card, while row 5 spans
    /// 116–138.
    @Test("a card opened from the rail expands nothing until the pointer moves over it")
    func openingRowWaitsForThePointer() async throws {
        let scene = Self.scene((0..<8).map { Self.entry($0, Self.longPrompt) }, pointedIndex: 5, pointerY: 53)
        defer { scene.host.tearDown() }
        try #require(scene.card.listScrollView.contentView.bounds.minY == 0, "precondition: the list fits unscrolled")

        #expect(await watchForSleeper(on: scene.clock) == false, "the card armed the row it opened with")
        await scene.clock.advance(by: Self.delay)
        await scene.card._drainRowDwellForTesting()
        #expect(scene.card.expandedRow == nil)

        // A real move onto that same row arms it, though the highlight was
        // already there.
        try scene.movePointer(toRow: 5)
        try await Self.fire(scene)
        #expect(scene.card.expandedRow == 5)
    }

    @Test("a scroll under a card opened from the rail arms nothing")
    func scrollAfterOpeningArmsNothing() async throws {
        let scene = Self.scene(
            (0..<40).map { Self.entry($0, Self.longPrompt) }, pane: NSSize(width: 680, height: 300),
            pointedIndex: 5, pointerY: 53)
        defer { scene.host.tearDown() }
        let clip = scene.card.listScrollView.contentView
        let opened = clip.bounds.minY

        clip.scroll(to: NSPoint(x: 0, y: opened + 22))
        scene.card.listScrollView.reflectScrolledClipView(clip)
        try #require(clip.bounds.minY == opened + 22, "the list did not scroll (offset \(clip.bounds.minY))")
        #expect(await watchForSleeper(on: scene.clock) == false, "a scroll armed the row the card opened with")
        #expect(scene.card.expandedRow == nil)
    }

    // MARK: New outlines

    @Test("changed rows hide the expansion at once, and it waits its delay again")
    func changedRowsHideAndRearm() async throws {
        // A 240pt card that one more row does not grow.
        let entries = (0..<40).map { Self.entry($0, Self.longPrompt) }
        let scene = Self.scene(entries, pane: NSSize(width: 680, height: 300))
        defer { scene.host.tearDown() }
        try scene.movePointer(toRow: 2)
        try await Self.fire(scene)
        try #require(scene.card.expandedRow == 2)

        scene.card.update(
            entries: entries + [Self.entry(40, Self.longPrompt)], workCounts: [], activeIndex: nil, earlier: nil)
        #expect(scene.card.expandedRow == nil, "the expansion outlived its rows changing")
        try await Self.fire(scene)
        #expect(scene.card.expandedRow == 2, "the row under the pointer did not expand again")
    }

    @Test("new counts and a new active row redraw an expansion in place")
    func countsAndActiveRelayInPlace() async throws {
        let entries = (0..<10).map { Self.entry($0, Self.longPrompt) }
        let counts = Array(repeating: 40, count: 10)
        let scene = Self.scene(entries, workCounts: counts)
        defer { scene.host.tearDown() }
        let expansion = scene.card.expansionView
        try scene.movePointer(toRow: 2)
        try await Self.fire(scene)
        try #require(expansion.countText == "40 tool calls")
        #expect(expansion.content?.dash.height == 2)

        var busier = counts
        busier[2] = 41
        scene.card.update(entries: entries, workCounts: busier, activeIndex: nil, earlier: nil)
        #expect(scene.card.expandedRow == 2, "new counts hid the expansion")
        #expect(expansion.countText == "41 tool calls")

        scene.card.update(entries: entries, workCounts: busier, activeIndex: 2, earlier: nil)
        #expect(scene.card.expandedRow == 2, "a new active row hid the expansion")
        #expect(expansion.content?.dash.height == 3, "the expansion kept the inactive dash")
        #expect(await watchForSleeper(on: scene.clock) == false, "redrawing in place armed the delay")
    }

    @Test("a row that only the active row's weight cuts off expands once it is active, and stops when it is not")
    func activeWeightDecidesPartial() async throws {
        let titleWidth = PromptRailCardMetrics.maxWidth - PromptRailCardMetrics.trailingPadding
            - PromptRailCardMetrics.textLeading
        let prompt = try #require(
            Self.promptFittingOnlyWhenInactive(titleWidth: titleWidth),
            "no prompt fits at regular weight but not at medium")
        let entries = [Self.entry(0, prompt)] + (1..<10).map { Self.entry($0, "fix it") }
        let scene = Self.scene(entries)
        defer { scene.host.tearDown() }
        try #require(scene.card.frame.width == PromptRailCardMetrics.maxWidth)
        try #require(scene.card.showsPartOfPrompt(entry: 0) == false, "precondition: the inactive row shows it whole")

        try scene.movePointer(toRow: 0)
        #expect(await watchForSleeper(on: scene.clock) == false, "a row showing its whole prompt armed the delay")

        scene.card.update(entries: entries, workCounts: [], activeIndex: 0, earlier: nil)
        try #require(scene.card.showsPartOfPrompt(entry: 0) == true, "precondition: the active row cuts it off")
        try await Self.fire(scene)
        #expect(scene.card.expandedRow == 0, "the row did not expand once active")

        scene.card.update(entries: entries, workCounts: [], activeIndex: nil, earlier: nil)
        #expect(scene.card.expandedRow == nil, "the row stayed expanded once it showed its whole prompt")
    }

    @Test("resizing the card hides the expansion at once")
    func resizingHidesAtOnce() async throws {
        let scene = Self.scene((0..<40).map { Self.entry($0, Self.longPrompt) }, pane: NSSize(width: 680, height: 300))
        defer { scene.host.tearDown() }
        try scene.movePointer(toRow: 2)
        try await Self.fire(scene)
        try #require(scene.card.expandedRow == 2)

        scene.card.layoutCard(maxSize: NSSize(width: 680, height: 400))
        try #require(scene.card.listScrollView.contentView.bounds.height == 340,
                     "precondition: the card grew (\(scene.card.listScrollView.contentView.bounds.height))")
        #expect(scene.card.expandedRow == nil, "the expansion outlived its card resizing")
    }

    // MARK: Helpers

    private static func entry(_ index: Int, _ text: String, timestamp: Date? = nil) -> PromptOutlineEntry {
        PromptOutlineEntry(
            id: "p-\(index)", rowIndex: index * 2, kind: .prompt,
            firstLine: PromptOutline.firstLine(of: text), excerpt: PromptOutline.excerpt(of: text),
            timestamp: timestamp)
    }

    /// A one-line prompt as wide as fits `titleWidth` at the card's regular
    /// weight but not at the active row's medium weight; nil if no run of
    /// "a"s and "l"s lands between the two.
    private static func promptFittingOnlyWhenInactive(titleWidth: CGFloat) -> String? {
        let regular = NSFont.systemFont(ofSize: PromptRailCardMetrics.fontSize)
        let medium = NSFont.systemFont(ofSize: PromptRailCardMetrics.fontSize, weight: .medium)
        for wide in 0..<200 {
            for narrow in 0..<40 {
                let text = String(repeating: "a", count: wide) + String(repeating: "l", count: narrow)
                let regularWidth = NSAttributedString(string: text, attributes: [.font: regular]).size().width
                if regularWidth > titleWidth { break }
                let mediumWidth = NSAttributedString(string: text, attributes: [.font: medium]).size().width
                if mediumWidth > titleWidth { return text }
            }
        }
        return nil
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
        pane: NSSize = NSSize(width: 680, height: 600),
        pointedIndex: Int? = nil, pointerY: CGFloat = 0
    ) -> ExpansionScene {
        let host = OffscreenHost(root: EmptyView(), size: pane)
        let clock = EventDrivenTestClock()
        let jumps = ExpansionJumps()
        let hover = PromptRailHoverModel(notificationCenter: NotificationCenter(), clock: EventDrivenTestClock())
        let card = PromptRailCardNSView(hover: hover, onJump: { jumps.ids.append($0) }, clock: clock)
        host.contentView.addSubview(card)
        card.update(entries: entries, workCounts: workCounts, activeIndex: nil, earlier: nil)
        card.open(pointedIndex: pointedIndex, pointerY: pointerY, maxSize: pane)
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
