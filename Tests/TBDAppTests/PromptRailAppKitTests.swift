import AppKit
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1 apart from the hosted cases, which mount a real offscreen window.
// Hover is fed to the model by hand or through synthesized mouse events; the
// hover model's timers run on `EventDrivenTestClock`.

/// The prompt rail's AppKit view: notch geometry and colours, the overflow
/// offset and fade, hit-testing and hover over the rail column, its wiring
/// through `TranscriptContainerView` to the hover model and the Escape
/// monitor, and the mount through `TableTranscriptView`.
@MainActor
@Suite("Prompt rail AppKit views", .clockDriven)
struct PromptRailAppKitTests {
    /// The hover model's timers are main-actor tasks; see the `timeout` note
    /// on `EventDrivenTestClock.sleeperArmed`.
    private static let mainActorHop = TestDeadlines.saturatedPass
    private static let openDelay = Duration.milliseconds(80)
    private static let closeGrace = Duration.milliseconds(100)

    // MARK: Rail

    @Test("one notch per entry, each as long as its turn's work, the active one 3pt tall and the rest 2pt, all at x 2")
    func notchLengthsFollowWork() {
        let rail = Self.makeRail(onJump: { _ in })
        let counts = [0, 3, 40, 1, 12]
        rail.promptRail(entriesDidChange: Self.entries(5))
        rail.promptRail(workCountsDidChange: counts)
        rail.promptRail(activeIndexDidChange: 2)

        let frames = rail.displayedNotchRects
        #expect(frames.count == 5)
        for (index, frame) in frames.enumerated() {
            #expect(Self.isClose(frame.minX, PromptRailLayout.notchLeading), "notch \(index) starts at \(frame.minX)")
            let length = PromptRailWorkScale.length(work: counts[index], busiest: 40)
            #expect(Self.isClose(frame.width, length), "notch \(index) is \(frame.width) long, not \(length)")
            #expect(frame.height == (index == 2 ? 3 : 2), "notch \(index) is \(frame.height) tall")
        }
        // No work is the 4pt floor; the busiest turn, here the active one, 16pt.
        #expect(Self.isClose(frames[0].width, 4))
        #expect(Self.isClose(frames[2].width, 16))
        // Stacked from the top inset at the resting pitch, which spreads a
        // short session over the height the lens needs.
        let layout = PromptRailLayout(count: 5, railHeight: 600)
        #expect(Self.isClose(frames[0].midY, layout.notchCenterY(0)), "notch 0 is centred at \(frames[0].midY)")
        #expect(Self.isClose(frames[4].midY, layout.notchCenterY(4)), "notch 4 is centred at \(frames[4].midY)")

        // The active notch is marked by thickness alone: moving it changes no
        // length.
        rail.promptRail(activeIndexDidChange: 0)
        let moved = rail.displayedNotchRects
        let lengthsKept = zip(moved, frames).allSatisfy { Self.isClose($0.width, $1.width) }
        #expect(lengthsKept, Comment(rawValue: "lengths \(frames.map(\.width)) became \(moved.map(\.width))"))
        #expect(moved[0].height == 3)
        #expect(moved[2].height == 2)
    }

