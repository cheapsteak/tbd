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
    }
}
