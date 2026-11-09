// PresentTimingLog — a diagnostic for the bulk-output frame cap. It records how long a view's
// drawables take to reach the screen, how late their present reports come, and what each display
// tick that dropped its frame for the GPU found. It changes nothing it observes.
//
// Under continuous output a libghostty view draws about one frame in two or three refreshes. A
// tick drops its frame while `TerminalRenderer.maxDrawablesAwaitingPresent` drawables await their
// present report, so how late those reports come bounds how often the view can draw. This log
// gives the numbers to choose a fix from.
//
// Two lines, both on subsystem `com.tbd.app`, category `terminallatency`. Neither uses the
// latency tap's verbs, so `scripts/diag/terminal-latency-report.py` skips them.
//
//     presents n=<n> dated=<n> main=<n> screenms=<s> reportms=<s> latems=<s> drops=<n> ringfull=<n> oldestagems=<s> spanms=<f>
//     gpubehind ringfull=<0|1> awaiting=<n> entries=<n> agesms=<ms,…|-> sincepresentms=<f|->
//
// Each `<s>` is `p50/p90/max` in milliseconds, or `-` with no samples.
//
//   * **`presents`** is `.notice`, at most one a second while reports arrive. It covers the
//     reports since the last one, and is left out when that window held fewer than
//     `minimumPresents` reports and no dropped tick, so a blinking cursor logs nothing.
//     - `n` reports, `dated` of them with a `presentedTime` above 0, and `main` of them whose
//       handler ran on the main thread.
//     - `screenms` is acquire to `presentedTime`, and `latems` is `presentedTime` to the handler.
//       Both count dated reports only: a `presentedTime` of 0 is a skipped present.
//     - `reportms` is acquire to the handler, for every report.
//     - `drops` ticks dropped for the GPU since the last summary, `ringfull` of them with the
//       ring full, and `oldestagems` the age of each drop's oldest unreported drawable.
//     - `spanms` is the first report to the last.
//   * **`gpubehind`** is `.debug`, one per dropped tick: whether the ring was full, the count the
//     tracker reported, its entries and each one's age oldest first, and how long before the
//     tick the newest reported drawable reached the screen.
//
// Acquire and handler times come off `hostNow`, host time, the clock of `presentedTime`. A dropped
// tick's ages are by the frames' own `now`, the timebase the tracker's entries are kept in.

import Foundation
import QuartzCore
import Synchronization
import os

/// The latency tap's category, so one `log stream` predicate shows both.
let terminalLatencyLog = Logger(subsystem: "com.tbd.app", category: "terminallatency")

/// The 50th and 90th percentiles and the largest of a set of samples, nearest-rank.
struct TimingSpread: Sendable, Equatable {
    var p50: Duration
    var p90: Duration
    var max: Duration

    /// nil for no samples.
    init?(_ samples: [Duration]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        func rank(_ fraction: Double) -> Duration {
            let index = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
            return sorted[Swift.max(0, Swift.min(sorted.count - 1, index))]
        }
        p50 = rank(0.5)
        p90 = rank(0.9)
        max = sorted[sorted.count - 1]
    }

    init(p50: Duration, p90: Duration, max: Duration) {
        self.p50 = p50
        self.p90 = p90
        self.max = max
    }
}

/// What a display tick that dropped its frame for the GPU found.
struct GPUBehindSample: Sendable, Equatable {
    /// The surface's ring had a slot free.
    var ringHasFreeSlot: Bool
    /// What `DrawableTracker.awaitingPresent(now:)` reported: the limit while a nil drawable's
    /// hold lasts, and the entries otherwise.
    var awaitingPresent: Int
    /// How old each unreported entry was, oldest first, by the frames' `now`.
    var entryAges: [Duration]
    /// How long before the tick the newest reported drawable reached the screen. nil before the
    /// first report.
    var sinceLastPresent: Duration?

    var line: String {
        let ages = entryAges.isEmpty ? "-" : entryAges.map(PresentTimingLog.milliseconds).joined(separator: ",")
        let since = sinceLastPresent.map(PresentTimingLog.milliseconds) ?? "-"
        return "gpubehind ringfull=\(ringHasFreeSlot ? 0 : 1) awaiting=\(awaitingPresent) "
            + "entries=\(entryAges.count) agesms=\(ages) sincepresentms=\(since)"
    }
}

/// One window of reports and dropped ticks, as the `presents` line gives it.
struct PresentTimingSummary: Sendable, Equatable {
    var presents: Int
    var dated: Int
    var onMainThread: Int
    /// Acquire to `presentedTime`, dated reports only.
    var screen: TimingSpread?
    /// Acquire to the handler, every report.
    var report: TimingSpread?
    /// `presentedTime` to the handler, dated reports only.
    var late: TimingSpread?
    var drops: Int
    var ringFullDrops: Int
    /// Each drop's oldest unreported drawable's age.
    var oldestAge: TimingSpread?
    /// The first report to the last.
    var span: Duration

    var line: String {
        func spread(_ value: TimingSpread?) -> String {
            guard let value else { return "-" }
            return [value.p50, value.p90, value.max].map(PresentTimingLog.milliseconds).joined(separator: "/")
        }
        return "presents n=\(presents) dated=\(dated) main=\(onMainThread) screenms=\(spread(screen)) "
            + "reportms=\(spread(report)) latems=\(spread(late)) drops=\(drops) ringfull=\(ringFullDrops) "
            + "oldestagems=\(spread(oldestAge)) spanms=\(PresentTimingLog.milliseconds(span))"
    }
}

