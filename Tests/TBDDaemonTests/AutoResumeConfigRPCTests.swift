import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct AutoResumeConfigRPCTests {
    let db: TBDDatabase
    let router: RPCRouter

    init() throws {
        let db = try TBDDatabase(inMemory: true)
        self.db = db
        self.router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(),
                tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date())
    }

    @Test func enablePersistsFlag() async throws {
        let request = try RPCRequest(
            method: RPCMethod.configSetAutoResumeOnLimitReset,
            params: ConfigSetAutoResumeOnLimitResetParams(enabled: true))
        let response = await router.handle(request)
        #expect(response.success)
        #expect(try await db.config.get().autoResumeOnLimitReset == true)
    }

    @Test func disableCancelsAllPendingRows() async throws {
        try await db.config.setAutoResumeOnLimitReset(true)
        let repo = try await db.repos.create(
            path: "/tmp/arc-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/arc-wt-\(UUID().uuidString)", tmuxServer: "tbd-arc")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1")
        _ = try await db.scheduledResumes.insertPending(ScheduledResume(
            terminalID: terminal.id, worktreeID: wt.id,
            resetsAt: Date(), fireAt: Date().addingTimeInterval(60),
            limitType: "session", rawMessage: "m"))

        let request = try RPCRequest(
            method: RPCMethod.configSetAutoResumeOnLimitReset,
            params: ConfigSetAutoResumeOnLimitResetParams(enabled: false))
        let response = await router.handle(request)
        #expect(response.success)
        #expect(try await db.config.get().autoResumeOnLimitReset == false)
        #expect(try await db.scheduledResumes.pending().isEmpty)
        #expect(try await db.terminals.get(id: terminal.id)?.pendingResumeAt == nil)
    }

    @Test func modelProfileListCarriesFlag() async throws {
        try await db.config.setAutoResumeOnLimitReset(true)
        let response = await router.handle(RPCRequest(method: RPCMethod.modelProfileList))
        #expect(response.success)
        let result = try response.decodeResult(ModelProfileListResult.self)
        #expect(result.autoResumeOnLimitReset == true)
    }

    @Test func oldListResultJSONDecodesWithDefaultFalse() throws {
        // decode-compat: a pre-feature daemon's result has no such key.
        let json = #"{"profiles":[],"globalEnvOverrides":{},"autoArchiveOnMergeDefault":false}"#
        let result = try JSONDecoder().decode(ModelProfileListResult.self, from: Data(json.utf8))
        #expect(result.autoResumeOnLimitReset == false)
        #expect(result.autoResumeOnApiError == false)
    }

    @Test func apiErrorListResultCarriesFlag() async throws {
        try await db.config.setAutoResumeOnApiError(true)
        let response = await router.handle(RPCRequest(method: RPCMethod.modelProfileList))
        #expect(response.success)
        let result = try response.decodeResult(ModelProfileListResult.self)
        #expect(result.autoResumeOnApiError == true)
    }

    // Seed one pending `session` row and one pending `api_error` row on two
    // separate terminals, then assert each toggle's off-path cancels only its
    // own scope (spec: per-toggle scoped cancel).
    private func seedTwoPendingRows() async throws -> (session: UUID, apiError: UUID) {
        let repo = try await db.repos.create(
            path: "/tmp/arc2-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/arc2-wt-\(UUID().uuidString)", tmuxServer: "tbd-arc2")
        let sessionTerminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1")
        let apiErrorTerminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2")
        _ = try await db.scheduledResumes.insertPending(ScheduledResume(
            terminalID: sessionTerminal.id, worktreeID: wt.id,
            resetsAt: Date(), fireAt: Date().addingTimeInterval(60),
            limitType: "session", rawMessage: "m"))
        _ = try await db.scheduledResumes.insertPending(ScheduledResume(
            terminalID: apiErrorTerminal.id, worktreeID: wt.id,
            resetsAt: Date(), fireAt: Date().addingTimeInterval(60),
            limitType: ScheduledResume.apiErrorLimitType, rawMessage: "m"))
        return (sessionTerminal.id, apiErrorTerminal.id)
    }

    @Test func disableApiErrorCancelsApiErrorRowNotSession() async throws {
        try await db.config.setAutoResumeOnLimitReset(true)
        try await db.config.setAutoResumeOnApiError(true)
        let (session, apiError) = try await seedTwoPendingRows()

        let request = try RPCRequest(
            method: RPCMethod.configSetAutoResumeOnApiError,
            params: ConfigSetAutoResumeOnApiErrorParams(enabled: false))
        let response = await router.handle(request)
        #expect(response.success)
        #expect(try await db.config.get().autoResumeOnApiError == false)
        #expect(try await db.scheduledResumes.pending(terminalID: apiError) == nil)
        #expect(try await db.scheduledResumes.pending(terminalID: session) != nil)
    }

    @Test func disableLimitResetCancelsSessionRowNotApiError() async throws {
        try await db.config.setAutoResumeOnLimitReset(true)
        try await db.config.setAutoResumeOnApiError(true)
        let (session, apiError) = try await seedTwoPendingRows()

        let request = try RPCRequest(
            method: RPCMethod.configSetAutoResumeOnLimitReset,
            params: ConfigSetAutoResumeOnLimitResetParams(enabled: false))
        let response = await router.handle(request)
        #expect(response.success)
        #expect(try await db.config.get().autoResumeOnLimitReset == false)
        #expect(try await db.scheduledResumes.pending(terminalID: session) == nil)
        #expect(try await db.scheduledResumes.pending(terminalID: apiError) != nil)
    }
}
