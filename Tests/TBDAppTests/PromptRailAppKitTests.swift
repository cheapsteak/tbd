import AppKit
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1 apart from the hosted cases, which mount a real offscreen window.
// Hover is fed to the model by hand; the open timer runs on
// `EventDrivenTestClock`.

/// The prompt rail's AppKit views: notch geometry and colours, the overflow
/// offset and fade, the card's rows, width cap and in-place updates, its
/// wiring through `TranscriptContainerView` to the hover model and the Escape
/// monitor, and the mount through `TableTranscriptView`.
@MainActor
@Suite("Prompt rail AppKit views", .clockDriven)
struct PromptRailAppKitTests {
    /// The open timer is a main-actor task; see the `timeout` note on
    /// `EventDrivenTestClock.sleeperArmed`.
    private static let mainActorHop = TestDeadlines.saturatedPass
    private static let openDelay = Duration.milliseconds(80)

    // MARK: Rail

    @Test("one notch per entry, the active one 18×3 and the rest 14×2, all at x 2")
    func oneNotchPerEntryActiveSized() {
        let rail = Self.makeRail(onJump: { _ in })
        rail.promptRail(entriesDidChange: Self.entries(5))
        rail.promptRail(activeIndexDidChange: 2)

        let frames = rail.notchLayerFrames
        #expect(frames.count == 5)
        for (index, frame) in frames.enumerated() {
            #expect(frame.minX == PromptRailLayout.notchLeading)
            let size = index == 2 ? CGSize(width: 18, height: 3) : CGSize(width: 14, height: 2)
            #expect(frame.size == size, "notch \(index) is \(frame.size)")
        }
        // Stacked from 12pt below the top at the 8pt maximum pitch.
        #expect(frames[0].midY == 16)
        #expect(frames[4].midY == 48)
    }

    @Test("an appearance change re-resolves the notch colours")
    func appearanceChangeReresolvesColors() throws {
        let aqua = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        let host = OffscreenHost(root: EmptyView(), size: NSSize(width: 680, height: 600))
        defer { host.tearDown() }
        let rail = Self.makeRail(onJump: { _ in })
        rail.appearance = aqua
        host.contentView.addSubview(rail)
        rail.promptRail(entriesDidChange: Self.entries(5))
        rail.promptRail(activeIndexDidChange: 2)

        let lightTertiary = Self.resolved(.tertiaryLabelColor, in: aqua)
        let darkTertiary = Self.resolved(.tertiaryLabelColor, in: dark)
        let darkAccent = Self.resolved(.controlAccentColor, in: dark)
        try #require(lightTertiary != darkTertiary, "the inactive colour does not differ by appearance")
        try #require(rail.notchLayers[0].backgroundColor == lightTertiary,
                     "the notches did not start in the light appearance")

