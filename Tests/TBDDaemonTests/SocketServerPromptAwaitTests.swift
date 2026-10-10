import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// Tier 2 — `prompt.await` over a real daemon socket: the long-poll bypasses
/// the RPC concurrency limiter, an answer reaches the awaiting connection and
/// settles through `prompt.ack`, and closing the connection resolves the
/// prompt. (`docs/specs/2026-10-09-transcript-prompt-answer-design.md`.)
///
/// No external process: the server, its router and the raw clients all live
/// in this test process, so the suite stays in the fast pass.
@Suite(.fastPassBounded)
struct SocketServerPromptAwaitTests {

    static let bashInput = #"{"command":"ls"}"#

    private struct Harness {
        let router: RPCRouter
        let store: PendingPromptStore
        let server: SocketServer
        let socketPath: String
        let terminalID: UUID
    }

    /// Short `/tmp` path, well under the ~104-byte `sun_path` limit. NOT
    /// `~/tbd/sock`.
    private func scratchSocketPath() -> String {
        "/tmp/tbd-pawait-\(UUID().uuidString.prefix(8)).sock"
    }

    private func makeHarness() async throws -> Harness {
        let db = try TBDDatabase(inMemory: true)
        let store = PendingPromptStore()
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            pendingQuestions: store,
            recordedAppIdentity: { SendHarness.AuthenticatedApp.identity },
            processSignaller: SendHarness.AuthenticatedApp.Signaller(),
            actuationLog: makeTestActuationLog())
        try await db.config.setTranscriptPromptAnswerEnabled(true)
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)", displayName: "test-repo", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test-wt-\(UUID().uuidString)", tmuxServer: "tbd-test")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@mock-0", tmuxPaneID: "%mock-0")
        let socketPath = scratchSocketPath()
        let server = SocketServer(router: router, socketPath: socketPath)
        try await server.start()
        return Harness(router: router, store: store, server: server,
                       socketPath: socketPath, terminalID: terminal.id)
    }

    private func tearDown(_ h: Harness) async {
        await h.server.stop()
        unlink(h.socketPath)
    }

    private func registerPrompt(_ h: Harness, session: String) async throws -> String {
        let params = PromptRegisterParams(
            terminalID: h.terminalID, sessionID: session, toolName: "Bash",
            toolInputJSON: Self.bashInput, suggestionsJSON: nil,
            inputHash: PromptInputHash.of(toolInputJSON: Self.bashInput))
        let response = await h.router.handle(try RPCRequest(method: RPCMethod.promptRegister, params: params))
        guard case .registered(let id, _) = try response.decodeResult(PromptRegisterResult.self) else {
            throw HarnessError.notRegistered
        }
        return id
    }

    private enum HarnessError: Error { case notRegistered }

    private func line(_ request: RPCRequest) throws -> String {
        try #require(String(data: try JSONEncoder().encode(request), encoding: .utf8))
    }

    /// Connects a client and sends one `prompt.await` line on it.
    private func openAwait(_ h: Harness, promptID: String) throws -> PromptRawClient {
        let client = PromptRawClient()
        try #require(client.connect(to: h.socketPath, receiveTimeout: TestDeadlines.saturatedPassSeconds),
                     "could not connect to the test server")
        let request = try RPCRequest(method: RPCMethod.promptAwait, params: PromptAwaitParams(promptID: promptID))
        try #require(client.send(line: try line(request)), "could not write prompt.await")
        return client
    }

    private func waitAttached(_ h: Harness, _ ids: [String]) async throws {
        let store = h.store
        let detached: @Sendable () async -> Int = {
            var count = 0
            for id in ids {
                let attached = await store.isWaiterAttached(promptID: id)
                if !attached { count += 1 }
            }
            return count
        }
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await detached() == 0
        }
        if outcome == .timedOut {
            let missing = await detached()
            throw PromptAwaitTimeout(
                what: "waiters to attach", observed: "\(missing) of \(ids.count) not attached")
        }
    }

    // MARK: Tests

    /// `prompt.ack` must never queue behind slow RPCs: `prompt.answer` reads
    /// an ack later than 5 s as `already_resolved`, turning a delivered
    /// answer into a false "answered elsewhere"; nor may `prompt.note`, which
    /// every tool call's hooks send under a 3-second timeout. Ordinary
    /// methods, including the other prompt RPCs, stay limited.
    @Test func limiterBypassClassification() {
        for method in [RPCMethod.stateSubscribe, RPCMethod.promptAwait, RPCMethod.promptAck,
                       RPCMethod.promptNote] {
            #expect(SocketServer.bypassesConcurrencyLimiter(method: method), "\(method)")
        }
        for method in [RPCMethod.promptAnswer, RPCMethod.promptRegister, "worktree.list"] {
            #expect(!SocketServer.bypassesConcurrencyLimiter(method: method), "\(method)")
        }
        #expect(!SocketServer.bypassesConcurrencyLimiter(method: nil))
    }

    @Test func awaitsDoNotOccupyLimiterSlots() async throws {
        let h = try await makeHarness()
        let count = RPCConcurrencyLimiter.maxConcurrentRPCs + 1
        var ids: [String] = []
        for index in 0..<count {
            ids.append(try await registerPrompt(h, session: "s\(index)"))
        }
        var clients: [PromptRawClient] = []
        for id in ids { clients.append(try openAwait(h, promptID: id)) }

        // Through the limiter, `prompt.await` would reach `RPCRouter.handle`,
        // which refuses it, so no waiter would ever attach.
        try await waitAttached(h, ids)

        // A cheap RPC on the normal path still answers with every await parked.
        let probe = PromptRawClient()
        try #require(probe.connect(to: h.socketPath, receiveTimeout: TestDeadlines.saturatedPassSeconds))
        let ack = try RPCRequest(method: RPCMethod.promptAck,
                                 params: PromptAckParams(token: UUID(), delivered: true))
        try #require(probe.send(line: try line(ack)))
        let raw = await gateHoldingTask { probe.receiveLine() }.value
        let response = try JSONDecoder().decode(RPCResponse.self, from: Data(try #require(raw).utf8))
        #expect(response.success)

        probe.disconnect()
        for client in clients { client.disconnect() }
        await tearDown(h)
    }

    @Test func answerReachesTheAwaitingConnection() async throws {
        let h = try await makeHarness()
        let id = try await registerPrompt(h, session: "s1")
        let client = try openAwait(h, promptID: id)
        try await waitAttached(h, [id])

        let router = h.router
        let answerRequest = try RPCRequest(
            method: RPCMethod.promptAnswer,
            params: PromptAnswerParams(
                terminalID: h.terminalID, promptID: id,
                answer: .permission(decision: .deny, message: "not now")),
            actor: .app)
        let answering = Task {
            await router.handle(answerRequest, connection: SendHarness.AuthenticatedApp.connection)
        }

        let raw = await gateHoldingTask { client.receiveLine() }.value
        let response = try JSONDecoder().decode(RPCResponse.self, from: Data(try #require(raw).utf8))
        let reply = try response.decodeResult(PromptAwaitReply.self)
        guard case .answered(let hookOutput) = reply.result else {
            Issue.record("expected an answered reply, got \(reply.result)")
            client.disconnect()
            await tearDown(h)
            return
        }
        #expect(hookOutput.contains(#""behavior":"deny""#))
        let token = try #require(reply.deliveryToken)

        // The hook acks on a connection of its own, after printing.
        let acker = PromptRawClient()
        try #require(acker.connect(to: h.socketPath, receiveTimeout: TestDeadlines.saturatedPassSeconds))
        try #require(acker.send(line: try line(try RPCRequest(
            method: RPCMethod.promptAck, params: PromptAckParams(token: token, delivered: true)))))
        _ = await gateHoldingTask { acker.receiveLine() }.value

        let answered = await answering.value
        #expect(answered.success, "error: \(answered.error ?? "none")")
        #expect(try answered.decodeResult(PromptAnswerResult.self).outcome == .delivered)

        acker.disconnect()
        client.disconnect()
        await tearDown(h)
    }

    @Test func closingTheAwaitingConnectionResolvesThePrompt() async throws {
        let h = try await makeHarness()
        let id = try await registerPrompt(h, session: "s1")
        let client = try openAwait(h, promptID: id)
        try await waitAttached(h, [id])

        client.disconnect()

        let store = h.store
        let terminalID = h.terminalID
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await store.prompts(forTerminal: terminalID).isEmpty
        }
        if outcome == .timedOut {
            let open = await store.prompts(forTerminal: terminalID).count
            Issue.record(PromptAwaitTimeout(
                what: "the prompt to resolve after its connection closed",
                observed: "\(open) prompt(s) still open"))
        }
        await tearDown(h)
    }
}