/// See the file header. One per `DrawableTracker`, so one per view.
///
/// Reports arrive on whatever thread Metal calls a presented handler on, and dropped ticks on
/// main, so the window sits behind a lock of its own: the tracker's lock is held no longer than
/// before. Both lines are emitted outside it.
final class PresentTimingLog: Sendable {
    /// How often the `presents` line comes while reports arrive.
    static let summaryInterval: Duration = .seconds(1)
    /// A window with fewer reports than this and no dropped tick is left out. A blinking cursor
    /// draws two frames a second.
    static let minimumPresents = 10
    /// The most samples of each kind one window keeps. A view whose reports stopped can drop
    /// ticks with no report to end the window, so the drops are counted past this and their
    /// ages are not kept.
    static let sampleCapacity = 1024

    private struct Window {
        var firstReportAt: Duration?
        var lastReportAt: Duration?
        var presents = 0
        var dated = 0
        var onMainThread = 0
        var screen: [Duration] = []
        var report: [Duration] = []
        var late: [Duration] = []
        var drops = 0
        var ringFullDrops = 0
        var oldestAges: [Duration] = []

        mutating func append(_ value: Duration, to samples: WritableKeyPath<Window, [Duration]>) {
            guard self[keyPath: samples].count < PresentTimingLog.sampleCapacity else { return }
            self[keyPath: samples].append(value)
        }

        /// The window as a `presents` line, or nil when it is too quiet to log.
        var summary: PresentTimingSummary? {
            guard presents >= PresentTimingLog.minimumPresents || drops > 0 else { return nil }
            var span = Duration.zero
            if let firstReportAt, let lastReportAt { span = lastReportAt - firstReportAt }
            return PresentTimingSummary(
                presents: presents, dated: dated, onMainThread: onMainThread,
                screen: TimingSpread(screen), report: TimingSpread(report), late: TimingSpread(late),
                drops: drops, ringFullDrops: ringFullDrops, oldestAge: TimingSpread(oldestAges),
                span: span)
        }
    }

    private struct State {
        var window = Window()
        /// Every dropped tick since the log was made, and the latest one's sample. Test seams,
        /// kept past the end of a window.
        var gpuBehindNoted = 0
        var lastGPUBehind: GPUBehindSample?
    }

    /// Host time, the clock of `presentedTime` and the display link. A seam the tests set.
    let hostNow: @Sendable () -> Duration
    private let emitSummary: @Sendable (PresentTimingSummary) -> Void
    private let emitDrop: @Sendable (GPUBehindSample) -> Void
    private let state = Mutex(State())

    init(
        hostNow: @escaping @Sendable () -> Duration = { .seconds(CACurrentMediaTime()) },
        emitSummary: @escaping @Sendable (PresentTimingSummary) -> Void = { summary in
            terminalLatencyLog.notice("\(summary.line, privacy: .public)")
        },
        // `line` is built inside the log call, so a `.debug` line nobody streams costs no string.
        emitDrop: @escaping @Sendable (GPUBehindSample) -> Void = { sample in
            terminalLatencyLog.debug("\(sample.line, privacy: .public)")
        }
    ) {
        self.hostNow = hostNow
        self.emitSummary = emitSummary
        self.emitDrop = emitDrop
    }

    /// A drawable acquired at `acquiredAt` was reported presented, by a handler that read
    /// `reportedAt` as it began. Both are `hostNow` readings. A report `summaryInterval` or more
    /// after the window's first ends that window, and starts the next.
    func notePresented(
        acquiredAt: Duration, reportedAt: Duration, presentedTime: CFTimeInterval, onMainThread: Bool
    ) {
        let finished = state.withLock { state -> PresentTimingSummary? in
            var finished: PresentTimingSummary?
            if let first = state.window.firstReportAt, reportedAt - first >= Self.summaryInterval {
                finished = state.window.summary
                state.window = Window()
            }
            state.window.firstReportAt = state.window.firstReportAt ?? reportedAt
            state.window.lastReportAt = reportedAt
            state.window.presents += 1
            if onMainThread { state.window.onMainThread += 1 }
            state.window.append(reportedAt - acquiredAt, to: \.report)
            // A `presentedTime` of 0 is a present that "has not been presented or has been
            // skipped": it has no time on screen to measure.
            if presentedTime > 0 {
                let presentedAt = Duration.seconds(presentedTime)
                state.window.dated += 1
                state.window.append(presentedAt - acquiredAt, to: \.screen)
                state.window.append(reportedAt - presentedAt, to: \.late)
            }
            return finished
        }
        if let finished { emitSummary(finished) }
    }

    /// A display tick dropped its frame for the GPU, and found `sample`.
    func noteGPUBehind(_ sample: GPUBehindSample) {
        state.withLock { state in
            state.window.drops += 1
            if !sample.ringHasFreeSlot { state.window.ringFullDrops += 1 }
            if let oldest = sample.entryAges.first { state.window.append(oldest, to: \.oldestAges) }
            state.gpuBehindNoted += 1
            state.lastGPUBehind = sample
        }
        emitDrop(sample)
    }

    // MARK: - Test seams

    /// The window as a `presents` line would give it now, with nothing ended.
    var pendingSummary: PresentTimingSummary? { state.withLock { $0.window.summary } }
    /// How many dropped ticks' oldest ages the current window keeps.
    var keptOldestAges: Int { state.withLock { $0.window.oldestAges.count } }
    /// Every dropped tick since the log was made.
    var gpuBehindNoted: Int { state.withLock { $0.gpuBehindNoted } }
    /// The latest dropped tick's sample.
    var lastGPUBehind: GPUBehindSample? { state.withLock { $0.lastGPUBehind } }

    /// `duration` in milliseconds, three places.
    static func milliseconds(_ duration: Duration) -> String {
        let components = duration.components
        let ms = Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
        return String(format: "%.3f", ms)
    }
}
