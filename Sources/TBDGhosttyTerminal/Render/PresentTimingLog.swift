// PresentTimingLog — the present-timing diagnostic. It records how long a view's drawables take
// to reach the screen, how late their present reports come, and what each frame that dropped for
// the GPU found. It changes nothing it observes.
//
// The reports drive the drawable tracker. A leading-edge draw drops while
// `TerminalRenderer.maxDrawablesAwaitingPresent` drawables await their report, so how late the
// reports come bounds how often output draws at once. A display tick drops only at a full ring or
// during a nil drawable's hold, so its drops show the GPU or the compositor falling behind.
//
// Two lines, both on subsystem `com.tbd.app`, category `terminallatency`. Neither uses the
// latency tap's verbs, so `scripts/diag/terminal-latency-report.py` skips them.
//
//     presents view=<n> n=<n> dated=<n> main=<n> screenms=<s> reportms=<s> latems=<s> drops=<n> ringfull=<n> held=<n> oldestagems=<s> spanms=<f>
//     gpubehind view=<n> ringfull=<0|1> held=<0|1> awaiting=<n> entries=<n> agesms=<ms,…|-> sincepresentms=<f|->
//
// `view` numbers the views in the order they were made, so lines from two panes on screen at once
// can be told apart. Each `<s>` is `p50/p90/max` in milliseconds, or `-` with no samples.
//
//   * **`presents`** is `.info`, the latency tap's level, and comes at most once a second while
//     reports arrive or frames drop. A window ends at its first report or dropped frame
//     `summaryInterval` or more after the window's first, so the last part-second before a view
//     goes quiet is logged only when it next draws. A window with fewer than `minimumPresents`
//     reports and no dropped frame is left out, so a blinking cursor logs nothing.
//     - `n` reports, `dated` of them with a `presentedTime` above 0, and `main` of them whose
//       handler ran on the main thread.
//     - `screenms` is acquire to `presentedTime`, and `latems` is `presentedTime` to the handler.
//       Both count dated reports only: a `presentedTime` of 0 is a skipped present.
//     - `reportms` is acquire to the handler, for every report.
//     - `drops` frames dropped for the GPU, `ringfull` of them with the ring full, `held` of them
//       during a nil drawable's hold, and `oldestagems` the age of each drop's oldest unreported
//       drawable. A drop that is neither is a leading-edge frame at the drawable limit, which
//       its delivery's own peek at the tracker should already have caught.
//     - `spanms` is the window's first report or drop to its last.
//   * **`gpubehind`** is `.debug`, one per dropped frame: whether the ring was full, whether a nil
//     drawable's hold lasted, the count the tracker gave the frame, its entries and each one's age
//     oldest first, and how long before the frame the newest dated present reached the screen.
//     - The entries are read just after the frame decided, so a report landing in between can show
//       fewer `entries` than `awaiting`.
//     - A drawable a leading-edge frame acquired after a vsync, and before that vsync's tick ran,
//       can show a negative age of under one refresh: the tick's `now` is its vsync. For the same
//       reason a tick that runs late, after a later vsync's present was reported, can show a
//       negative `sincepresentms`.
//
// Acquire and handler times, and a window's bounds, come off `hostNow`, host time, the clock of
// `presentedTime`. A dropped frame's ages are by the frames' own `now`, the timebase the tracker's
// entries are kept in.

import Foundation
import QuartzCore
import Synchronization
import os

/// The latency tap's category, so one `log stream` predicate shows both.
let terminalLatencyLog = Logger(subsystem: "com.tbd.app", category: "terminallatency")

/// The last `view` number handed out.
private let presentTimingViewIDs = Atomic<Int>(0)

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

/// What a frame that dropped for the GPU found.
struct GPUBehindSample: Sendable, Equatable {
    /// The surface's ring had a slot free.
    var ringHasFreeSlot: Bool
    /// A nil drawable's hold lasted, which is what drops a display tick with a slot free.
    var nilDrawableHold: Bool
    /// What `DrawableTracker.check(now:)` counted: the limit while a nil drawable's hold lasts,
    /// and the entries otherwise.
    var awaitingPresent: Int
    /// How old each unreported entry was, oldest first, by the frames' `now`.
    var entryAges: [Duration]
    /// How long before the tick the newest dated present reached the screen. nil before the first.
    var sinceLastPresent: Duration?

