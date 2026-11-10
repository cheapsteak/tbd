import AppKit
import Foundation
import Metal
import QuartzCore
@testable import TBDGhosttyTerminal
import TestSupport
import Testing

/// Slots of a ring taken as frames the GPU still holds, given back when a test says.
///
/// Every slot must be given back before the ring goes: a `DispatchSemaphore` freed below its
/// starting value traps, so a test that takes them calls `releaseAll()` in a `defer`.
@MainActor
final class HeldRingSlots {
    let ring: FrameRing
    private(set) var held = 0

    /// Takes every slot of a fresh ring and puts the ring on `surface`, as the renderer would on
    /// a first encode.
    init(on surface: TerminalSurface) {
        ring = FrameRing()
        surface.frameRing = ring
        for _ in 0..<FrameRing.depth {
            guard ring.tryAcquire() != nil else { break }
            ring.commit()
            held += 1
        }
    }

    /// Gives one slot back, as a command buffer's completion handler would.
    func releaseOne() {
        guard held > 0 else { return }
        ring.releaser.release()
        held -= 1
    }

    /// Hands one slot's release to the caller, who must call it.
    func handOff() -> FrameRing.Releaser {
        held -= 1
        return ring.releaser
    }

    func releaseAll() {
        while held > 0 { releaseOne() }
    }
}

/// `FrameRing.tryAcquire()` and `hasFreeSlot`, which let a display tick drop a frame the GPU
/// cannot take instead of blocking main.
@Suite(.fastPassBounded)
struct FrameRingTryAcquireTests {
    /// Three slots, then nil. Nothing here gives a slot back, so a `tryAcquire()` that waited
    /// would hang the test. A release frees one, and `hasFreeSlot` follows the commits, the
    /// release, and a slot taken but not yet committed.
    @Test func tryAcquireGivesThreeSlotsThenNilAndHasFreeSlotFollows() {
        let ring = FrameRing()
        var committed = 0
        defer { for _ in 0..<committed { ring.releaser.release() } }

        for index in 0..<FrameRing.depth {
            let free = ring.hasFreeSlot
            #expect(free, "with \(index) slots in flight the ring reports no free slot")
            guard ring.tryAcquire() != nil else {
                Issue.record("a ring with \(index) slots in flight refused a slot")
                return
            }
            ring.commit()
            committed += 1
        }
        let freeWhenFull = ring.hasFreeSlot
        #expect(!freeWhenFull, "with every slot in flight the ring reports a free slot")
        let refused = ring.tryAcquire()
        #expect(refused == nil, "a ring with every slot in flight handed out a slot")

        ring.releaser.release()
        committed -= 1
        let freeAfterRelease = ring.hasFreeSlot
        #expect(freeAfterRelease, "a slot given back by its completion handler is not free")
        let taken = ring.tryAcquire()
        #expect(taken != nil, "the slot given back could not be taken")
        let freeWhileTaken = ring.hasFreeSlot
        #expect(!freeWhileTaken, "a slot taken and not yet committed still counts as free")

        // A frame that bails gives its slot back unused.
        ring.release()
        let freeAfterBail = ring.hasFreeSlot
        #expect(freeAfterBail, "a slot given back by a frame that bailed is not free")
    }
}

/// `DrawableTracker`: the drawables a view's layer handed out that Metal has not reported
/// presented, and its recovery from lost reports, evidence first and time last.
@Suite(.fastPassBounded)
struct DrawableTrackerTests {
    @Test func acquiringAddsAnEntryAndItsReportRemovesIt() {
        let tracker = DrawableTracker()
        let id = tracker.add(acquiredAt: .seconds(100))
        let afterAdd = tracker.awaitingPresent(now: .seconds(100.25))
        #expect(afterAdd == 1, "an acquired drawable counted as \(afterAdd) awaiting")

        tracker.reportPresented(id, presentedTime: 100.5)
        let afterReport = tracker.awaitingPresent(now: .seconds(100.5))
        #expect(afterReport == 0, "a reported drawable still counts: \(afterReport) awaiting")
    }

