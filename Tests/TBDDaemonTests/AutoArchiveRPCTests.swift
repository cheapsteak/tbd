import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct AutoArchiveRPCTests {

    private func makeRouter() throws -> (RPCRouter, TBDDatabase) {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date()
        )
        return (router, db)
    }

    @Test func setWorktreeAutoArchivePersists() async throws {
        let (router, db) = try makeRouter()
        let repo = try await db.repos.create(
            path: "/tmp/repoB-\(UUID().uuidString)",
            displayName: "repoB",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "w",
            branch: "b",
            path: "/tmp/repoB-w-\(UUID().uuidString)",
            tmuxServer: "s"
        )

        let req = try RPCRequest(
            method: RPCMethod.worktreeSetAutoArchive,
            params: WorktreeSetAutoArchiveParams(worktreeID: wt.id, enabled: true)
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let after = try await db.worktrees.get(id: wt.id)
        #expect(after?.autoArchiveOnMerge == true)
    }

    @Test func configGetAndSetDefault() async throws {
        let (router, db) = try makeRouter()
        let setReq = try RPCRequest(
            method: RPCMethod.configSetAutoArchiveOnMergeDefault,
            params: ConfigSetAutoArchiveDefaultParams(enabled: true)
        )
        #expect(await router.handle(setReq).success)

        let getReq = RPCRequest(method: RPCMethod.configGet)
        let getResp = await router.handle(getReq)
        let cfg = try getResp.decodeResult(Config.self)
        #expect(cfg.autoArchiveOnMergeDefault == true)
        _ = db
    }
}
