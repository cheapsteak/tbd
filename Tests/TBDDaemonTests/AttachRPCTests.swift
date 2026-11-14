import Foundation
import DaemonTestSupport
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TBDKernel

/// Build a fresh router over an in-memory DB with dry-run tmux. Returns the
/// DB too so tests can create repo/worktree rows for server resolution.
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
        startTime: Date(),
        actuationLog: makeTestActuationLog()
    )
    return (router, db)
}

/// Create a repo + worktree row and return the worktree's ID.
private func makeWorktree(in db: TBDDatabase, tmuxServer: String = "tbd-attach-test") async throws -> UUID {
    let repo = try await db.repos.create(
        path: "/tmp/attach-test-repo", displayName: "attach-test", defaultBranch: "main"
    )
    let worktree = try await db.worktrees.create(
        repoID: repo.id, name: "attach-wt",
        branch: "main", path: "/tmp/attach-test-repo",
        tmuxServer: tmuxServer
    )
    return worktree.id
}

@Suite("Attach RPC stubs")
struct AttachRPCStubTests {
    /// Only a holder-backed terminal can be attached; a request that names no
    /// terminal has nothing the daemon could vend.
    @Test("attach.request naming no terminal is answered unavailable")
    func requestWithoutATerminalIsUnavailable() async throws {
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db)
        let request = try RPCRequest(
            method: RPCMethod.attachRequest,
            params: AttachRequestParams(worktreeID: worktreeID, paneID: "%0", windowID: "@0", attachID: UUID()))
        let response = await router.handle(request)
        #expect(response.success)
        let result = try response.decodeResult(AttachRequestResult.self)
        #expect(result.status == "unavailable")
    }

    @Test("attach.ready naming no holder-backed terminal fails")
    func readyWithoutAHolderTerminalFails() async throws {
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db)
        let request = try RPCRequest(
            method: RPCMethod.attachReady,
            params: AttachReadyParams(worktreeID: worktreeID, paneID: "%0"))
        let response = await router.handle(request)
        #expect(!response.success)
    }

    @Test("pane.detach accepts the detach")
    func detachRoundTrip() async throws {
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db)
        let request = try RPCRequest(
            method: RPCMethod.paneDetach,
            params: PaneDetachParams(worktreeID: worktreeID, paneID: "%0"))
        let response = await router.handle(request)
        #expect(response.success)
    }
}