    /// The drop path and the presented handler can both run for one drawable. Removal is by id,
    /// so whichever runs second finds nothing and takes no other entry with it.
    @Test func theDropPathAndTheReportTogetherRemoveAnEntryOnce() {
        // Dropped, then reported.
        let tracker = DrawableTracker()
        _ = tracker.add(acquiredAt: .seconds(100))
        let dropped = tracker.add(acquiredAt: .seconds(100.25))
        tracker.remove(dropped)
        let afterDrop = tracker.entryCount
        #expect(afterDrop == 1, "dropping one of two drawables left \(afterDrop)")
        tracker.reportPresented(dropped, presentedTime: 0)
        let afterLateReport = tracker.entryCount
        #expect(afterLateReport == 1, "a report for a dropped drawable took another entry: \(afterLateReport) left")

        // Reported, then dropped.
        let other = DrawableTracker()
        _ = other.add(acquiredAt: .seconds(100))
        let reported = other.add(acquiredAt: .seconds(100.25))
        _ = other.add(acquiredAt: .seconds(100.5))
        other.reportPresented(reported, presentedTime: 100.75)
        let afterReport = other.entryCount
        #expect(afterReport == 1, "a report for the second of three drawables left \(afterReport)")
        other.remove(reported)
        let afterLateDrop = other.entryCount
        #expect(afterLateDrop == 1, "dropping a reported drawable took another entry: \(afterLateDrop) left")
    }

    /// A layer's presents reach the screen in order, so a report for one drawable is a report
    /// for every older one. One lost report clears at the next.
    @Test func aReportRemovesEveryOlderEntryAndNoNewerOne() {
        let tracker = DrawableTracker()
        _ = tracker.add(acquiredAt: .seconds(100))
        let middle = tracker.add(acquiredAt: .seconds(100.25))
        let newest = tracker.add(acquiredAt: .seconds(100.5))

        tracker.reportPresented(middle, presentedTime: 100.75)
        let afterMiddle = tracker.entryCount
        #expect(afterMiddle == 1, "a report for the middle of three drawables left \(afterMiddle)")
        tracker.reportPresented(newest, presentedTime: 101)
        let afterNewest = tracker.entryCount
        #expect(afterNewest == 0, "the newest drawable's report left \(afterNewest): it was not the one kept")
    }

    /// An old entry is not proof that its drawable is free, so time clears nothing until a
    /// whole `presentReportTimeout` has passed, however long ago the last report came.
    @Test func entriesYoungerThanTheTimeoutStayHoweverLongReportsAreDelayed() {
        let tracker = DrawableTracker()
        let early = tracker.add(acquiredAt: .seconds(10))
        tracker.reportPresented(early, presentedTime: 10.25)
        _ = tracker.awaitingPresent(now: .seconds(10.5))

        _ = tracker.add(acquiredAt: .seconds(100))
        _ = tracker.add(acquiredAt: .seconds(100.25))
        for now in [100.5, 100.75, 100.9375] {
            let awaiting = tracker.awaitingPresent(now: .seconds(now))
            #expect(awaiting == 2, "at \(now) s, drawables acquired at 100 s counted \(awaiting)")
        }
        let clears = tracker.timeoutClears
        #expect(clears == 0, "entries younger than the timeout were cleared \(clears) times")
    }

    /// A report that came after the oldest entry was acquired starts the wait again.
    @Test func aReportAfterTheOldestEntryHoldsOffTheClear() {
        let tracker = DrawableTracker()
        let late = tracker.add(acquiredAt: .seconds(99.75))
        _ = tracker.add(acquiredAt: .seconds(100))
        _ = tracker.add(acquiredAt: .seconds(100.25))
        // The first drawable is reported presented at 100.5 s, after the other two were acquired.
        tracker.reportPresented(late, presentedTime: 100.5)
        let seen = tracker.awaitingPresent(now: .seconds(100.5))
        #expect(seen == 2, "the late report left \(seen) awaiting")

        let soonAfter = tracker.awaitingPresent(now: .seconds(101.25))
        #expect(soonAfter == 2, "0.75 s after a report the entries were cleared: \(soonAfter) awaiting")
        let aTimeoutAfter = tracker.awaitingPresent(now: .seconds(101.5))
        #expect(aTimeoutAfter == 0, "a timeout after the last report the entries stayed: \(aTimeoutAfter) awaiting")
    }

