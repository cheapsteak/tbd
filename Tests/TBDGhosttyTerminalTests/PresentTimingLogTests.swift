import Foundation
import Synchronization
@testable import TBDGhosttyTerminal
import TestSupport
import Testing

/// What a `PresentTimingLog` emitted, collected in place of the log, and the host time it reads,
/// which stays where a test sets it.
private final class PresentTimingRecorder: Sendable {
    private let emittedSummaries = Mutex<[PresentTimingSummary]>([])
    private let emittedDrops = Mutex<[GPUBehindSample]>([])
    private let emittedViews = Mutex<Set<Int>>([])
    private let hostTime = Mutex<Duration>(.zero)

    var summaries: [PresentTimingSummary] { emittedSummaries.withLock { $0 } }
    var drops: [GPUBehindSample] { emittedDrops.withLock { $0 } }
    /// Every `view` number a line was emitted for.
    var views: Set<Int> { emittedViews.withLock { $0 } }

    /// Sets the host time a dropped frame is noted at.
    func setHostNow(_ time: Duration) { hostTime.withLock { $0 = time } }

    func makeLog() -> PresentTimingLog {
        PresentTimingLog(
            hostNow: { self.hostTime.withLock { $0 } },
            emitSummary: { view, summary in
                self.emittedViews.withLock { _ = $0.insert(view) }
                self.emittedSummaries.withLock { $0.append(summary) }
            },
            emitDrop: { view, sample in
                self.emittedViews.withLock { _ = $0.insert(view) }
                self.emittedDrops.withLock { $0.append(sample) }
            })
    }
}

/// `duration` as the log prints it, or `-`.
private func ms(_ duration: Duration?) -> String {
    duration.map(PresentTimingLog.milliseconds) ?? "-"
}

/// A report whose handler ran `reportAfter` after `acquiredAt`. Dated `screenAfter` after it, or
/// undated with a `presentedTime` of 0 when that is nil.
private func report(
    _ log: PresentTimingLog, acquiredAt: Duration, screenAfter: Duration?, reportAfter: Duration,
    onMainThread: Bool = false
) {
    let presentedTime: CFTimeInterval = screenAfter.map { (acquiredAt + $0) / .seconds(1) } ?? 0
    log.notePresented(
        acquiredAt: acquiredAt, reportedAt: acquiredAt + reportAfter,
        presentedTime: presentedTime, onMainThread: onMainThread)
}

private func sample(
    ringHasFreeSlot: Bool = true, held: Bool = false, awaiting: Int = 2, ages: [Duration],
    sinceLastPresent: Duration? = nil
) -> GPUBehindSample {
    GPUBehindSample(
        ringHasFreeSlot: ringHasFreeSlot, nilDrawableHold: held, awaitingPresent: awaiting, entryAges: ages,
        sinceLastPresent: sinceLastPresent)
}

