import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct ScheduledResumeCancellationTests {
    let db: TBDDatabase
    let router: RPCRouter
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
        try await db.config.setAutoResumeOnLimitReset(true)
        let repo = try await db.repos.create(
            path: "/tmp/can-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/can-wt-\(UUID().uuidString)", tmuxServer: "tbd-can")
        worktreeID = wt.id
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1")
        terminalID = terminal.id
        _ = try await db.scheduledResumes.insertPending(ScheduledResume(
            terminalID: terminal.id, worktreeID: wt.id,
            resetsAt: Date().addingTimeInterval(3600),
            fireAt: Date().addingTimeInterval(3660),
            limitType: "session", rawMessage: "m"))
    }

    private func assertCancelled() async throws {
        #expect(try await db.scheduledResumes.pending(terminalID: terminalID) == nil)
        let terminal = try await db.terminals.get(id: terminalID)
        #expect(terminal == nil || terminal?.pendingResumeAt == nil)
    }

    @Test func userPromptSubmitCancels() async throws {
        // UserPromptSubmit → overlay → `tbd terminal-activity working` →
        // terminal.activityEvent(working): user continued manually.
        let request = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(terminalID: terminalID, activityState: .working))
        let response = await router.handle(request)
        #expect(response.success)
        try await assertCancelled()
    }

    @Test func nonWorkingActivityDoesNotCancel() async throws {
        let request = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(terminalID: terminalID, activityState: .idle))
        _ = await router.handle(request)
        #expect(try await db.scheduledResumes.pending(terminalID: terminalID) != nil)
    }

    @Test func terminalDeleteCancels() async throws {
        let request = try RPCRequest(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: terminalID))
        let response = await router.handle(request)
        #expect(response.success)
        try await assertCancelled()
    }

    @Test func terminalSuspendCancels() async throws {
        // manualSuspend returns .notClaudeTerminal for a session-less terminal,
        // but the cancel must happen regardless of the coordinator's verdict.
        let request = try RPCRequest(
            method: RPCMethod.terminalSuspend,
            params: TerminalSuspendParams(terminalID: terminalID))
        _ = await router.handle(request)
        try await assertCancelled()
    }

    @Test func worktreeSuspendCancelsAllTerminals() async throws {
        let request = try RPCRequest(
            method: RPCMethod.worktreeSuspend,
            params: WorktreeSuspendParams(worktreeID: worktreeID))
        _ = await router.handle(request)
        try await assertCancelled()
    }

    @Test func terminalHibernateCancels() async throws {
        // Hibernation is a parking mechanism just like suspend: a parked pane
        // must not receive a scheduled auto-resume send (spec §Cancellation).
        // This terminal needs a claudeSessionID + idle state to actually
        // complete the hibernate transition (unlike terminalSuspendCancels,
        // the cancel here is wired inside HibernationCoordinator itself, at
        // the point of the real state transition — not unconditionally
        // upfront — so the hibernate must actually succeed to observe it).
        let hibTerminal = try await db.terminals.create(
            worktreeID: worktreeID, tmuxWindowID: "@2", tmuxPaneID: "%2",
            claudeSessionID: "sess-hib", kind: .claude)
        try await db.terminals.setActivityState(id: hibTerminal.id, activityState: .idle)
        _ = try await db.scheduledResumes.insertPending(ScheduledResume(
            terminalID: hibTerminal.id, worktreeID: worktreeID,
            resetsAt: Date().addingTimeInterval(3600),
            fireAt: Date().addingTimeInterval(3660),
            limitType: "session", rawMessage: "m"))

        let request = try RPCRequest(
            method: RPCMethod.terminalHibernate,
            params: TerminalHibernateParams(terminalID: hibTerminal.id))
        let response = await router.handle(request)
        #expect(response.success)

        #expect(try await db.scheduledResumes.pending(terminalID: hibTerminal.id) == nil)
        let terminal = try await db.terminals.get(id: hibTerminal.id)
        #expect(terminal?.pendingResumeAt == nil)
        #expect(terminal?.isHibernated == true)
    }

    @Test func explicitCancelRPC() async throws {
        let request = try RPCRequest(
            method: RPCMethod.terminalCancelScheduledResume,
            params: CancelScheduledResumeParams(terminalID: terminalID))
        let response = await router.handle(request)
        #expect(response.success)
        try await assertCancelled()
    }
}
