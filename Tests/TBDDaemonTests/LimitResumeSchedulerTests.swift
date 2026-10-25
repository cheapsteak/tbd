import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// Scripted actuator: returns queued outcomes in order, records calls.
final class FakeActuator: LimitResumeActuating, @unchecked Sendable {
    private let queue = DispatchQueue(label: "FakeActuator")
    private var outcomes: [ResumeActuationOutcome]
    private var _calls: [ScheduledResume] = []
    private var _alreadyContinued = false
    private var _earlyProbes: [ScheduledResume] = []
    var calls: [ScheduledResume] { queue.sync { _calls } }
    /// Rows the scheduler ran the early-cancel probe against.
    var earlyProbes: [ScheduledResume] { queue.sync { _earlyProbes } }
    /// What `userAlreadyContinued` answers — flip mid-test to simulate the
    /// session's transcript growing while the row is still pending.
    var alreadyContinued: Bool {
        get { queue.sync { _alreadyContinued } }
        set { queue.sync { _alreadyContinued = newValue } }
    }

    init(_ outcomes: [ResumeActuationOutcome] = [.sent]) {
        self.outcomes = outcomes
    }

    func actuate(_ resume: ScheduledResume) async -> ResumeActuationOutcome {
        queue.sync {
            _calls.append(resume)
            return outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
        }
    }

    func userAlreadyContinued(_ resume: ScheduledResume) async -> Bool {
        queue.sync {
            _earlyProbes.append(resume)
            return _alreadyContinued
        }
    }
}

final class OutcomeCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "OutcomeCollector")
    private var _events: [(ScheduledResume, LimitResumeOutcome)] = []
    var events: [(ScheduledResume, LimitResumeOutcome)] { queue.sync { _events } }
    func record(_ resume: ScheduledResume, _ outcome: LimitResumeOutcome) {
        queue.sync { _events.append((resume, outcome)) }
    }
}

/// No step sleeps a fixed time. Each test uses one of two waits, whichever
/// its next assertion needs:
///
/// - `clock.requireSleeperArmed()` when the loop still has a pending row. The
///   loop parks on exactly one clock sleep per pending row, so once it is
///   parked, everything the last advance made due has run, and a negative
///   ("still sleeping, not actuated") is settled rather than sampled.
/// - `loopEffect(_:)` when the row leaves pending and the loop goes idle,
///   which the clock cannot see. It waits for the last write the branch makes
///   (the row's status, or the outcome callback that follows it), so every
///   assertion after it reads a finished fire.
@Suite struct LimitResumeSchedulerTests {
    let db: TBDDatabase
    let clock: TestPollerClock
    let terminalID: UUID
    let worktreeID: UUID

    init() async throws {
        db = try TBDDatabase(inMemory: true)
        clock = TestPollerClock()
        try await db.config.setAutoResumeOnLimitReset(true)
        let repo = try await db.repos.create(
            path: "/tmp/lrs-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/lrs-wt-\(UUID().uuidString)", tmuxServer: "tbd-lrs")
        worktreeID = wt.id
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1")
        terminalID = terminal.id
    }

    private func makeScheduler(
        actuator: FakeActuator,
        jitter: TimeInterval = 0,
        onOutcome: @escaping @Sendable (ScheduledResume, LimitResumeOutcome) async -> Void = { _, _ in }
    ) -> LimitResumeScheduler {
        LimitResumeScheduler(
            store: db.scheduledResumes, config: db.config,
            actuator: actuator, clock: clock,
            jitterProvider: { jitter }, onOutcome: onOutcome)
    }

    /// Waits until `condition` holds, throwing a named timeout otherwise.
    private func loopEffect(
        _ what: String, _ condition: () async -> Bool
    ) async throws {
        switch await pollUntilTrue(timeout: TestDeadlines.saturatedPass, condition) {
        case .satisfied: return
        case .cancelled: throw CancellationError()
        case .timedOut:
            throw BoundedWaitTimeout(what: what, observed: nil, deadline: TestDeadlines.saturatedPass)
        }
    }

    private func status(of id: UUID) async -> ScheduledResumeStatus? {
        try? await db.scheduledResumes.get(id: id)?.status
    }

    /// Waits for the row to leave `.pending`, the last store write of every
    /// fire and early-cancel branch, and returns the status it landed on.
    /// Waiting for "left pending" rather than for the expected status lets a
    /// wrong branch fail on the assertion at once instead of on the timeout.
    private func settledStatus(of id: UUID) async throws -> ScheduledResumeStatus? {
        try await loopEffect("row \(id) leaving .pending") {
            guard let current = await status(of: id) else { return false }
            return current != .pending
        }
        return await status(of: id)
    }