        rail.appearance = dark
        let followed = RunLoopPump.until {
            rail.notchLayers[2].backgroundColor == darkAccent
                && rail.notchLayers[0].backgroundColor == darkTertiary
        }
        #expect(followed, "the notch colours stayed resolved for the light appearance")
    }

    @Test("an overflowing rail offsets its notches to keep the active one in view, behind a fade")
    func overflowAppliesOffsetAndFades() throws {
        let rail = Self.makeRail(onJump: { _ in })
        rail.promptRail(entriesDidChange: Self.entries(300))
        rail.promptRail(activeIndexDidChange: 299)

        let last = try #require(rail.notchLayerFrames.last)
        #expect(rail.bounds.contains(last), "the last notch \(last) lies outside the rail")
        // 300 notches at the 4pt floor: 12 + 1200 + 12 = 1224pt of content
        // in a 600pt rail, so the offset is clamped to its 624pt maximum.
        #expect(rail.offset == 624)
        #expect(rail.hasFadeMask, "an overflowing rail has no fade")

        let short = Self.makeRail(onJump: { _ in })
        short.promptRail(entriesDidChange: Self.entries(10))
        short.promptRail(activeIndexDidChange: 9)
        #expect(short.offset == 0)
        #expect(!short.hasFadeMask, "a rail that fits has a fade")
    }

    @Test("a list that shrinks past the active index leaves no notch active")
    func shrunkListHasNoActiveNotch() {
        let rail = Self.makeRail(onJump: { _ in })
        rail.promptRail(entriesDidChange: Self.entries(5))
        rail.promptRail(activeIndexDidChange: 4)
        // The entries arrive before the index computed against them.
        rail.promptRail(entriesDidChange: Self.entries(3))

        #expect(rail.activeIndex == nil)
        #expect(rail.notchLayerFrames.map(\.size) == Array(repeating: CGSize(width: 14, height: 2), count: 3))
    }

    @Test("the wheel over the rail scrolls the transcript, not the rail")
    func railForwardsWheel() throws {
        let rail = Self.makeRail(onJump: { _ in })
        let target = WheelRecorder()
        rail.wheelTarget = target
        let cgEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -10, wheel2: 0, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: cgEvent))

        rail.scrollWheel(with: event)
        #expect(target.events == 1)
    }

    @Test("the rail is a Prompts group of buttons that jump")
    func accessibilityButtonsJump() throws {
        let jumps = JumpRecorder()
        let rail = Self.makeRail(onJump: { jumps.ids.append($0) })
        let dated = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"), year: 2020, month: 1, day: 2, hour: 12)))
        var entries = Self.entries(3)
        entries[0] = PromptOutlineEntry(
            id: "p-0", rowIndex: 0, kind: .prompt, firstLine: "Prompt 0", tooltip: "Prompt 0", timestamp: dated)
        rail.promptRail(entriesDidChange: entries)

        #expect(rail.accessibilityRole() == .group)
        #expect(rail.accessibilityLabel() == "Prompts")
        let buttons = try #require(rail.accessibilityChildren() as? [PromptRailAccessibilityButton])
        #expect(buttons.count == 3)
        #expect(buttons.allSatisfy { $0.isAccessibilityElement() })
        #expect(buttons[1].accessibilityRole() == .button)
        #expect(buttons[1].accessibilityLabel() == "Prompt 1")
        let time = PromptOutline.timeLabel(dated, now: Date(), calendar: .current, locale: .current)
        #expect(buttons[0].accessibilityLabel() == "Prompt 0, \(time)")

        #expect(buttons[1].accessibilityPerformPress())
        #expect(jumps.ids == ["p-1"])
    }

    /// The pitch follows the rail's height, so a resize moves every
    /// button's band even when the overflow offset stays at zero.
    @Test("a rail height change moves the accessibility bands though the offset stays put")
    func railResizeMovesAccessibilityFrames() throws {
        let rail = Self.makeRail(onJump: { _ in })
        rail.promptRail(entriesDidChange: Self.entries(10))
        let buttons = try #require(rail.accessibilityChildren() as? [PromptRailAccessibilityButton])
        try #require(buttons.count == 10)
        // 600pt: the 8pt maximum pitch, band 9 at 12 + 9.5 × 8 − 4.
        try #require(buttons[9].accessibilityFrameInParentSpace()
                         == NSRect(x: 0, y: 84, width: PromptRailLayout.width, height: 8))

        // 64pt: 40pt free over 10 notches is the 4pt minimum pitch, and the
        // 64pt of content still fits, so nothing overflows.
        rail.setFrameSize(NSSize(width: PromptRailLayout.width, height: 64))
        try #require(rail.offset == 0, "precondition: the offset stayed put, so only the height moved the bands")
        #expect(buttons[9].accessibilityFrameInParentSpace()
                    == NSRect(x: 0, y: 48, width: PromptRailLayout.width, height: 4),
                Comment(rawValue: "band 9 is \(buttons[9].accessibilityFrameInParentSpace())"))
        #expect(buttons[0].accessibilityFrameInParentSpace().height == 4)
    }

    /// `closeNow()` — the window resigning key, the app deactivating — forgets
    /// rail hover, and a pointer resting on the rail sends no new enter.
    @Test("a pointer moving over the rail reopens a card closed under it")
    func railMoveReassertsHover() async throws {
        let clock = EventDrivenTestClock()
        let hover = Self.makeHover(clock: clock)
        let rail = PromptRailNSView(hover: hover, onJump: { _ in })
        rail.frame = NSRect(x: 0, y: 0, width: PromptRailLayout.width, height: 600)
        rail.promptRail(entriesDidChange: Self.entries(5))
        try await Self.openCard(hover, clock)
        hover.closeNow()
        try #require(!hover.isOpen)

        let move = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: NSPoint(x: 8, y: 300), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        rail.mouseMoved(with: move)
        try await clock.requireAdvanceWhenArmed(by: Self.openDelay, timeout: Self.mainActorHop)
        await hover._drainForTesting()
        #expect(hover.isOpen, "a move over the rail did not reopen the card")
    }

    // MARK: Card

    @Test("the card lists an earlier row first, never loads on opening, and a row click jumps")
    func cardRowsAndEarlierRow() {
        let hover = Self.makeHover()
        let jumps = JumpRecorder()
        let loads = JumpRecorder()
        let card = PromptRailCardNSView(hover: hover, onJump: { jumps.ids.append($0) })
        card.update(
            entries: Self.entries(5), activeIndex: nil,
            earlier: PromptRailEarlierHistory(hasEarlier: true, load: { loads.ids.append("load") }))
        #expect(card.rowCount == 6)

        card.open(pointedIndex: 1, pointerY: 30, maxSize: CGSize(width: 680, height: 600))
        #expect(card.isOpen)
        #expect(loads.ids.isEmpty, "opening the card loaded earlier history")

        // Row 0 is the earlier row, so row 2 is the second prompt.
        card.performClick(row: 2)
        #expect(jumps.ids == ["p-1"])
        #expect(!hover.isOpen)

        card.performClick(row: 0)
        #expect(jumps.ids == ["p-1"], "the earlier row jumped")
        #expect(loads.ids.isEmpty, "a click on the earlier row loaded history")

        card.update(entries: Self.entries(5), activeIndex: nil, earlier: nil)
        #expect(card.rowCount == 5)
    }

    @Test("the card is 320pt wide, capped at the pane's width minus 24pt, and at most the rail's height less 60pt")
    func cardWidthCaps() {
        let card = PromptRailCardNSView(hover: Self.makeHover(), onJump: { _ in })
        card.update(entries: Self.entries(5), activeIndex: nil, earlier: nil)

        card.open(pointedIndex: nil, pointerY: 0, maxSize: CGSize(width: 300, height: 600))
        #expect(card.frame.width == 276)
        // Five 22pt rows inside 6pt of padding above and below.
        #expect(card.frame.height == 122)
        card.close()

        card.open(pointedIndex: nil, pointerY: 0, maxSize: CGSize(width: 700, height: 600))
        #expect(card.frame.width == 320)
        card.close()

        // Forty rows outgrow a 300pt rail, so the card stops 60pt above its
        // bottom, clear of the pane's jump-to-bottom button.
        card.update(entries: Self.entries(40), activeIndex: nil, earlier: nil)
        card.open(pointedIndex: nil, pointerY: 0, maxSize: CGSize(width: 700, height: 300))
        #expect(card.frame.height == 240)
        #expect(PromptRailCardMetrics.bottomClearance == 60)
    }

    @Test("a new entry while the card is open keeps it open and keeps the list where it was")
    func entriesChangeWhileOpenKeepsCardAndScroll() throws {
        let card = PromptRailCardNSView(hover: Self.makeHover(), onJump: { _ in })
        card.update(entries: Self.entries(40), activeIndex: 3, earlier: nil)
        card.open(pointedIndex: nil, pointerY: 0, maxSize: CGSize(width: 680, height: 300))
        let clip = card.listScrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 40))
        card.listScrollView.reflectScrolledClipView(clip)
        try #require(clip.bounds.minY == 40, "the list did not scroll (offset \(clip.bounds.minY))")

        card.update(entries: Self.entries(41), activeIndex: 3, earlier: nil)
        #expect(card.isOpen)
        #expect(!card.isHidden)
        #expect(card.rowCount == 41)
        #expect(clip.bounds.minY == 40, "the update moved the list to \(clip.bounds.minY)")
    }

    @Test("opening puts the pointed row under the pointer")
    func openScrollsPointedRowUnderPointer() {
        let card = PromptRailCardNSView(hover: Self.makeHover(), onJump: { _ in })
        card.update(entries: Self.entries(100), activeIndex: nil, earlier: nil)

        // Row 50's centre is 6 + 50 × 22 + 11 = 1117pt down the list.
        card.open(pointedIndex: 50, pointerY: 200, maxSize: CGSize(width: 680, height: 600))
        #expect(card.listScrollView.contentView.bounds.minY == 917)
        card.close()

        // Near the top the list cannot scroll above its first row.
        card.open(pointedIndex: 1, pointerY: 500, maxSize: CGSize(width: 680, height: 600))
        #expect(card.listScrollView.contentView.bounds.minY == 0)
    }

    /// The card stops 60pt above the rail's bottom, so a pointer over that
    /// stretch is below the card: its row goes as low as the card allows.
    @Test("a pointer below the card's bottom keeps the pointed row inside the card")
    func openKeepsPointedRowInsideCard() throws {
        let card = PromptRailCardNSView(hover: Self.makeHover(), onJump: { _ in })
        card.update(entries: Self.entries(100), activeIndex: nil, earlier: nil)
        let rail = CGSize(width: 680, height: 600)
        let pointerY: CGFloat = 585
        let pointed = try #require(
            PromptRailLayout(count: 100, railHeight: rail.height).index(atRailY: pointerY, offset: 0))

        card.open(pointedIndex: pointed, pointerY: pointerY, maxSize: rail)
        try #require(card.frame.height == 540,
                     Comment(rawValue: "precondition: the card stops 60pt above the rail's bottom "
                         + "(\(card.frame.height) pt)"))
        try #require(pointerY > card.frame.height, "precondition: the pointer is below the card")

        let listOffset = card.listScrollView.contentView.bounds.minY
        let row = PromptRailCardMetrics.rowRect(pointed, width: card.frame.width)
            .offsetBy(dx: 0, dy: -listOffset)
        #expect(row.minY >= 0 && row.maxY <= card.frame.height,
                Comment(rawValue: "row \(pointed) sat at \(row.minY)…\(row.maxY) pt in a "
                    + "\(card.frame.height) pt card (list offset \(listOffset) pt)"))
        // As low as the card allows: its bottom edge on the card's.
        #expect(abs(row.maxY - card.frame.height) <= 0.5,
                Comment(rawValue: "row \(pointed) ended at \(row.maxY) pt, not the card's bottom"))
    }

    // MARK: Container wiring

    @Test("the hover model opens the card with the rail's outline, and a row click closes it and stops Escape")
    func cardFollowsHoverModel() async throws {
        let clock = EventDrivenTestClock()
        let hover = Self.makeHover(clock: clock)
        let escape = EscapeTable()
        let jumps = JumpRecorder()
        let mounted = Self.mount(hover: hover, escape: escape, onJump: { jumps.ids.append($0) })
        defer { mounted.host.tearDown() }
        mounted.rail.promptRail(entriesDidChange: Self.entries(5))
        mounted.rail.promptRail(activeIndexDidChange: 4)
        #expect(mounted.card.rowCount == 5, "the rail's outline did not reach the card")
        #expect(mounted.card.activeIndex == 4)
        #expect(mounted.card.isHidden)

        try await Self.openCard(hover, clock)
        #expect(mounted.card.isOpen)
        #expect(!mounted.card.isHidden)
        #expect(mounted.card.frame.width == 320, "the card was not laid out against the 680pt pane")
        #expect(escape.live == 1, "the Escape monitor is not running while the card is open")

        mounted.card.performClick(row: 1)
        #expect(jumps.ids == ["p-1"])
        #expect(!hover.isOpen)
        #expect(!mounted.card.isOpen)
        #expect(mounted.card.isHidden)
        #expect(escape.live == 0, "the Escape monitor outlived the card")
    }

    @Test("removing the container from its window closes the card")
    func teardownClosesCard() async throws {
        let clock = EventDrivenTestClock()
        let hover = Self.makeHover(clock: clock)
        let escape = EscapeTable()
        let mounted = Self.mount(hover: hover, escape: escape, onJump: { _ in })
        defer { mounted.host.tearDown() }
        mounted.rail.promptRail(entriesDidChange: Self.entries(5))
        try await Self.openCard(hover, clock)
        try #require(mounted.card.isOpen)

        mounted.container.removeFromSuperview()
        #expect(!hover.isOpen, "the hover model stayed open after its pane left the window")
        #expect(!mounted.card.isOpen)
        #expect(escape.live == 0, "the Escape monitor outlived the pane")
    }

    @Test("the window resigning key closes the card")
    func resignKeyClosesCard() async throws {
        let clock = EventDrivenTestClock()
        let hover = Self.makeHover(clock: clock)
        let escape = EscapeTable()
        let center = NotificationCenter()
        let mounted = Self.mount(hover: hover, escape: escape, center: center, onJump: { _ in })
        defer { mounted.host.tearDown() }
        mounted.rail.promptRail(entriesDidChange: Self.entries(5))
        try await Self.openCard(hover, clock)
        try #require(mounted.card.isOpen)

        center.post(name: NSWindow.didResignKeyNotification, object: mounted.host.window)
        #expect(!hover.isOpen, "the card stayed open in a window that is no longer key")
        #expect(!mounted.card.isOpen)
        #expect(escape.live == 0, "the Escape monitor outlived the card")
    }

    /// The gutter exists with no prompts and the rail reports hover there
    /// too, so the hover model opens a card with no rows. Nothing is on
    /// screen, so nothing may take Escape: the local monitor would swallow it
    /// for every view in the window, a terminal's interrupt included.
    @Test("an open card with no rows takes no Escape until a row puts it on screen")
    func emptyCardTakesNoEscape() async throws {
        let clock = EventDrivenTestClock()
        let hover = Self.makeHover(clock: clock)
        let escape = EscapeTable()
        let mounted = Self.mount(hover: hover, escape: escape, onJump: { _ in })
        defer { mounted.host.tearDown() }

        try await Self.openCard(hover, clock)
        #expect(mounted.card.isOpen)
        #expect(!mounted.card.isShown, "a card with no rows is on screen")
        #expect(escape.installs == 0, "a card with no rows installed the Escape monitor")
        #expect(escape.live == 0)

        // The first prompt arrives while the card is open: it shows, and only
        // now takes Escape.
        mounted.rail.promptRail(entriesDidChange: Self.entries(1))
        #expect(mounted.card.isShown, "the open card stayed hidden after its first row arrived")
        #expect(mounted.card.frame.height == 34)
        #expect(escape.live == 1, "the card showed without the Escape monitor")

        // Losing its last row takes it off screen and gives Escape back,
        // though the hover model still has it open.
        mounted.rail.promptRail(entriesDidChange: [])
        #expect(!mounted.card.isShown)
        #expect(hover.isOpen)
        #expect(escape.live == 0, "the Escape monitor outlived the card's last row")

        hover.closeNow()
        #expect(!mounted.card.isOpen)
        #expect(escape.installs == 1)
        #expect(escape.live == 0)
    }

    // MARK: Mounted through the table

    @Test("an AppKit mount puts the rail in the gutter as presenter, feeds the card, and routes jumps to the table")
    func appKitMountWiresRailCardAndJump() async throws {
        let suiteName = "prompt-rail-appkit-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let table = Self.table(appState: AppState(userDefaults: defaults), earlier: nil)
        let host = OffscreenHost(root: table, size: NSSize(width: 680, height: 600))
        defer { host.tearDown() }

        let delivered = await host.settle {
            (host.firstDescendant(PromptRailCardNSView.self)?.rowCount ?? 0) == 3
        }
        try #require(delivered, "the card never received the outline")
        let container = try #require(host.firstDescendant(TranscriptContainerView.self))
        let coordinator = try #require(container.coordinator, "the container has no coordinator")
        let rail = try #require(container.railView as? PromptRailNSView)
        let card = try #require(container.cardView as? PromptRailCardNSView)

        #expect(coordinator.promptRailPresenter === rail)
        #expect(rail.entries == coordinator.promptEntries)
        #expect(card.entries == coordinator.promptEntries)
        #expect(rail.frame == NSRect(x: 0, y: 0, width: PromptRailLayout.width, height: 600))
        #expect(rail.notchLayerFrames.count == 3)
        #expect(container.subviews == [container.scrollView, rail, card])

        card.performClick(row: 1)
        #expect(coordinator.heldJumpTargetID == "p-1", "the card's click did not reach the table's jump")
    }

    @Test("the card's earlier row follows the pane's earlier-history state across updates")
    func earlierFollowsUpdate() async throws {
        let suiteName = "prompt-rail-appkit-earlier-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let box = EarlierBox()
        let root = EarlierHarness(box: box, appState: AppState(userDefaults: defaults))
        let host = OffscreenHost(root: root, size: NSSize(width: 680, height: 600))
        defer { host.tearDown() }

        let withEarlier = await host.settle {
            (host.firstDescendant(PromptRailCardNSView.self)?.rowCount ?? 0) == 4
        }
        try #require(withEarlier, "the card never showed the earlier row")
        let card = try #require(host.firstDescendant(PromptRailCardNSView.self))
        card.earlier?.load()
        #expect(box.loads == 1, "the card's load action is not the pane's")

        box.hasEarlier = false
        let withoutEarlier = await host.settle { card.rowCount == 3 }
        #expect(withoutEarlier, "the earlier row outlived the pane's history loading (rows: \(card.rowCount))")
    }

    // MARK: Helpers

    private static func entries(_ count: Int) -> [PromptOutlineEntry] {
        (0..<count).map { index in
            PromptOutlineEntry(
                id: "p-\(index)", rowIndex: index * 2, kind: .prompt,
                firstLine: "Prompt \(index)", tooltip: "Prompt \(index)", timestamp: nil)
        }
    }

    private static func makeHover(clock: EventDrivenTestClock = EventDrivenTestClock()) -> PromptRailHoverModel {
        PromptRailHoverModel(notificationCenter: NotificationCenter(), clock: clock)
    }

    private static func makeRail(onJump: @escaping @MainActor (String) -> Void) -> PromptRailNSView {
        let rail = PromptRailNSView(hover: makeHover(), onJump: onJump)
        rail.frame = NSRect(x: 0, y: 0, width: PromptRailLayout.width, height: 600)
        return rail
    }

    private static func resolved(_ color: NSColor, in appearance: NSAppearance) -> CGColor? {
        var result: CGColor?
        appearance.performAsCurrentDrawingAppearance { result = color.cgColor }
        return result
    }

    /// Hovers the rail and fires the open timer.
    private static func openCard(_ hover: PromptRailHoverModel, _ clock: EventDrivenTestClock) async throws {
        hover.railHoverChanged(true)
        try await clock.requireAdvanceWhenArmed(by: openDelay, timeout: mainActorHop)
        await hover._drainForTesting()
        try #require(hover.isOpen, "the hover model did not open")
    }

    private struct Mounted {
        let host: OffscreenHost<EmptyView>
        let container: TranscriptContainerView
        let rail: PromptRailNSView
        let card: PromptRailCardNSView
    }

    /// A 680×600 container in an offscreen window with the prompt rail
    /// installed, wired as `makeNSView` wires it but with the test's seams.
    private static func mount(
        hover: PromptRailHoverModel,
        escape: EscapeTable,
        center: NotificationCenter = NotificationCenter(),
        onJump: @escaping @MainActor (String) -> Void
    ) -> Mounted {
        let host = OffscreenHost(root: EmptyView(), size: NSSize(width: 680, height: 600))
        let container = TranscriptContainerView(
            scrollView: NSScrollView(), leadingGutter: PromptRailLayout.width)
        container.frame = host.contentView.bounds
        host.contentView.addSubview(container)
        let rail = PromptRailNSView(hover: hover, onJump: onJump)
        let card = PromptRailCardNSView(hover: hover, onJump: onJump)
        container.installPromptRail(
            rail: rail, card: card, hover: hover, earlier: nil,
            escapeMonitor: escape.makeMonitor(), notificationCenter: center)
        container.layoutSubtreeIfNeeded()
        return Mounted(host: host, container: container, rail: rail, card: card)
    }

    /// A three-prompt table with the prompt rail mounted.
    fileprivate static func table(
        appState: AppState, earlier: PromptRailEarlierHistory?
    ) -> TableTranscriptView {
        let nodes = transcriptRenderNodes(
            from: PromptRailFixtures.conversation(prompts: 3, replySentences: { _ in 2 }))
        return TableTranscriptView(
            context: TranscriptCardContext(
                terminalID: nil,
                openTranscriptOverlay: nil,
                appState: appState,
                linkResolver: nil,
                onLinkClicked: nil),
            atBottom: .constant(true),
            scrollToBottomToken: 0,
            activityToggleToken: 0,
            linkRoot: "",
            nodesProvider: { nodes },
            promptRail: .rail(earlier: earlier))
    }
}