private struct PromptAwaitTimeout: Error, CustomStringConvertible {
    let what: String
    let observed: String
    var description: String {
        "timed out after \(TestDeadlines.saturatedPassSeconds) s waiting for \(what) — observed \(observed)"
    }
}

/// A newline-delimited-JSON client over a plain `AF_UNIX` socket.
private final class PromptRawClient: @unchecked Sendable {
    private var fd: Int32 = -1

    func connect(to path: String, receiveTimeout: TimeInterval) -> Bool {
        let newFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard newFD >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(newFD)
            return false
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(newFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(newFD)
            return false
        }
        var timeout = timeval(tv_sec: Int(receiveTimeout), tv_usec: 0)
        _ = setsockopt(newFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        fd = newFD
        return true
    }

    func send(line: String) -> Bool {
        guard fd >= 0 else { return false }
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { buffer in
                Darwin.write(fd, buffer.baseAddress, buffer.count)
            }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    /// The first newline-terminated line, or nil if the peer closed or the
    /// receive timeout expired first.
    func receiveLine() -> String? {
        guard fd >= 0 else { return nil }
        var accumulated: [UInt8] = []
        var scratch = [UInt8](repeating: 0, count: 4096)
        while !accumulated.contains(UInt8(ascii: "\n")) {
            let count = scratch.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress, buffer.count)
            }
            guard count > 0 else { return nil }
            accumulated.append(contentsOf: scratch[0..<count])
        }
        guard let newline = accumulated.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        return String(bytes: accumulated[0..<newline], encoding: .utf8)
    }

    func disconnect() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }
}