    @Test func scheduleComputesFireAtWithSlackAndJitter() async throws {
        let scheduler = makeScheduler(actuator: FakeActuator(), jitter: 10)
        let resetsAt = clock.now().addingTimeInterval(3600)
        let row = await scheduler.schedule(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: resetsAt, limitType: "session", rawMessage: "m")
        #expect(row != nil)
        #expect(abs(row!.fireAt.timeIntervalSince(resetsAt) - 70) < 1) // 60 slack + 10 jitter
    }

    @Test func latchSecondScheduleReturnsNil() async throws {
        let scheduler = makeScheduler(actuator: FakeActuator())
        let resetsAt = clock.now().addingTimeInterval(3600)
        _ = await scheduler.schedule(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: resetsAt, limitType: "session", rawMessage: "m")
        let second = await scheduler.schedule(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: resetsAt, limitType: "session", rawMessage: "m")
        #expect(second == nil)
    }

    @Test func pastDueRowFiresImmediatelyOnStart() async throws {
        // Startup reload: a persisted past-due row (Mac slept past reset).
        _ = try await db.scheduledResumes.insertPending(ScheduledResume(
            terminalID: terminalID, worktreeID: worktreeID,
            resetsAt: clock.now().addingTimeInterval(-120),
            fireAt: clock.now().addingTimeInterval(-60),
            limitType: "session", rawMessage: "m"))
        let actuator = FakeActuator([.sent])
        let collector = OutcomeCollector()
        let scheduler = makeScheduler(actuator: actuator) { collector.record($0, $1) }
        await scheduler.start()
        // onOutcome runs after the status write, so it closes the fire.
        try await loopEffect("the past-due row's outcome") { !collector.events.isEmpty }
        #expect(actuator.calls.count == 1)
        let rows = try await db.scheduledResumes.pending()
        #expect(rows.isEmpty)
        #expect(collector.events.count == 1)
        if case .sent = collector.events.first?.1 {} else { Issue.record("expected .sent") }
        await scheduler.stop()
    }

    @Test func sleepsUntilFireAtThenActuates() async throws {
        let actuator = FakeActuator([.sent])
        let scheduler = makeScheduler(actuator: actuator)
        await scheduler.start()
        let scheduled = await scheduler.schedule(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: clock.now().addingTimeInterval(600),
            limitType: "session", rawMessage: "m")
        let id = try #require(scheduled?.id)
        try await clock.requireSleeperArmed()
        #expect(actuator.calls.isEmpty)          // still sleeping
        await clock.advance(by: 700)             // past resetsAt + slack
        #expect(try await settledStatus(of: id) == .sent)
        #expect(actuator.calls.count == 1)
        await scheduler.stop()
    }

    @Test func copyModeReschedulesPlusTwoMinutes() async throws {
        let actuator = FakeActuator([.paneInCopyMode, .sent])
        let scheduler = makeScheduler(actuator: actuator)
        await scheduler.start()
        let scheduled = await scheduler.schedule(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: clock.now().addingTimeInterval(-120),
            limitType: "session", rawMessage: "m")
        let id = try #require(scheduled?.id)
        // The reschedule leaves the row pending, so the loop re-parks.
        try await clock.requireSleeperArmed()
        #expect(actuator.calls.count == 1)
        let row = try #require(try await db.scheduledResumes.pending(terminalID: terminalID))
        #expect(row.attemptCount == 1)
        #expect(row.fireAt.timeIntervalSince(clock.now()) > 100) // ~+120s
        await clock.advance(by: 130)
        #expect(try await settledStatus(of: id) == .sent)
        #expect(actuator.calls.count == 2)
        #expect(try await db.scheduledResumes.pending(terminalID: terminalID) == nil)
        await scheduler.stop()
    }

    @Test func copyModeCapsAtFifteenAttemptsThenFails() async throws {
        let actuator = FakeActuator([.paneInCopyMode])
        let collector = OutcomeCollector()
        let scheduler = makeScheduler(actuator: actuator) { collector.record($0, $1) }
        await scheduler.start()
        _ = await scheduler.schedule(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: clock.now().addingTimeInterval(-120),
            limitType: "session", rawMessage: "m")
        // Every attempt below the cap reschedules +120 s and re-parks the
        // loop, so each arming is the barrier before the next advance. The
        // attempt that hits the cap leaves nothing pending.
        for attempt in 1..<LimitResumeScheduler.maxCopyModeAttempts {
            try await clock.requireSleeperArmed()
            #expect(actuator.calls.count == attempt)
            await clock.advance(by: 130)
        }
        try await loopEffect("the copy-mode cap's .failed outcome") {
            collector.events.contains { if case .failed = $0.1 { return true }; return false }
        }
        #expect(actuator.calls.count == LimitResumeScheduler.maxCopyModeAttempts)
        let rows = try await db.scheduledResumes.pending()
        #expect(rows.isEmpty)
        await scheduler.stop()
    }