    /// A report that came before the entries were acquired says nothing about them, even if no
    /// check saw it until after. A frame's own report, made the moment it is drawn, is one.
    @Test func aReportFromBeforeTheOldestEntryDoesNotHoldOffTheClear() {
        let tracker = DrawableTracker()
        let early = tracker.add(acquiredAt: .seconds(99))
        tracker.reportPresented(early, presentedTime: 99.25)
        _ = tracker.add(acquiredAt: .seconds(100))
        _ = tracker.add(acquiredAt: .seconds(100.25))

        let awaiting = tracker.awaitingPresent(now: .seconds(101))
        #expect(awaiting == 0, "a report from before the entries held off their clear: \(awaiting) awaiting")
    }

    /// A report is dated by its `presentedTime`, not by the check that first sees it. After a
    /// pause with no frames, the first check finds the last report long past and clears at once:
    /// dated by that check, it would hold the entries, and the ticks, for another timeout.
    @Test func aReportIsDatedByItsPresentedTimeNotByTheCheckThatSeesIt() {
        let tracker = DrawableTracker()
        let reported = tracker.add(acquiredAt: .seconds(100))
        _ = tracker.add(acquiredAt: .seconds(100.25))
        _ = tracker.add(acquiredAt: .seconds(100.5))
        tracker.reportPresented(reported, presentedTime: 100.75)

        // The first check after the pause.
        let afterPause = tracker.awaitingPresent(now: .seconds(130))
        #expect(afterPause == 0, "a report 29 s old held off the clear: \(afterPause) awaiting")
    }

    /// A report with no `presentedTime` is dated by the `now` of the check that first sees it:
    /// late, never early. It still holds off the clear, for a timeout from that check.
    @Test func aReportWithNoPresentedTimeIsDatedByTheCheckThatFirstSeesIt() {
        let tracker = DrawableTracker()
        let skipped = tracker.add(acquiredAt: .seconds(100))
        _ = tracker.add(acquiredAt: .seconds(100.25))
        _ = tracker.add(acquiredAt: .seconds(100.5))
        tracker.reportPresented(skipped, presentedTime: 0)

        let seen = tracker.awaitingPresent(now: .seconds(100.5))
        #expect(seen == 2, "the undated report left \(seen) awaiting")
        // A timeout after the oldest entry left, 0.75 s after the check that dated the report.
        let soonAfter = tracker.awaitingPresent(now: .seconds(101.25))
        #expect(soonAfter == 2, "0.75 s after an undated report was seen the entries were cleared: \(soonAfter) awaiting")
        // A later check does not date the report again.
        let aTimeoutAfter = tracker.awaitingPresent(now: .seconds(101.5))
        #expect(aTimeoutAfter == 0, "a timeout after the undated report was seen the entries stayed: \(aTimeoutAfter) awaiting")
    }

    /// With no report for `presentReportTimeout` the entries clear, and the first clear of a run
    /// logs a notice. A report ends the run.
    @Test func withNoReportForTheTimeoutTheEntriesClearAndTheNoticeLogsOnce() {
        let tracker = DrawableTracker()
        _ = tracker.add(acquiredAt: .seconds(100))
        _ = tracker.add(acquiredAt: .seconds(100.25))
        let justBefore = tracker.awaitingPresent(now: .seconds(100.9375))
        #expect(justBefore == 2, "the entries cleared before the timeout: \(justBefore) awaiting")
        let atTimeout = tracker.awaitingPresent(now: .seconds(101))
        #expect(atTimeout == 0, "a timeout with no report left \(atTimeout) awaiting")
        let firstRun = [tracker.timeoutClears, tracker.lostReportNotices]
        #expect(firstRun == [1, 1], "after the first clear, [clears, notices] is \(firstRun)")

        // A second clear in the same run, with no report between: no second notice.
        _ = tracker.add(acquiredAt: .seconds(101))
        let last = tracker.add(acquiredAt: .seconds(101.25))
        _ = tracker.awaitingPresent(now: .seconds(102))
        let sameRun = [tracker.timeoutClears, tracker.lostReportNotices]
        #expect(sameRun == [2, 1], "after a second clear in one run, [clears, notices] is \(sameRun)")

        // A report, even for a drawable a clear already removed, ends the run.
        tracker.reportPresented(last, presentedTime: 102.25)
        _ = tracker.add(acquiredAt: .seconds(102.5))
        _ = tracker.add(acquiredAt: .seconds(102.75))
        let nextRun = tracker.awaitingPresent(now: .seconds(103.5))
        #expect(nextRun == 0, "the next run's timeout left \(nextRun) awaiting")
        let afterNextRun = [tracker.timeoutClears, tracker.lostReportNotices]
        #expect(afterNextRun == [3, 2], "after a clear in the next run, [clears, notices] is \(afterNextRun)")
    }

