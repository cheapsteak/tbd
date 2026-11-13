// Dropping a frame instead of blocking follows termio 8196587 Shared/Sources/TermioStream/TermiodStreamRenderer.swift (MIT, see LICENSE-termio.txt), which drops on its in-flight count; this tracker carries the drop to drawables.
// DrawableTracker — the drawables a view's layer has handed out that Metal has not yet reported
// presented.
//
// `CAMetalLayer.nextDrawable()` blocks, for up to a second, when every drawable in the layer's
// pool is out. A leading-edge draw, which runs inside a render signal's delivery, asks for one only
// while fewer than `TerminalRenderer.maxDrawablesAwaitingPresent` await their present report, so
// it never waits for a drawable this tracker counts as out. A display tick does not count them.
// Under bulk output each report reaches this tracker three or more refreshes after the frame that
// acquired its drawable, so a tick that waited for the count would draw about one refresh in two.
// A tick asks for a drawable whatever the count, and may wait in `nextDrawable()` for one the
// compositor still holds.
//
// That count is only as good as the reports, and an offscreen window's drawables may never be
// reported presented at all. A lost report would hold the count up and stop the leading edge
// drawing for good. An old entry is not proof that its drawable is free, though. So recovery takes
// evidence first and time last:
//
//   * **Evidence.** A layer's presents reach the screen in the order they were made, so a report
//     for one drawable also removes every older entry. One lost report clears at the next report.
//   * **Time.** Only when no report has arrived for `presentReportTimeout`, by the frames' own
//     `now`, are the entries cleared. The first clear in a run logs a notice. Each frame's check
//     runs this, so the entries stay bounded while a tick draws past them. After a clear, a
//     leading-edge draw too asks for a drawable with no proof that one is free, and the hold
//     below bounds its wait as it does a tick's.
//
// The tick's wait is bounded: a nil drawable proves the pool full, and the tracker then holds off
// every tick and leading-edge draw until a present made after the nil came back is reported, or
// another `presentReportTimeout` passes. A late report of an earlier present, which bulk output
// leaves queued, proves nothing about the pool since and ends nothing. So a compositor that stalls
// costs main one wait of up to a second, and then at least a second with none. One that is slow
// but alive, freeing each drawable within the timeout, makes every tick wait for it, and starts no
// hold.
//
// One per view, because the drawables belong to the view's layer and outlive a surface detach.

import Foundation
import Synchronization
import TBDGhosttyCore
import os

/// The drawables a view's layer has handed out and Metal has not reported presented.
///
/// Main acquires, drops and checks. Reports arrive on whatever thread Metal calls a drawable's
/// presented handler on, so the state sits behind a lock.
final class DrawableTracker: Sendable {
    /// One acquired drawable. Ids rise in the order the drawables were acquired.
    struct DrawableID: Hashable, Sendable {
        fileprivate let value: UInt64
    }

    /// How long the tracker waits for a report before it stops trusting its entries, and how long
    /// it holds the limit after a nil drawable. `nextDrawable()`'s own timeout.
    static let presentReportTimeout: Duration = .seconds(1)

    private struct Entry {
        let id: DrawableID
        /// The `now` of the frame that acquired the drawable.
        let acquiredAt: Duration
        /// `State.reports` when the drawable was acquired: a report counts against this entry's
        /// silence only if it came later.
        let reportsBefore: UInt64
    }

    /// A nil drawable's hold on the limit.
    private struct LimitHold {
        /// The earliest the nil could have come back: the `now` of the frame that asked, plus
        /// `presentReportTimeout`, since `nextDrawable()` returns nil for a full pool only once
        /// it has waited that long. Only a present dated from then on shows a drawable freed since.
        let freshPresentsFrom: Duration
        /// The `now` of the first check after the nil drawable, which starts the timer; nil until
        /// that check.
        var startedAt: Duration?
    }

