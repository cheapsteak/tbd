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

    @Test func toggleOffAtFireTimeCancelsSilently() async throws {
        let actuator = FakeActuator([.sent])
        let collector = OutcomeCollector()
        let scheduler = makeScheduler(actuator: actuator) { collector.record($0, $1) }
        await scheduler.start()
        _ = await scheduler.schedule(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: clock.now().addingTimeInterval(-120),
            limitType: "session", rawMessage: "m")
        try await db.config.setAutoResumeOnLimitReset(false)
        await scheduler.wake()
        await pump()
        #expect(actuator.calls.isEmpty)
        #expect(try await db.scheduledResumes.pending().isEmpty)
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
}