    /// Deterministic toggle-off race: schedule with a FUTURE resetsAt so the
    /// loop parks sleeping on the virtual clock, write the config change
    /// (guaranteed to complete before anything else happens), THEN advance
    /// the clock past fireAt. No real-time dependence, no thread-scheduling
    /// race between the config write and the fire.
    @Test func toggleOffAtFireTimeCancelsSilently() async throws {
        let actuator = FakeActuator([.sent])
        let collector = OutcomeCollector()
        let scheduler = makeScheduler(actuator: actuator) { collector.record($0, $1) }
        await scheduler.start()
        let resetsAt = clock.now().addingTimeInterval(600)
        let scheduled = await scheduler.schedule(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: resetsAt, limitType: "session", rawMessage: "m")
        let id = try #require(scheduled?.id)
        try await clock.requireSleeperArmed()
        #expect(actuator.calls.isEmpty)   // still parked, sleeping until fireAt

        // Completes fully before the clock advances below — no race.
        try await db.config.setAutoResumeOnLimitReset(false)

        await clock.advance(by: 700)      // past resetsAt + slack

        #expect(try await settledStatus(of: id) == .cancelled)
        #expect(actuator.calls.isEmpty)
        #expect(collector.events.isEmpty)
        await scheduler.stop()
    }

    @Test func userAlreadyContinuedCancelsWithoutOutcome() async throws {
        let actuator = FakeActuator([.userAlreadyContinued])
        let collector = OutcomeCollector()
        let scheduler = makeScheduler(actuator: actuator) { collector.record($0, $1) }
        await scheduler.start()
        let scheduled = await scheduler.schedule(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: clock.now().addingTimeInterval(-120),
            limitType: "session", rawMessage: "m")
        let id = try #require(scheduled?.id)
        #expect(try await settledStatus(of: id) == .cancelled)
        #expect(try await db.scheduledResumes.pending().isEmpty)
        #expect(collector.events.isEmpty)
        await scheduler.stop()
    }

    @Test func terminalGoneCancelsWithoutOutcome() async throws {
        let actuator = FakeActuator([.terminalGone])
        let collector = OutcomeCollector()
        let scheduler = makeScheduler(actuator: actuator) { collector.record($0, $1) }
        await scheduler.start()
        let scheduled = await scheduler.schedule(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: clock.now().addingTimeInterval(-120),
            limitType: "session", rawMessage: "m")
        let id = try #require(scheduled?.id)
        #expect(try await settledStatus(of: id) == .cancelled)
        #expect(actuator.calls.count == 1)   // no retry
        #expect(collector.events.isEmpty)
        await scheduler.stop()
    }

    /// If a row is cancelled out from under a copy-mode retry (e.g. by a
    /// concurrent cancel) between actuation and the reschedule write,
    /// `store.reschedule` returns false. The scheduler must not resurrect
    /// the row into pending — it drops it from consideration instead.
    ///
    /// The row's cancel lands inside `actuate`, before the reschedule write
    /// this test is about, so "nothing pending" alone could be read too early.
    /// A second terminal's row, scheduled once the first actuation has begun,
    /// is the barrier: the loop fires due rows in sequence and that row was not
    /// in the batch being fired, so its outcome follows the first row's
    /// reschedule attempt.
    @Test func copyModeRescheduleDropsRowNoLongerPending() async throws {
        final class CancellingActuator: LimitResumeActuating, @unchecked Sendable {
            let store: ScheduledResumeStore
            let barrierTerminalID: UUID
            private let lock = NSLock()
            private var _calls: [UUID] = []
            /// Terminal IDs in actuation order.
            var calls: [UUID] { lock.withLock { _calls } }
            init(store: ScheduledResumeStore, barrierTerminalID: UUID) {
                self.store = store
                self.barrierTerminalID = barrierTerminalID
            }
            func actuate(_ resume: ScheduledResume) async -> ResumeActuationOutcome {
                lock.withLock { _calls.append(resume.terminalID) }
                if resume.terminalID == barrierTerminalID { return .sent }
                _ = try? await store.cancelPending(terminalID: resume.terminalID)
                return .paneInCopyMode
            }
            func userAlreadyContinued(_ resume: ScheduledResume) async -> Bool { false }
        }
        let barrierTerminal = try await db.terminals.create(
            worktreeID: worktreeID, tmuxWindowID: "@2", tmuxPaneID: "%2")
        let actuator = CancellingActuator(
            store: db.scheduledResumes, barrierTerminalID: barrierTerminal.id)
        let collector = OutcomeCollector()
        let scheduler = LimitResumeScheduler(
            store: db.scheduledResumes, config: db.config,
            actuator: actuator, clock: clock,
            jitterProvider: { 0 }, onOutcome: { collector.record($0, $1) })
        await scheduler.start()
        _ = await scheduler.schedule(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: clock.now().addingTimeInterval(-120),
            limitType: "session", rawMessage: "m")
        try await loopEffect("the copy-mode actuation") { !actuator.calls.isEmpty }
        _ = await scheduler.schedule(
            terminalID: barrierTerminal.id, worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: clock.now().addingTimeInterval(-120),
            limitType: "session", rawMessage: "m")
        try await loopEffect("the barrier row's outcome") { !collector.events.isEmpty }

        #expect(try await db.scheduledResumes.pending().isEmpty)
        #expect(actuator.calls == [terminalID, barrierTerminal.id])   // never re-actuated
        #expect(collector.events.map { $0.0.terminalID } == [barrierTerminal.id])
        await scheduler.stop()
    }

