import AppKit
import SwiftUI
import Testing
@testable import TBDApp
import TestSupport

// Tier 1 apart from the offscreen window every case mounts. Hover reaches the
// hover model through synthesized mouse events, its timers run on
// `EventDrivenTestClock`, and frames are driven by hand through
// `advanceFrame(to:)`: the rail is built with no display link, so no live
// frame can land while a test awaits.

/// The prompt rail's lens on screen: when it opens and how it grows and
/// shrinks, the frames that drive it, the box that keeps it open and takes
/// clicks, jumps, and how it follows the outline, the rail's height, the
/// window and the pane's width while it exists.
@MainActor
@Suite("Prompt rail lens view", .clockDriven)
struct PromptRailLensViewTests {
    /// The hover model's timers are main-actor tasks; see the `timeout` note
    /// on `EventDrivenTestClock.sleeperArmed`.
    private static let mainActorHop = TestDeadlines.saturatedPass
    private static let openDelay = Duration.milliseconds(80)
    private static let closeGrace = Duration.milliseconds(100)
    /// A point on the rail column, mid-column.
    private static let onRail = NSPoint(x: 8, y: 170)
    /// A point past the overlay's widest, over the transcript.
    private static let offLens = NSPoint(x: 390, y: 170)
    /// Frames that carry a whole grow or shrink: the first counts 1/60s and
    /// the other sixteen 1/120s each, 0.15s in all.
    private static let wholeAnimation = 17

    // MARK: Opening