    /// A nil drawable proves the pool full, so the tracker reports the limit, whatever its
    /// entries say, until a present made after the nil came back is reported.
    @Test func aNilDrawableHoldsTheLimitUntilAReportArrives() {
        let tracker = DrawableTracker()
        let out = tracker.add(acquiredAt: .seconds(100))
        tracker.noteNoDrawable(requestedAt: .seconds(100.5))
        for now in [101.0, 101.5] {
            let awaiting = tracker.awaitingPresent(now: .seconds(now))
            #expect(awaiting == tracker.limit, "at \(now) s after a nil drawable the tracker counted \(awaiting)")
        }
        tracker.reportPresented(out, presentedTime: 101.5)
        let afterReport = tracker.awaitingPresent(now: .seconds(101.75))
        #expect(afterReport == 0, "a report left the nil drawable's hold in place: \(afterReport) awaiting")
    }

    /// A present made after the nil came back, reported before the frame notes the nil, as a
    /// handler on another thread can, freed a drawable. The nil then sets no hold: set, it would
    /// outlast the report meant to end it.
    @Test func aFreshReportBeforeTheNilIsNotedSetsNoHold() {
        let tracker = DrawableTracker()
        let out = tracker.add(acquiredAt: .seconds(100))
        tracker.reportPresented(out, presentedTime: 101.5)
        tracker.noteNoDrawable(requestedAt: .seconds(100.5))
        let awaiting = tracker.awaitingPresent(now: .seconds(101.25))
        #expect(awaiting == 0, "a nil drawable after a report set a hold: \(awaiting) awaiting")
    }

    /// Under bulk output reports run several refreshes late, so a few are still queued when a
    /// request comes back nil. Their presents were made before the nil, and prove nothing about
    /// the pool since: reported before the nil, they leave it to set its hold, and reported after
    /// it, they leave the hold in place, even one dated at the request's own `now`. So does an
    /// undated report. A present dated a `presentReportTimeout` after the request, the earliest
    /// the nil could have come back, ends it.
    @Test func aReportOfAPresentMadeBeforeTheRequestLeavesTheHold() {
        let tracker = DrawableTracker()
        let first = tracker.add(acquiredAt: .seconds(100))
        let second = tracker.add(acquiredAt: .seconds(100.25))
        let third = tracker.add(acquiredAt: .seconds(100.375))
        let fourth = tracker.add(acquiredAt: .seconds(100.4375))
        tracker.reportPresented(first, presentedTime: 100.25)
        tracker.noteNoDrawable(requestedAt: .seconds(100.5))
        let atFirstCheck = tracker.check(now: .seconds(101.5))
        #expect(atFirstCheck.nilDrawableHold, "a report of an earlier present kept the nil from setting a hold: \(atFirstCheck)")

        tracker.reportPresented(second, presentedTime: 100.5)
        tracker.reportPresented(third, presentedTime: 0)
        let kept = tracker.check(now: .seconds(101.75))
        #expect(kept.nilDrawableHold, "late reports of earlier presents ended the hold: \(kept)")

        tracker.reportPresented(fourth, presentedTime: 101.5)
        let ended = tracker.check(now: .seconds(102))
        #expect(!ended.nilDrawableHold, "a present made after the nil left the hold in place: \(ended)")
    }

