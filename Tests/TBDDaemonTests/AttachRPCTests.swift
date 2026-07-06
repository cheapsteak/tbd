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

    @Test("attach.ready without a live attach fails (M4.3: app must fall back)")
    func readyWithoutAttachFails() async throws {
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
        // No attach.request preceded this ack, so there is no sink to replay
        // into — the replay sequence cannot run and the RPC must error so the
        // app's catch falls back to grouped sessions.
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
        readyTimeout: Duration = .seconds(5),
        commandProvider: (@Sendable (String) async -> TmuxControlCommandClient?)? = nil
    ) -> TmuxControlModeBridge {
        TmuxControlModeBridge(
            supervisor: supervisor,
            tmuxVersion: TmuxVersion(major: 3, minor: 6),
            environment: gateOn ? ["TBD_TMUX_CONTROL_MODE": "1"] : [:],
            fdVending: vending,
            readyTimeout: readyTimeout,
            commandProvider: commandProvider)
    }

    /// Thread-safe, synchronous recorder of fake-client stream writes.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _writes: [String] = []
        func record(_ line: String) { lock.lock(); _writes.append(line); lock.unlock() }
        var writes: [String] { lock.lock(); defer { lock.unlock() }; return _writes }
    }

    /// Thread-safe monotonic counter — lets a commandProvider hand each
    /// successive attach.ready sequence its OWN fake correlator, so a test
    /// can complete a later sequence's replies before an earlier one's.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; let c = count; count += 1; return c }
    }

    /// A fake-backed correlator (real FIFO, recorded writes) for the bridge's
    /// commandProvider seam — the M4.3 attach.ready sequence rides it.
    private func makeFakeClient() -> (TmuxControlCommandClient, Recorder) {
        let recorder = Recorder()
        let client = TmuxControlCommandClient(
            writeLine: { recorder.record($0) },
            onFatalError: {})
        return (client, recorder)
    }

    /// A 21-field state line for `paneID` (80x24, primary screen, cursor 0,0).
    private func stateLine(paneID: String) -> String {
        "\(paneID) 0 0 0 4294967295 4294967295 0 23 1 0 0 0 1 0 0 0 0 0 0 80 24"
    }

    /// Feed the full happy-path reply set: pause, history, alt, state, pending.
    private func feedCaptureReplies(
        _ client: TmuxControlCommandClient, paneID: String, history: [String]
    ) async {
        for lines in [[], history, [], [stateLine(paneID: paneID)], [] as [String]] {
            await client.handle(.commandSucceeded(number: 0, fromClient: true, lines: lines))
        }
    }

    private func waitFor(
        _ what: String, deadline: Duration = .seconds(60),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let end = ContinuousClock.now + deadline
        while ContinuousClock.now < end {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    /// Drain everything currently readable from `fd` (made nonblocking).
    private func drain(_ fd: Int32) -> Data {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            out.append(contentsOf: buffer[0..<n])
        }
        return out
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

        let (rxFD, header) = try SidecarTestSupport.receiveVend(from: clientSide)
        defer { Darwin.close(rxFD) }
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

        let (rxFD, _) = try SidecarTestSupport.receiveVend(from: clientSide)
        defer { Darwin.close(rxFD) }

        // No attach.ready is ever sent. After the timeout, the daemon must
        // detach — closing the write end, so the vended read fd sees EOF.
        try await Task.sleep(for: .milliseconds(400))
        var buffer = [UInt8](repeating: 0, count: 8)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(rxFD, $0.baseAddress, $0.count) }
        #expect(count == 0, "un-acked attach must be torn down (EOF on the vended fd)")
    }

    @Test("attach.ready triggers the replay sequence; the gate opens only after the replay lands")
    func readyTriggersSequenceGateOpensAfterReplay() async throws {
        let (serverSide, clientSide) = try makeSocketPair()
        defer { Darwin.close(clientSide) }

        let supervisor = TmuxControlSupervisor()
        let vending = FDVendingServer()
        await vending.adoptConnection(fd: serverSide)
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db, tmuxServer: "tbd-gate-test")
        let (client, recorder) = makeFakeClient()
        router.controlMode = bridge(
            supervisor: supervisor, vending: vending, commandProvider: { _ in client })

        let attach = try RPCRequest(
            method: RPCMethod.attachRequest,
            params: AttachRequestParams(worktreeID: worktreeID, paneID: "%7", windowID: "@7", attachID: UUID()))
        _ = await router.handle(attach)
        let (rxFD, _) = try SidecarTestSupport.receiveVend(from: clientSide)
        defer { Darwin.close(rxFD) }

        #expect(await supervisor.isReady(server: "tbd-gate-test", paneID: "%7") == false)
        let ready = try RPCRequest(
            method: RPCMethod.attachReady,
            params: AttachReadyParams(worktreeID: worktreeID, paneID: "%7"))
        let readyTask = Task { await router.handle(ready) }

        // The ack triggers ONE atomic stream write: pause then the captures.
        try await waitFor("capture batch write") { recorder.writes.count >= 1 }
        let batch = try #require(recorder.writes.first)
        #expect(batch.hasPrefix("refresh-client -A '%7:pause'\ncapture-pane -peqJN -S -50000 -t %7\n"))
        // The gate stays CLOSED while the capture is in flight.
        #expect(await supervisor.isReady(server: "tbd-gate-test", paneID: "%7") == false)

        await feedCaptureReplies(client, paneID: "%7", history: ["replayed-history"])
        let response = await readyTask.value
        #expect(response.success)
        #expect(await supervisor.isReady(server: "tbd-gate-test", paneID: "%7") == true)

        // Unpause is the last command, after the gate opened.
        try await waitFor("unpause write") { recorder.writes.count >= 2 }
        #expect(recorder.writes.last == "refresh-client -A '%7:continue'")

        // The vended fd carries the replay (which ends with a CUP).
        let text = (String(bytes: drain(rxFD), encoding: .utf8) ?? "")
        #expect(text.contains("replayed-history"))
        #expect(text.hasSuffix("H"))
    }

    @Test("an acked attach whose replay is still in flight survives the ready-timeout")
    func ackedReplayInFlightSurvivesTimeout() async throws {
        let (serverSide, clientSide) = try makeSocketPair()
        defer { Darwin.close(clientSide) }

        let supervisor = TmuxControlSupervisor()
        let vending = FDVendingServer()
        await vending.adoptConnection(fd: serverSide)
        let (router, db) = try makeRouterAndDB()
        let (client, recorder) = makeFakeClient()
        let worktreeID = try await makeWorktree(in: db, tmuxServer: "tbd-timeout-test")
        router.controlMode = bridge(
            supervisor: supervisor, vending: vending,
            readyTimeout: .milliseconds(100), commandProvider: { _ in client })

        let attach = try RPCRequest(
            method: RPCMethod.attachRequest,
            params: AttachRequestParams(worktreeID: worktreeID, paneID: "%6", windowID: "@6", attachID: UUID()))
        _ = await router.handle(attach)
        let (rxFD, _) = try SidecarTestSupport.receiveVend(from: clientSide)
        defer { Darwin.close(rxFD) }

        // Ack arrives promptly, but the capture replies stall (slow tmux).
        let ready = try RPCRequest(
            method: RPCMethod.attachReady,
            params: AttachReadyParams(worktreeID: worktreeID, paneID: "%6"))
        let readyTask = Task { await router.handle(ready) }
        try await waitFor("capture batch write") { recorder.writes.count >= 1 }

        // Let the 100 ms ready-timeout fire while the replay is in flight:
        // the acked attach must NOT be torn down (no EOF on the vended fd).
        try await Task.sleep(for: .milliseconds(400))
        let flags = fcntl(rxFD, F_GETFL)
        _ = fcntl(rxFD, F_SETFL, flags | O_NONBLOCK)
        var probe = [UInt8](repeating: 0, count: 8)
        let n = probe.withUnsafeMutableBytes { Darwin.read(rxFD, $0.baseAddress, $0.count) }
        #expect(n < 0 && errno == EAGAIN, "acked attach must survive the timer (no EOF, no data yet)")

        // The stalled replies arrive; the sequence completes normally.
        await feedCaptureReplies(client, paneID: "%6", history: ["late-history"])
        let response = await readyTask.value
        #expect(response.success)
        #expect(await supervisor.isReady(server: "tbd-timeout-test", paneID: "%6") == true)
        #expect((String(bytes: drain(rxFD), encoding: .utf8) ?? "").contains("late-history"))
    }

    @Test("a re-attach mid-sequence supersedes: attach.ready still returns success")
    func supersededMidSequenceReturnsSuccess() async throws {
        let (serverSide, clientSide) = try makeSocketPair()
        defer { Darwin.close(clientSide) }

        let supervisor = TmuxControlSupervisor()
        let vending = FDVendingServer()
        await vending.adoptConnection(fd: serverSide)
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db, tmuxServer: "tbd-supersede-test")
        let (client, recorder) = makeFakeClient()
        router.controlMode = bridge(
            supervisor: supervisor, vending: vending, commandProvider: { _ in client })

        func attachRequest() throws -> RPCRequest {
            try RPCRequest(
                method: RPCMethod.attachRequest,
                params: AttachRequestParams(worktreeID: worktreeID, paneID: "%8", windowID: "@8", attachID: UUID()))
        }
        _ = await router.handle(try attachRequest())
        let (rxFD1, _) = try SidecarTestSupport.receiveVend(from: clientSide)
        defer { Darwin.close(rxFD1) }

        let ready = try RPCRequest(
            method: RPCMethod.attachReady,
            params: AttachReadyParams(worktreeID: worktreeID, paneID: "%8"))
        let readyTask = Task { await router.handle(ready) }
        try await waitFor("capture batch write") { recorder.writes.count >= 1 }

        // A newer attach replaces the sink mid-sequence.
        _ = await router.handle(try attachRequest())
        let (rxFD2, _) = try SidecarTestSupport.receiveVend(from: clientSide)
        defer { Darwin.close(rxFD2) }

        await feedCaptureReplies(client, paneID: "%8", history: ["stale-history"])
        // Benign race: RPC SUCCESS, but the successor's gate stays closed
        // (its own attach.ready opens it) and its pipe got no stale replay.
        let response = await readyTask.value
        #expect(response.success)
        #expect(await supervisor.isReady(server: "tbd-supersede-test", paneID: "%8") == false)
        // No unpause from the superseded sequence (M2 review fix): the
        // successor's own FIFO-ordered sequence unpauses the pane. The RPC
        // returned, so the write log is final — batch only, no continue.
        #expect(recorder.writes.count == 1)
        #expect(!recorder.writes.contains { $0.contains(":continue'") })
        #expect(drain(rxFD2).isEmpty, "successor's pipe must not receive the stale replay")
    }

    @Test("a stale attach.ready (echoed older generation) sends ZERO commands on the shared correlator")
    func staleReadyEchoedGenerationSendsNothing() async throws {
        let (serverSide, clientSide) = try makeSocketPair()
        defer { Darwin.close(clientSide) }

        let supervisor = TmuxControlSupervisor()
        let vending = FDVendingServer()
        await vending.adoptConnection(fd: serverSide)
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db, tmuxServer: "tbd-staleready-test")
        // ONE fake correlator for BOTH generations — pause state is keyed per
        // pane on the shared per-server command client, so this is the seam
        // the reviewer flagged as untested with per-generation clients.
        let (client, recorder) = makeFakeClient()
        router.controlMode = bridge(
            supervisor: supervisor, vending: vending, commandProvider: { _ in client })

        func attach() async throws -> UInt64 {
            let request = try RPCRequest(
                method: RPCMethod.attachRequest,
                params: AttachRequestParams(
                    worktreeID: worktreeID, paneID: "%12", windowID: "@12", attachID: UUID()))
            let result = try (await router.handle(request)).decodeResult(AttachRequestResult.self)
            return try #require(result.generation)
        }
        // Attach #1 (the stale viewer's) … superseded by attach #2 before the
        // stale ready is processed.
        let gen1 = try await attach()
        let (fd1, _) = try SidecarTestSupport.receiveVend(from: clientSide)
        defer { Darwin.close(fd1) }
        let gen2 = try await attach()
        let (fd2, _) = try SidecarTestSupport.receiveVend(from: clientSide)
        defer { Darwin.close(fd2) }

        // The stale ready echoes gen 1: RPC success (benign race), but ZERO
        // commands — no pause that could freeze the pane, no continue that
        // could resume output into the successor's still-closed gate.
        let staleReady = try RPCRequest(
            method: RPCMethod.attachReady,
            params: AttachReadyParams(worktreeID: worktreeID, paneID: "%12", generation: gen1))
        #expect((await router.handle(staleReady)).success)
        #expect(recorder.writes.isEmpty, "stale ready must send NOTHING on the shared correlator")

        // The successor's OWN ready (echoing gen 2) runs the full sequence.
        let freshReady = try RPCRequest(
            method: RPCMethod.attachReady,
            params: AttachReadyParams(worktreeID: worktreeID, paneID: "%12", generation: gen2))
        let readyTask = Task { await router.handle(freshReady) }
        try await waitFor("successor capture batch") { recorder.writes.count >= 1 }
        await feedCaptureReplies(client, paneID: "%12", history: ["fresh"])
        #expect((await readyTask.value).success)
        #expect(await supervisor.isReady(server: "tbd-staleready-test", paneID: "%12") == true)
        try await waitFor("successor unpause") { recorder.writes.count >= 2 }
        #expect(recorder.writes.last == "refresh-client -A '%12:continue'")
    }

    @Test("mid-sequence supersession on ONE shared correlator: stale generation sends no continue; the successor's sequence ends with its own")
    func midSequenceSupersedeOnSharedClientSkipsUnpause() async throws {
        let (serverSide, clientSide) = try makeSocketPair()
        defer { Darwin.close(clientSide) }

        let supervisor = TmuxControlSupervisor()
        let vending = FDVendingServer()
        await vending.adoptConnection(fd: serverSide)
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db, tmuxServer: "tbd-sharedsup-test")
        let (client, recorder) = makeFakeClient()
        router.controlMode = bridge(
            supervisor: supervisor, vending: vending, commandProvider: { _ in client })

        func attach() async throws -> UInt64 {
            let request = try RPCRequest(
                method: RPCMethod.attachRequest,
                params: AttachRequestParams(
                    worktreeID: worktreeID, paneID: "%13", windowID: "@13", attachID: UUID()))
            let result = try (await router.handle(request)).decodeResult(AttachRequestResult.self)
            return try #require(result.generation)
        }
        // Attach #1 (gen 1); its ready sequence starts, then stalls on replies.
        let gen1 = try await attach()
        let (fd1, _) = try SidecarTestSupport.receiveVend(from: clientSide)
        defer { Darwin.close(fd1) }
        let ready1 = try RPCRequest(
            method: RPCMethod.attachReady,
            params: AttachReadyParams(worktreeID: worktreeID, paneID: "%13", generation: gen1))
        let ready1Task = Task { await router.handle(ready1) }
        try await waitFor("gen 1 capture batch") { recorder.writes.count >= 1 }

        // Attach #2 replaces the sink MID-sequence; gen 1's replies then land.
        let gen2 = try await attach()
        let (fd2, _) = try SidecarTestSupport.receiveVend(from: clientSide)
        defer { Darwin.close(fd2) }
        await feedCaptureReplies(client, paneID: "%13", history: ["stale"])
        #expect((await ready1Task.value).success)
        // The superseded sequence sent its batch and NOTHING else — its
        // unpause is skipped so it cannot land inside the successor's own
        // pause window (FIFO puts the successor's sequence after this one).
        #expect(recorder.writes.count == 1)
        #expect(!recorder.writes.contains { $0.contains(":continue'") })

        // The successor's sequence runs on the SAME correlator and ends with
        // its own continue — the pane ends unpaused, exactly once.
        let ready2 = try RPCRequest(
            method: RPCMethod.attachReady,
            params: AttachReadyParams(worktreeID: worktreeID, paneID: "%13", generation: gen2))
        let ready2Task = Task { await router.handle(ready2) }
        try await waitFor("gen 2 capture batch") { recorder.writes.count >= 2 }
        await feedCaptureReplies(client, paneID: "%13", history: ["fresh"])
        #expect((await ready2Task.value).success)
        #expect(await supervisor.isReady(server: "tbd-sharedsup-test", paneID: "%13") == true)
        try await waitFor("gen 2 unpause") { recorder.writes.count >= 3 }
        let continues = recorder.writes.filter { $0.contains(":continue'") }
        #expect(continues == ["refresh-client -A '%13:continue'"],
                "exactly ONE continue, the successor's own")
        #expect(recorder.writes.last == "refresh-client -A '%13:continue'")
    }

    @Test("a stale attach's late failure must not kill a healthy successor's sink")
    func staleFailureCleanupSparesSuccessor() async throws {
        let (serverSide, clientSide) = try makeSocketPair()
        defer { Darwin.close(clientSide) }

        let supervisor = TmuxControlSupervisor()
        let vending = FDVendingServer()
        await vending.adoptConnection(fd: serverSide)
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db, tmuxServer: "tbd-stalefail-test")

        // One fake correlator PER attach.ready sequence: the stale (gen 1)
        // sequence rides clientA, the fresh (gen 2) one rides clientB — so
        // the test can complete gen 2's capture batch while gen 1's replies
        // stay delayed, reproducing the fast tab-switch race.
        let (clientA, recorderA) = makeFakeClient()
        let (clientB, recorderB) = makeFakeClient()
        let calls = CallCounter()
        router.controlMode = bridge(
            supervisor: supervisor, vending: vending,
            commandProvider: { _ in calls.next() == 0 ? clientA : clientB })

        func attachRequest() throws -> RPCRequest {
            try RPCRequest(
                method: RPCMethod.attachRequest,
                params: AttachRequestParams(
                    worktreeID: worktreeID, paneID: "%5", windowID: "@5", attachID: UUID()))
        }
        let ready = try RPCRequest(
            method: RPCMethod.attachReady,
            params: AttachReadyParams(worktreeID: worktreeID, paneID: "%5"))

        // Attach #1 (gen 1); its ready sequence starts and stalls on replies.
        _ = await router.handle(try attachRequest())
        let (fd1, _) = try SidecarTestSupport.receiveVend(from: clientSide)
        defer { Darwin.close(fd1) }
        let ready1 = Task { await router.handle(ready) }
        try await waitFor("gen 1 capture batch") { recorderA.writes.count >= 1 }

        // Attach #2 (fast tab-switch re-attach, gen 2) replaces the sink and
        // completes its OWN sequence: replay written, gate open. Healthy.
        _ = await router.handle(try attachRequest())
        let (fd2, _) = try SidecarTestSupport.receiveVend(from: clientSide)
        defer { Darwin.close(fd2) }
        let ready2 = Task { await router.handle(ready) }
        try await waitFor("gen 2 capture batch") { recorderB.writes.count >= 1 }
        await feedCaptureReplies(clientB, paneID: "%5", history: ["fresh-history"])
        let response2 = await ready2.value
        #expect(response2.success)
        #expect(await supervisor.isReady(server: "tbd-stalefail-test", paneID: "%5") == true)
        #expect((String(bytes: drain(fd2), encoding: .utf8) ?? "").contains("fresh-history"))

        // Gen 1's DELAYED capture reply is a %error → its sequence fails.
        // (pause OK, main-history %error, remaining three OK.)
        await clientA.handle(.commandSucceeded(number: 0, fromClient: true, lines: []))
        await clientA.handle(.commandFailed(number: 0, fromClient: true, lines: ["no such pane"]))
        for _ in 0..<3 {
            await clientA.handle(.commandSucceeded(number: 0, fromClient: true, lines: []))
        }
        let response1 = await ready1.value
        #expect(!response1.success, "the stale caller must get an RPC error")

        // THE REGRESSION: gen 1's failure cleanup must NOT detach gen 2's
        // healthy sink — gate still open, no EOF, output still routes.
        #expect(await supervisor.isReady(server: "tbd-stalefail-test", paneID: "%5") == true)
        supervisor.fanout.route(
            server: "tbd-stalefail-test",
            event: .output(paneID: "%5", bytes: Data("still-alive".utf8)))
        #expect((String(bytes: drain(fd2), encoding: .utf8) ?? "") == "still-alive",
                "successor's pipe must survive the stale attach's failure cleanup")
    }

    @Test("a stale pane.detach (older generation) no-ops against a newer attach's sink")
    func stalePaneDetachSparesSuccessor() async throws {
        let (serverSide, clientSide) = try makeSocketPair()
        defer { Darwin.close(clientSide) }

        let supervisor = TmuxControlSupervisor()
        let vending = FDVendingServer()
        await vending.adoptConnection(fd: serverSide)
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db, tmuxServer: "tbd-staledet-test")
        router.controlMode = bridge(supervisor: supervisor, vending: vending)

        func attach() async throws -> AttachRequestResult {
            let request = try RPCRequest(
                method: RPCMethod.attachRequest,
                params: AttachRequestParams(
                    worktreeID: worktreeID, paneID: "%3", windowID: "@3", attachID: UUID()))
            return try (await router.handle(request)).decodeResult(AttachRequestResult.self)
        }
        // Attach #1 (the closing view's) … superseded by attach #2.
        let result1 = try await attach()
        let gen1 = try #require(result1.generation, "attach.request must vend the generation")
        let (fd1, _) = try SidecarTestSupport.receiveVend(from: clientSide)
        defer { Darwin.close(fd1) }
        let result2 = try await attach()
        let gen2 = try #require(result2.generation)
        #expect(gen2 > gen1)
        let (fd2, _) = try SidecarTestSupport.receiveVend(from: clientSide)
        defer { Darwin.close(fd2) }

        // The closing view's pane.detach arrives AFTER the new attach: it
        // echoes gen 1 and must NOT kill the gen-2 sink.
        let staleDetach = try RPCRequest(
            method: RPCMethod.paneDetach,
            params: PaneDetachParams(worktreeID: worktreeID, paneID: "%3", generation: gen1))
        #expect((await router.handle(staleDetach)).success)
        let flags = fcntl(fd2, F_GETFL)
        _ = fcntl(fd2, F_SETFL, flags | O_NONBLOCK)
        #expect(try await eofObserved(on: fd2, within: .milliseconds(200)) == false,
                "newer sink must survive the stale pane.detach (no EOF)")

        // The CURRENT generation's detach still tears the sink down.
        let currentDetach = try RPCRequest(
            method: RPCMethod.paneDetach,
            params: PaneDetachParams(worktreeID: worktreeID, paneID: "%3", generation: gen2))
        #expect((await router.handle(currentDetach)).success)
        #expect(try await eofObserved(on: fd2, within: .seconds(60)) == true,
                "matching-generation pane.detach must detach (EOF)")
    }

    /// Poll a NONBLOCKING, empty fd for EOF until `deadline`. Retries on
    /// EAGAIN/EINTR — a single-shot read probe flakes under parallel-suite
    /// load. Callers assert `== true` (detach expected) or `== false` (sink
    /// must survive; the short deadline is the observation window).
    private func eofObserved(on fd: Int32, within deadline: Duration) async throws -> Bool {
        let end = ContinuousClock.now + deadline
        var buffer = [UInt8](repeating: 0, count: 8)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n == 0 { return true }
            if n > 0 { Issue.record("unexpected data on a pipe that should be empty") }
            if ContinuousClock.now >= end { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("pane.detach without a generation detaches unconditionally (back-compat)")
    func paneDetachWithoutGenerationDetaches() async throws {
        let (serverSide, clientSide) = try makeSocketPair()
        defer { Darwin.close(clientSide) }

        let supervisor = TmuxControlSupervisor()
        let vending = FDVendingServer()
        await vending.adoptConnection(fd: serverSide)
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db, tmuxServer: "tbd-nogendet-test")
        router.controlMode = bridge(supervisor: supervisor, vending: vending)

        let request = try RPCRequest(
            method: RPCMethod.attachRequest,
            params: AttachRequestParams(
                worktreeID: worktreeID, paneID: "%4", windowID: "@4", attachID: UUID()))
        _ = await router.handle(request)
        let (fd, _) = try SidecarTestSupport.receiveVend(from: clientSide)
        defer { Darwin.close(fd) }

        let detach = try RPCRequest(
            method: RPCMethod.paneDetach,
            params: PaneDetachParams(worktreeID: worktreeID, paneID: "%4"))
        #expect((await router.handle(detach)).success)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        #expect(try await eofObserved(on: fd, within: .seconds(60)) == true,
                "generation-less pane.detach must still detach (EOF)")
    }

    @Test("a capture failure detaches the pane and fails the RPC (app falls back)")
    func captureFailureDetachesAndErrors() async throws {
        let (serverSide, clientSide) = try makeSocketPair()
        defer { Darwin.close(clientSide) }

        let supervisor = TmuxControlSupervisor()
        let vending = FDVendingServer()
        await vending.adoptConnection(fd: serverSide)
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db, tmuxServer: "tbd-capfail-test")
        let (client, recorder) = makeFakeClient()
        router.controlMode = bridge(
            supervisor: supervisor, vending: vending, commandProvider: { _ in client })

        let attach = try RPCRequest(
            method: RPCMethod.attachRequest,
            params: AttachRequestParams(worktreeID: worktreeID, paneID: "%9", windowID: "@9", attachID: UUID()))
        _ = await router.handle(attach)
        let (rxFD, _) = try SidecarTestSupport.receiveVend(from: clientSide)
        defer { Darwin.close(rxFD) }

        let ready = try RPCRequest(
            method: RPCMethod.attachReady,
            params: AttachReadyParams(worktreeID: worktreeID, paneID: "%9"))
        let readyTask = Task { await router.handle(ready) }
        try await waitFor("capture batch write") { recorder.writes.count >= 1 }

        // pause OK, then the main-history capture %errors (dead pane).
        await client.handle(.commandSucceeded(number: 0, fromClient: true, lines: []))
        await client.handle(.commandFailed(number: 0, fromClient: true, lines: ["no such pane"]))
        for _ in 0..<3 {
            await client.handle(.commandSucceeded(number: 0, fromClient: true, lines: []))
        }

        let response = await readyTask.value
        #expect(!response.success)
        // The daemon detached: the vended fd sees EOF (mirrors pane.detach).
        var buffer = [UInt8](repeating: 0, count: 8)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(rxFD, $0.baseAddress, $0.count) }
        #expect(n == 0, "failed attach must be detached (EOF on the vended fd)")
        // Unpause still ran despite the failure.
        try await waitFor("unpause write") { recorder.writes.count >= 2 }
        #expect(recorder.writes.last == "refresh-client -A '%9:continue'")
    }
}
