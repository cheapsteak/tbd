import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Scripted actuator: returns queued outcomes in order, records calls.
final class FakeActuator: LimitResumeActuating, @unchecked Sendable {
    private let queue = DispatchQueue(label: "FakeActuator")
    private var outcomes: [ResumeActuationOutcome]
    private var _calls: [ScheduledResume] = []
    var calls: [ScheduledResume] { queue.sync { _calls } }

    init(_ outcomes: [ResumeActuationOutcome] = [.sent]) {
        self.outcomes = outcomes
    }

    func actuate(_ resume: ScheduledResume) async -> ResumeActuationOutcome {
        queue.sync {
            _calls.append(resume)
            return outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
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

    /// Let the actor loop cross its awaits (GRDB runs on its own threads,
    /// so pure Task.yield isn't enough — mirror ClaudeUsagePollerTests' pump).
    private func pump() async {
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            await Task.yield()
        }
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
        await pump()
        #expect(actuator.calls.count == 1)
        let rows = try await db.scheduledResumes.pending()
        #expect(rows.isEmpty)
        #expect(collector.events.count == 1)
        if case .sent = collector.events[0].1 {} else { Issue.record("expected .sent") }
        await scheduler.stop()
    }

    @Test func sleepsUntilFireAtThenActuates() async throws {
        let actuator = FakeActuator([.sent])
        let scheduler = makeScheduler(actuator: actuator)
        await scheduler.start()
        _ = await scheduler.schedule(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: clock.now().addingTimeInterval(600),
            limitType: "session", rawMessage: "m")
        await pump()
        #expect(actuator.calls.isEmpty)          // still sleeping
        await clock.advance(by: 700)             // past resetsAt + slack
        await pump()
        #expect(actuator.calls.count == 1)
        await scheduler.stop()
    }

    @Test func copyModeReschedulesPlusTwoMinutes() async throws {
        let actuator = FakeActuator([.paneInCopyMode, .sent])
        let scheduler = makeScheduler(actuator: actuator)
        await scheduler.start()
        _ = await scheduler.schedule(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: clock.now().addingTimeInterval(-120),
            limitType: "session", rawMessage: "m")
        await pump()
        #expect(actuator.calls.count == 1)
        let row = try await db.scheduledResumes.pending(terminalID: terminalID)
        #expect(row?.attemptCount == 1)
        #expect(row!.fireAt.timeIntervalSince(clock.now()) > 100) // ~+120s
        await clock.advance(by: 130)
        await pump()
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
        for _ in 0..<15 {
            await pump()
            await clock.advance(by: 130)
        }
        await pump()
        #expect(actuator.calls.count == LimitResumeScheduler.maxCopyModeAttempts)
        let rows = try await db.scheduledResumes.pending()
        #expect(rows.isEmpty)
        #expect(collector.events.contains { if case .failed = $0.1 { return true }; return false })
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
        #expect(scheduled != nil)
        await pump()
        #expect(actuator.calls.isEmpty)   // still parked, sleeping until fireAt

        // Completes fully before the clock advances below — no race.
        try await db.config.setAutoResumeOnLimitReset(false)

        await clock.advance(by: 700)      // past resetsAt + slack
        await pump()

        #expect(actuator.calls.isEmpty)
        let row = try await db.scheduledResumes.get(id: scheduled!.id)
        #expect(row?.status == .cancelled)
        #expect(collector.events.isEmpty)
        await scheduler.stop()
    }

    @Test func userAlreadyContinuedCancelsWithoutOutcome() async throws {
        let actuator = FakeActuator([.userAlreadyContinued])
        let collector = OutcomeCollector()
        let scheduler = makeScheduler(actuator: actuator) { collector.record($0, $1) }
        await scheduler.start()
        _ = await scheduler.schedule(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: clock.now().addingTimeInterval(-120),
            limitType: "session", rawMessage: "m")
        await pump()
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
        await pump()
        #expect(actuator.calls.count == 1)   // no retry
        let row = try await db.scheduledResumes.get(id: scheduled!.id)
        #expect(row?.status == .cancelled)
        #expect(collector.events.isEmpty)
        await scheduler.stop()
    }

    /// If a row is cancelled out from under a copy-mode retry (e.g. by a
    /// concurrent cancel) between actuation and the reschedule write,
    /// `store.reschedule` returns false. The scheduler must not resurrect
    /// the row into pending — it drops it from consideration instead.
    @Test func copyModeRescheduleDropsRowNoLongerPending() async throws {
        final class CancellingActuator: LimitResumeActuating, @unchecked Sendable {
            let store: ScheduledResumeStore
            init(store: ScheduledResumeStore) { self.store = store }
            func actuate(_ resume: ScheduledResume) async -> ResumeActuationOutcome {
                _ = try? await store.cancelPending(terminalID: resume.terminalID)
                return .paneInCopyMode
            }
        }
        let actuator = CancellingActuator(store: db.scheduledResumes)
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
        await pump()
        #expect(try await db.scheduledResumes.pending().isEmpty)
        #expect(collector.events.isEmpty)
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
        #expect(scheduled != nil)
        await clock.advance(by: 65)
        await pump()
        #expect(actuator.calls.count == 1)
        let row = try await db.scheduledResumes.get(id: scheduled!.id)
        #expect(row?.status == .sent)
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
        #expect(scheduled != nil)
        await clock.advance(by: 65)
        await pump()
        #expect(actuator.calls.isEmpty)
        let row = try await db.scheduledResumes.get(id: scheduled!.id)
        #expect(row?.status == .cancelled)
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
        #expect(scheduled != nil)
        await clock.advance(by: 130)
        await pump()
        #expect(actuator.calls.count == 1)
        let row = try await db.scheduledResumes.get(id: scheduled!.id)
        #expect(row?.status == .sent)
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
        #expect(scheduled != nil)
        await clock.advance(by: 130)
        await pump()
        #expect(actuator.calls.isEmpty)
        let row = try await db.scheduledResumes.get(id: scheduled!.id)
        #expect(row?.status == .cancelled)
        await scheduler.stop()
    }
}