    /// With no report, the hold lasts `presentReportTimeout` from the first check after the nil
    /// drawable. That frame's own `now` is a second old by the time `nextDrawable()` returns nil,
    /// so it cannot start the hold; `noteNoDrawable(requestedAt:)` only dates the request.
    @Test func aNilDrawableHoldsTheLimitForTheTimeoutFromTheNextCheck() {
        let tracker = DrawableTracker()
        tracker.noteNoDrawable(requestedAt: .seconds(100.25))
        let first = tracker.awaitingPresent(now: .seconds(101.25))
        #expect(first == tracker.limit, "the first check after a nil drawable counted \(first)")
        let within = tracker.awaitingPresent(now: .seconds(102.125))
        #expect(within == tracker.limit, "0.875 s into the hold the tracker counted \(within)")
        let after = tracker.awaitingPresent(now: .seconds(102.25))
        #expect(after == 0, "a timeout after the hold began the tracker counted \(after)")
    }

    /// The check tells a nil drawable's hold, which a display tick drops for, from entries at the
    /// limit, which only a leading-edge draw drops for. Both count as the limit.
    @Test func theCheckTellsANilDrawablesHoldFromEntriesAtTheLimit() {
        let tracker = DrawableTracker()
        _ = tracker.add(acquiredAt: .seconds(100))
        let newer = tracker.add(acquiredAt: .seconds(100.25))
        let atTheLimit = tracker.check(now: .seconds(100.5))
        let entries = DrawableTracker.Check(awaitingPresent: tracker.limit, nilDrawableHold: false)
        #expect(atTheLimit == entries, "two entries awaiting their report checked as \(atTheLimit)")

        tracker.reportPresented(newer, presentedTime: 100.5)
        tracker.noteNoDrawable(requestedAt: .seconds(100.625))
        let inTheHold = tracker.check(now: .seconds(100.75))
        let held = DrawableTracker.Check(awaitingPresent: tracker.limit, nilDrawableHold: true)
        #expect(inTheHold == held, "a nil drawable's hold with no entries checked as \(inTheHold)")
    }

    /// A peek answers what the check would, and changes nothing: entries past the timeout are
    /// counted as cleared but stay, no notice logs, and a nil drawable's hold does not start.
    @Test func aPeekAnswersAsTheCheckWouldAndChangesNothing() {
        let tracker = DrawableTracker()
        _ = tracker.add(acquiredAt: .seconds(100))
        _ = tracker.add(acquiredAt: .seconds(100.25))
        let young = tracker.peekAwaitingPresent(now: .seconds(100.5))
        #expect(young == 2, "a peek within the timeout counted \(young)")
        let pastTimeout = tracker.peekAwaitingPresent(now: .seconds(101.5))
        #expect(pastTimeout == 0, "a peek past the timeout counted \(pastTimeout), not the 0 a clear leaves")
        let afterPeeks = [tracker.entryCount, tracker.timeoutClears, tracker.lostReportNotices]
        #expect(afterPeeks == [2, 0, 0], "after two peeks, [entries, clears, notices] is \(afterPeeks)")
        let checked = tracker.awaitingPresent(now: .seconds(101.5))
        #expect(checked == pastTimeout, "the check counted \(checked) where the peek counted \(pastTimeout)")

        // A peek is not the first check after a nil drawable: the hold starts at the next real one.
        tracker.noteNoDrawable(requestedAt: .seconds(101.5))
        let peekedHold = tracker.peekAwaitingPresent(now: .seconds(102))
        #expect(peekedHold == tracker.limit, "a peek during a nil drawable's hold counted \(peekedHold)")
        let firstCheck = tracker.awaitingPresent(now: .seconds(103.25))
        #expect(firstCheck == tracker.limit, "the first check after a peeked hold counted \(firstCheck): the peek started its timer")
    }

    /// Metal reports a frame that was skipped, or never presented, with a `presentedTime` of 0.
    /// The handler counts those, and only those.
    @Test func aPresentWithNoPresentedTimeCountsAsSkipped() {
        let tracker = DrawableTracker()
        let skipped = tracker.add(acquiredAt: .seconds(100))
        let shown = tracker.add(acquiredAt: .seconds(100.25))
        tracker.reportPresented(skipped, presentedTime: 0)
        let afterSkipped = tracker.skippedPresents
        #expect(afterSkipped == 1, "a present at time 0 counted \(afterSkipped) skipped")
        tracker.reportPresented(shown, presentedTime: 100.5)
        let afterShown = tracker.skippedPresents
        #expect(afterShown == 1, "a present with a time counted as skipped: \(afterShown)")
    }