    @Test("new work counts restyle the notches in place, a busier turn rescaling the rest")
    func workCountsRescaleNotches() {
        let rail = Self.makeRail(onJump: { _ in })
        rail.promptRail(entriesDidChange: Self.entries(3))
        rail.promptRail(workCountsDidChange: [1, 10, 0])
        let before = rail.displayedNotchRects
        #expect(Self.isClose(before[1].width, 16))
        #expect(Self.isClose(before[2].width, 4))

        // The common live case: one turn's count changes and the busiest turn
        // stays the busiest. That notch grows; the others keep their frames.
        rail.promptRail(workCountsDidChange: [1, 10, 5])
        let grown = rail.displayedNotchRects
        #expect(Self.isClose(grown[2].width, PromptRailWorkScale.length(work: 5, busiest: 10)))
        #expect(grown[2].width > before[2].width + 1,
                Comment(rawValue: "notch 2 stayed \(grown[2].width) long"))
        #expect(grown[0] == before[0] && grown[1] == before[1],
                Comment(rawValue: "untouched notches moved: \(before.prefix(2)) became \(grown.prefix(2))"))

        rail.promptRail(workCountsDidChange: [1, 10, 100])
        let after = rail.displayedNotchRects
        #expect(rail.workCounts == [1, 10, 100])
        #expect(Self.isClose(after[2].width, 16))
        #expect(after[1].width < before[1].width - 1,
                Comment(rawValue: "the old busiest notch stayed \(after[1].width) long"))
        #expect(after[0].width < before[0].width)
    }

    /// Colours resolve in each draw, so an appearance change has only to
    /// redraw. The palette a draw resolved shows which appearance it drew in.
    @Test("an appearance change redraws the notches in the new appearance's colours")
    func appearanceChangeRedrawsNotchColors() throws {
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
        let drewLight = RunLoopPump.until { rail.lastDrawnPalette?.prompt == lightTertiary }
        try #require(drewLight, "the notches never drew in the light appearance")

        rail.appearance = dark
        let followed = RunLoopPump.until {
            rail.lastDrawnPalette?.activePrompt == darkAccent
                && rail.lastDrawnPalette?.prompt == darkTertiary
        }
        #expect(followed, "the notches were not redrawn in the dark appearance's colours")
    }

    @Test("an overflowing rail offsets its notches to keep the active one in view, behind a fade")
    func overflowAppliesOffsetAndFades() throws {
        let rail = Self.makeRail(onJump: { _ in })
        rail.promptRail(entriesDidChange: Self.entries(300))
        rail.promptRail(activeIndexDidChange: 299)

        let last = try #require(rail.displayedNotchRects.last)
        #expect(rail.bounds.contains(last), "the last notch \(last) lies outside the rail")
        // 300 notches at the 4pt floor: 12 + 1200 + 12 = 1224pt of content
        // in a 600pt rail, so the offset is clamped to its 624pt maximum.
        let layout = PromptRailLayout(count: 300, railHeight: 600)
        try #require(layout.pitch == PromptRailLayout.minPitch, "precondition: 300 prompts rest at the floor")
        #expect(rail.offset == layout.contentHeight - 600)
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
        // No counts delivered: every notch is the no-work floor.
        #expect(rail.displayedNotchRects.map(\.size)
                    == Array(repeating: CGSize(width: PromptRailWorkScale.minLength, height: 2), count: 3))
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
            id: "p-0", rowIndex: 0, kind: .prompt, firstLine: "Prompt 0", excerpt: "Prompt 0", timestamp: dated)
        rail.promptRail(entriesDidChange: entries)
        rail.promptRail(workCountsDidChange: [40, 1, 0])

        #expect(rail.accessibilityRole() == .group)
        #expect(rail.accessibilityLabel() == "Prompts")
        let buttons = try #require(rail.accessibilityChildren() as? [PromptRailAccessibilityButton])
        #expect(buttons.count == 3)
        let allElements = buttons.allSatisfy { $0.isAccessibilityElement() }
        #expect(allElements)
        #expect(buttons[1].accessibilityRole() == .button)
        #expect(buttons[1].accessibilityLabel() == "Prompt 1, 1 tool call")
        #expect(buttons[2].accessibilityLabel() == "Prompt 2, 0 tool calls")
        let time = PromptOutline.timeLabel(dated, now: Date(), calendar: .current, locale: .current)
        #expect(buttons[0].accessibilityLabel() == "Prompt 0, \(time), 40 tool calls")

        // New counts relabel the same buttons in place.
        rail.promptRail(workCountsDidChange: [40, 2, 0])
        let relabelled = try #require(rail.accessibilityChildren() as? [PromptRailAccessibilityButton])
        #expect(relabelled.count == 3)
        #expect(relabelled[1] === buttons[1], "new counts rebuilt the buttons")
        #expect(buttons[1].accessibilityLabel() == "Prompt 1, 2 tool calls")

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
        // 600pt: band 9 is one resting pitch tall, centred on notch 9.
        let tall = PromptRailLayout(count: 10, railHeight: 600)
        let tallBand = buttons[9].accessibilityFrameInParentSpace()
        try #require(
            Self.isClose(tallBand, Self.band(9, tall)),
            Comment(rawValue: "precondition: band 9 at 600pt is \(tallBand), not \(Self.band(9, tall))"))

        // 64pt: 40pt free over 10 notches is the 4pt minimum pitch, and the
        // 64pt of content still fits, so nothing overflows.
        rail.setFrameSize(NSSize(width: PromptRailLayout.width, height: 64))
        let short = PromptRailLayout(count: 10, railHeight: 64)
        try #require(short.pitch == PromptRailLayout.minPitch && !short.overflows,
                     "precondition: 64pt rests 10 notches at the floor without overflowing")
        try #require(rail.offset == 0, "precondition: the offset stayed put, so only the height moved the bands")
        let shortBand = buttons[9].accessibilityFrameInParentSpace()
        #expect(Self.isClose(shortBand, Self.band(9, short)),
                Comment(rawValue: "band 9 is \(shortBand), not \(Self.band(9, short))"))
        #expect(shortBand != tallBand, "the resize left band 9 where it was")
        #expect(buttons[0].accessibilityFrameInParentSpace().height == PromptRailLayout.minPitch)
    }

    /// The overlay is as wide as the lens's box can grow, but the transcript
    /// keeps its clicks and its wheel outside the rail column.
    @Test("the overlay answers only over the rail column, and its group and buttons span the column alone")
    func hitTestPassesThroughOutsideRail() throws {
        let host = OffscreenHost(root: EmptyView(), size: NSSize(width: 680, height: 600))
        defer { host.tearDown() }
        let rail = PromptRailNSView(hover: Self.makeHover(), onJump: { _ in })
        rail.frame = NSRect(x: 0, y: 0, width: 344, height: 600)
        host.contentView.addSubview(rail)
        rail.promptRail(entriesDidChange: Self.entries(5))

        #expect(rail.hitTest(NSPoint(x: 8, y: 300)) === rail, "a point on the rail column missed the rail")
        #expect(rail.hitTest(NSPoint(x: 100, y: 300)) == nil, "the overlay took a point meant for the transcript")

        #expect(rail.accessibilityFrame().width == PromptRailLayout.width,
                "the Prompts group spans \(rail.accessibilityFrame().width)pt, not the rail column")
        let buttons = try #require(rail.accessibilityChildren() as? [PromptRailAccessibilityButton])
        let widths = buttons.map { $0.accessibilityFrameInParentSpace().width }
        #expect(widths == Array(repeating: PromptRailLayout.width, count: 5))
    }

    /// `closeNow()` — the window resigning key, the app deactivating — forgets
    /// rail hover, and a pointer resting on the rail sends no new enter.
    @Test("a pointer moving over the rail reopens a lens closed under it")
    func railMoveReassertsHover() async throws {
        let clock = EventDrivenTestClock()
        let hover = Self.makeHover(clock: clock)
        let rail = PromptRailNSView(hover: hover, onJump: { _ in })
        rail.frame = NSRect(x: 0, y: 0, width: PromptRailLayout.width, height: 600)
        rail.promptRail(entriesDidChange: Self.entries(5))
        try await Self.openLens(hover, clock)
        hover.closeNow()
        try #require(!hover.isOpen)

        let move = try Self.mouseMoved(to: NSPoint(x: 8, y: 300))
        rail.mouseMoved(with: move)
        try await clock.requireAdvanceWhenArmed(by: Self.openDelay, timeout: Self.mainActorHop)
        await hover._drainForTesting()
        #expect(hover.isOpen, "a move over the rail did not reopen the lens")
    }

    /// The overlay reaches past the rail column, and its one tracking area
    /// with it; code keeps the rail's hover to the column. The point off the
    /// column lies past the open lens's box too, which would hold it open.
    @Test("a move off the rail column inside the overlay leaves the rail")
    func moveOffRailColumnLeavesRail() async throws {
        let clock = EventDrivenTestClock()
        let hover = Self.makeHover(clock: clock)
        let rail = PromptRailNSView(hover: hover, onJump: { _ in })
        rail.frame = NSRect(x: 0, y: 0, width: 344, height: 600)
        rail.promptRail(entriesDidChange: Self.entries(5))

        let onRail = try Self.mouseMoved(to: NSPoint(x: 8, y: 300))
        let offRail = try Self.mouseMoved(to: NSPoint(x: 340, y: 300))
        rail.mouseMoved(with: onRail)
        #expect(rail.isPointerOverRail)
        #expect(rail.pointedIndex != nil, "a move over the rail column pointed at no notch")
        try await clock.requireAdvanceWhenArmed(by: Self.openDelay, timeout: Self.mainActorHop)
        await hover._drainForTesting()
        try #require(hover.isOpen, "a move over the rail column did not open the lens")

        rail.mouseMoved(with: offRail)
        #expect(!rail.isPointerOverRail)
        #expect(rail.pointedIndex == nil, "a pointer off the rail column still points at a notch")
        try await clock.requireAdvanceWhenArmed(by: Self.closeGrace, timeout: Self.mainActorHop)
        await hover._drainForTesting()
        #expect(!hover.isOpen, "a pointer off the rail column kept the rail hovered")
    }

    // MARK: Container wiring

    @Test("the hover model opens the rail's lens, and the Escape monitor runs while it is shown")
    func lensShownStartsEscape() async throws {
        let clock = EventDrivenTestClock()
        let hover = Self.makeHover(clock: clock)
        let escape = EscapeTable()
        let mounted = Self.mount(hover: hover, escape: escape)
        defer { mounted.host.tearDown() }
        mounted.rail.promptRail(entriesDidChange: Self.entries(5))
        #expect(!mounted.rail.isLensShown)
        #expect(escape.live == 0)

        try await Self.openLens(hover, clock)
        #expect(mounted.rail.lensOpen, "the hover model's open did not reach the rail")
        #expect(mounted.rail.isLensShown)
        #expect(escape.live == 1, "the Escape monitor is not running while the lens is open")

        hover.dismiss(.escape)
        #expect(!mounted.rail.lensOpen)
        #expect(!mounted.rail.isLensShown)
        #expect(escape.live == 0, "the Escape monitor outlived the lens")
        #expect(escape.installs == 1)
    }

    /// The gutter exists with no prompts and the rail reports hover there
    /// too, so the hover model opens a lens with nothing to show. Nothing is
    /// on screen, so nothing may take Escape: the local monitor would swallow
    /// it for every view in the window, a terminal's interrupt included.
    @Test("an open lens with no prompts takes no Escape until a prompt puts it on screen")
    func emptyRailTakesNoEscape() async throws {
        let clock = EventDrivenTestClock()
        let hover = Self.makeHover(clock: clock)
        let escape = EscapeTable()
        let mounted = Self.mount(hover: hover, escape: escape)
        defer { mounted.host.tearDown() }

        try await Self.openLens(hover, clock)
        #expect(mounted.rail.lensOpen)
        #expect(!mounted.rail.isLensShown, "a lens with no prompts is on screen")
        #expect(escape.installs == 0, "a lens with no prompts installed the Escape monitor")
        #expect(escape.live == 0)

        // The first prompt arrives while the lens is open: it shows, and only
        // now takes Escape.
        mounted.rail.promptRail(entriesDidChange: Self.entries(1))
        #expect(mounted.rail.isLensShown, "the open lens stayed hidden after its first prompt arrived")
        #expect(escape.live == 1, "the lens showed without the Escape monitor")

        // Losing its last prompt takes it off screen and gives Escape back,
        // though the hover model still has it open.
        mounted.rail.promptRail(entriesDidChange: [])
        #expect(!mounted.rail.isLensShown)
        #expect(hover.isOpen)
        #expect(escape.live == 0, "the Escape monitor outlived the lens's last prompt")

        hover.closeNow()
        #expect(!mounted.rail.lensOpen)
        #expect(escape.installs == 1)
        #expect(escape.live == 0)
    }

    @Test("removing the container from its window closes the lens")
    func teardownClosesLens() async throws {
        let clock = EventDrivenTestClock()
        let hover = Self.makeHover(clock: clock)
        let escape = EscapeTable()
        let mounted = Self.mount(hover: hover, escape: escape)
        defer { mounted.host.tearDown() }
        mounted.rail.promptRail(entriesDidChange: Self.entries(5))
        try await Self.openLens(hover, clock)
        try #require(mounted.rail.isLensShown)

        mounted.container.removeFromSuperview()
        #expect(!hover.isOpen, "the hover model stayed open after its pane left the window")
        #expect(!mounted.rail.lensOpen)
        #expect(!mounted.rail.isLensShown)
        #expect(escape.live == 0, "the Escape monitor outlived the pane")
    }

    @Test("the window resigning key closes the lens")
    func resignKeyClosesLens() async throws {
        let clock = EventDrivenTestClock()
        let hover = Self.makeHover(clock: clock)
        let escape = EscapeTable()
        let center = NotificationCenter()
        let mounted = Self.mount(hover: hover, escape: escape, center: center)
        defer { mounted.host.tearDown() }
        mounted.rail.promptRail(entriesDidChange: Self.entries(5))
        try await Self.openLens(hover, clock)
        try #require(mounted.rail.isLensShown)

        center.post(name: NSWindow.didResignKeyNotification, object: mounted.host.window)
        #expect(!hover.isOpen, "the lens stayed open in a window that is no longer key")
        #expect(!mounted.rail.lensOpen)
        #expect(!mounted.rail.isLensShown)
        #expect(escape.live == 0, "the Escape monitor outlived the lens")
    }

    // MARK: Mounted through the table

    @Test("an AppKit mount lays the rail over the transcript as presenter and routes its jumps to the table")
    func appKitMountWiresRailAndJump() async throws {
        let suite = TestDefaultsSuite("prompt-rail-appkit")
        let defaults = suite.defaults
        defer { suite.tearDown() }
        let table = Self.table(appState: AppState(userDefaults: defaults))
        let host = OffscreenHost(root: table, size: NSSize(width: 680, height: 600))
        defer { host.tearDown() }

        let delivered = await host.settle {
            (host.firstDescendant(PromptRailNSView.self)?.entries.count ?? 0) == 3
        }
        try #require(delivered, "the rail never received the outline")
        let container = try #require(host.firstDescendant(TranscriptContainerView.self))
        let coordinator = try #require(container.coordinator, "the container has no coordinator")
        let rail = try #require(container.railView as? PromptRailNSView)

        #expect(coordinator.promptRailPresenter === rail)
        #expect(rail.entries == coordinator.promptEntries)
        #expect(rail.frame == NSRect(x: 0, y: 0, width: PromptRailLayout.width, height: 600))
        #expect(container.scrollView.frame.minX == PromptRailLayout.width)
        #expect(rail.displayedNotchRects.count == 3)
        #expect(container.subviews == [container.scrollView, rail])

        let buttons = try #require(rail.accessibilityChildren() as? [PromptRailAccessibilityButton])
        try #require(buttons.count == 3)
        #expect(buttons[1].accessibilityPerformPress())
        #expect(coordinator.heldJumpTargetID == "p-1", "the rail's jump did not reach the table")
    }

    // MARK: Helpers

    private static func entries(_ count: Int) -> [PromptOutlineEntry] {
        (0..<count).map { index in
            PromptOutlineEntry(
                id: "p-\(index)", rowIndex: index * 2, kind: .prompt,
                firstLine: "Prompt \(index)", excerpt: "Prompt \(index)", timestamp: nil)
        }
    }

    /// Within a thousandth of a point: pitches and lengths are fractional.
    private static func isClose(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) < 0.001
    }

    private static func isClose(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        isClose(lhs.minX, rhs.minX) && isClose(lhs.minY, rhs.minY)
            && isClose(lhs.width, rhs.width) && isClose(lhs.height, rhs.height)
    }

    /// The band of a rail `layout` lays out that notch `index` owns for its
    /// accessibility button, with no overflow offset: the rail column's
    /// width, one pitch tall, centred on the notch.
    private static func band(_ index: Int, _ layout: PromptRailLayout) -> NSRect {
        NSRect(
            x: 0, y: layout.notchCenterY(index) - layout.pitch / 2,
            width: PromptRailLayout.width, height: layout.pitch)
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

    /// A pointer move to `location`, in the window coordinates of a view with
    /// no window: its own, flipped about its height.
    private static func mouseMoved(to location: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    }

    /// Hovers the rail and fires the open timer.
    private static func openLens(_ hover: PromptRailHoverModel, _ clock: EventDrivenTestClock) async throws {
        hover.railHoverChanged(true)
        try await clock.requireAdvanceWhenArmed(by: openDelay, timeout: mainActorHop)
        await hover._drainForTesting()
        try #require(hover.isOpen, "the hover model did not open")
    }

    private struct Mounted {
        let host: OffscreenHost<EmptyView>
        let container: TranscriptContainerView
        let rail: PromptRailNSView
    }

    /// A 680×600 container in an offscreen window with the prompt rail
    /// installed, wired as `makeNSView` wires it but with the test's seams.
    private static func mount(
        hover: PromptRailHoverModel,
        escape: EscapeTable,
        center: NotificationCenter = NotificationCenter()
    ) -> Mounted {
        let host = OffscreenHost(root: EmptyView(), size: NSSize(width: 680, height: 600))
        let container = TranscriptContainerView(
            scrollView: NSScrollView(), leadingGutter: PromptRailLayout.width)
        container.frame = host.contentView.bounds
        host.contentView.addSubview(container)
        let rail = PromptRailNSView(hover: hover, onJump: { _ in }, usesDisplayLink: false)
        container.installPromptRail(
            rail: rail, hover: hover, escapeMonitor: escape.makeMonitor(), notificationCenter: center)
        container.layoutSubtreeIfNeeded()
        return Mounted(host: host, container: container, rail: rail)
    }

    /// A three-prompt table with the prompt rail mounted.
    private static func table(appState: AppState) -> TableTranscriptView {
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
            promptRail: .rail)
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