@MainActor
private final class JumpRecorder {
    var ids: [String] = []
}

/// Counts wheel events handed to it.
private final class WheelRecorder: NSView {
    private(set) var events = 0
    override func scrollWheel(with event: NSEvent) { events += 1 }
}

/// AppKit's monitor table, faked: counts installs and removals, so a test can
/// ask whether the Escape monitor is running.
@MainActor
private final class EscapeTable {
    private(set) var installs = 0
    private let removals = FireRecorder<Int>()

    /// Monitors installed and not yet removed.
    var live: Int { installs - removals.values.count }

    func makeMonitor() -> PromptRailEscapeMonitor {
        let removals = self.removals
        return PromptRailEscapeMonitor(
            install: { [self] _ in
                installs += 1
                return NSObject()
            },
            remove: { _ in removals.record(1) })
    }
}

/// The Remote pane's earlier-history flag, as a test drives it.
@MainActor
@Observable
private final class EarlierBox {
    var hasEarlier = true
    var loads = 0
}

/// A pane-shaped body that rebuilds the table's mount from `box`, so a change
/// to the flag reaches the table through `updateNSView`.
private struct EarlierHarness: View {
    let box: EarlierBox
    let appState: AppState

    var body: some View {
        let box = self.box
        PromptRailAppKitTests.table(
            appState: appState,
            earlier: PromptRailEarlierHistory(hasEarlier: box.hasEarlier, load: { box.loads += 1 }))
    }
}