/// The present-timing diagnostic: how late present reports come, and what a frame that dropped
/// for the GPU found.
@Suite(.fastPassBounded)
struct PresentTimingLogTests {
    /// Nothing is logged until a report or dropped tick comes a `summaryInterval` after the
    /// window's first. That one ends the window and starts the next.
    @Test func aSummaryComesOnlyOnceTheWindowSpansTheInterval() throws {
        let recorder = PresentTimingRecorder()
        let log = recorder.makeLog()

        recorder.setHostNow(.seconds(100))
        log.noteGPUBehind(sample(ages: [.milliseconds(25)]))
        log.noteGPUBehind(sample(ages: [.milliseconds(17)]))
        for index in 0..<12 {
            report(log, acquiredAt: Duration.seconds(100) + .milliseconds(50 * index),
                   screenAfter: .milliseconds(16), reportAfter: .milliseconds(25))
        }
        let withinInterval = recorder.summaries.count
        #expect(withinInterval == 0, "drops and reports within the interval made \(withinInterval) summaries")

        // The window began with the drops at 100 s, and its last report was handled at 100.575 s.
        report(log, acquiredAt: .seconds(101), screenAfter: .milliseconds(16), reportAfter: .milliseconds(25))
        let summaries = recorder.summaries
        try #require(summaries.count == 1, "a report an interval after the first drop made \(summaries.count) summaries")
        let summary = summaries[0]
        #expect(summary.presents == 12, "the summary counted \(summary.presents) reports, not the 12 before it")
        #expect(summary.drops == 2, "the summary counted \(summary.drops) dropped ticks, not 2")
        let span = ms(summary.span)
        #expect(span == "575.000", "the summary spanned \(span) ms")
        let reportMax = ms(summary.report?.max)
        #expect(reportMax == "25.000", "acquire to handler peaked at \(reportMax) ms")
        let line = summary.line(view: log.viewID)
        let expectedPrefix = "presents view=\(log.viewID) n=12 dated=12 main=0 screenms=16.000/16.000/16.000 "
        #expect(line.hasPrefix(expectedPrefix), "the summary line read \(line)")

        let next = log.pendingSummary
        let none: PresentTimingSummary? = nil
        #expect(next == none, "the next window, one report and no drop, would log \(String(describing: next))")
    }

    /// A view whose reports stopped still drops ticks, and a drop a `summaryInterval` after the
    /// window's first ends it, so the drops are logged with no report among them. That drop
    /// starts the next window.
    @Test func aDroppedTickEndsAWindowThatSpansTheInterval() throws {
        let recorder = PresentTimingRecorder()
        let log = recorder.makeLog()
        for index in 0..<3 {
            recorder.setHostNow(Duration.seconds(100) + .milliseconds(100 * index))
            log.noteGPUBehind(sample(ringHasFreeSlot: false, ages: [.milliseconds(40)]))
        }
        let withinInterval = recorder.summaries.count
        #expect(withinInterval == 0, "drops within the interval made \(withinInterval) summaries")

        recorder.setHostNow(.seconds(101))
        log.noteGPUBehind(sample(ages: [.milliseconds(900)]))
        let summaries = recorder.summaries
        try #require(summaries.count == 1, "a drop an interval after the first made \(summaries.count) summaries")
        let summary = summaries[0]
        #expect(summary.presents == 0, "the window of drops counted \(summary.presents) reports")
        #expect(summary.drops == 3, "the window counted \(summary.drops) drops, not the 3 before the one that ended it")
        #expect(summary.ringFullDrops == 3, "the window counted \(summary.ringFullDrops) ring-full drops, not 3")
        let span = ms(summary.span)
        #expect(span == "200.000", "the window of drops spanned \(span) ms")

        let next = try #require(log.pendingSummary, "the drop that ended the window began no next one")
        #expect(next.drops == 1, "the next window counted \(next.drops) drops, not 1")
    }

    /// Each log numbers its lines with a `view` of its own, so two panes' lines can be told apart.
    @Test func eachLogNumbersItsLinesWithItsOwnView() {
        let recorder = PresentTimingRecorder()
        let first = recorder.makeLog()
        let second = recorder.makeLog()
        #expect(first.viewID != second.viewID, "two logs were both numbered \(first.viewID)")

        first.noteGPUBehind(sample(ages: []))
        second.noteGPUBehind(sample(ages: []))
        let views = recorder.views
        let expected: Set<Int> = [first.viewID, second.viewID]
        #expect(views == expected, "the lines were emitted for the views \(views)")
    }