    /// The `gpubehind` line, for the view numbered `view`.
    func line(view: Int) -> String {
        let ages = entryAges.isEmpty ? "-" : entryAges.map(PresentTimingLog.milliseconds).joined(separator: ",")
        let since = sinceLastPresent.map(PresentTimingLog.milliseconds) ?? "-"
        return "gpubehind view=\(view) ringfull=\(ringHasFreeSlot ? 0 : 1) held=\(nilDrawableHold ? 1 : 0) "
            + "awaiting=\(awaitingPresent) entries=\(entryAges.count) agesms=\(ages) sincepresentms=\(since)"
    }
}

/// One window of reports and dropped frames, as the `presents` line gives it.
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
    /// Drops during a nil drawable's hold.
    var heldDrops: Int
    /// Each drop's oldest unreported drawable's age.
    var oldestAge: TimingSpread?
    /// The window's first report or drop to its last.
    var span: Duration

    /// The `presents` line, for the view numbered `view`.
    func line(view: Int) -> String {
        func spread(_ value: TimingSpread?) -> String {
            guard let value else { return "-" }
            return [value.p50, value.p90, value.max].map(PresentTimingLog.milliseconds).joined(separator: "/")
        }
        return "presents view=\(view) n=\(presents) dated=\(dated) main=\(onMainThread) "
            + "screenms=\(spread(screen)) reportms=\(spread(report)) latems=\(spread(late)) "
            + "drops=\(drops) ringfull=\(ringFullDrops) held=\(heldDrops) oldestagems=\(spread(oldestAge)) "
            + "spanms=\(PresentTimingLog.milliseconds(span))"
    }
}

/// See the file header. One per `DrawableTracker`, so one per view.
///
/// Reports arrive on whatever thread Metal calls a presented handler on, and dropped frames on
/// main, so the window sits behind a lock of its own: the tracker's lock is held no longer than
/// before. A finished window is summarised, and both lines are emitted, outside it.
final class PresentTimingLog: Sendable {
    /// How often the `presents` line comes while reports arrive or frames drop.
    static let summaryInterval: Duration = .seconds(1)
    /// A window with fewer reports than this and no dropped frame is left out. A blinking cursor
    /// draws two frames a second.
    static let minimumPresents = 10
    /// The most samples of each kind one window keeps. Frames that drop all within one window, as
    /// they would with a stopped `hostNow`, are counted past this and their ages are not kept.
    static let sampleCapacity = 1024

    private struct Window {
        /// The window's first report or dropped frame, and its latest, by `hostNow`.
        var startedAt: Duration?
        var lastEventAt: Duration?
        var presents = 0
        var dated = 0
        var onMainThread = 0
        var screen: [Duration] = []
        var report: [Duration] = []
        var late: [Duration] = []
        var drops = 0
        var ringFullDrops = 0
        var heldDrops = 0
        var oldestAges: [Duration] = []

        mutating func append(_ value: Duration, to samples: WritableKeyPath<Window, [Duration]>) {
            guard self[keyPath: samples].count < PresentTimingLog.sampleCapacity else { return }
            self[keyPath: samples].append(value)
        }

        /// The window as a `presents` line, or nil when it is too quiet to log.
        var summary: PresentTimingSummary? {
            guard presents >= PresentTimingLog.minimumPresents || drops > 0 else { return nil }
            var span = Duration.zero
            if let startedAt, let lastEventAt { span = lastEventAt - startedAt }
            return PresentTimingSummary(
                presents: presents, dated: dated, onMainThread: onMainThread,
                screen: TimingSpread(screen), report: TimingSpread(report), late: TimingSpread(late),
                drops: drops, ringFullDrops: ringFullDrops, heldDrops: heldDrops,
                oldestAge: TimingSpread(oldestAges), span: span)
        }
    }

    private struct State {
        var window = Window()
        /// Every dropped frame since the log was made, and the latest one's sample. Test seams,
        /// kept past the end of a window.
        var gpuBehindNoted = 0
        var lastGPUBehind: GPUBehindSample?