    /// The skipped count logs a notice each time it reaches a power of two: at 1, 2, 4 and 8 of
    /// nine skipped presents, and never for a present with a time.
    @Test func theSkippedCountLogsANoticeAtEachPowerOfTwo() {
        let tracker = DrawableTracker()
        var notices: [Int] = []
        for skipped in 1...9 {
            let id = tracker.add(acquiredAt: .seconds(100))
            tracker.reportPresented(id, presentedTime: 0)
            notices.append(tracker.skippedPresentNotices)
            let shown = tracker.add(acquiredAt: .seconds(100))
            tracker.reportPresented(shown, presentedTime: 100 + Double(skipped))
        }
        let expected = [1, 2, 2, 3, 3, 3, 3, 4, 4]
        #expect(notices == expected, "the notices after each of nine skipped presents were \(notices)")
    }

    /// The view tests' seam stands for the newest drawable's presented handler. With nothing
    /// tracked it reports nothing, so it cannot end a nil drawable's hold.
    @Test func reportNewestPresentedReportsTheNewestAndNothingWhenEmpty() {
        let tracker = DrawableTracker()
        _ = tracker.add(acquiredAt: .seconds(100))
        _ = tracker.add(acquiredAt: .seconds(100.25))
        tracker.reportNewestPresented()
        let afterReport = tracker.entryCount
        #expect(afterReport == 0, "reporting the newest drawable left \(afterReport)")

        tracker.noteNoDrawable(requestedAt: .seconds(100.5))
        tracker.reportNewestPresented()
        let held = tracker.awaitingPresent(now: .seconds(101))
        #expect(held == tracker.limit, "reporting the newest of no drawables ended a nil drawable's hold: \(held)")
    }

    /// A presented handler's report reaches the tracker unless a test has set
    /// `ignoresPresentedHandlers`. The view tests that time their own reports rely on the seam:
    /// were it to let Metal's reports through, they would clear the entries those tests keep, and
    /// the late-report repro would pass whatever the tick does.
    @Test func aPresentedHandlersReportIsIgnoredOnlyWhileTheSeamIsSet() {
        let tracker = DrawableTracker()
        let out = tracker.add(acquiredAt: .seconds(100))
        tracker.ignoresPresentedHandlers = true
        tracker.reportFromPresentedHandler(out, presentedTime: 100.25)
        let whileIgnoring = tracker.entryCount
        #expect(whileIgnoring == 1, "a handler's report reached a tracker that ignores them: \(whileIgnoring) entries")

        tracker.ignoresPresentedHandlers = false
        tracker.reportFromPresentedHandler(out, presentedTime: 100.5)
        let heard = tracker.entryCount
        #expect(heard == 0, "a handler's report did not reach a tracker that hears them: \(heard) entries")
    }
}

/// The renderer's half of "drop, never block": the slot it takes after the build, the nil
/// drawable, and the wait a live resize and `drawFrameNow()` keep. Drawn into a layer in no
/// window, through a `nextDrawable` seam, so no test depends on Metal presenting anything.
@Suite(.fastPassBounded)
@MainActor
struct RendererBackpressureTests {
    private struct Scene {
        let renderer: TerminalRenderer
        let terminal: GhosttyTerminal
        let surface: TerminalSurface
        let layer: CAMetalLayer
    }