    private struct State {
        /// Oldest first.
        var entries: [Entry] = []
        var lastID: UInt64 = 0
        /// Every report, whatever drawable it names.
        var reports: UInt64 = 0
        /// When the latest report arrived, in the frames' timebase. Dated by its `presentedTime`,
        /// which is host time, as the display link's timestamps are. A report with none is dated
        /// by the `now` of the check that first sees it: late, never early.
        var lastReportAt: Duration?
        /// A report with no `presentedTime` came in, and no check has dated it yet.
        var undatedReportPending = false
        /// The latest `presentedTime` reported, for `noteGPUBehind`: `lastReportAt` without the
        /// dates a check gives undated reports.
        var lastPresentedAt: Duration?
        /// Set by a nil drawable: the pool is full whatever the entries say.
        var hold: LimitHold?
        /// Whether this run of unreported presents has logged its notice. A report ends the run.
        var noticeLoggedThisRun = false
        /// Backs `ignoresPresentedHandlers`.
        var ignoresPresentedHandlers = false

        var acquiredCount = 0
        var timeoutClears = 0
        var lostReportNotices = 0
        var skippedPresents = 0
        var skippedPresentNotices = 0
    }

    /// The count a full pool reports: `TerminalRenderer.maxDrawablesAwaitingPresent`.
    let limit: Int
    /// The present-timing diagnostic: how late this view's reports come, and what each frame that
    /// dropped for the GPU found. It reads the tracker and changes nothing.
    let presentTiming: PresentTimingLog
    private let state = Mutex(State())

    init(
        limit: Int = TerminalRenderer.maxDrawablesAwaitingPresent,
        presentTiming: PresentTimingLog = PresentTimingLog()
    ) {
        self.limit = limit
        self.presentTiming = presentTiming
    }

    // MARK: - The frame's side (main)

    /// What a frame learns from the tracker before it builds anything.
    struct Check: Sendable, Equatable {
        /// How many drawables to count as awaiting their present report: the limit while a nil
        /// drawable's hold lasts, and the entries otherwise. A leading-edge draw drops at the
        /// limit.
        var awaitingPresent: Int
        /// A nil drawable's hold lasts: the pool is full, whatever the entries say. The only
        /// drawable reason a display tick drops.
        var nilDrawableHold: Bool

        fileprivate static func entries(_ count: Int) -> Check {
            Check(awaitingPresent: count, nilDrawableHold: false)
        }
    }

    /// What a frame due at `now` should count as awaiting a report, and whether a nil drawable's
    /// hold lasts. Called before the frame builds anything. Starts a nil drawable's hold at the
    /// first check after it, and clears the entries when no report has arrived for
    /// `presentReportTimeout`.
    func check(now: Duration) -> Check {
        let (result, clearedForNotice) = state.withLock { state in
            Self.runCheck(&state, now: now, limit: limit)
        }
        if let clearedForNotice {
            let timeout = String(describing: Self.presentReportTimeout)
            terminalEngineLog.notice("""
                no drawable was reported presented for \(timeout, privacy: .public): cleared \
                \(clearedForNotice, privacy: .public) drawables awaiting their report
                """)
        }
        return result
    }

    /// `check(now:)`'s count alone.
    func awaitingPresent(now: Duration) -> Int {
        check(now: now).awaitingPresent
    }

    /// What `awaitingPresent(now:)` would answer at `now`, with none of its side effects: no
    /// clear, no notice, no start to a nil drawable's hold, and no date given to a report. For a
    /// caller that only asks, as a render signal's delivery does when it decides whether to draw.
    /// The frame it then draws makes the real check, at the same `now`.
    func peekAwaitingPresent(now: Duration) -> Int {
        state.withLock { state in
            var copy = state
            return Self.runCheck(&copy, now: now, limit: limit).check.awaitingPresent
        }
    }

