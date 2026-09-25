import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// `remote.transcriptSync` and `remote.sendMessage` through the router: every
/// gate on both branches, the argv and stdin each invokes, the actuation row,
/// and per-session serialization of sends.
///
/// Tier 2: in-memory GRDB, a fake provider invoker, a temp `TBD_HOME` for the
/// cache and a temp actuation log; no real subprocess. `describe` is popped
/// first, so scripts read `[describe, ...]`.
@Suite("RPCRouter remote.transcriptSync / remote.sendMessage")
struct RPCRouterRemoteTranscriptSyncTests: ~Copyable {
    let db: TBDDatabase
    let subs: StateSubscriptionManager
    let dir: URL
    let registryURL: URL
    let logPath: String

    init() throws {
        let localDB = try TBDDatabase(inMemory: true)
        let localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpc-remote-transcript-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        let localRegistryURL = localDir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "agentbox", "exec": "/nonexistent"}]"#
            .write(to: localRegistryURL, atomically: true, encoding: .utf8)
        db = localDB
        subs = StateSubscriptionManager()
        dir = localDir
        registryURL = localRegistryURL
        logPath = localDir.appendingPathComponent("actuations.jsonl").path
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private var home: URL { dir.appendingPathComponent("home", isDirectory: true) }

    private func manager(_ invoker: FakeProviderInvoker, describe: Bool = true) async -> RemoteProviderManager {
        let manager = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL,
            actuationLog: makeTestActuationLog())
        if describe { await manager.loadRegistryAndDescribe() }
        return manager
    }

    private func router(_ manager: RemoteProviderManager?) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver(),
                subscriptions: subs),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            subscriptions: subs,
            remoteManager: manager,
            actuationLog: ActuationLog(path: logPath),
            remoteTranscriptEnvironment: ["TBD_HOME": home.path])
    }

    private func describeDeclaring(_ capabilities: [String]) -> ProviderResult {
        let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ", ")
        return providerOK(#"{"contract_versions": [1], "name": "agentbox", "capabilities": [\#(caps)]}"#)
    }

    private func sync(_ r: RPCRouter) async -> RPCResponse {
        await r.handle(RPCRequest(
            method: RPCMethod.remoteTranscriptSync,
            params: #"{"provider": "agentbox", "sessionID": "s-1"}"#))
    }

    private func send(_ r: RPCRouter, _ text: String = "hello agent") async throws -> RPCResponse {
        await r.handle(try RPCRequest(
            method: RPCMethod.remoteSendMessage,
            params: RemoteSendMessageParams(provider: "agentbox", sessionID: "s-1", text: text)))
    }

    private func seedSession(state: RemoteProcessState = .running, agentState: RemoteAgentState) async throws {
        _ = try await db.remoteSessions.applySnapshot(
            provider: "agentbox",
            sessions: [RemoteSessionPayload(id: "s-1", state: state, agentState: agentState)],
            now: Date())
    }

    private func actuationRows() throws -> [[String: Any]] {
        guard let contents = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
        return try contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    // MARK: - Shared gates

    @Test func bothAreRefusedWhileRemoteBackendsAreOff() async throws {
        try await db.config.setRemoteTranscriptEnabled(true)
        let invoker = FakeProviderInvoker(script: [])
        let r = router(await manager(invoker, describe: false))
        #expect(await sync(r).error == "remote backends disabled")
        #expect(try await send(r).error == "remote backends disabled")
        #expect(invoker.callsSnapshot().isEmpty)
    }

    /// The flag is on in the DB but the daemon booted without a manager.
    @Test func bothAreRefusedWithNoManager() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setRemoteTranscriptEnabled(true)
        let r = router(nil)
        #expect(await sync(r).error == "remote backends disabled")
        #expect(try await send(r).error == "remote backends disabled")
    }

    // MARK: - remote.transcriptSync

    @Test func syncIsRefusedWithTheFlagOff() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [describeDeclaring([RemoteCapability.transcriptRead])])
        let r = router(await manager(invoker))
        let response = await sync(r)
        #expect(response.success == false)
        #expect(response.error == RPCRouter.remoteTranscriptDisabledResponse.error)
        #expect(invoker.callsSnapshot() == [["describe"]])
    }

    /// An explicit `false` refuses too — not only the unset default.
    @Test func syncIsRefusedWithTheFlagExplicitlyOff() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setRemoteTranscriptEnabled(false)
        let invoker = FakeProviderInvoker(script: [describeDeclaring([RemoteCapability.transcriptRead])])
        let r = router(await manager(invoker))
        #expect(await sync(r).error == RPCRouter.remoteTranscriptDisabledResponse.error)
        #expect(invoker.callsSnapshot() == [["describe"]])
    }

    @Test func syncIsRefusedWithoutTranscriptRead() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setRemoteTranscriptEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["transcript", RemoteCapability.transcriptRecall, "log"]),
        ])
        let r = router(await manager(invoker))
        let response = await sync(r)
        #expect(response.success == false)
        #expect(response.error?.contains(RemoteCapability.transcriptRead) == true)
        #expect(invoker.callsSnapshot() == [["describe"]])
    }

    @Test func syncWritesTheCacheAndReturnsWhereItIs() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setRemoteTranscriptEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring([RemoteCapability.transcriptRead]),
            ProviderResult(exitCode: 0, stdout: Data("{\"n\":1}\n".utf8), stderr: #"{"cursor": "c-1"}"#),
            ProviderResult(exitCode: 0, stdout: Data("{\"n\":2}\n".utf8), stderr: #"{"cursor": "c-2"}"#),
        ])
        let r = router(await manager(invoker))

        let first = try await sync(r).decodeResult(RemoteTranscriptSyncResult.self)
        let second = try await sync(r).decodeResult(RemoteTranscriptSyncResult.self)

        let expectedPath = TBDConstants.remoteTranscriptDir(
            provider: "agentbox", sessionID: "s-1", environment: ["TBD_HOME": home.path])
            .appendingPathComponent(TBDConstants.remoteTranscriptFileName).path
        #expect(second == RemoteTranscriptSyncResult(path: expectedPath, generation: 1, caughtUp: true))
        #expect(first.generation == 1)
        #expect(try String(contentsOfFile: expectedPath, encoding: .utf8) == "{\"n\":1}\n{\"n\":2}\n")
        #expect(invoker.callsSnapshot() == [
            ["describe"],
            RemoteVerb.transcriptRead(sessionID: "s-1"),
            RemoteVerb.transcriptRead(sessionID: "s-1", since: "c-1"),
        ])
    }

    @Test func syncSurfacesAProviderFailure() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setRemoteTranscriptEnabled(true)
        let invoker = FakeProviderInvoker(outcomes: [
            .result(describeDeclaring([RemoteCapability.transcriptRead])),
            .result(ProviderResult(
                exitCode: 1,
                stdout: Data(#"{"error": {"code": "not_found", "message": "no such session"}}"#.utf8),
                stderr: "")),
            .timeout,
        ])
        let r = router(await manager(invoker))
        #expect(await sync(r).error == "no such session")
        #expect(await sync(r).error == "provider 'agentbox' timed out running 'transcript read'")
    }

    // MARK: - remote.sendMessage refusals

    @Test func sendIsRefusedWithoutSendSubmit() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [describeDeclaring(["send"])])
        let r = router(await manager(invoker))
        let response = try await send(r)
        #expect(response.success == false)
        #expect(response.error?.contains(RemoteCapability.sendSubmit) == true)
        #expect(invoker.callsSnapshot() == [["describe"]])
        #expect(try actuationRows().isEmpty)
    }

    @Test func sendIsRefusedOnAStaleSnapshot() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["send", RemoteCapability.sendSubmit]),
            providerOK(#"{"sessions": [{"id": "s-1", "state": "running"}]}"#),
            ProviderResult(exitCode: 3, stdout: Data(), stderr: "inventory unavailable"),
        ])
        let m = await manager(invoker)
        let config = RemoteProviderConfig(name: "agentbox", exec: "/nonexistent")
        await m.pollOnce(provider: config)
        await m.pollOnce(provider: config)
        let r = router(m)
        let response = try await send(r)
        #expect(response.success == false)
        #expect(response.error?.contains("inventory is stale") == true)
        #expect(!invoker.callsSnapshot().contains { $0.first == "send" })
        #expect(try actuationRows().isEmpty)
    }

    @Test func sendIsRefusedWhileTheAgentWaitsOnAPrompt() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await seedSession(agentState: .waitingInput)
        let invoker = FakeProviderInvoker(script: [describeDeclaring(["send", RemoteCapability.sendSubmit])])
        let r = router(await manager(invoker))
        let response = try await send(r)
        #expect(response.error == RPCRouter.sendMessageWaitingInputRefusal)
        #expect(response.error?.contains("answer it in the terminal") == true)
        #expect(invoker.callsSnapshot() == [["describe"]])
    }

    @Test(arguments: [
        (RemoteProcessState.exited, RemoteAgentState.exited),
        (RemoteProcessState.exited, RemoteAgentState.idle),
        (RemoteProcessState.running, RemoteAgentState.exited),
    ])
    func sendIsRefusedAfterTheSessionExited(state: RemoteProcessState, agentState: RemoteAgentState) async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await seedSession(state: state, agentState: agentState)
        let invoker = FakeProviderInvoker(script: [describeDeclaring(["send", RemoteCapability.sendSubmit])])
        let r = router(await manager(invoker))
        #expect(try await send(r).error == RPCRouter.sendMessageExitedRefusal)
        #expect(invoker.callsSnapshot() == [["describe"]])
    }

    @Test func aGoneSessionReadsAsExited() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await seedSession(agentState: .idle)
        try await db.remoteSessions.markGone(provider: "agentbox", sessionID: "s-1")
        let invoker = FakeProviderInvoker(script: [describeDeclaring(["send", RemoteCapability.sendSubmit])])
        let r = router(await manager(invoker))
        #expect(try await send(r).error == RPCRouter.sendMessageExitedRefusal)
    }

    // MARK: - remote.sendMessage delivery

    /// The two ungated branches of the state checks: a working or idle agent,
    /// and a session the mirror has not reported yet.
    @Test(arguments: [RemoteAgentState.working, RemoteAgentState.idle, nil])
    func sendInvokesSendSubmitWithTheTextOnStdin(agentState: RemoteAgentState?) async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        if let agentState { try await seedSession(agentState: agentState) }
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["send", RemoteCapability.sendSubmit]),
            providerOK("{}"),
        ])
        let r = router(await manager(invoker))
        let text = "fix the flaky test\nthen push"
        let response = try await send(r, text)
        #expect(response.success)
        #expect(invoker.callsSnapshot() == [["describe"], ["send", "s-1", "--submit"]])
        #expect(invoker.stdinsSnapshot().last ?? nil == Data(text.utf8))

        let rows = try actuationRows()
        #expect(rows.count == 2)
        let request = try #require(rows.first)
        #expect(request["kind"] as? String == "send")
        #expect(request["method"] as? String == RPCMethod.remoteSendMessage)
        #expect(request["message"] as? String == text)
        #expect(request["submit"] as? Bool == true)
        #expect(rows.last?["result"] as? String == "dispatched")
    }

    @Test func aFailedSendIsRecordedAndSurfaced() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["send", RemoteCapability.sendSubmit]),
            ProviderResult(
                exitCode: 1,
                stdout: Data(#"{"error": {"code": "not_ready", "message": "input box not ready"}}"#.utf8),
                stderr: ""),
        ])
        let r = router(await manager(invoker))
        #expect(try await send(r).error == "input box not ready")
        #expect(try actuationRows().last?["result"] as? String == "transport-failed")
    }

    /// Two sends to one session never overlap: the second reaches the provider
    /// only after the first has returned.
    @Test func concurrentSendsToOneSessionAreSerialized() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["send", RemoteCapability.sendSubmit]),
            providerOK("{}"),
            providerOK("{}"),
        ])
        let trace = Trace()
        let gate = Gate()
        invoker.onCall = { verb in
            guard verb.first == "send" else { return }
            let isFirst = await trace.enter()
            if isFirst { await gate.wait() }
            await trace.exit()
        }
        let r = router(await manager(invoker))

        let one = try RPCRequest(
            method: RPCMethod.remoteSendMessage,
            params: RemoteSendMessageParams(provider: "agentbox", sessionID: "s-1", text: "one"))
        let two = try RPCRequest(
            method: RPCMethod.remoteSendMessage,
            params: RemoteSendMessageParams(provider: "agentbox", sessionID: "s-1", text: "two"))
        async let first = r.handle(one)
        let firstEntered = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await trace.events == ["in"]
        }
        async let second = r.handle(two)
        let secondQueued = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await r.remoteSendMessageSerializer.admittedCount == 2
        }
        let eventsWhileHeld = await trace.events
        await gate.open()

        let responses = await [first, second]
        #expect(firstEntered == .satisfied)
        #expect(secondQueued == .satisfied)
        #expect(eventsWhileHeld == ["in"])
        let allSucceeded = responses.allSatisfy { $0.success }
        #expect(allSucceeded)
        #expect(await trace.events == ["in", "out", "in", "out"])
        let stdins = invoker.stdinsSnapshot().dropFirst().map { $0.flatMap { String(data: $0, encoding: .utf8) } }
        #expect(stdins == ["one", "two"])
    }

    private actor Trace {
        private(set) var events: [String] = []
        private var entries = 0
        /// Returns whether this is the first entry.
        func enter() -> Bool {
            events.append("in")
            entries += 1
            return entries == 1
        }
        func exit() { events.append("out") }
    }

    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            opened = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}