    /// A `presentedTime` of 0 is a skipped present: it counts as a report, and in acquire to
    /// handler, but it has no time on screen, so the screen and late figures leave it out.
    @Test func anUndatedPresentIsLeftOutOfTheScreenAndLateFigures() throws {
        let recorder = PresentTimingRecorder()
        let log = recorder.makeLog()
        // Four dated, six undated: had the undated counted, they would set every percentile.
        for index in 0..<4 {
            report(log, acquiredAt: Duration.seconds(100) + .milliseconds(10 * index),
                   screenAfter: .milliseconds(16), reportAfter: .milliseconds(25))
        }
        for index in 4..<10 {
            report(log, acquiredAt: Duration.seconds(100) + .milliseconds(10 * index),
                   screenAfter: nil, reportAfter: .milliseconds(40))
        }
        report(log, acquiredAt: .seconds(102), screenAfter: .milliseconds(16), reportAfter: .milliseconds(25))

        let summaries = recorder.summaries
        try #require(summaries.count == 1, "the window made \(summaries.count) summaries")
        let summary = summaries[0]
        #expect(summary.presents == 10, "the summary counted \(summary.presents) reports, not 10")
        #expect(summary.dated == 4, "the summary counted \(summary.dated) dated reports, not 4")
        let screen = [ms(summary.screen?.p50), ms(summary.screen?.max)]
        #expect(screen == ["16.000", "16.000"], "acquire to screen read \(screen)")
        let late = [ms(summary.late?.p50), ms(summary.late?.max)]
        #expect(late == ["9.000", "9.000"], "screen to handler read \(late)")
        // Every report: four at 25 ms and six at 40 ms.
        let reports = [ms(summary.report?.p50), ms(summary.report?.max)]
        #expect(reports == ["40.000", "40.000"], "acquire to handler read \(reports)")
    }