    /// A renderer of its own, so its stats move only for this test, and a dirty 10×3 surface.
    private func makeScene() throws -> Scene {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let glyphCache = GlyphCache(fontSet: FontSet(font: font, scale: 2), device: device)
        let renderer = try TerminalRenderer(device: device, glyphCache: glyphCache)
        let terminal = try GhosttyTerminal(cols: 10, rows: 3, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        terminal.feed(text: "A")
        let surface = TerminalSurface()
        try surface.attach(terminal)
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        let size = renderer.drawableSize(columns: 10, rows: 3)
        layer.drawableSize = CGSize(width: size.width, height: size.height)
        return Scene(renderer: renderer, terminal: terminal, surface: surface, layer: layer)
    }

    /// The view checks the ring before it builds, so this guard cannot fail on its path, but it
    /// still guards the slot: a frame that finds the ring full is dropped before it asks for a
    /// drawable, and leaves the surface dirty for the next frame.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aFrameThatFindsTheRingFullIsDroppedBeforeItAsksForADrawable() throws {
        let scene = try makeScene()
        defer { scene.terminal.close() }
        let held = HeldRingSlots(on: scene.surface)
        defer { held.releaseAll() }
        try #require(held.held == FrameRing.depth, "only \(held.held) of the ring's slots could be taken")
        let tracker = DrawableTracker()

        let before = scene.renderer.stats
        let outcome = try scene.renderer.render(
            surface: scene.surface, layer: scene.layer, tracker: tracker, now: .seconds(100),
            nextDrawable: { _ in nil })
        let after = scene.renderer.stats
        #expect(!outcome.didEncode, "a frame was encoded with every ring slot in flight")
        let asked = after.drawableRequests - before.drawableRequests
        #expect(asked == 0, "a frame with the ring full asked for \(asked) drawables")
        let dirty = scene.surface.needsDisplay
        #expect(dirty, "the dropped frame left the surface clean, so the next frame would skip")

        // Control: with one slot back, the same frame gets as far as asking for a drawable.
        held.releaseOne()
        _ = try scene.renderer.render(
            surface: scene.surface, layer: scene.layer, tracker: tracker, now: .seconds(100.25),
            nextDrawable: { _ in nil })
        let askedOnceFree = scene.renderer.stats.drawableRequests - after.drawableRequests
        #expect(askedOnceFree == 1, "control: with a slot free the frame asked for \(askedOnceFree) drawables")
    }

    /// A nil drawable takes today's path, giving its slot back and counting `nilDrawables`, and
    /// makes the tracker hold the limit: the pool is full, whatever it counted.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aNilDrawableMakesTheTrackerHoldTheLimit() throws {
        let scene = try makeScene()
        defer { scene.terminal.close() }
        let tracker = DrawableTracker()

        let before = scene.renderer.stats
        let outcome = try scene.renderer.render(
            surface: scene.surface, layer: scene.layer, tracker: tracker, now: .seconds(100),
            nextDrawable: { _ in nil })
        let after = scene.renderer.stats
        #expect(!outcome.didEncode, "a frame with no drawable was encoded")
        let nils = after.nilDrawables - before.nilDrawables
        #expect(nils == 1, "a frame given no drawable counted \(nils) nil drawables")
        let ringFree = scene.surface.frameRing?.hasFreeSlot ?? false
        #expect(ringFree, "a frame given no drawable kept its ring slot")
        let entries = tracker.entryCount
        #expect(entries == 0, "a nil drawable was tracked: \(entries) entries")
        let awaiting = tracker.awaitingPresent(now: .seconds(100.25))
        #expect(awaiting == tracker.limit, "after a nil drawable the tracker counted \(awaiting), not the limit")
    }

    /// A live resize and `drawFrameNow()` wait on the ring rather than drop. Here the GPU gives a
    /// slot back from another thread while the frame waits, as a completion handler would. Had
    /// the frame dropped instead, it would never have asked for a drawable.
    ///
    /// The release is a little delayed so that it lands while the frame waits. When a loaded
    /// runner reaches the frame later than that, the release has come first and the frame takes
    /// the slot without waiting; the test still passes, it only stops telling a wait from a drop.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aFrameThatWaitsForASlotGetsOneOnceTheGPUGivesItBack() throws {
        let scene = try makeScene()
        defer { scene.terminal.close() }
        let held = HeldRingSlots(on: scene.surface)
        defer { held.releaseAll() }
        try #require(held.held == FrameRing.depth, "only \(held.held) of the ring's slots could be taken")
        let tracker = DrawableTracker()

        let releaser = held.handOff()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { releaser.release() }
        let before = scene.renderer.stats
        _ = try scene.renderer.render(
            surface: scene.surface, layer: scene.layer, tracker: tracker, now: .seconds(100),
            waitsForSlot: true, nextDrawable: { _ in nil })
        let asked = scene.renderer.stats.drawableRequests - before.drawableRequests
        #expect(asked == 1, "a frame that waits for a slot asked for \(asked) drawables: it was dropped")
    }
}
