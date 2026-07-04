import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct RateLimitDetectedRPCTests {
    let db: TBDDatabase
    let router: RPCRouter
    let clock = TestPollerClock()
    let terminalID: UUID
    let worktreeID: UUID

    init() async throws {
        let db = try TBDDatabase(inMemory: true)
        self.db = db
        self.router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(),
                tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date())
        let repo = try await db.repos.create(
            path: "/tmp/rld-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/rld-wt-\(UUID().uuidString)", tmuxServer: "tbd-rld")
        worktreeID = wt.id
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1")
        terminalID = terminal.id
        // Router-held scheduler, not started (schedule() works without loop).
        router.limitResumeScheduler = LimitResumeScheduler(
            store: db.scheduledResumes, config: db.config,
            actuator: FakeActuator(), clock: clock,
            jitterProvider: { 0 }, onOutcome: { _, _ in })
    }

    private func detect() async -> RPCResponse {
        let request = try! RPCRequest(
            method: RPCMethod.claudeRateLimitDetected,
            params: RateLimitDetectedParams(
                terminalID: terminalID,
                resetsAt: Date().addingTimeInterval(3600),
                limitType: "session",
                rawMessage: "You've hit your session limit · resets 3pm (UTC)"))
        return await router.handle(request)
    }

    // GATE BRANCH 1: toggle ON → pending row + scheduled notification.
    @Test func toggleOnSchedulesAndNotifies() async throws {
        try await db.config.setAutoResumeOnLimitReset(true)
        let response = await detect()
        #expect(response.success)
        let pending = try await db.scheduledResumes.pending(terminalID: terminalID)
        #expect(pending != nil)
        #expect(try await db.terminals.get(id: terminalID)?.pendingResumeAt != nil)
        let unread = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(unread.count == 1)
        #expect(unread[0].type == .limitReached)
        #expect(unread[0].message?.hasPrefix("Session limit hit — auto-resume scheduled for") == true)
        #expect(unread[0].terminalID == terminalID)
    }

    // GATE BRANCH 2: toggle OFF → audit row recorded + notification, NO send scheduled.
    @Test func toggleOffRecordsAndNotifiesWithoutScheduling() async throws {
        try await db.config.setAutoResumeOnLimitReset(false)
        let response = await detect()
        #expect(response.success)
        #expect(try await db.scheduledResumes.pending().isEmpty)
        #expect(try await db.terminals.get(id: terminalID)?.pendingResumeAt == nil)
        let unread = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(unread.count == 1)
        #expect(unread[0].type == .limitReached)
        #expect(unread[0].message?.hasPrefix("Session limit hit — resets") == true)
        // The off-branch's audit row (recorded via insertAudit) must actually
        // land in the DB, not just be attempted.
        let rows = try await db.scheduledResumes.all(terminalID: terminalID)
        #expect(rows.count == 1)
        #expect(rows[0].status == .cancelled)
    }

    @Test func latchSuppressesDuplicateNotification() async throws {
        try await db.config.setAutoResumeOnLimitReset(true)
        _ = await detect()
        _ = await detect()   // second StopFailure while already parked
        let unread = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(unread.count == 1)
        let rows = try await db.scheduledResumes.pending()
        #expect(rows.count == 1)
    }

    @Test func unknownTerminalIsSoftNoOp() async throws {
        try await db.config.setAutoResumeOnLimitReset(true)
        let request = try RPCRequest(
            method: RPCMethod.claudeRateLimitDetected,
            params: RateLimitDetectedParams(
                terminalID: UUID(), resetsAt: Date(), limitType: "session", rawMessage: "m"))
        let response = await router.handle(request)
        #expect(response.success)   // fire-and-forget hook caller: never error
        #expect(try await db.scheduledResumes.pending().isEmpty)
    }

    @Test func limitReachedSeverityIsAttentionLevel() {
        #expect(NotificationType.limitReached.severity == 3)
        #expect(NotificationType(rawValue: "limit_reached") == .limitReached)
    }
}
