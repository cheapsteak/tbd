import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

@Suite struct TransientApiErrorRPCTests {
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
            startTime: Date(), actuationLog: makeTestActuationLog())
        let repo = try await db.repos.create(
            path: "/tmp/tae-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/tae-wt-\(UUID().uuidString)", tmuxServer: "tbd-tae")
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

    private func detect(terminalID: UUID? = nil, rawMessage: String = "API Error: 500") async -> RPCResponse {
        let request = try! RPCRequest(
            method: RPCMethod.claudeTransientApiErrorDetected,
            params: TransientApiErrorDetectedParams(
                terminalID: terminalID ?? self.terminalID,
                errorClass: "overloaded",
                rawMessage: rawMessage))
        return await router.handle(request)
    }

    /// Seed a `sent` api_error attempt row so the backoff ladder counts it.
    private func seedSentApiErrorAttempts(_ count: Int) async throws {
        for _ in 0..<count {
            try await db.scheduledResumes.insertAudit(ScheduledResume(
                terminalID: terminalID, worktreeID: worktreeID,
                resetsAt: Date(), fireAt: Date(),
                limitType: ScheduledResume.apiErrorLimitType, rawMessage: "m",
                createdAt: Date(), status: .sent))
        }
    }

    // GATE OFF: not handled, no row, no notification.
    @Test func toggleOffIsNotHandled() async throws {
        try await db.config.setAutoResumeOnApiError(false)
        let response = await detect()
        #expect(response.success)
        #expect(try response.decodeResult(TransientApiErrorDetectedResult.self).handled == false)
        #expect(try await db.scheduledResumes.pending().isEmpty)
        #expect(try await db.scheduledResumes.all(terminalID: terminalID).isEmpty)
        #expect(try await db.notifications.unread(worktreeID: worktreeID).isEmpty)
    }

    // GATE ON, attempt 1: pending api_error row + "auto-continue in 60s (attempt 1/4)".
    @Test func toggleOnAttempt1SchedulesAndNotifies() async throws {
        try await db.config.setAutoResumeOnApiError(true)
        let response = await detect(rawMessage: "API Error: 529 overloaded")
        #expect(response.success)
        #expect(try response.decodeResult(TransientApiErrorDetectedResult.self).handled == true)
        let pending = try await db.scheduledResumes.pending(terminalID: terminalID)
        #expect(pending != nil)
        #expect(pending?.limitType == ScheduledResume.apiErrorLimitType)
        let unread = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(unread.count == 1)
        #expect(unread[0].type == .error)
        #expect(unread[0].message?.contains("auto-continue in 60s (attempt 1/4)") == true)
        #expect(unread[0].terminalID == terminalID)
    }

    // GATE ON, one prior attempt seeded → next fires at 2m (attempt 2/4).
    @Test func seededOneAttemptSchedulesAt2m() async throws {
        try await db.config.setAutoResumeOnApiError(true)
        try await seedSentApiErrorAttempts(1)
        let response = await detect()
        #expect(try response.decodeResult(TransientApiErrorDetectedResult.self).handled == true)
        let unread = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(unread.count == 1)
        #expect(unread[0].message?.contains("auto-continue in 2m (attempt 2/4)") == true)
    }

    // GATE ON, cap reached (4 prior attempts) → handled, NO new row, gave-up notice.
    @Test func seededFourAttemptsGivesUp() async throws {
        try await db.config.setAutoResumeOnApiError(true)
        try await seedSentApiErrorAttempts(4)
        let response = await detect(rawMessage: "API Error: 500")
        #expect(try response.decodeResult(TransientApiErrorDetectedResult.self).handled == true)
        #expect(try await db.scheduledResumes.pending(terminalID: terminalID) == nil)
        let unread = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(unread.count == 1)
        #expect(unread[0].type == .attentionNeeded)
        #expect(unread[0].message?.contains("gave up after 4 attempts") == true)
    }

    // Unknown terminal → not handled, nothing else.
    @Test func unknownTerminalIsNotHandled() async throws {
        try await db.config.setAutoResumeOnApiError(true)
        let response = await detect(terminalID: UUID())
        #expect(response.success)
        #expect(try response.decodeResult(TransientApiErrorDetectedResult.self).handled == false)
        #expect(try await db.scheduledResumes.pending().isEmpty)
        #expect(try await db.notifications.unread(worktreeID: worktreeID).isEmpty)
    }

    // Pending limit row already present (limitType-agnostic latch) → handled,
    // no duplicate notification.
    @Test func pendingLimitRowLatchesSilently() async throws {
        try await db.config.setAutoResumeOnApiError(true)
        _ = try await db.scheduledResumes.insertPending(ScheduledResume(
            terminalID: terminalID, worktreeID: worktreeID,
            resetsAt: Date(), fireAt: Date().addingTimeInterval(3600),
            limitType: "session", rawMessage: "limit"))
        let response = await detect()
        #expect(try response.decodeResult(TransientApiErrorDetectedResult.self).handled == true)
        // No api_error row added; the pre-seeded session row is the only pending one.
        let pending = try await db.scheduledResumes.pending()
        #expect(pending.count == 1)
        #expect(pending[0].limitType == "session")
        #expect(try await db.notifications.unread(worktreeID: worktreeID).isEmpty)
    }
}