    /// A window of only undated reports has no screen or late figure, and prints `-` for each.
    @Test func aWindowWithNoDatedReportPrintsNoScreenFigure() throws {
        let recorder = PresentTimingRecorder()
        let log = recorder.makeLog()
        for index in 0..<10 {
            report(log, acquiredAt: Duration.seconds(100) + .milliseconds(10 * index),
                   screenAfter: nil, reportAfter: .milliseconds(30))
        }
        report(log, acquiredAt: .seconds(102), screenAfter: nil, reportAfter: .milliseconds(30))

        let summaries = recorder.summaries
        try #require(summaries.count == 1, "the window made \(summaries.count) summaries")
        let line = summaries[0].line(view: log.viewID)
        #expect(line.contains(" screenms=- reportms=30.000/30.000/30.000 latems=- "),
                "the summary line read \(line)")
    }

    /// A window with fewer than `minimumPresents` reports, as a blinking cursor makes, is left
    /// out. One that dropped a tick is logged however few its reports.
    @Test func aQuietWindowIsLeftOutUnlessATickDropped() throws {
        let recorder = PresentTimingRecorder()
        let log = recorder.makeLog()
        report(log, acquiredAt: .seconds(100), screenAfter: .milliseconds(16), reportAfter: .milliseconds(25))
        report(log, acquiredAt: .seconds(100.5), screenAfter: .milliseconds(16), reportAfter: .milliseconds(25))
        // Ends the quiet window, and starts the next.
        report(log, acquiredAt: .seconds(101.25), screenAfter: .milliseconds(16), reportAfter: .milliseconds(25))
        let afterQuiet = recorder.summaries.count
        #expect(afterQuiet == 0, "a window of two reports made \(afterQuiet) summaries")

        // The last report began a window at 101.275 s, so a drop at 101.5 s falls inside it.
        recorder.setHostNow(.seconds(101.5))
        log.noteGPUBehind(sample(ages: [.milliseconds(25), .milliseconds(8)]))
        report(log, acquiredAt: .seconds(102.5), screenAfter: .milliseconds(16), reportAfter: .milliseconds(25))
        let summaries = recorder.summaries
        try #require(summaries.count == 1, "a window with a dropped tick made \(summaries.count) summaries")
        let summary = summaries[0]
        #expect(summary.presents == 1, "the window with a dropped tick counted \(summary.presents) reports, not 1")
        #expect(summary.drops == 1, "the window with a dropped tick counted \(summary.drops) drops, not 1")
    }

    /// A handler that ran on the main thread is counted, and one that ran elsewhere is not.
    @Test func reportsOnTheMainThreadAreCounted() throws {
        let recorder = PresentTimingRecorder()
        let log = recorder.makeLog()
        for index in 0..<10 {
            report(log, acquiredAt: Duration.seconds(100) + .milliseconds(10 * index),
                   screenAfter: .milliseconds(16), reportAfter: .milliseconds(25), onMainThread: index < 3)
        }
        report(log, acquiredAt: .seconds(102), screenAfter: .milliseconds(16), reportAfter: .milliseconds(25))
        let summaries = recorder.summaries
        try #require(summaries.count == 1, "the window made \(summaries.count) summaries")
        let onMain = summaries[0].onMainThread
        #expect(onMain == 3, "\(onMain) of the reports counted as on the main thread, not 3")
    }

    /// Each dropped frame is emitted as it happens. The window counts the drops with the ring
    /// full and those during a nil drawable's hold apart, and keeps each drop's oldest entry's age;
    /// a drop with no entries adds no age. A drop with neither, a leading-edge draw at the
    /// drawable limit, counts only in `drops`.
    @Test func aDroppedFrameIsEmittedAndCounted() throws {
        let recorder = PresentTimingRecorder()
        let log = recorder.makeLog()
        let ringFull = sample(ringHasFreeSlot: false, awaiting: 1, ages: [.milliseconds(25)])
        let drawables = sample(ages: [.milliseconds(33), .milliseconds(17)], sinceLastPresent: .milliseconds(4))
        let held = sample(held: true, awaiting: 2, ages: [])
        log.noteGPUBehind(ringFull)
        log.noteGPUBehind(drawables)
        log.noteGPUBehind(held)

        let emitted = recorder.drops
        let expectedDrops = [ringFull, drawables, held]
        #expect(emitted == expectedDrops, "the drops emitted were \(emitted)")
        let view = log.viewID
        let lines = emitted.map { $0.line(view: view) }
        let expectedLines = [
            "gpubehind view=\(view) ringfull=1 held=0 awaiting=1 entries=1 agesms=25.000 sincepresentms=-",
            "gpubehind view=\(view) ringfull=0 held=0 awaiting=2 entries=2 agesms=33.000,17.000 sincepresentms=4.000",
            "gpubehind view=\(view) ringfull=0 held=1 awaiting=2 entries=0 agesms=- sincepresentms=-",
        ]
        #expect(lines == expectedLines, "the drop lines read \(lines)")

        let summary = try #require(log.pendingSummary, "a window with dropped frames would log nothing")
        let counts = [summary.drops, summary.ringFullDrops, summary.heldDrops]
        #expect(counts == [3, 1, 1], "the window counted [drops, ring full, held] as \(counts)")
        let oldest = [ms(summary.oldestAge?.p50), ms(summary.oldestAge?.max)]
        #expect(oldest == ["25.000", "33.000"], "the oldest entries' ages read \(oldest)")
        let line = summary.line(view: view)
        #expect(line.contains(" drops=3 ringfull=1 held=1 oldestagems="), "the summary line read \(line)")
        let noted = log.gpuBehindNoted
        #expect(noted == 3, "the log noted \(noted) dropped frames, not 3")
    }

    /// Drops that all fall in one window, as they do while the host time stands still, are counted
    /// however many come, and their ages are kept only up to `sampleCapacity`.
    @Test func aWindowKeepsAtMostSampleCapacityAges() {
        let log = PresentTimingRecorder().makeLog()
        let count = PresentTimingLog.sampleCapacity + 5
        for _ in 0..<count {
            log.noteGPUBehind(sample(ages: [.milliseconds(25)]))
        }
        let kept = log.keptOldestAges
        #expect(kept == PresentTimingLog.sampleCapacity, "the window kept \(kept) ages")
        let drops = log.pendingSummary?.drops ?? 0
        #expect(drops == count, "the window counted \(drops) drops, not \(count)")
    }

    /// Nearest-rank percentiles, and none for no samples.
    @Test func aSpreadIsNearestRank() {
        let samples: [Duration] = (1...10).map { .milliseconds($0) }
        let spread = TimingSpread(samples.shuffled())
        let expected = TimingSpread(p50: .milliseconds(5), p90: .milliseconds(9), max: .milliseconds(10))
        #expect(spread == expected, "ten samples spread as \(String(describing: spread))")

        let single = TimingSpread([.milliseconds(7)])
        let alone = TimingSpread(p50: .milliseconds(7), p90: .milliseconds(7), max: .milliseconds(7))
        #expect(single == alone, "one sample spread as \(String(describing: single))")

        let empty = TimingSpread([])
        let none: TimingSpread? = nil
        #expect(empty == none, "no samples spread as \(String(describing: empty))")
    }
}