    // MARK: - Early cancel on transcript growth

    /// Claude Code retried and recovered its OWN turn: no UserPromptSubmit
    /// event fires, so the only signal is transcript growth. The loop's
    /// capped sleep must catch it well before fireAt instead of leaving the
    /// session badged "auto-resume scheduled" for the whole wait.
    @Test func transcriptGrowthCancelsPendingRowLongBeforeFireAt() async throws {
        let actuator = FakeActuator([.sent])
        let collector = OutcomeCollector()
        let scheduler = makeScheduler(actuator: actuator) { collector.record($0, $1) }
        await scheduler.start()
        let scheduled = await scheduler.schedule(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: clock.now().addingTimeInterval(600),
            limitType: "session", rawMessage: "m")
        let id = try #require(scheduled?.id)
        try await clock.requireSleeperArmed()
        #expect(actuator.calls.isEmpty)   // parked, nowhere near fireAt

        actuator.alreadyContinued = true
        await clock.advance(by: LimitResumeScheduler.earlyCheckInterval + 1)

        #expect(try await settledStatus(of: id) == .cancelled)
        // The UI mirror is nilled by the same write (setStatus).
        #expect(try await db.terminals.get(id: terminalID)?.pendingResumeAt == nil)
        #expect(actuator.calls.isEmpty)   // never actuated
        #expect(collector.events.isEmpty)

        // Still cancelled past the original fireAt — no late fire. Nothing is
        // pending, so nothing is parked on the clock for an advance to wake.
        #expect(clock.sleeperCount == 0)
        await clock.advance(by: 700)
        #expect(actuator.calls.isEmpty)
        await scheduler.stop()
    }

    /// Other branch: the probe says the transcript did NOT grow, so the row
    /// survives every early pass and fires normally at fireAt.
    @Test func noTranscriptGrowthLeavesRowPendingAndStillFiresAtFireAt() async throws {
        let actuator = FakeActuator([.sent])
        let scheduler = makeScheduler(actuator: actuator)
        await scheduler.start()
        let scheduled = await scheduler.schedule(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: clock.now().addingTimeInterval(600),
            limitType: "session", rawMessage: "m")
        let id = try #require(scheduled?.id)
        try await clock.requireSleeperArmed()

        // The early pass runs, the row survives it, and the loop re-parks.
        await clock.advance(by: LimitResumeScheduler.earlyCheckInterval + 1)
        try await clock.requireSleeperArmed()
        #expect(!actuator.earlyProbes.isEmpty)   // the pass really ran
        #expect(try await db.scheduledResumes.pending(terminalID: terminalID) != nil)
        #expect(actuator.calls.isEmpty)

        await clock.advance(by: 700)             // past resetsAt + slack
        #expect(try await settledStatus(of: id) == .sent)
        #expect(actuator.calls.count == 1)
        await scheduler.stop()
    }

    /// A due row is never early-probed — `actuate`'s own eligibility pass
    /// runs the same predicate on fresher bytes moments later.
    @Test func dueRowSkipsEarlyProbeAndFires() async throws {
        let actuator = FakeActuator([.sent])
        actuator.alreadyContinued = true   // would cancel if it were probed
        let scheduler = makeScheduler(actuator: actuator)
        await scheduler.start()
        let scheduled = await scheduler.schedule(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: clock.now().addingTimeInterval(-120),
            limitType: "session", rawMessage: "m")
        let id = try #require(scheduled?.id)
        #expect(try await settledStatus(of: id) == .sent)
        #expect(actuator.earlyProbes.isEmpty)
        #expect(actuator.calls.count == 1)
        await scheduler.stop()
    }

