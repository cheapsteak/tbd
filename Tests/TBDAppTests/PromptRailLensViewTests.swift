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
        #expect(mount.rail.frame.width == 338)
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

    /// The lens measures the pointer's speed from its moves' own times, not
    /// from frames. A move made a second after the last, while the frames
    /// were stopped, is measured over that second: 148pt in it is slow, and
    /// the first frame follows.
    @Test("a move after a pause in the frames is measured over the pause, and the first frame follows it")
    func moveAfterPausedFramesIsNoFlick() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)
        mount.frames(Self.wholeAnimation)
        try mount.move(to: NSPoint(x: Self.onRail.x, y: Self.onRail.y + 2))
        mount.frame()
        try #require(!mount.rail.isRunningFrames, "precondition: the open lens settled")
        let opened = try #require(mount.rail.lens).centre

        mount.wait(1)
        try mount.move(to: NSPoint(x: Self.onRail.x, y: Self.onRail.y + 150))
        try #require(mount.rail.isRunningFrames, "precondition: a move over the open lens asked for a frame")
        mount.frame()
        let lens = try #require(mount.rail.lens)
        #expect(lens.speed <= PromptRailSteadyLens.flickSpeed,
                "a move a second after the last read as a flick, at \(lens.speed)pt/ms")
        #expect(lens.centre > opened + 1, "the first frame left the lens at \(lens.centre), from \(opened)")
    }

    /// A flick that starts while the frames are stopped freezes the lens on
    /// the first frame after it. The lens settles and its frames stop; a
    /// second later the pointer moves 1pt, and 10ms after that 99pt on, past
    /// the dead zone. The same move made a second after the 1pt one is slow,
    /// and the first frame follows it.
    @Test("a flick that starts while the frames are stopped freezes the lens on the first frame")
    func flickWhileFramesStoppedFreezes() async throws {
        func push(after gap: TimeInterval) async throws -> (opened: CGFloat, lens: PromptRailSteadyLens) {
            let mount = LensMount()
            defer { mount.host.tearDown() }
            try await Self.openLens(mount)
            mount.frames(Self.wholeAnimation)
            try mount.move(to: NSPoint(x: Self.onRail.x, y: Self.onRail.y + 1))
            mount.frame()
            try #require(!mount.rail.isRunningFrames, "precondition: the open lens settled")
            let opened = try #require(mount.rail.lens).centre

            mount.wait(1)
            try mount.move(to: NSPoint(x: Self.onRail.x, y: Self.onRail.y + 2))
            mount.wait(gap)
            try mount.move(to: NSPoint(x: Self.onRail.x, y: Self.onRail.y + 101))
            mount.frame()
            let lens = try #require(mount.rail.lens)
            return (opened, lens)
        }
        let flick = try await push(after: 0.010)
        #expect(flick.lens.centre == flick.opened,
                "the first frame after a flick moved the lens from \(flick.opened) to \(flick.lens.centre)")
        #expect(flick.lens.speed > PromptRailSteadyLens.flickSpeed,
                "99pt in 10ms read as \(flick.lens.speed)pt/ms")

        let slow = try await push(after: 1)
        #expect(slow.lens.speed <= PromptRailSteadyLens.flickSpeed, "99pt in 1s read as \(slow.lens.speed)pt/ms")
        #expect(slow.lens.centre > slow.opened,
                "the first frame after the same move, made slowly, left the lens at \(slow.lens.centre)")
    }

    /// Where the pointer went while it was off the rail column and the box
    /// was no move over the rail. Back 150pt lower 60ms after it left, before
    /// the close grace ends, it is no flick, though 150pt in 60ms would be.
    @Test("a pointer that comes back after leaving the rail and the box is no flick")
    func returnAfterLeavingIsNoFlick() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)
        mount.frames(Self.wholeAnimation)
        try mount.move(to: NSPoint(x: Self.onRail.x, y: Self.onRail.y + 1))
        mount.frame()
        let opened = try #require(mount.rail.lens).centre

        try mount.move(to: Self.offLens)
        mount.wait(0.06)
        try mount.move(to: NSPoint(x: Self.onRail.x, y: Self.onRail.y + 150))
        try #require(mount.hover.isOpen && mount.rail.lensOpen, "precondition: the lens is still open")
        mount.frame()
        let lens = try #require(mount.rail.lens)
        #expect(lens.speed <= PromptRailSteadyLens.flickSpeed,
                "the pointer's return read as a flick, at \(lens.speed)pt/ms")
        #expect(lens.centre > opened + 1, "the first frame left the lens at \(lens.centre), from \(opened)")
    }

    /// The display link exists only while frames run: once the lens settles
    /// it is released, and the next movement makes a new one. The rail has a
    /// real link here, and the test runs without suspending, so the link
    /// never fires.
    @Test("the display link is released once the lens settles, and the next movement makes a new one")
    func frameLinkReleasedWhenSettled() throws {
        let mount = LensMount(usesDisplayLink: true)
        defer { mount.host.tearDown() }
        #expect(mount.rail.lensState.frameLink == nil, "a rail with no lens holds a display link")

        mount.rail.lensOpenChanged(true)
        let opening = try #require(mount.rail.lensState.frameLink, "an opening lens made no display link")
        mount.frames(Self.wholeAnimation)
        try #require(mount.rail.openFraction == 1, "precondition: the lens opened")
        #expect(!mount.rail.isRunningFrames)
        #expect(mount.rail.lensState.frameLink == nil, "the settled lens kept its display link")

        mount.rail.lensPointerMoved()
        let moving = try #require(mount.rail.lensState.frameLink, "a move over the settled lens made no display link")
        #expect(moving !== opening, "the next run of frames reused the released link")
        mount.frame()
        #expect(mount.rail.lensState.frameLink == nil, "the link outlived the frame that settled the lens")
    }

    /// A frame on which no row moves changes only the hovered row, and
    /// redraws only its fill, where it was and where it is. The pointer moves
    /// a row down inside the dead zone: the hover follows it, and the rows
    /// and the box stay. The redraw covers the fill `drawHoverFill` draws, a
    /// point in from each side of the box over the row's text band, and
    /// reaches a point past the box at most.
    @Test("a frame on which no row moves changes only the hovered row, and redraws only its fill")
    func stillFrameMovesOnlyTheHover() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)
        mount.frames(Self.wholeAnimation)
        let rows = mount.rail.displayedRows
        let box = try #require(mount.rail.boxRect, "the open lens has no box")
        let hovered = try #require(mount.rail.hoveredRow, "precondition: the open lens hovers the row under the pointer")
        let next = hovered + 1
        try #require(rows.heights.indices.contains(next))

        try mount.move(to: NSPoint(x: Self.onRail.x, y: rows.tops[next] + rows.heights[next] / 2))
        mount.frame()
        #expect(mount.rail.hoveredRow == next, "the hover stayed on row \(String(describing: mount.rail.hoveredRow))")
        #expect(mount.rail.displayedRows == rows, "a move inside the dead zone moved the rows")
        #expect(mount.rail.boxRect == box, "a move inside the dead zone moved the box")

        let width = mount.rail.lensState.shape.width
        let band = PromptRailLensPainter.textBand(row: next, in: rows)
        let fill = CGRect(x: 1, y: band.minY, width: width - 2, height: band.height)
        let rect = PromptRailNSView.hoverRedrawRect(row: next, in: rows, width: width)
        #expect(rect.contains(fill), "the redraw \(rect) misses the fill \(fill)")
        #expect(rect.maxX <= width + 1, "the redraw \(rect) reaches past the box, \(width) wide")
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

    /// The box is as wide as the widest row it shows. While the pointer is
    /// over it, though, it never narrows: moving through rows with shorter
    /// titles must not leave the pointer outside it, which would close the
    /// lens. One long title, on the row the lens opens on, makes the box 320pt
    /// wide; every other title is a few letters.
    @Test("the box never narrows under the pointer, and fits its rows again once the pointer leaves it")
    func boxHoldsWidthUnderPointer() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        let long = PromptRailLayout(count: 40, railHeight: 601).index(atRailY: Self.onRail.y, offset: 0) ?? 0
        let entries = (0..<40).map { index in
            PromptOutlineEntry(
                id: "p-\(index)", rowIndex: index * 2, kind: .prompt,
                firstLine: index == long ? String(repeating: "A long prompt title ", count: 6) : "P\(index)",
                timestamp: nil)
        }
        mount.rail.promptRail(entriesDidChange: entries)
        try await Self.openLens(mount)
        mount.frames(Self.wholeAnimation)
        let opened = try #require(mount.rail.boxRect, "the open lens has no box")
        try #require(opened.width > 300, "precondition: the long title widens the box, to \(opened.width)")

        var narrowest = opened.width
        func settle() {
            var frames = 0
            while mount.rail.isRunningFrames, frames < 1200 {
                mount.frame()
                narrowest = min(narrowest, mount.rail.boxRect?.width ?? 0)
                frames += 1
            }
        }
        // Into the box, past where any short title reaches, then down it in
        // 10pt steps: the lens follows, and the long title's row shrinks.
        var pointer = NSPoint(x: 250, y: Self.onRail.y)
        try mount.move(to: pointer)
        settle()
        try #require(mount.rail.lensState.isPointerOverBox, "precondition: \(pointer) is over the box")
        var moves = 0
        while mount.rail.lensState.shape.textRows?.contains(long) == true, moves < 20 {
            pointer.y += 10
            try mount.move(to: pointer)
            settle()
            moves += 1
        }
        let longShows = mount.rail.lensState.shape.textRows?.contains(long) == true
        try #require(!longShows, "precondition: the long title still shows after \(moves) moves")
        #expect(narrowest >= opened.width - 0.01,
                "the box narrowed from \(opened.width) to \(narrowest) under the pointer")
        #expect(mount.rail.lensState.isPointerOverBox, "the pointer at \(pointer) fell outside the box")
        let armedClose = await watchForSleeper(on: mount.clock)
        #expect(!armedClose, "the lens started to close under a pointer on its box")
        #expect(mount.hover.isOpen)

        // Back onto the rail column: the box fits its short rows again.
        try mount.move(to: NSPoint(x: Self.onRail.x, y: pointer.y))
        settle()
        let fitted = mount.rail.boxRect?.width ?? PromptRailLayout.width
        #expect(fitted < 200, "the box stayed \(fitted) wide after the pointer left it")
    }

    /// Only a move over the rail column or the box, or one that changes
    /// which the pointer is over, can move the lens or its hovered row.
    @Test("a move across the overlay off the rail column and the box asks for no frame")
    func moveOffRailAndBoxAsksNoFrame() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)
        mount.frames(Self.wholeAnimation)
        let box = try #require(mount.rail.boxRect, "the open lens has no box")
        let past = NSPoint(x: box.maxX + 4, y: box.midY)
        try #require(past.x + 8 < mount.rail.frame.width, "precondition: \(past) lies inside the overlay")

        // Leaving the rail column changes the hover: a frame clears the
        // hovered row.
        try mount.move(to: past)
        #expect(mount.rail.isRunningFrames, "leaving the rail column asked for no frame")
        var frames = 0
        while mount.rail.isRunningFrames, frames < 1200 {
            mount.frame()
            frames += 1
        }
        #expect(mount.rail.hoveredRow == nil)
        try #require(!mount.rail.isRunningFrames, "precondition: the frames stopped, after \(frames)")

        try mount.move(to: NSPoint(x: past.x + 4, y: past.y + 20))
        #expect(!mount.rail.isRunningFrames, "a move off the rail column and the box asked for a frame")
    }

    /// The overlays above the rail hide while the lens shows. The container
    /// reports the lens coming and going, and the table's coordinator writes
    /// each report to the pane's `PromptLensVisibility` a main-queue turn
    /// later, outside any SwiftUI update.
    @Test("the lens coming and going reaches the pane's visibility object through the container and the coordinator")
    func lensShownReachesPane() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        let coordinator = TableTranscriptView.Coordinator(context: TranscriptCardContext(
            terminalID: nil, openTranscriptOverlay: nil, appState: nil, linkResolver: nil, onLinkClicked: nil))
        defer { withExtendedLifetime(coordinator) {} }
        let visibility = PromptLensVisibility()
        coordinator.promptLensVisibility = visibility
        coordinator.observePromptLensShown(of: mount.container)

        try await Self.openLens(mount)
        await drainMainQueue()
        #expect(visibility.isShown, "the open never reached the pane")

        mount.hover.dismiss(.escape)
        #expect(visibility.isShown, "the close reached the pane inside the change rather than a turn later")
        await drainMainQueue()
        #expect(!visibility.isShown, "the close never reached the pane")
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

    /// Reopening while the lens shrinks builds it afresh, as an open does:
    /// at the pointer where it is now, not where the shrinking lens was. The
    /// grow goes on from the open fraction the shrink reached, so the box
    /// does not pop.
    @Test("reopening while the lens shrinks builds it afresh at the pointer, growing on from where the shrink was")
    func reopenWhileShrinkingRebuilds() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        let layout = PromptRailLayout(count: 40, railHeight: 601)
        try await Self.openLens(mount, at: NSPoint(x: Self.onRail.x, y: layout.notchCenterY(5)))
        mount.frames(Self.wholeAnimation)
        let opened = try #require(mount.rail.lens).centre

        mount.rail.lensOpenChanged(false)
        mount.frames(8)
        let partWay = mount.rail.openFraction
        try #require(mount.rail.lens != nil, "precondition: the lens is still shrinking")
        try #require(partWay > 0 && partWay < 1, "precondition: the lens is \(partWay) open part way through shrinking")

        let notch30 = NSPoint(x: Self.onRail.x, y: layout.notchCenterY(30))
        try mount.move(to: notch30)
        mount.rail.lensOpenChanged(true)
        let lens = try #require(mount.rail.lens, "the reopen left no lens")
        let fresh = PromptRailSteadyLens(geometry: mount.rail.currentLensGeometry(), pointerY: notch30.y)
        try #require(abs(fresh.centre - opened) > 10,
                     "precondition: notch 30's opening centre \(fresh.centre) lies far from notch 5's lens, at \(opened)")
        #expect(abs(lens.centre - fresh.centre) < 1e-9,
                "the reopened lens is centred on \(lens.centre), not on notch 30's opening centre \(fresh.centre)")
        #expect(mount.rail.openFraction == partWay,
                "the reopen moved the open fraction from \(partWay) to \(mount.rail.openFraction)")
        mount.frame()
        #expect(mount.rail.openFraction > partWay, "the reopened lens did not grow on from \(partWay)")
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

    @Test("once the lens starts to close, its shrinking box takes no clicks, and the rail column still does")
    func closingBoxTakesNoClicks() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)
        mount.frames(Self.wholeAnimation)
        let box = try #require(mount.rail.boxRect, "the open lens has no box")
        let inside = NSPoint(x: (PromptRailLayout.width + box.maxX) / 2, y: box.midY)
        try #require(mount.rail.hitTest(inside) === mount.rail, "precondition: the open box takes clicks")

        mount.hover.dismiss(.escape)
        mount.frame()
        let shrinking = try #require(mount.rail.boxRect, "the box went with the close's first frame")
        try #require(mount.rail.openFraction > 0 && shrinking.contains(inside),
                     "precondition: \(inside) is over the shrinking box \(shrinking)")
        #expect(mount.rail.hitTest(inside) == nil, "the shrinking box took a click")
        #expect(mount.rail.clickRow(at: inside) == nil, "a click on the shrinking box found a row")
        #expect(mount.rail.hitTest(Self.onRail) === mount.rail, "the rail column stopped taking clicks")
    }

    /// A short session's column ends well above the rail's bottom: two
    /// prompts in a 601pt rail rest from 12pt to 196pt. A pointer below the
    /// last row points at no row, however far the rows would clamp it.
    @Test("a pointer on the rail below the last row hovers no row, and a click there jumps nowhere")
    func pointerPastColumnPointsAtNoRow() async throws {
        let mount = LensMount(entryCount: 2)
        defer { mount.host.tearDown() }
        let layout = PromptRailLayout(count: 2, railHeight: 601)
        let end = PromptRailLayout.topInset + 2 * layout.pitch
        let below = NSPoint(x: Self.onRail.x, y: 500)
        try #require(below.y > end + 100, "precondition: y \(below.y) lies well below the column's end, \(end)")
        try await Self.openLens(mount, at: NSPoint(x: Self.onRail.x, y: end - layout.pitch / 2))
        mount.frames(Self.wholeAnimation)
        try #require(mount.rail.hoveredRow == 1, "precondition: the pointer on the last row hovers it")

        try mount.move(to: below)
        var frames = 0
        while mount.rail.isRunningFrames, frames < 1200 {
            mount.frame()
            frames += 1
        }
        #expect(mount.hover.isOpen, "a pointer on the rail column below the rows closed the lens")
        #expect(mount.rail.hoveredRow == nil,
                "a pointer below the column hovers row \(String(describing: mount.rail.hoveredRow))")
        #expect(mount.rail.clickRow(at: below) == nil, "a click below the column found a row")
        try mount.click(at: below)
        #expect(mount.jumps.ids.isEmpty, "a click below the column jumped to \(mount.jumps.ids)")
    }

    @Test("a click on the bare rail below the last notch jumps nowhere, and one on the notch's band jumps to it")
    func bareRailClickPastColumn() throws {
        let mount = LensMount(entryCount: 2)
        defer { mount.host.tearDown() }
        let layout = PromptRailLayout(count: 2, railHeight: 601)
        let end = PromptRailLayout.topInset + 2 * layout.pitch
        let below = NSPoint(x: Self.onRail.x, y: 500)
        try #require(below.y > end + 100, "precondition: y \(below.y) lies well below the column's end, \(end)")

        try mount.click(at: below)
        #expect(mount.jumps.ids.isEmpty, "a click below the bare rail's column jumped to \(mount.jumps.ids)")
        try mount.click(at: NSPoint(x: Self.onRail.x, y: end - layout.pitch / 2))
        #expect(mount.jumps.ids == ["p-1"], "a click on the last notch's band jumped to \(mount.jumps.ids)")
    }

    /// A few-prompts rail draws each row's text, its hover fill and its
    /// share of the box in a band the peak's height, centred on a row far
    /// taller (lens spec, "Drawing"). Only that band points at the row:
    /// between two bands the pointer hovers no row and a click jumps nowhere.
    @Test("on a few-prompts rail a row is pointed at only within its text band")
    func fewPromptsPointWithinBand() async throws {
        let mount = LensMount(entryCount: 3)
        defer { mount.host.tearDown() }
        let layout = PromptRailLayout(count: 3, railHeight: 601)
        try await Self.openLens(mount, at: NSPoint(x: Self.onRail.x, y: layout.notchCenterY(1)))
        mount.frames(Self.wholeAnimation)
        let rows = mount.rail.displayedRows
        try #require(rows.heights.count == 3, "precondition: three rows, not \(rows.heights.count)")
        try #require(rows.heights[1] > PromptRailLayout.lensPeak + 20,
                     "precondition: three prompts rest far taller than the peak, at \(rows.heights)")
        #expect(mount.rail.hoveredRow == 1,
                "the pointer opened on row 1's band hovers row \(String(describing: mount.rail.hoveredRow))")

        // Where rows 0 and 1 meet, above row 1's band and below row 0's.
        let band = PromptRailLensPainter.textBand(row: 1, in: rows)
        let gap = NSPoint(x: Self.onRail.x, y: rows.tops[1])
        try #require(gap.y < band.minY - 10, "precondition: y \(gap.y) lies well above row 1's band, at \(band.minY)")
        try mount.move(to: gap)
        mount.frame()
        #expect(mount.hover.isOpen, "a pointer between the bands closed the lens")
        #expect(mount.rail.hoveredRow == nil,
                "a pointer between the bands hovers row \(String(describing: mount.rail.hoveredRow))")
        #expect(mount.rail.clickRow(at: gap) == nil, "a click between the bands found a row")
        try mount.click(at: gap)
        #expect(mount.jumps.ids.isEmpty, "a click between the bands jumped to \(mount.jumps.ids)")

        let centre = NSPoint(x: Self.onRail.x, y: band.midY)
        try mount.move(to: centre)
        mount.frame()
        #expect(mount.rail.hoveredRow == 1,
                "the pointer on row 1's band hovers row \(String(describing: mount.rail.hoveredRow))")
        #expect(mount.rail.clickRow(at: centre) == 1, "a click on row 1's band found no row 1")
    }

    /// A lens that keeps the resting rows never follows the pointer, so a
    /// flick over it keeps no frames running once its frame has passed. The
    /// same flick over a lens that follows keeps them running, for the lens
    /// may have to follow once the pointer slows.
    @Test("a flick keeps frames running over a lens that follows, and not over one that keeps the resting rows")
    func flickOverRestingLensStopsFrames() async throws {
        func flick(prompts: Int) async throws -> (keepsRestingRows: Bool, speed: CGFloat, running: Bool) {
            let mount = LensMount(entryCount: prompts)
            defer { mount.host.tearDown() }
            try await Self.openLens(mount)
            mount.frames(Self.wholeAnimation)
            try mount.move(to: NSPoint(x: Self.onRail.x, y: Self.onRail.y + 1))
            mount.wait(0.010)
            try mount.move(to: NSPoint(x: Self.onRail.x, y: Self.onRail.y + 61))
            mount.frame()
            let lens = try #require(mount.rail.lens)
            return (lens.geometry.keepsRestingRows, lens.speed, mount.rail.isRunningFrames)
        }
        let few = try await flick(prompts: 3)
        try #require(few.keepsRestingRows, "precondition: three prompts keep the resting rows")
        try #require(few.speed > PromptRailSteadyLens.flickSpeed, "precondition: 60pt in 10ms read as \(few.speed)pt/ms")
        #expect(!few.running, "a flick over a lens that never follows kept the frames running")

        let many = try await flick(prompts: 40)
        try #require(!many.keepsRestingRows, "precondition: forty prompts' lens follows the pointer")
        try #require(many.speed > PromptRailSteadyLens.flickSpeed, "precondition: 60pt in 10ms read as \(many.speed)pt/ms")
        #expect(many.running, "a flick over a lens that follows stopped the frames")
    }

    /// The press keeps the pressed prompt's id, so prompts arriving above it
    /// before the release, which hand its row to another prompt, still let
    /// the click jump to the prompt pressed.
    @Test("an outline change between press and release jumps to the pressed prompt")
    func pressSurvivesOutlineChange() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)
        mount.frames(Self.wholeAnimation)
        let row = try #require(mount.rail.displayedRows.index(atY: Self.onRail.y))

        try mount.press(at: Self.onRail)
        let prepended = (0..<3).map { "n-\($0)" } + (0..<40).map { "p-\($0)" }
        mount.rail.promptRail(entriesDidChange: Self.entries(ids: prepended))
        try mount.release(at: Self.onRail)
        #expect(mount.jumps.ids == ["p-\(row)"], "a press on p-\(row) jumped to \(mount.jumps.ids)")
    }

    @Test("a press whose prompt leaves the outline before the release jumps nowhere")
    func pressOnRemovedPromptJumpsNowhere() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)
        mount.frames(Self.wholeAnimation)

        try mount.press(at: Self.onRail)
        mount.rail.promptRail(entriesDidChange: Self.entries(ids: (0..<40).map { "q-\($0)" }))
        try mount.release(at: Self.onRail)
        #expect(mount.jumps.ids.isEmpty, "a press on a prompt now gone jumped to \(mount.jumps.ids)")
    }

    /// A step of an existing lens redraws only what can change: the rail
    /// column and the box before and after the step, each widened for the
    /// taper and the shadow. AppKit offers no readback of the dirty rect, so
    /// this checks the helper that picks it.
    @Test("a lens step redraws the rail column and the box before and after it, widened for taper and shadow")
    func lensRedrawRectCoversColumnAndBoxes() {
        let column = NSRect(x: 0, y: 0, width: PromptRailLayout.width, height: 601)
        let outset = PromptRailRowMetrics.boxDrawingOutset
        #expect(outset >= PromptRailRowMetrics.boxTaper + PromptRailRowMetrics.boxShadowRadius + 2)
        let bare = PromptRailNSView.lensRedrawRect(railColumn: column, previousBox: nil, box: nil)
        #expect(bare == column, "a step with no box redraws \(bare)")

        let before = CGRect(x: 0, y: 100, width: 200, height: 80)
        let after = CGRect(x: 0, y: 140, width: 120, height: 60)
        let rect = PromptRailNSView.lensRedrawRect(railColumn: column, previousBox: before, box: after)
        #expect(rect.contains(column), "the redraw \(rect) misses the rail column")
        #expect(rect.contains(before.insetBy(dx: -outset, dy: -outset)), "the redraw \(rect) misses the old box")
        #expect(rect.contains(after.insetBy(dx: -outset, dy: -outset)), "the redraw \(rect) misses the new box")
        #expect(abs(rect.maxX - (before.maxX + outset)) < 0.001,
                "the redraw \(rect) reaches past the widest box's drawing, to \(rect.maxX)")
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

        // The pointer on the row's middle, inside its band, so it hovers it.
        let one = LensMount(entryCount: 1)
        defer { one.host.tearDown() }
        let oneLayout = PromptRailLayout(count: 1, railHeight: 601)
        try await Self.openLens(one, at: NSPoint(x: Self.onRail.x, y: oneLayout.notchCenterY(0)))
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

    /// A rebase can leave the lens off its target for a still pointer, so an
    /// open lens asks for a frame, which steps it there.
    @Test("a new prompt under a settled open lens asks for a frame, with no pointer move")
    func rebaseAsksForFrame() async throws {
        let mount = LensMount()
        defer { mount.host.tearDown() }
        try await Self.openLens(mount)
        mount.frames(Self.wholeAnimation)
        try mount.move(to: NSPoint(x: Self.onRail.x, y: Self.onRail.y + 2))
        mount.frame()
        try #require(!mount.rail.isRunningFrames, "precondition: the open lens settled")

        mount.rail.promptRail(entriesDidChange: Self.entries(41))
        #expect(mount.rail.lens?.geometry.count == 41, "the lens did not move onto the new column")
        #expect(mount.rail.isRunningFrames, "a rebase under a still pointer asked for no frame")
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
        #expect(narrow.rail.frame.width == 54)
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
    /// One prompt per id, in order, with no timestamps.
    fileprivate static func entries(ids: [String]) -> [PromptOutlineEntry] {
        ids.enumerated().map { index, id in
            PromptOutlineEntry(id: id, rowIndex: index * 2, kind: .prompt, firstLine: "Prompt \(id)", timestamp: nil)
        }
    }

    fileprivate static func entries(_ count: Int) -> [PromptOutlineEntry] {
        (0..<count).map { index in
            PromptOutlineEntry(
                id: "p-\(index)", rowIndex: index * 2, kind: .prompt,
                firstLine: "Prompt \(index)",
                timestamp: index.isMultiple(of: 2) ? Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60) : nil)
        }
    }

    /// Moves the pointer onto the rail column, at `point`, and fires the
    /// open timer: the lens exists, not yet grown.
    private static func openLens(_ mount: LensMount, at point: NSPoint = PromptRailLensViewTests.onRail) async throws {
        try mount.move(to: point)
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
/// no display link unless asked for, a Reduce Motion switch, and one time
/// that both frames and pointer events are stamped with.
@MainActor
private final class LensMount {
    let host: OffscreenHost<EmptyView>
    let container: TranscriptContainerView
    let rail: PromptRailNSView
    let hover: PromptRailHoverModel
    let clock: EventDrivenTestClock
    let center: NotificationCenter
    let jumps: LensJumpRecorder
    /// The time frames and pointer events are stamped with, in seconds.
    /// Each frame moves it on 1/120s, and `wait(_:)` moves it on with no
    /// frame.
    private(set) var now: TimeInterval = 0

    init(width: CGFloat = 400, entryCount: Int = 40, reduceMotion: Bool = false, usesDisplayLink: Bool = false) {
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
            usesDisplayLink: usesDisplayLink)
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

    /// One frame, 1/120s on.
    func frame() {
        now += 1.0 / 120
        rail.advanceFrame(to: now)
    }

    /// `seconds` pass with no frame: the frames are stopped, or the next one
    /// has not come yet.
    func wait(_ seconds: TimeInterval) {
        now += seconds
    }

    func frames(_ count: Int) {
        for _ in 0..<count { frame() }
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        let pressed = type != .mouseMoved
        return try #require(NSEvent.mouseEvent(
            with: type, location: rail.convert(point, to: nil), modifierFlags: [], timestamp: now,
            windowNumber: host.window.windowNumber, context: nil, eventNumber: 0,
            clickCount: pressed ? 1 : 0, pressure: pressed ? 1 : 0))
    }
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