    @Test("no lens before the 80ms open delay has passed")
    func noLensBefore80ms() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }

        try mount.move(to: Self.onRail)
        try await mount.clock.requireAdvanceWhenArmed(by: .milliseconds(79), timeout: Self.mainActorHop)
        #expect(!mount.hover.isOpen)
        #expect(mount.rail.lens == nil, "a lens grew before the open delay passed")
        #expect(mount.rail.openFraction == 0)
        #expect(mount.rail.boxRect == nil)
        #expect(mount.rail.frame.width == PromptRailLayout.width, "the overlay widened with no lens")
    }

    @Test("the lens starts to grow once the 80ms open delay has passed, in an overlay wide enough for its box")
    func lensAfter80ms() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }

        try await Self.openLens(mount)
        #expect(mount.rail.lens != nil)
        #expect(mount.rail.openFraction == 0, "the lens grew before any frame")
        #expect(mount.rail.isRunningFrames, "an opening lens wants no frames")
        #expect(mount.rail.boxMaxWidth == PromptRailRowMetrics.boxMaxWidth(paneWidth: 400))
        #expect(mount.rail.frame.width == PromptRailRowMetrics.openOverlayWidth(paneWidth: 400))
        #expect(mount.rail.frame.width == 332)
        #expect(mount.rail.frame.height == 601)
    }

    @Test("the lens grows over 150ms, easing out")
    func growsOver150msEaseOut() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)

        // 75ms in: 1 − (1 − 0.5)³ = 0.875.
        mount.frames(8)
        let halfway = mount.rail.openFraction
        #expect((0.8...0.95).contains(halfway), "75ms in, the lens is \(halfway) open")
        #expect(mount.rail.isRunningFrames)
        try Self.drawOnce(mount.rail)

        mount.frames(9)
        #expect(mount.rail.openFraction == 1, "150ms in, the lens is \(mount.rail.openFraction) open")
        #expect(!mount.rail.isRunningFrames, "an open, settled lens still wants frames")
        #expect(mount.rail.boxRect != nil, "the open lens has no box")
        #expect(mount.rail.hoveredRow != nil, "the row under the pointer is not hovered")
        try Self.drawOnce(mount.rail)
    }

    @Test("with Reduce Motion the lens opens and closes at once")
    func reduceMotionIsInstant() async throws {
        let mount = LensMount(reduceMotion: true)
        defer { mount.host.tearDown() }

        try await Self.openLens(mount)
        #expect(mount.rail.openFraction == 1, "with Reduce Motion the lens opened \(mount.rail.openFraction) of the way")
        #expect(!mount.rail.isRunningFrames, "an instant open still wants frames")
        #expect(mount.rail.boxRect != nil)

        try mount.move(to: Self.offLens)
        try await mount.clock.requireAdvanceWhenArmed(by: Self.closeGrace, timeout: Self.mainActorHop)
        await mount.hover._drainForTesting()
        #expect(!mount.hover.isOpen)
        #expect(mount.rail.lens == nil, "with Reduce Motion the lens did not close at once")
        #expect(mount.rail.openFraction == 0)
        #expect(!mount.rail.isRunningFrames)
        #expect(mount.rail.frame.width == PromptRailLayout.width)
    }

    @Test("both ends of the column hold still on every frame while the lens opens")
    func endsHoldWhileOpening() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)
        let lens = try #require(mount.rail.lens)
        let top = PromptRailLayout.topInset
        let bottom = top + lens.geometry.columnHeight
        try #require(!lens.geometry.keepsRestingRows, "precondition: 40 prompts open a lens that moves rows")

        var checked = 0
        for _ in 0...Self.wholeAnimation {
            let rows = mount.rail.displayedRows
            let first = try #require(rows.tops.first)
            let last = try #require(rows.tops.last) + (rows.heights.last ?? 0)
            let fraction = mount.rail.openFraction
            #expect(abs(first - top) <= 0.5, "at \(fraction) open the column starts at \(first), not \(top)")
            #expect(abs(last - bottom) <= 0.5, "at \(fraction) open the column ends at \(last), not \(bottom)")
            checked += 1
            mount.frame()
        }
        #expect(checked == Self.wholeAnimation + 1)
        #expect(mount.rail.openFraction == 1)
    }

    // MARK: Hover and closing

    @Test("the pointer over the box keeps the lens open, and leaving both closes it")
    func boxCountsAsHover() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)
        mount.frames(Self.wholeAnimation)
        let box = try #require(mount.rail.boxRect, "the open lens has no box")
        let overBox = NSPoint(x: (PromptRailLayout.width + box.maxX) / 2, y: Self.onRail.y)
        try #require(overBox.x > PromptRailLayout.width && box.contains(overBox),
                     "precondition: \(overBox) is off the rail column and inside the box \(box)")

        try mount.move(to: overBox)
        #expect(!mount.rail.isPointerOverRail)
        let armedClose = await watchForSleeper(on: mount.clock)
        #expect(!armedClose, "leaving the rail column for the box started the close grace")
        await mount.clock.advance(by: .milliseconds(300))
        await mount.hover._drainForTesting()
        #expect(mount.hover.isOpen, "the lens closed under a pointer on its box")
        #expect(mount.rail.lens != nil)

        try mount.move(to: Self.offLens)
        try await mount.clock.requireAdvanceWhenArmed(by: Self.closeGrace, timeout: Self.mainActorHop)
        await mount.hover._drainForTesting()
        #expect(!mount.hover.isOpen, "the lens stayed open with the pointer off both the rail and the box")
        #expect(mount.rail.lens != nil, "the lens vanished rather than shrinking")
        #expect(mount.rail.isRunningFrames, "a shrinking lens wants no frames")

        mount.frames(4)
        #expect(mount.rail.openFraction > 0 && mount.rail.openFraction < 1,
                "the lens is \(mount.rail.openFraction) open part way through shrinking")
        mount.frames(Self.wholeAnimation - 4)
        #expect(mount.rail.lens == nil, "the lens had not closed 150ms after it started shrinking")
        #expect(mount.rail.openFraction == 0)
        #expect(!mount.rail.isRunningFrames, "a closed lens still wants frames")
        #expect(mount.rail.boxRect == nil)
        #expect(mount.rail.frame.width == PromptRailLayout.width, "the overlay stayed wide after the lens closed")
    }

    @Test("the frames stop once the lens has opened, and once it has followed the pointer and settled")
    func framesStopWhenSettled() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)
        mount.frames(Self.wholeAnimation)
        try #require(!mount.rail.isRunningFrames, "precondition: the open lens settled")
        let opened = try #require(mount.rail.lens).centre

        // A move asks for a frame; one inside the dead zone moves nothing,
        // and the frames stop after it.
        try mount.move(to: NSPoint(x: Self.onRail.x, y: Self.onRail.y + 2))
        #expect(mount.rail.isRunningFrames, "a move over the open lens asked for no frame")
        mount.frame()
        #expect(!mount.rail.isRunningFrames, "a move inside the dead zone kept the frames running")
        let held = try #require(mount.rail.lens).centre
        #expect(held == opened, "a move inside the dead zone moved the lens from \(opened) to \(held)")

        // A push far down the column: the lens follows, then settles.
        try mount.move(to: NSPoint(x: Self.onRail.x, y: 300))
        var frames = 0
        while mount.rail.isRunningFrames && frames < 1200 {
            mount.frame()
            frames += 1
        }
        #expect(!mount.rail.isRunningFrames, "the lens never settled after \(frames) frames")
        let followed = try #require(mount.rail.lens).centre
        #expect(followed > opened + 1, "the lens stayed at \(followed) after a push from \(opened)")
    }

    /// The frames pause once the lens settles, and the lens's last pointer
    /// height is where it settled. A move made then must not read, on the
    /// first frame after, as a flick from there.
    @Test("a pointer that moved while the frames were paused is no flick: the first frame follows it")
    func pausedFramesResumeWithoutFlick() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)
        mount.frames(Self.wholeAnimation)
        try #require(!mount.rail.isRunningFrames, "precondition: the open lens settled")
        let opened = try #require(mount.rail.lens).centre

        try mount.move(to: NSPoint(x: Self.onRail.x, y: Self.onRail.y + 150))
        try #require(mount.rail.isRunningFrames, "precondition: a move over the open lens asked for a frame")
        mount.frame()
        let lens = try #require(mount.rail.lens)
        #expect(lens.speed <= PromptRailSteadyLens.flickSpeed,
                "the move made while the frames were paused read as a flick, at \(lens.speed)pt/ms")
        #expect(lens.centre > opened + 1, "the first frame left the lens at \(lens.centre), from \(opened)")
    }

    @Test("the pointer leaving the overlay takes the hovered row's fill away at once")
    func exitClearsHoveredRow() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)
        mount.frames(Self.wholeAnimation)
        try #require(mount.rail.hoveredRow != nil, "precondition: the open lens hovers the row under the pointer")

        // What `mouseExited(with:)` does for the overlay's own tracking area.
        mount.rail.pointerExitedOverlay()
        #expect(mount.rail.hoveredRow == nil, "the hovered row's fill outlived the pointer")
        #expect(!mount.rail.isPointerOverRail)
        try await mount.clock.requireAdvanceWhenArmed(by: Self.closeGrace, timeout: Self.mainActorHop)
        await mount.hover._drainForTesting()
        #expect(!mount.hover.isOpen, "the lens stayed open after the pointer left the overlay")
    }

    /// The live pane hides its jump-to-latest button while the lens shows.
    /// The container reports the lens coming and going, and the table's
    /// coordinator passes each report up to the pane a main-queue turn later,
    /// outside any SwiftUI update.
    @Test("the lens coming and going reaches the pane through the container and the table's coordinator")
    func lensShownReachesPane() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        let coordinator = TableTranscriptView.Coordinator(context: TranscriptCardContext(
            terminalID: nil, openTranscriptOverlay: nil, appState: nil, linkResolver: nil, onLinkClicked: nil))
        defer { withExtendedLifetime(coordinator) {} }
        let reports = LensShownRecorder()
        coordinator.onPromptLensShownChange = { shown in reports.values.append(shown) }
        coordinator.observePromptLensShown(of: mount.container)

        try await Self.openLens(mount)
        await drainMainQueue()
        #expect(reports.values == [true], "the open reached the pane as \(reports.values)")

        mount.hover.dismiss(.escape)
        #expect(reports.values == [true], "the close reached the pane inside the change rather than a turn later")
        await drainMainQueue()
        #expect(reports.values == [true, false], "the close reached the pane as \(reports.values)")
    }

    @Test("an empty rail grows no lens, and an open lens appears with the first prompt and goes with the last")
    func emptyOutlineNoLens() async throws {
        let mount = LensMount(entryCount: 0)
        defer { mount.host.tearDown() }

        try mount.move(to: Self.onRail)
        try await mount.clock.requireAdvanceWhenArmed(by: Self.openDelay, timeout: Self.mainActorHop)
        await mount.hover._drainForTesting()
        #expect(mount.hover.isOpen)
        #expect(mount.rail.lens == nil, "an empty rail grew a lens")
        #expect(mount.rail.boxRect == nil)
        #expect(!mount.rail.isRunningFrames)
        #expect(mount.rail.frame.width == PromptRailLayout.width)

        mount.rail.promptRail(entriesDidChange: Self.entries(5))
        #expect(mount.rail.lens != nil, "the open lens did not grow with its first prompts")

        mount.rail.promptRail(entriesDidChange: [])
        #expect(mount.rail.lens == nil, "the lens outlived its last prompt")
        #expect(mount.rail.openFraction == 0)
        #expect(!mount.rail.isRunningFrames)
        #expect(mount.rail.frame.width == PromptRailLayout.width)
    }

    @Test("the window resigning key shrinks the lens away and stops the frames")
    func resignKeyStopsFrames() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)
        mount.frames(6)
        let grown = mount.rail.openFraction
        try #require(grown > 0 && grown < 1, "precondition: the lens is part way open, at \(grown)")

        mount.center.post(name: NSWindow.didResignKeyNotification, object: mount.host.window)
        #expect(!mount.hover.isOpen)
        #expect(mount.rail.isRunningFrames, "the lens stopped where it was rather than shrinking")
        mount.frames(Self.wholeAnimation)
        #expect(mount.rail.lens == nil)
        #expect(!mount.rail.isRunningFrames, "frames ran on after the lens closed")
        #expect(mount.rail.frame.width == PromptRailLayout.width)
    }

    // MARK: Clicks and hit-testing

    @Test("a click on a row of the open lens jumps to it and closes the lens, which grows again only after the pointer leaves the rail")
    func clickRowJumps() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)
        mount.frames(Self.wholeAnimation)
        let row = try #require(mount.rail.displayedRows.index(atY: Self.onRail.y))

        try mount.click(at: Self.onRail)
        #expect(mount.jumps.ids == ["p-\(row)"])
        #expect(!mount.hover.isOpen, "the click left the lens open")
        #expect(!mount.rail.lensOpen)

        // Still on the rail: no new lens.
        try mount.move(to: Self.onRail)
        let armedOpen = await watchForSleeper(on: mount.clock)
        #expect(!armedOpen, "the lens started to grow again under the pointer that clicked it")
        mount.frames(Self.wholeAnimation)
        #expect(mount.rail.lens == nil)

        // Off the rail and back on: it grows.
        try mount.move(to: Self.offLens)
        try await Self.openLens(mount)
        #expect(mount.rail.lens != nil)
    }

    @Test("a click on the box's text jumps to the row it lands on")
    func clickInBoxTextJumps() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)
        mount.frames(Self.wholeAnimation)
        let box = try #require(mount.rail.boxRect)
        let point = NSPoint(x: (PromptRailLayout.width + box.maxX) / 2, y: Self.onRail.y)
        let row = try #require(mount.rail.displayedRows.index(atY: point.y))

        try mount.click(at: point)
        #expect(mount.jumps.ids == ["p-\(row)"])
        #expect(!mount.hover.isOpen)
    }

    @Test("a click on a notch of the bare rail jumps to it")
    func clickBareRailJumps() throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        let layout = PromptRailLayout(count: 40, railHeight: 601)
        try #require(mount.rail.offset == 0, "precondition: 40 prompts fit the rail")

        try mount.click(at: NSPoint(x: 8, y: layout.notchCenterY(5)))
        #expect(mount.jumps.ids == ["p-5"])
        #expect(mount.rail.lens == nil)
    }

    /// The rows move under a still pointer while the lens grows, so the row
    /// under a mouse-up can differ from the row its mouse-down pressed.
    @Test("a click whose row moves away under it while the lens grows still jumps to the row it pressed")
    func clickDuringGrowJumpsToPressedRow() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)
        mount.frames(2)
        let grown = mount.rail.openFraction
        try #require(grown > 0 && grown < 1, "precondition: the lens is part way open, at \(grown)")
        let point = NSPoint(x: Self.onRail.x, y: 230)
        let pressed = try #require(mount.rail.displayedRows.index(atY: point.y))

        try mount.press(at: point)
        mount.frames(Self.wholeAnimation)
        let under = try #require(mount.rail.displayedRows.index(atY: point.y))
        try #require(under != pressed, "precondition: the grow moved row \(pressed) from under the pointer")
        try mount.release(at: point)
        #expect(mount.jumps.ids == ["p-\(pressed)"], "the click jumped to \(mount.jumps.ids), not row \(pressed)")
        #expect(!mount.hover.isOpen)
    }

    @Test("the overlay answers over the rail column and the open box, and nowhere else")
    func hitTestFollowsBox() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        #expect(mount.rail.hitTest(NSPoint(x: 200, y: 170)) == nil, "the closed rail took a point on the transcript")
        #expect(mount.rail.hitTest(Self.onRail) === mount.rail)

        try await Self.openLens(mount)
        mount.frames(Self.wholeAnimation)
        let box = try #require(mount.rail.boxRect)
        let inside = NSPoint(x: (PromptRailLayout.width + box.maxX) / 2, y: box.midY)
        let past = NSPoint(x: box.maxX + 10, y: box.midY)
        try #require(past.x < mount.rail.frame.width, "precondition: \(past) lies inside the overlay")
        #expect(mount.rail.hitTest(inside) === mount.rail, "the box let a click through to the transcript")
        #expect(mount.rail.hitTest(past) == nil, "the overlay took a point past the box")
        #expect(mount.rail.hitTest(NSPoint(x: inside.x, y: box.maxY + 20)) == nil,
                "the overlay took a point below the box")
    }

    @Test("the wheel over the box scrolls the transcript")
    func wheelOverBoxScrollsTranscript() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)
        mount.frames(Self.wholeAnimation)
        let box = try #require(mount.rail.boxRect)
        let inside = NSPoint(x: (PromptRailLayout.width + box.maxX) / 2, y: box.midY)
        #expect(mount.rail.wheelTarget === mount.container.scrollView)
        let recorder = LensWheelRecorder()
        mount.rail.wheelTarget = recorder
        let cgEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -10, wheel2: 0, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: cgEvent))

        let target = try #require(mount.rail.hitTest(inside), "the box let the wheel through")
        target.scrollWheel(with: event)
        #expect(recorder.events == 1)
    }

    // MARK: Drawing

    /// A few-prompts rail rests its rows far taller than the peak. Each row
    /// draws its text, its hover fill and its share of the box in a band the
    /// peak's height, centred on it, so the box hugs the text.
    @Test("on a rail of one or two prompts the box hugs each row's 26pt text band, not the whole row")
    func fewPromptsBoxHugsText() async throws {
        let peak = PromptRailLayout.lensPeak
        let padding = PromptRailRowMetrics.boxPadding

        let one = LensMount(entryCount: 1)
        defer { one.host.tearDown() }
        try await Self.openLens(one)
        one.frames(Self.wholeAnimation)
        let single = one.rail.displayedRows
        try #require(single.heights.count == 1 && single.heights[0] > peak,
                     "precondition: one prompt rests taller than the peak, at \(single.heights)")
        let oneBox = try #require(one.rail.boxRect, "the open lens has no box")
        #expect(oneBox.height <= peak + 2 * padding + 0.5, "one prompt's box is \(oneBox.height)pt tall")
        let middle = single.tops[0] + single.heights[0] / 2
        #expect(abs(oneBox.midY - middle) <= 0.01, "the box's middle is at \(oneBox.midY), the row's at \(middle)")
        #expect(one.rail.hoveredRow == 0)
        try Self.drawOnce(one.rail)

        let two = LensMount(entryCount: 2)
        defer { two.host.tearDown() }
        try await Self.openLens(two)
        two.frames(Self.wholeAnimation)
        let rows = two.rail.displayedRows
        let tall = rows.heights.allSatisfy { $0 > peak }
        try #require(rows.heights.count == 2 && tall, "precondition: two prompts rest taller than the peak")
        let box = try #require(two.rail.boxRect, "the open lens has no box")
        let firstBandTop = rows.tops[0] + (rows.heights[0] - peak) / 2
        let lastBandBottom = rows.tops[1] + (rows.heights[1] + peak) / 2
        #expect(abs(box.minY - (firstBandTop - padding)) <= 0.01,
                "the box starts at \(box.minY), not 3pt above the first band at \(firstBandTop)")
        #expect(abs(box.maxY - (lastBandBottom + padding)) <= 0.01,
                "the box ends at \(box.maxY), not 3pt below the last band at \(lastBandBottom)")
        try Self.drawOnce(two.rail)
    }

    /// The resting rail fades a clipped end with a mask on its own layer.
    /// While a lens exists that mask would fade the box and its text too, so
    /// it comes off and the painter fades the notches alone.
    @Test("a lens on a sliding rail fades its notches without the layer mask, which returns once the lens closes")
    func lensFadesWithoutLayerMask() async throws {
        let mount = LensMount(entryCount: 450)
        defer { mount.host.tearDown() }
        #expect(mount.rail.hasFadeMask, "the windowed resting rail has no fade")

        try await Self.openLens(mount)
        let lens = try #require(mount.rail.lens)
        try #require(lens.geometry.slidesPastFloor, "precondition: 450 prompts slide in a 601pt rail")
        mount.frames(Self.wholeAnimation)
        #expect(mount.rail.openFraction == 1)
        #expect(!mount.rail.hasFadeMask, "the open lens kept the layer mask, which fades its box")
        let fade = mount.rail.lensState.fade
        #expect(fade.top || fade.bottom, "the open lens's rows run past an end, but no notch fades")
        try Self.drawOnce(mount.rail)

        mount.hover.dismiss(.escape)
        mount.frames(Self.wholeAnimation)
        #expect(mount.rail.lens == nil, "the lens had not closed")
        #expect(mount.rail.hasFadeMask, "the resting rail's fade did not come back")
    }

    /// With no lens, the notches are all the rail draws, so a change to them
    /// redraws the rail column alone, however wide the overlay is; while a
    /// lens exists, the whole overlay.
    @Test("a change to the notches redraws the rail column alone while no lens exists, and the whole overlay while one does")
    func notchRedrawStaysInColumn() async throws {
        let wide = PromptRailNSView(
            hover: PromptRailHoverModel(notificationCenter: NotificationCenter(), clock: EventDrivenTestClock()),
            onJump: { _ in }, usesDisplayLink: false)
        wide.frame = NSRect(x: 0, y: 0, width: 344, height: 601)
        let column = NSRect(x: 0, y: 0, width: PromptRailLayout.width, height: 601)
        #expect(wide.railColumnRect == column)
        wide.promptRail(entriesDidChange: Self.entries(40))
        #expect(wide.notchRedrawRect == column, "an outline change redraws \(wide.notchRedrawRect)")
        wide.promptRail(activeIndexDidChange: 3)
        #expect(wide.notchRedrawRect == column, "an active change redraws \(wide.notchRedrawRect)")
        wide.promptRail(workCountsDidChange: Array(repeating: 2, count: 40))
        #expect(wide.notchRedrawRect == column, "a work change redraws \(wide.notchRedrawRect)")

        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)
        #expect(mount.rail.bounds.width > PromptRailLayout.width)
        #expect(mount.rail.notchRedrawRect == mount.rail.bounds, "with a lens, a change redraws \(mount.rail.notchRedrawRect)")
    }

    // MARK: Live changes

    /// The table's jump makes the clicked prompt active before the lens
    /// shrinks, which on a windowed rail moves the resting offset. The shrink
    /// must end on the rail at that new offset, not jump to it.
    @Test("a click that scrolls a windowed rail shrinks the lens onto the new window, with no jump when it drops")
    func clickOnWindowedRailClosesWithoutJump() async throws {
        let mount = LensMount(entryCount: 300)
        defer { mount.host.tearDown() }
        mount.rail.promptRail(activeIndexDidChange: 2)
        try #require(mount.rail.offset == 0, "precondition: the window starts at the top")
        mount.jumps.then = { [weak rail = mount.rail] id in
            guard let index = Int(id.dropFirst(2)) else { return }
            rail?.promptRail(activeIndexDidChange: index)
        }
        try await Self.openLens(mount)
        mount.frames(Self.wholeAnimation)
        let lens = try #require(mount.rail.lens)
        try #require(lens.geometry.restOverflows, "precondition: 300 prompts window the rail")

        let target = NSPoint(x: Self.onRail.x, y: 580)
        let row = try #require(mount.rail.displayedRows.index(atY: target.y))
        let layout = PromptRailLayout(count: 300, railHeight: 601)
        try #require(layout.notchCenterY(row) > 601 - PromptRailLayout.edgeMargin,
                     "precondition: row \(row) lies below the window at offset 0")
        let openRows = mount.rail.displayedRows

        try mount.click(at: target)
        try #require(mount.jumps.ids == ["p-\(row)"])
        try #require(mount.rail.activeIndex == row)
        #expect(mount.rail.offset > 0, "the jump left the window at the top")
        #expect(mount.rail.displayedRows == openRows, "the active prompt's move shifted the open lens's rows")

        var before: [CGRect] = []
        var frames = 0
        while mount.rail.lens != nil && frames < 60 {
            before = mount.rail.displayedNotchRects
            mount.frame()
            frames += 1
        }
        try #require(mount.rail.lens == nil, "the lens had not dropped after \(frames) frames")
        let after = mount.rail.displayedNotchRects
        try #require(before.count == 300 && after.count == 300)

        var jumped: [Int] = []
        var visible = 0
        for index in after.indices where after[index].maxY > 0 && after[index].minY < 601 {
            visible += 1
            let was = before[index]
            let now = after[index]
            if abs(was.midY - now.midY) > 0.5 || abs(was.height - now.height) > 0.5
                || abs(was.minX - now.minX) > 0.5 || abs(was.width - now.width) > 0.5 {
                jumped.append(index)
            }
        }
        #expect(visible > 100, "only \(visible) notches are visible on the resting rail")
        #expect(jumped.isEmpty, "\(jumped.count) notches jumped as the lens dropped, from row \(jumped.first ?? -1)")

        // The window followed the jump: the new active notch rests on the
        // rail, not past its end.
        let active = after[row]
        #expect(active.minY >= 0 && active.maxY <= 601, "the new active notch rests at \(active), out of view")
    }

    /// The overflow offset moves under an open lens with the active prompt.
    /// That alone must not re-anchor the lens; a real column change rebases
    /// it at the offset the rail has now.
    @Test("a moved overflow offset leaves an open lens's rows alone, and a later rebase anchors at the current offset")
    func movedOffsetDoesNotReanchorLens() async throws {
        let mount = LensMount(entryCount: 300)
        defer { mount.host.tearDown() }
        mount.rail.promptRail(activeIndexDidChange: 2)
        try await Self.openLens(mount)
        mount.frames(Self.wholeAnimation)
        let opened = try #require(mount.rail.lens)
        let openRows = mount.rail.displayedRows

        mount.rail.promptRail(activeIndexDidChange: 250)
        try #require(mount.rail.offset > 0, "precondition: the active prompt's move scrolled the window")
        #expect(mount.rail.displayedRows == openRows)

        // The same outline again: same column, so no rebase.
        mount.rail.promptRail(entriesDidChange: Self.entries(300))
        let kept = try #require(mount.rail.lens)
        #expect(kept.anchor == opened.anchor, "an outline of the same size re-anchored the lens on the moved offset")
        #expect(mount.rail.displayedRows == openRows, "an outline of the same size moved the open lens's rows")

        // One more prompt: a new column, rebased at the current offset.
        mount.rail.promptRail(entriesDidChange: Self.entries(301))
        let rebased = try #require(mount.rail.lens)
        #expect(rebased.geometry.count == 301)
        #expect(rebased.geometry.restOffset == mount.rail.offset,
                "the rebase anchored at offset \(rebased.geometry.restOffset), not the rail's \(mount.rail.offset)")
    }

    @Test("a new outline under an open lens keeps its centre, clamped to the new count")
    func outlineChangeWhileOpen() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)
        mount.frames(Self.wholeAnimation)
        let centre = try #require(mount.rail.lens).centre
        try #require(centre > 5, "precondition: the lens opened past row 5, at \(centre)")

        mount.rail.promptRail(entriesDidChange: Self.entries(41))
        let grown = try #require(mount.rail.lens, "a new prompt closed the lens")
        #expect(grown.geometry.count == 41)
        #expect(abs(grown.centre - centre) < 0.01, "the centre moved from \(centre) to \(grown.centre)")
        #expect(mount.rail.displayedRows.heights.count == 41)

        mount.rail.promptRail(entriesDidChange: Self.entries(5))
        let shrunk = try #require(mount.rail.lens)
        #expect(shrunk.centre <= 5, "the centre \(shrunk.centre) lies past the last of 5 rows")
        #expect(mount.rail.displayedRows.heights.count == 5)
        try Self.drawOnce(mount.rail)
    }

    @Test("a rail height change under an open lens moves it onto the new column")
    func resizeWhileOpenRebases() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)
        mount.frames(Self.wholeAnimation)
        let centre = try #require(mount.rail.lens).centre

        mount.container.frame = NSRect(x: 0, y: 0, width: 400, height: 401)
        mount.container.layoutSubtreeIfNeeded()
        #expect(mount.rail.frame.height == 401)
        let lens = try #require(mount.rail.lens, "the resize closed the lens")
        #expect(lens.geometry.railHeight == 401, "the lens kept the old rail's height")
        #expect(abs(lens.centre - centre) < 0.01)
        let rows = mount.rail.displayedRows
        let first = try #require(rows.tops.first)
        let end = try #require(rows.tops.last) + (rows.heights.last ?? 0)
        #expect(abs(first - PromptRailLayout.topInset) <= 0.5, "the column starts at \(first), not the top inset")
        #expect(end <= 401 - PromptRailLayout.bottomInset + 0.5, "the column runs past the shorter rail, to \(end)")
    }

    @Test("a narrow pane caps the box at its width less 24pt, and a pane too narrow for one shows none")
    func narrowPaneCapsBox() async throws {
        let narrow = LensMount(width: 60)
        defer { narrow.host.tearDown() }
        try await Self.openLens(narrow)
        narrow.frames(Self.wholeAnimation)
        #expect(narrow.rail.boxMaxWidth == 36)
        #expect(narrow.rail.frame.width == 48)
        let box = try #require(narrow.rail.boxRect)
        #expect(box.width <= 36, "the box is \(box.width) wide in a 60pt pane")
        try Self.drawOnce(narrow.rail)

        let sliver = LensMount(width: 30)
        defer { sliver.host.tearDown() }
        try await Self.openLens(sliver)
        sliver.frames(Self.wholeAnimation)
        #expect(sliver.rail.boxMaxWidth == PromptRailLayout.width)
        #expect(sliver.rail.frame.width == 30)
        #expect(sliver.rail.boxRect == nil, "a 30pt pane drew a box")
        try Self.drawOnce(sliver.rail)
    }

    /// Natural widths are measured for rows tall enough to start widening,
    /// once each, and kept while the lens moves.
    @Test("the box measures each widening row's natural width once")
    func widthCacheMeasuresOnce() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)
        mount.frames(Self.wholeAnimation)
        let rows = mount.rail.displayedRows
        var widening = 0
        for height in rows.heights where height > PromptRailRowMetrics.widthRevealStart { widening += 1 }
        let measured = mount.rail.lensPainter.measuredWidths
        #expect(measured > 0, "the open lens measured no row")
        #expect(measured < 40, "the lens measured all \(measured) rows, not only the widening ones")
        #expect(measured >= widening, "\(widening) rows widen but only \(measured) were measured")

        try mount.move(to: NSPoint(x: Self.onRail.x, y: Self.onRail.y + 2))
        mount.frames(3)
        #expect(mount.rail.lensPainter.measuredWidths == measured, "frames re-measured rows already measured")
    }

    @Test("a row's text fades in from 10.5pt tall to 13pt")
    func textOpacityRule() {
        typealias Metrics = PromptRailRowMetrics
        #expect(Metrics.textOpacity(rowHeight: 8) == 0)
        #expect(Metrics.textOpacity(rowHeight: 10.5) == 0)
        #expect(abs(Metrics.textOpacity(rowHeight: 11.5) - 0.4) < 0.0001)
        #expect(Metrics.textOpacity(rowHeight: 13) == 1)
        #expect(Metrics.textOpacity(rowHeight: 26) == 1)
    }

    // MARK: Helpers

    /// `count` prompts, every other one stamped, so rows carry a time column.
    fileprivate static func entries(_ count: Int) -> [PromptOutlineEntry] {
        (0..<count).map { index in
            PromptOutlineEntry(
                id: "p-\(index)", rowIndex: index * 2, kind: .prompt,
                firstLine: "Prompt \(index)",
                timestamp: index.isMultiple(of: 2) ? Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60) : nil)
        }
    }

    /// Moves the pointer onto the rail column and fires the open timer: the
    /// lens exists, not yet grown.
    private static func openLens(_ mount: LensMount) async throws {
        try mount.move(to: onRail)
        try await mount.clock.requireAdvanceWhenArmed(by: openDelay, timeout: mainActorHop)
        await mount.hover._drainForTesting()
        try #require(mount.hover.isOpen, "the hover model did not open")
        try #require(mount.rail.lens != nil, "the open grew no lens")
    }

    /// Runs `draw(_:)` once, into a bitmap: the offscreen host's own display
    /// pass draws nothing.
    private static func drawOnce(_ view: NSView) throws {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
    }
}

