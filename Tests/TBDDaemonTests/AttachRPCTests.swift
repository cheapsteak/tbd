import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

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
        startTime: Date()
    )
    return (router, db)
}

/// Create a repo + worktree row and return the worktree's ID. The worktree's
/// tmuxServer is what attach handlers resolve for composite pane keys.
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
    @Test("attach.request round-trips through the router")
    func requestRoundTrip() async throws {
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db)
        let request = try RPCRequest(
            method: RPCMethod.attachRequest,
            params: AttachRequestParams(worktreeID: worktreeID, paneID: "%0", windowID: "@0"))
        let response = await router.handle(request)
        #expect(response.success)
        let result = try response.decodeResult(AttachRequestResult.self)
        #expect(result.status == "pending" || result.status == "unavailable")
    }

    @Test("attach.ready accepts the ack")
    func readyRoundTrip() async throws {
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db)
        let request = try RPCRequest(
            method: RPCMethod.attachReady,
            params: AttachReadyParams(worktreeID: worktreeID, paneID: "%0"))
        let response = await router.handle(request)
        #expect(response.success)
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

    @Test("daemon.capabilities reports control mode off when no bridge is set")
    func capabilitiesDefaultOff() async throws {
        let (router, _) = try makeRouterAndDB()
        let request = RPCRequest(method: RPCMethod.daemonCapabilities)
        let response = await router.handle(request)
        #expect(response.success)
        let result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.controlModeEnabled == false)
    }

    @Test("daemon.capabilities reports control mode on when the bridge gate passes")
    func capabilitiesOnWhenGated() async throws {
        let (router, _) = try makeRouterAndDB()
        router.controlMode = TmuxControlModeBridge(
            supervisor: TmuxControlSupervisor(),
            tmuxVersion: TmuxVersion(major: 3, minor: 6),
            environment: ["TBD_TMUX_CONTROL_MODE": "1"],
            fdVending: FDVendingServer())
        let request = RPCRequest(method: RPCMethod.daemonCapabilities)
        let response = await router.handle(request)
        let result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.controlModeEnabled == true)
    }
}