    /// The check behind `check(now:)`, run on `state` under the lock. Returns what the frame
    /// learns, and how many entries a clear removed when that clear is the first in its run and so
    /// logs.
    private static func runCheck(
        _ state: inout State, now: Duration, limit: Int
    ) -> (check: Check, clearedForNotice: Int?) {
        if state.undatedReportPending {
            state.undatedReportPending = false
            state.lastReportAt = max(state.lastReportAt ?? now, now)
        }
        let held = Check(awaitingPresent: limit, nilDrawableHold: true)
        if let hold = state.hold {
            guard let started = hold.startedAt else {
                // Timed from the first check after the nil drawable, not from that frame's own
                // `now`: its `nextDrawable()` waited up to a second before returning nil, so that
                // `now` is already old, and timing from it would let the next wait follow at once.
                state.hold?.startedAt = now
                return (held, nil)
            }
            guard now - started >= presentReportTimeout else { return (held, nil) }
            state.hold = nil
        }
        guard let oldest = state.entries.first else { return (.entries(0), nil) }
        var quietSince = oldest.acquiredAt
        if state.reports != oldest.reportsBefore, let lastReportAt = state.lastReportAt {
            quietSince = max(quietSince, lastReportAt)
        }
        guard now - quietSince >= presentReportTimeout else { return (.entries(state.entries.count), nil) }
        let cleared = state.entries.count
        state.entries.removeAll()
        state.timeoutClears += 1
        guard !state.noticeLoggedThisRun else { return (.entries(0), nil) }
        state.noticeLoggedThisRun = true
        state.lostReportNotices += 1
        return (.entries(0), cleared)
    }

    /// Records a drawable the frame due at `now` acquired, and returns its id for the presented
    /// handler and the drop path.
    func add(acquiredAt now: Duration) -> DrawableID {
        state.withLock { state in
            state.lastID += 1
            state.acquiredCount += 1
            let id = DrawableID(value: state.lastID)
            state.entries.append(Entry(id: id, acquiredAt: now, reportsBefore: state.reports))
            return id
        }
    }

    /// The frame dropped the drawable `id` unpresented, as when its render encoder could not be
    /// made. Removes that entry alone: no older drawable has been presented by this.
    func remove(_ id: DrawableID) {
        state.withLock { state in
            state.entries.removeAll { $0.id == id }
        }
    }

    /// The layer gave the frame due at `now` no drawable: the pool is full, whatever the entries
    /// say. Holds the limit until a present made after the nil came back is reported, or until
    /// `presentReportTimeout` has passed from the next check.
    ///
    /// For a full pool, `nextDrawable()` returns nil only after waiting `presentReportTimeout`, so
    /// a present is fresh from `now` plus that timeout. A present dated earlier was made before
    /// the nil: had it freed a drawable no frame took, the request would have had it. Bulk output
    /// leaves several such reports queued, and were they to end the hold, the next tick would wait
    /// again at once. A fresh present already reported, which a handler on another thread can
    /// deliver before the frame notes the nil, means no hold is set: set, it would outlast the
    /// report that should have ended it. A nil that came back sooner, as one for a layer with no
    /// usable size can, holds until the timeout.
    func noteNoDrawable(requestedAt now: Duration) {
        state.withLock { state in
            let freshPresentsFrom = now + Self.presentReportTimeout
            if let presented = state.lastPresentedAt, presented >= freshPresentsFrom { return }
            state.hold = LimitHold(freshPresentsFrom: freshPresentsFrom)
        }
    }

    /// A frame due at `now` dropped for the GPU: hands `presentTiming` the age of each entry, and
    /// how long ago the newest dated present reached the screen. Reads the state and changes none
    /// of it, so it runs no recovery, as `entryCount` does not.
    ///
    /// - Parameters:
    ///   - ringHasFreeSlot: whether the surface's ring had a slot free.
    ///   - drawables: what `check(now:)` told the frame.
    func noteGPUBehind(now: Duration, ringHasFreeSlot: Bool, drawables: Check) {
        let sample = state.withLock { state in
            GPUBehindSample(
                ringHasFreeSlot: ringHasFreeSlot, nilDrawableHold: drawables.nilDrawableHold,
                awaitingPresent: drawables.awaitingPresent,
                entryAges: state.entries.map { now - $0.acquiredAt },
                sinceLastPresent: state.lastPresentedAt.map { now - $0 })
        }
        presentTiming.noteGPUBehind(sample)
    }

    // MARK: - Metal's side (any thread)

    /// A drawable's presented handler ran: `reportPresented(_:presentedTime:)`, unless a test has
    /// set `ignoresPresentedHandlers`.
    func reportFromPresentedHandler(_ id: DrawableID, presentedTime: CFTimeInterval) {
        guard !ignoresPresentedHandlers else { return }
        reportPresented(id, presentedTime: presentedTime)
    }