        /// Stretches the window's bounds to an event at `time`, first ending the window when `time`
        /// is `summaryInterval` or more past its first event. Returns the ended window, for the
        /// caller to summarise once the lock is released: the summary sorts its samples.
        mutating func advance(to time: Duration) -> Window? {
            var finished: Window?
            if let started = window.startedAt, time - started >= PresentTimingLog.summaryInterval {
                finished = window
                window = Window()
            }
            window.startedAt = window.startedAt ?? time
            // Reports and drops take the lock in whatever order their threads reach it, so a
            // later event can carry an earlier time.
            window.lastEventAt = Swift.max(window.lastEventAt ?? time, time)
            return finished
        }
    }

    /// Numbers this view's lines.
    let viewID: Int
    /// Host time, the clock of `presentedTime` and the display link. A seam the tests set.
    let hostNow: @Sendable () -> Duration
    private let emitSummary: @Sendable (_ view: Int, PresentTimingSummary) -> Void
    private let emitDrop: @Sendable (_ view: Int, GPUBehindSample) -> Void
    private let state = Mutex(State())

    // Each line is built inside its log call, so a level nobody streams costs no string.
    init(
        viewID: Int = PresentTimingLog.nextViewID(),
        hostNow: @escaping @Sendable () -> Duration = { .seconds(CACurrentMediaTime()) },
        emitSummary: @escaping @Sendable (_ view: Int, PresentTimingSummary) -> Void = { view, summary in
            terminalLatencyLog.info("\(summary.line(view: view), privacy: .public)")
        },
        emitDrop: @escaping @Sendable (_ view: Int, GPUBehindSample) -> Void = { view, sample in
            terminalLatencyLog.debug("\(sample.line(view: view), privacy: .public)")
        }
    ) {
        self.viewID = viewID
        self.hostNow = hostNow
        self.emitSummary = emitSummary
        self.emitDrop = emitDrop
    }

    /// A drawable acquired at `acquiredAt` was reported presented, by a handler that read
    /// `reportedAt` as it began. Both are `hostNow` readings.
    func notePresented(
        acquiredAt: Duration, reportedAt: Duration, presentedTime: CFTimeInterval, onMainThread: Bool
    ) {
        let finished = state.withLock { state -> Window? in
            let finished = state.advance(to: reportedAt)
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
        if let summary = finished?.summary { emitSummary(viewID, summary) }
    }

    /// A frame dropped for the GPU, and found `sample`.
    func noteGPUBehind(_ sample: GPUBehindSample) {
        let noticedAt = hostNow()
        let finished = state.withLock { state -> Window? in
            let finished = state.advance(to: noticedAt)
            state.window.drops += 1
            if !sample.ringHasFreeSlot { state.window.ringFullDrops += 1 }
            if sample.nilDrawableHold { state.window.heldDrops += 1 }
            if let oldest = sample.entryAges.first { state.window.append(oldest, to: \.oldestAges) }
            state.gpuBehindNoted += 1
            state.lastGPUBehind = sample
            return finished
        }
        if let summary = finished?.summary { emitSummary(viewID, summary) }
        emitDrop(viewID, sample)
    }

    /// The next `view` number.
    static func nextViewID() -> Int {
        presentTimingViewIDs.wrappingAdd(1, ordering: .relaxed).newValue
    }

    // MARK: - Test seams

    /// The window as a `presents` line would give it now, with nothing ended.
    var pendingSummary: PresentTimingSummary? { state.withLock { $0.window.summary } }
    /// How many dropped frames' oldest ages the current window keeps.
    var keptOldestAges: Int { state.withLock { $0.window.oldestAges.count } }
    /// Every dropped frame since the log was made.
    var gpuBehindNoted: Int { state.withLock { $0.gpuBehindNoted } }
    /// The latest dropped frame's sample.
    var lastGPUBehind: GPUBehindSample? { state.withLock { $0.lastGPUBehind } }

    /// `duration` in milliseconds, three places.
    static func milliseconds(_ duration: Duration) -> String {
        let components = duration.components
        let ms = Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
        return String(format: "%.3f", ms)
    }
}
