import Foundation
import Synchronization
@testable import TBDGhosttyTerminal
import TestSupport
import Testing

/// What a `PresentTimingLog` emitted, collected in place of the log.
private final class PresentTimingRecorder: Sendable {
    private let emittedSummaries = Mutex<[PresentTimingSummary]>([])
    private let emittedDrops = Mutex<[GPUBehindSample]>([])

    var summaries: [PresentTimingSummary] { emittedSummaries.withLock { $0 } }
    var drops: [GPUBehindSample] { emittedDrops.withLock { $0 } }

    func makeLog() -> PresentTimingLog {
        PresentTimingLog(
            hostNow: { .zero },
            emitSummary: { summary in self.emittedSummaries.withLock { $0.append(summary) } },
            emitDrop: { sample in self.emittedDrops.withLock { $0.append(sample) } })
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
    ringHasFreeSlot: Bool = true, awaiting: Int = 2, ages: [Duration], sinceLastPresent: Duration? = nil
) -> GPUBehindSample {
    GPUBehindSample(
        ringHasFreeSlot: ringHasFreeSlot, awaitingPresent: awaiting, entryAges: ages,
        sinceLastPresent: sinceLastPresent)
}

/// The diagnostic for the bulk-output frame cap: how late present reports come, and what a tick
/// that dropped its frame for the GPU found.
@Suite(.fastPassBounded)
struct PresentTimingLogTests {
    /// Dropped ticks alone never make a `presents` line, and reports make one only once a report
    /// comes a `summaryInterval` after the window's first. That report starts the next window.
    @Test func aSummaryComesOnlyOnceReportsSpanTheInterval() throws {
        let recorder = PresentTimingRecorder()
        let log = recorder.makeLog()

        log.noteGPUBehind(sample(ages: [.milliseconds(25)]))
        log.noteGPUBehind(sample(ages: [.milliseconds(17)]))
        let afterDrops = recorder.summaries.count
        #expect(afterDrops == 0, "dropped ticks with no report made \(afterDrops) summaries")

        for index in 0..<12 {
            report(log, acquiredAt: Duration.seconds(100) + .milliseconds(50 * index),
                   screenAfter: .milliseconds(16), reportAfter: .milliseconds(25))
        }
        let withinInterval = recorder.summaries.count
        #expect(withinInterval == 0, "reports within the interval made \(withinInterval) summaries")

        // The first report was handled at 100.025 s.
        report(log, acquiredAt: .seconds(101), screenAfter: .milliseconds(16), reportAfter: .milliseconds(25))
        let summaries = recorder.summaries
        try #require(summaries.count == 1, "a report an interval after the first made \(summaries.count) summaries")
        let summary = summaries[0]
        #expect(summary.presents == 12, "the summary counted \(summary.presents) reports, not the 12 before it")
        #expect(summary.drops == 2, "the summary counted \(summary.drops) dropped ticks, not 2")
        let span = ms(summary.span)
        #expect(span == "550.000", "the summary spanned \(span) ms")
        let reportMax = ms(summary.report?.max)
        #expect(reportMax == "25.000", "acquire to handler peaked at \(reportMax) ms")
        let line = summary.line
        #expect(line.hasPrefix("presents n=12 dated=12 main=0 screenms=16.000/16.000/16.000 "),
                "the summary line read \(line)")

        let next = log.pendingSummary
        let none: PresentTimingSummary? = nil
        #expect(next == none, "the next window, one report and no drop, would log \(String(describing: next))")
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
        let line = summaries[0].line
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

    /// Each dropped tick is emitted as it happens. The window counts the drops with the ring
    /// full apart, and keeps each drop's oldest entry's age; a drop with no entries, as under a
    /// nil drawable's hold, adds no age.
    @Test func aDroppedTickIsEmittedAndCounted() throws {
        let recorder = PresentTimingRecorder()
        let log = recorder.makeLog()
        let ringFull = sample(ringHasFreeSlot: false, awaiting: 1, ages: [.milliseconds(25)])
        let drawables = sample(ages: [.milliseconds(33), .milliseconds(17)], sinceLastPresent: .milliseconds(4))
        let held = sample(awaiting: 2, ages: [])
        log.noteGPUBehind(ringFull)
        log.noteGPUBehind(drawables)
        log.noteGPUBehind(held)

        let emitted = recorder.drops
        let expectedDrops = [ringFull, drawables, held]
        #expect(emitted == expectedDrops, "the drops emitted were \(emitted)")
        let lines = emitted.map(\.line)
        let expectedLines = [
            "gpubehind ringfull=1 awaiting=1 entries=1 agesms=25.000 sincepresentms=-",
            "gpubehind ringfull=0 awaiting=2 entries=2 agesms=33.000,17.000 sincepresentms=4.000",
            "gpubehind ringfull=0 awaiting=2 entries=0 agesms=- sincepresentms=-",
        ]
        #expect(lines == expectedLines, "the drop lines read \(lines)")

        let summary = try #require(log.pendingSummary, "a window with dropped ticks would log nothing")
        #expect(summary.drops == 3, "the window counted \(summary.drops) drops, not 3")
        #expect(summary.ringFullDrops == 1, "the window counted \(summary.ringFullDrops) ring-full drops, not 1")
        let oldest = [ms(summary.oldestAge?.p50), ms(summary.oldestAge?.max)]
        #expect(oldest == ["25.000", "33.000"], "the oldest entries' ages read \(oldest)")
        let noted = log.gpuBehindNoted
        #expect(noted == 3, "the log noted \(noted) dropped ticks, not 3")
    }

    /// Drops with no report to end the window are counted however many come, and their ages are
    /// kept only up to `sampleCapacity`.
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

/// `DrawableTracker.noteGPUBehind`, which hands the diagnostic a dropped tick's entries.
@Suite(.fastPassBounded)
struct DrawableTrackerGPUBehindTests {
    /// The ages are by the tick's `now`, oldest first, and the time since the newest reported
    /// drawable reached the screen is by its `presentedTime`. Noting changes nothing.
    @Test func theTrackerHandsADroppedTickItsEntriesAges() throws {
        let recorder = PresentTimingRecorder()
        let tracker = DrawableTracker(presentTiming: recorder.makeLog())
        let first = tracker.add(acquiredAt: .seconds(100))
        _ = tracker.add(acquiredAt: .seconds(100.25))
        _ = tracker.add(acquiredAt: .seconds(100.375))

        tracker.noteGPUBehind(now: .seconds(100.5), ringHasFreeSlot: true, awaitingPresent: 3)
        let entriesAfterNote = tracker.entryCount
        #expect(entriesAfterNote == 3, "noting a dropped tick left \(entriesAfterNote) entries, not 3")

        tracker.reportPresented(first, presentedTime: 100.4375)
        tracker.noteGPUBehind(now: .seconds(100.5), ringHasFreeSlot: false, awaitingPresent: 2)

        let drops = recorder.drops
        try #require(drops.count == 2, "the tracker noted \(drops.count) dropped ticks")
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
    }
}
