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
            params: AttachRequestParams(worktreeID: worktreeID, paneID: "%0", windowID: "@0", attachID: UUID()))
        let response = await router.handle(request)
        #expect(response.success)
        let result = try response.decodeResult(AttachRequestResult.self)
        #expect(result.status == "pending" || result.status == "unavailable")
    }

    @Test("attach.ready accepts the ack when the bridge is configured")
    func readyRoundTrip() async throws {
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db)
        router.controlMode = TmuxControlModeBridge(
            supervisor: TmuxControlSupervisor(),
            tmuxVersion: TmuxVersion(major: 3, minor: 6),
            environment: ["TBD_TMUX_CONTROL_MODE": "1"],
            fdVending: FDVendingServer())
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

@Suite("Attach RPC orchestration")
struct AttachRPCOrchestrationTests {

    private func makeSocketPair() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        try pair.withUnsafeMutableBufferPointer { buf in
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress) == 0 else {
                throw FDChannelError.sendFailed(errno)
            }
        }
        return (pair[0], pair[1])
    }

    private func bridge(
        supervisor: TmuxControlSupervisor,
        vending: FDVendingServer,
        gateOn: Bool = true,
        readyTimeout: Duration = .seconds(5)
    ) -> TmuxControlModeBridge {
        TmuxControlModeBridge(
            supervisor: supervisor,
            tmuxVersion: TmuxVersion(major: 3, minor: 6),
            environment: gateOn ? ["TBD_TMUX_CONTROL_MODE": "1"] : [:],
            fdVending: vending,
            readyTimeout: readyTimeout)
    }

    @Test("attach.request with the gate on vends an fd whose header carries the pane identity")
    func vendsFDWhenGateOn() async throws {
        let (serverSide, clientSide) = try makeSocketPair()
        defer { Darwin.close(clientSide) }

        let supervisor = TmuxControlSupervisor()
        let vending = FDVendingServer()
        await vending.adoptConnection(fd: serverSide)
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db)
        router.controlMode = bridge(supervisor: supervisor, vending: vending)

        let request = try RPCRequest(
            method: RPCMethod.attachRequest,
            params: AttachRequestParams(worktreeID: worktreeID, paneID: "%1", windowID: "@1", attachID: UUID()))
        let response = await router.handle(request)
        #expect(response.success)
        let result = try response.decodeResult(AttachRequestResult.self)
        #expect(result.status == "pending")

        let (rxFD, rxHeader) = try FDChannel.receiveFD(from: clientSide, headerCapacity: 256)
        defer { Darwin.close(rxFD) }
        let header = try JSONDecoder().decode(FDVendHeader.self, from: rxHeader)
        #expect(header.worktreeID == worktreeID)
        #expect(header.paneID == "%1")
    }

    @Test("attach.request with the gate off returns unavailable and does not send an fd")
    func gateOffReturnsUnavailable() async throws {
        let (serverSide, clientSide) = try makeSocketPair()
        defer {
            Darwin.close(serverSide)
            Darwin.close(clientSide)
        }

        let supervisor = TmuxControlSupervisor()
        let vending = FDVendingServer()
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db)
        router.controlMode = bridge(supervisor: supervisor, vending: vending, gateOn: false)

        let request = try RPCRequest(
            method: RPCMethod.attachRequest,
            params: AttachRequestParams(worktreeID: worktreeID, paneID: "%2", windowID: "@2", attachID: UUID()))
        let response = await router.handle(request)
        let result = try response.decodeResult(AttachRequestResult.self)
        #expect(result.status == "unavailable")
    }

    @Test("attach.request for an unknown worktree fails")
    func unknownWorktreeFails() async throws {
        let (serverSide, clientSide) = try makeSocketPair()
        defer { Darwin.close(clientSide) }

        let supervisor = TmuxControlSupervisor()
        let vending = FDVendingServer()
        await vending.adoptConnection(fd: serverSide)
        let (router, _) = try makeRouterAndDB()
        router.controlMode = bridge(supervisor: supervisor, vending: vending)

        let request = try RPCRequest(
            method: RPCMethod.attachRequest,
            params: AttachRequestParams(worktreeID: UUID(), paneID: "%9", windowID: "@9", attachID: UUID()))
        let response = await router.handle(request)
        #expect(!response.success)
    }

    @Test("an attach the app never acks is torn down after readyTimeout")
    func unackedAttachTornDownAfterTimeout() async throws {
        let (serverSide, clientSide) = try makeSocketPair()
        defer { Darwin.close(clientSide) }

        let supervisor = TmuxControlSupervisor()
        let vending = FDVendingServer()
        await vending.adoptConnection(fd: serverSide)
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db)
        router.controlMode = bridge(
            supervisor: supervisor, vending: vending, readyTimeout: .milliseconds(100))

        let request = try RPCRequest(
            method: RPCMethod.attachRequest,
            params: AttachRequestParams(worktreeID: worktreeID, paneID: "%5", windowID: "@5", attachID: UUID()))
        _ = await router.handle(request)

        let (rxFD, _) = try FDChannel.receiveFD(from: clientSide, headerCapacity: 256)
        defer { Darwin.close(rxFD) }

        // No attach.ready is ever sent. After the timeout, the daemon must
        // detach — closing the write end, so the vended read fd sees EOF.
        try await Task.sleep(for: .milliseconds(400))
        var buffer = [UInt8](repeating: 0, count: 8)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(rxFD, $0.baseAddress, $0.count) }
        #expect(count == 0, "un-acked attach must be torn down (EOF on the vended fd)")
    }

    @Test("attach.ready opens the write gate for the resolved server")
    func readyOpensGate() async throws {
        let (serverSide, clientSide) = try makeSocketPair()
        defer { Darwin.close(clientSide) }

        let supervisor = TmuxControlSupervisor()
        let vending = FDVendingServer()
        await vending.adoptConnection(fd: serverSide)
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db, tmuxServer: "tbd-gate-test")
        router.controlMode = bridge(supervisor: supervisor, vending: vending)

        let attach = try RPCRequest(
            method: RPCMethod.attachRequest,
            params: AttachRequestParams(worktreeID: worktreeID, paneID: "%7", windowID: "@7", attachID: UUID()))
        _ = await router.handle(attach)
        let (rxFD, _) = try FDChannel.receiveFD(from: clientSide, headerCapacity: 256)
        defer { Darwin.close(rxFD) }

        #expect(await supervisor.isReady(server: "tbd-gate-test", paneID: "%7") == false)
        let ready = try RPCRequest(
            method: RPCMethod.attachReady,
            params: AttachReadyParams(worktreeID: worktreeID, paneID: "%7"))
        let response = await router.handle(ready)
        #expect(response.success)
        #expect(await supervisor.isReady(server: "tbd-gate-test", paneID: "%7") == true)
    }
}