/// `DrawableTracker.noteGPUBehind`, which hands the diagnostic a dropped frame's entries.
@Suite(.fastPassBounded)
struct DrawableTrackerGPUBehindTests {
    /// The ages are by the frame's `now`, oldest first, and the time since the newest dated
    /// present reached the screen is by its `presentedTime`: a skipped present, which a check
    /// dates by its own `now`, does not move it. Noting changes nothing, and passes on what the
    /// frame's check found.
    @Test func theTrackerHandsADroppedFrameItsEntriesAges() throws {
        let recorder = PresentTimingRecorder()
        let tracker = DrawableTracker(presentTiming: recorder.makeLog())
        let first = tracker.add(acquiredAt: .seconds(100))
        let second = tracker.add(acquiredAt: .seconds(100.25))
        _ = tracker.add(acquiredAt: .seconds(100.375))

        tracker.noteGPUBehind(
            now: .seconds(100.5), ringHasFreeSlot: true,
            drawables: DrawableTracker.Check(awaitingPresent: 3, nilDrawableHold: false))
        let entriesAfterNote = tracker.entryCount
        #expect(entriesAfterNote == 3, "noting a dropped tick left \(entriesAfterNote) entries, not 3")

        tracker.reportPresented(first, presentedTime: 100.4375)
        tracker.noteGPUBehind(
            now: .seconds(100.5), ringHasFreeSlot: false,
            drawables: DrawableTracker.Check(awaitingPresent: 2, nilDrawableHold: true))

        // Skipped, and dated 100.625 s by the check.
        tracker.reportPresented(second, presentedTime: 0)
        let checkAfterSkip = tracker.check(now: .seconds(100.625))
        tracker.noteGPUBehind(now: .seconds(100.625), ringHasFreeSlot: true, drawables: checkAfterSkip)

        let drops = recorder.drops
        try #require(drops.count == 3, "the tracker noted \(drops.count) dropped ticks")
        let firstAges = drops[0].entryAges.map(ms)
        #expect(firstAges == ["500.000", "250.000", "125.000"], "the first drop's ages read \(firstAges)")
        let firstSince = ms(drops[0].sinceLastPresent)
        #expect(firstSince == "-", "with no report yet the first drop read \(firstSince) since a present")
        let secondAges = drops[1].entryAges.map(ms)
        #expect(secondAges == ["250.000", "125.000"], "the second drop's ages read \(secondAges)")
        let secondSince = ms(drops[1].sinceLastPresent)
        #expect(secondSince == "62.500", "the second drop read \(secondSince) ms since the present")
        let ring = drops[1].ringHasFreeSlot
        #expect(!ring, "the second drop, with the ring full, read a free slot")
        let awaiting = drops[1].awaitingPresent
        #expect(awaiting == 2, "the second drop read \(awaiting) awaiting, not the 2 it was handed")
        let held = drops.map(\.nilDrawableHold)
        #expect(held == [false, true, false], "the drops read a nil drawable's hold as \(held)")
        let thirdAges = drops[2].entryAges.map(ms)
        #expect(thirdAges == ["250.000"], "the third drop's ages read \(thirdAges)")
        let thirdSince = ms(drops[2].sinceLastPresent)
        #expect(thirdSince == "187.500", "after a skipped present the third drop read \(thirdSince) ms since a present")
    }
}
