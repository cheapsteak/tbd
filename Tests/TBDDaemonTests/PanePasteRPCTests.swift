import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Covers `pane.paste` route dispatch and its error branches without live tmux.
/// The happy path (real load-buffer/paste-buffer) is exercised by
/// `PasteExecutorIntegrationTests`; here we prove the router gates correctly.
@Suite("pane.paste RPC")
struct PanePasteRPCTests {
    private func makeRouterAndDB() throws -> (RPCRouter, TBDDatabase) {
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

    private func makeWorktree(in db: TBDDatabase, tmuxServer: String = "tbd-paste-rpc") async throws -> UUID {
        let repo = try await db.repos.create(
            path: "/tmp/paste-rpc-repo", displayName: "paste-rpc", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "paste-wt", branch: "main",
            path: "/tmp/paste-rpc-repo", tmuxServer: tmuxServer)
        return worktree.id
    }

    private func bridge() -> TmuxControlModeBridge {
        TmuxControlModeBridge(
            supervisor: TmuxControlSupervisor(),
            tmuxVersion: TmuxVersion(major: 3, minor: 6),
            environment: ["TBD_TMUX_CONTROL_MODE": "1"],
            fdVending: FDVendingServer())
    }

    @Test("pane.paste with no bridge configured errors")
    func noBridgeErrors() async throws {
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db)
        let request = try RPCRequest(
            method: RPCMethod.panePaste,
            params: PanePasteParams(worktreeID: worktreeID, paneID: "%0", bytes: Data("hi".utf8)))
        let response = await router.handle(request)
        #expect(!response.success)
    }

    @Test("pane.paste for an unknown worktree errors")
    func unknownWorktreeErrors() async throws {
        let (router, _) = try makeRouterAndDB()
        let router2 = router
        router2.controlMode = bridge()
        let request = try RPCRequest(
            method: RPCMethod.panePaste,
            params: PanePasteParams(worktreeID: UUID(), paneID: "%0", bytes: Data("hi".utf8)))
        let response = await router2.handle(request)
        #expect(!response.success)
    }

    @Test("pane.paste with no live -CC connection reports connection-not-up")
    func noConnectionErrors() async throws {
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db)
        router.controlMode = bridge()  // supervisor has no connection for this server
        let request = try RPCRequest(
            method: RPCMethod.panePaste,
            params: PanePasteParams(worktreeID: worktreeID, paneID: "%0", bytes: Data("hi".utf8)))
        let response = await router.handle(request)
        #expect(!response.success)
    }

    @Test("pane.paste rejects payloads over the size cap")
    func oversizeRejected() async throws {
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db)
        router.controlMode = bridge()
        let oversize = Data(count: PanePasteParams.maxBytes + 1)
        let request = try RPCRequest(
            method: RPCMethod.panePaste,
            params: PanePasteParams(worktreeID: worktreeID, paneID: "%0", bytes: oversize))
        let response = await router.handle(request)
        #expect(!response.success)
    }
}