    // MARK: - scheduleTransient (spec 2026-07-08 §Backoff)

    @Test func scheduleTransientFireAtIsExactNoSlackNoJitter() async throws {
        // Non-zero jitter provider proves scheduleTransient never consults it.
        let scheduler = makeScheduler(actuator: FakeActuator(), jitter: 999)
        let now = clock.now()
        let row = await scheduler.scheduleTransient(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            delay: 60, rawMessage: "m")
        #expect(row != nil)
        #expect(row!.limitType == ScheduledResume.apiErrorLimitType)
        #expect(row!.fireAt == now.addingTimeInterval(60))
        #expect(row!.resetsAt == row!.fireAt)
    }

    @Test func scheduleTransientLatchSecondCallReturnsNil() async throws {
        let scheduler = makeScheduler(actuator: FakeActuator())
        _ = await scheduler.scheduleTransient(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            delay: 60, rawMessage: "m")
        let second = await scheduler.scheduleTransient(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            delay: 60, rawMessage: "m")
        #expect(second == nil)
    }

    /// Api-error row fires purely off `autoResumeOnApiError`, independent of
    /// `autoResumeOnLimitReset` — mirror-image of
    /// `sessionRowGatedOnlyByLimitResetToggle` below (spec 2026-07-08 §Gating).
    @Test func apiErrorRowGatedOnlyByApiErrorToggle() async throws {
        try await db.config.setAutoResumeOnLimitReset(false)
        try await db.config.setAutoResumeOnApiError(true)
        let actuator = FakeActuator([.sent])
        let scheduler = makeScheduler(actuator: actuator)
        await scheduler.start()
        let scheduled = await scheduler.scheduleTransient(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            delay: 60, rawMessage: "m")
        let id = try #require(scheduled?.id)
        try await clock.requireSleeperArmed()
        await clock.advance(by: 65)
        #expect(try await settledStatus(of: id) == .sent)
        #expect(actuator.calls.count == 1)
        await scheduler.stop()
    }

    @Test func apiErrorRowCancelledWhenApiErrorToggleOffEvenIfLimitResetOn() async throws {
        try await db.config.setAutoResumeOnLimitReset(true)
        try await db.config.setAutoResumeOnApiError(false)
        let actuator = FakeActuator([.sent])
        let scheduler = makeScheduler(actuator: actuator)
        await scheduler.start()
        let scheduled = await scheduler.scheduleTransient(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            delay: 60, rawMessage: "m")
        let id = try #require(scheduled?.id)
        try await clock.requireSleeperArmed()
        await clock.advance(by: 65)
        #expect(try await settledStatus(of: id) == .cancelled)
        #expect(actuator.calls.isEmpty)
        await scheduler.stop()
    }

    /// Session row fires purely off `autoResumeOnLimitReset`, independent of
    /// `autoResumeOnApiError` — mirror-image of the api_error pair above.
    @Test func sessionRowGatedOnlyByLimitResetToggle() async throws {
        try await db.config.setAutoResumeOnLimitReset(true)
        try await db.config.setAutoResumeOnApiError(false)
        let actuator = FakeActuator([.sent])
        let scheduler = makeScheduler(actuator: actuator)
        await scheduler.start()
        let scheduled = await scheduler.schedule(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: clock.now().addingTimeInterval(60), limitType: "session", rawMessage: "m")
        let id = try #require(scheduled?.id)
        try await clock.requireSleeperArmed()
        await clock.advance(by: 130)
        #expect(try await settledStatus(of: id) == .sent)
        #expect(actuator.calls.count == 1)
        await scheduler.stop()
    }

    @Test func sessionRowCancelledWhenLimitResetToggleOffEvenIfApiErrorOn() async throws {
        try await db.config.setAutoResumeOnLimitReset(false)
        try await db.config.setAutoResumeOnApiError(true)
        let actuator = FakeActuator([.sent])
        let scheduler = makeScheduler(actuator: actuator)
        await scheduler.start()
        let scheduled = await scheduler.schedule(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: clock.now().addingTimeInterval(60), limitType: "session", rawMessage: "m")
        let id = try #require(scheduled?.id)
        try await clock.requireSleeperArmed()
        await clock.advance(by: 130)
        #expect(try await settledStatus(of: id) == .cancelled)
        #expect(actuator.calls.isEmpty)
        await scheduler.stop()
    }
}