/// A 400×601 (or `width`) transcript container in an offscreen window, the
/// rail installed as `makeNSView` installs it but with the test's seams: an
/// event-driven clock, a private notification center, a fake Escape monitor,
/// no display link, and a Reduce Motion switch.
@MainActor
private final class LensMount {
    let host: OffscreenHost<EmptyView>
    let container: TranscriptContainerView
    let rail: PromptRailNSView
    let hover: PromptRailHoverModel
    let clock: EventDrivenTestClock
    let center: NotificationCenter
    let jumps: LensJumpRecorder
    /// The last frame's timestamp.
    private var frameTime: TimeInterval = 0

    init(width: CGFloat = 400, entryCount: Int = 40, reduceMotion: Bool = false) {
        let clock = EventDrivenTestClock()
        let center = NotificationCenter()
        let jumps = LensJumpRecorder()
        let host = OffscreenHost(root: EmptyView(), size: NSSize(width: width, height: 601))
        let container = TranscriptContainerView(
            scrollView: NSScrollView(), leadingGutter: PromptRailLayout.width)
        container.frame = host.contentView.bounds
        host.contentView.addSubview(container)
        let hover = PromptRailHoverModel(notificationCenter: center, clock: clock)
        let rail = PromptRailNSView(
            hover: hover,
            onJump: { id in
                jumps.ids.append(id)
                jumps.then?(id)
            },
            reduceMotion: { reduceMotion },
            usesDisplayLink: false)
        container.installPromptRail(
            rail: rail, hover: hover,
            escapeMonitor: PromptRailEscapeMonitor(install: { _ in NSObject() }, remove: { _ in }),
            notificationCenter: center)
        container.layoutSubtreeIfNeeded()
        rail.promptRail(entriesDidChange: PromptRailLensViewTests.entries(entryCount))
        self.clock = clock
        self.center = center
        self.jumps = jumps
        self.host = host
        self.container = container
        self.hover = hover
        self.rail = rail
    }