    /// The drawable `id` was reported presented. Removes it and every older entry, since a layer's
    /// presents reach the screen in order. An id no longer tracked, because a drop or a clear
    /// removed it, removes nothing, but still counts as a report: Metal is reporting this layer's
    /// presents, and a present frees a drawable. A present made after a nil drawable came back
    /// ends its hold; an earlier or undated one does not (`noteNoDrawable(requestedAt:)`).
    ///
    /// - Parameter presentedTime: the drawable's `presentedTime`, which dates the report. Zero is a
    ///   frame that "has not been presented or has been skipped": it is counted, and the next
    ///   check dates the report instead. The count is logged at `.notice` each time it reaches a
    ///   power of two, so a soak or an A/B log shows whether it rises without a line per present.
    func reportPresented(_ id: DrawableID, presentedTime: CFTimeInterval) {
        let skippedForNotice = state.withLock { state -> Int? in
            state.reports &+= 1
            state.noticeLoggedThisRun = false
            var countToLog: Int?
            if presentedTime > 0 {
                let presentedAt = Duration.seconds(presentedTime)
                state.lastReportAt = max(state.lastReportAt ?? presentedAt, presentedAt)
                state.lastPresentedAt = max(state.lastPresentedAt ?? presentedAt, presentedAt)
                if let hold = state.hold, presentedAt >= hold.freshPresentsFrom {
                    state.hold = nil
                }
            } else {
                state.skippedPresents += 1
                state.undatedReportPending = true
                if state.skippedPresents.nonzeroBitCount == 1 {
                    state.skippedPresentNotices += 1
                    countToLog = state.skippedPresents
                }
            }
            if let index = state.entries.firstIndex(where: { $0.id == id }) {
                state.entries.removeSubrange(...index)
            }
            return countToLog
        }
        if let skippedForNotice {
            // A count that rises while typing is the sign of a leading-edge frame sharing a vsync
            // with the next tick's ("Risks" in docs/specs/2026-11-08-libghostty-frame-timing-design.md).
            terminalEngineLog.notice("""
                \(skippedForNotice, privacy: .public) presents of this view were reported skipped \
                (presentedTime 0) so far
                """)
        }
    }

    // MARK: - Diagnostics and test seams

    /// Whether the tracker ignores what Metal's presented handlers report. A test seam: an
    /// offscreen window's presents may be reported at once, late or never, so a view test that
    /// reports its drawables itself, through `reportPresented(_:presentedTime:)`, sets it, and
    /// each report then comes when the test sends it. The present-timing log and the view's
    /// `onFramePresented` still hear Metal's reports.
    var ignoresPresentedHandlers: Bool {
        get { state.withLock { $0.ignoresPresentedHandlers } }
        set { state.withLock { $0.ignoresPresentedHandlers = newValue } }
    }

    /// The entries, as they stand: no recovery is run.
    var entryCount: Int { state.withLock { $0.entries.count } }
    /// The newest entry's id, or nil with none. A test seam: a view test reports a frame's own
    /// drawable late through it, as a handler running behind a busy main thread would.
    var newestEntryID: DrawableID? { state.withLock { $0.entries.last?.id } }
    /// Drawables recorded since the tracker was made.
    var acquiredCount: Int { state.withLock { $0.acquiredCount } }
    /// How many times the entries were cleared for want of a report.
    var timeoutClears: Int { state.withLock { $0.timeoutClears } }
    /// How many notices those clears logged: one for each run of them.
    var lostReportNotices: Int { state.withLock { $0.lostReportNotices } }
    /// Reports whose `presentedTime` was 0. A count that rises while typing is the sign of a frame
    /// drawn just before a vsync landing on the same vsync as the next one.
    var skippedPresents: Int { state.withLock { $0.skippedPresents } }
    /// How many notices that count logged: one each time it reached a power of two.
    var skippedPresentNotices: Int { state.withLock { $0.skippedPresentNotices } }

    /// Reports the newest entry presented, as its presented handler would, at the time it was
    /// acquired. A test seam: an offscreen window's drawables may never be reported, so the view
    /// tests report each frame's drawable this way. Does nothing with no entries.
    func reportNewestPresented() {
        guard let newest = state.withLock({ $0.entries.last }) else { return }
        reportPresented(newest.id, presentedTime: newest.acquiredAt / .seconds(1))
    }
}