    /// The pointer moves to `point`, in rail coordinates.
    func move(to point: NSPoint) throws {
        rail.mouseMoved(with: try event(.mouseMoved, at: point))
    }

    /// A press and release at `point`, in rail coordinates.
    func click(at point: NSPoint) throws {
        try press(at: point)
        try release(at: point)
    }

    /// A mouse-down at `point`, in rail coordinates.
    func press(at point: NSPoint) throws {
        rail.mouseDown(with: try event(.leftMouseDown, at: point))
    }

    /// A mouse-up at `point`, in rail coordinates.
    func release(at point: NSPoint) throws {
        rail.mouseUp(with: try event(.leftMouseUp, at: point))
    }

    /// One frame, 1/120s after the last.
    func frame() {
        frameTime += 1.0 / 120
        rail.advanceFrame(to: frameTime)
    }

    func frames(_ count: Int) {
        for _ in 0..<count { frame() }
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        let pressed = type != .mouseMoved
        return try #require(NSEvent.mouseEvent(
            with: type, location: rail.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: host.window.windowNumber, context: nil, eventNumber: 0,
            clickCount: pressed ? 1 : 0, pressure: pressed ? 1 : 0))
    }
}

/// The lens-shown reports a coordinator passes up, in order.
@MainActor
private final class LensShownRecorder {
    var values: [Bool] = []
}

@MainActor
private final class LensJumpRecorder {
    var ids: [String] = []
    /// Runs after each jump is recorded, inside the jump, as the table's
    /// jump runs before the rail dismisses its lens.
    var then: (@MainActor (String) -> Void)?
}

/// Counts wheel events handed to it.
private final class LensWheelRecorder: NSView {
    private(set) var events = 0
    override func scrollWheel(with event: NSEvent) { events += 1 }
}
