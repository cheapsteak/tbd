import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// `remote.answer` through the router: every gate, the stale-prompt short
/// circuit, the argv and stdin it invokes, the provider error mapping, the
/// unknown outcomes, the actuation row, and the lane it shares with
/// `remote.sendMessage`.
///
/// Tier 2: in-memory GRDB, a fake provider invoker and a temp actuation log; no
/// real subprocess. `describe` is popped first, so scripts read
/// `[describe, ...]`.
@Suite("RPCRouter remote.answer")
struct RPCRouterRemoteAnswerTests: ~Copyable {
    let db: TBDDatabase
    let subs: StateSubscriptionManager
    let dir: URL
    let registryURL: URL
    let logPath: String

    init() throws {
        let localDB = try TBDDatabase(inMemory: true)
        let localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpc-remote-answer-\(UUID().uuidString)")
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

    private static let allowAnswer = PromptAnswer.permission(decision: .allow, message: nil)

    private func answer(
        _ r: RPCRouter, promptID: String = "p-1", _ answer: PromptAnswer = RPCRouterRemoteAnswerTests.allowAnswer
    ) async throws -> RPCResponse {
        await r.handle(try RPCRequest(
            method: RPCMethod.remoteAnswer,
            params: RemoteAnswerParams(provider: "agentbox", sessionID: "s-1", promptID: promptID, answer: answer)))
    }

    /// A `list` answer naming session `s-1` blocked on permission prompt `p-1`.
    /// Mirrored through the manager's own poll, as the send tests do.
    private func listing(agentState: RemoteAgentState = .waitingInput) -> ProviderResult {
        providerOK(#"""
            {"sessions": [{"id": "s-1", "state": "running", "agent_state": "\#(agentState.rawValue)", \#
            "pending_prompt": {"id": "p-1", "kind": "permission", "tool_name": "Bash", \#
            "tool_input": {"command": "touch x"}}}]}
            """#)
    }

    /// Everything `remote.answer` needs on: remote backends and the flag.
    private func enable() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setTranscriptPromptAnswerEnabled(true)
    }

    private func poll(_ manager: RemoteProviderManager) async {
        await manager.pollOnce(provider: RemoteProviderConfig(name: "agentbox", exec: "/nonexistent"))
    }

    private static func answers(_ invoker: FakeProviderInvoker) -> [[String]] {
        invoker.callsSnapshot().filter { $0.first == "answer" }
    }

    private func actuationRows() throws -> [[String: Any]] {
        guard let contents = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
        return try contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    private func failure(code: String, message: String) -> ProviderResult {
        ProviderResult(
            exitCode: 1,
            stdout: Data(#"{"error": {"code": "\#(code)", "message": "\#(message)"}}"#.utf8),
            stderr: "")
    }

    /// A manager that has described with `answer` and mirrored the prompt,
    /// with `rest` scripted after the `list`.
    private func primed(_ rest: [FakeProviderOutcome]) async -> (FakeProviderInvoker, RPCRouter) {
        let invoker = FakeProviderInvoker(outcomes: [
            .result(describeDeclaring([RemoteCapability.answer])),
            .result(listing()),
        ] + rest)
        let m = await manager(invoker)
        await poll(m)
        return (invoker, router(m))
    }

    // MARK: - Gates

    @Test func refusedWhileRemoteBackendsAreOff() async throws {
        try await db.config.setTranscriptPromptAnswerEnabled(true)
        let invoker = FakeProviderInvoker(script: [])
        let r = router(await manager(invoker, describe: false))
        #expect(try await answer(r).error == "remote backends disabled")
        #expect(invoker.callsSnapshot().isEmpty)
    }

    @Test func refusedWhileFlagOff() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [describeDeclaring([RemoteCapability.answer]), listing()])
        let m = await manager(invoker)
        await poll(m)
        let response = try await answer(router(m))
        #expect(response.error == RPCRouter.promptAnswerDisabledRefusal)
        #expect(Self.answers(invoker).isEmpty)
        #expect(try actuationRows().isEmpty)
    }

    @Test func refusedWithoutAnswerCapability() async throws {
        try await enable()
        let invoker = FakeProviderInvoker(script: [describeDeclaring(["send"]), listing()])
        let m = await manager(invoker)
        await poll(m)
        let response = try await answer(router(m))
        #expect(response.success == false)
        #expect(response.error?.contains("has not declared capability '\(RemoteCapability.answer)'") == true)
        #expect(response.error?.contains("answer <session_id> <prompt_id>") == true)
        #expect(Self.answers(invoker).isEmpty)
        #expect(try actuationRows().isEmpty)
    }

    @Test func refusedOnAStaleSnapshot() async throws {
        try await enable()
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring([RemoteCapability.answer]),
            listing(),
            ProviderResult(exitCode: 3, stdout: Data(), stderr: "inventory unavailable"),
        ])
        let m = await manager(invoker)
        await poll(m)
        await poll(m)
        let response = try await answer(router(m))
        #expect(response.success == false)
        #expect(response.error?.contains("inventory is stale") == true)
        #expect(Self.answers(invoker).isEmpty)
        #expect(try actuationRows().isEmpty)
    }

    @Test func refusedWhenTheSessionIsNotMirrored() async throws {
        try await enable()
        let invoker = FakeProviderInvoker(script: [describeDeclaring([RemoteCapability.answer])])
        let response = try await answer(router(await manager(invoker)))
        #expect(response.error == RPCRouter.remoteAnswerNotMirroredRefusal)
        #expect(Self.answers(invoker).isEmpty)
    }

    /// The prompt named was replaced or answered elsewhere: already resolved,
    /// as a result rather than an error, and the provider is never asked.
    @Test func stalePromptIDIsAlreadyResolvedWithoutInvoking() async throws {
        try await enable()
        let (invoker, r) = await primed([])
        let response = try await answer(r, promptID: "p-0")
        #expect(response.success)
        #expect(try response.decodeResult(PromptAnswerResult.self).outcome == .alreadyResolved)
        #expect(Self.answers(invoker).isEmpty)
        #expect(try actuationRows().isEmpty)
    }

    /// An answer that cannot fit the mirrored prompt is refused locally with
    /// the contract's `invalid_params`, before anything is invoked.
    @Test func anAnswerThatDoesNotFitThePromptIsRefusedLocally() async throws {
        try await enable()
        let (invoker, r) = await primed([])
        let response = try await answer(r, .question(answers: ["Which?": "A"]))
        #expect(response.success == false)
        #expect(response.error == PromptAnswerValidation.kindMismatch.message)
        #expect(Self.answers(invoker).isEmpty)
        #expect(try actuationRows().isEmpty)
    }

    /// `allow_always` on a prompt that offered no suggestions.
    @Test func allowAlwaysWithoutSuggestionsIsRefusedLocally() async throws {
        try await enable()
        let (invoker, r) = await primed([])
        let response = try await answer(r, .permission(decision: .allowAlways, message: nil))
        #expect(response.error == PromptAnswerValidation.allowAlwaysWithoutSuggestions.message)
        #expect(Self.answers(invoker).isEmpty)
    }

    // MARK: - Delivery

    @Test func invokesAnswerWithThePayloadOnStdin() async throws {
        try await enable()
        let (invoker, r) = await primed([.result(providerOK("{}"))])
        let sent = PromptAnswer.permission(decision: .deny, message: "not that file")
        let response = try await answer(r, sent)
        #expect(response.success)
        #expect(try response.decodeResult(PromptAnswerResult.self).outcome == .delivered)
        #expect(Self.answers(invoker) == [["answer", "s-1", "p-1"]])
        let stdin = try #require(invoker.stdinsSnapshot().last ?? nil)
        #expect(try JSONDecoder().decode(PromptAnswer.self, from: stdin) == sent)

        let rows = try actuationRows()
        #expect(rows.count == 2)
        let request = try #require(rows.first)
        #expect(request["kind"] as? String == "send")
        #expect(request["method"] as? String == RPCMethod.remoteAnswer)
        #expect(request["message"] as? String == String(data: stdin, encoding: .utf8))
        #expect(rows.last?["result"] as? String == "dispatched")
    }

    /// The `waiting_input` refusal `remote.sendMessage` applies is not this
    /// verb's: a waiting agent is exactly what an answer is for.
    @Test func aWaitingAgentIsNotRefused() async throws {
        try await enable()
        let (invoker, r) = await primed([.result(providerOK("{}"))])
        #expect(try await answer(r).success)
        #expect(Self.answers(invoker).count == 1)
    }

    @Test func providerAlreadyResolvedMapsToAlreadyResolved() async throws {
        try await enable()
        let (invoker, r) = await primed([.result(failure(code: "already_resolved", message: "prompt is gone"))])
        let response = try await answer(r)
        #expect(response.success)
        #expect(try response.decodeResult(PromptAnswerResult.self).outcome == .alreadyResolved)
        #expect(Self.answers(invoker).count == 1)
        let last = try #require(try actuationRows().last)
        #expect(last["result"] as? String == "refused")
    }

    @Test(arguments: ["invalid_params", "not_found"])
    func providerErrorsAreRPCErrorsCarryingTheCode(code: String) async throws {
        try await enable()
        let (invoker, r) = await primed([.result(failure(code: code, message: "provider says no"))])
        let response = try await answer(r)
        #expect(response.success == false)
        #expect(response.error == "\(code): provider says no")
        #expect(Self.answers(invoker).count == 1)
        #expect(try actuationRows().count == 2)
    }

    /// The deadline fired with no exit status: the decision may have reached
    /// the dialog. Unknown — a result, not an error — and never retried.
    @Test func timeoutIsUnknownAndNotRetried() async throws {
        try await enable()
        let (invoker, r) = await primed([.timeout])
        let response = try await answer(r)
        #expect(response.success)
        #expect(try response.decodeResult(PromptAnswerResult.self).outcome == .unknown)
        #expect(Self.answers(invoker) == [["answer", "s-1", "p-1"]])
        let last = try #require(try actuationRows().last)
        #expect(last["result"] as? String == "transport-failed")
        #expect((last["error"] as? String)?.hasPrefix("outcome unknown") == true)
    }

    @Test func signalIsUnknown() async throws {
        try await enable()
        let (invoker, r) = await primed([
            .result(ProviderResult(exitCode: 9, stdout: Data(), stderr: "", terminatedBySignal: true)),
        ])
        let response = try await answer(r)
        #expect(response.success)
        #expect(try response.decodeResult(PromptAnswerResult.self).outcome == .unknown)
        #expect(Self.answers(invoker).count == 1)
        #expect((try actuationRows().last?["error"] as? String)?.hasPrefix("outcome unknown") == true)
    }

    // MARK: - Serialization with remote.sendMessage

    /// An answer and a typed message to one session never overlap: the message
    /// reaches the provider only after the answer has returned.
    ///
    /// The mirror reports `working` beside the prompt so the send's own
    /// `waiting_input` refusal does not decide the outcome; the daemon reads
    /// each field as given.
    @Test func answerAndSendMessageToOneSessionAreSerialized() async throws {
        try await enable()
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring([RemoteCapability.answer, "send", RemoteCapability.sendSubmit]),
            listing(agentState: .working),
            providerOK("{}"),
            providerOK("{}"),
        ])
        let trace = Trace()
        let gate = Gate()
        invoker.onCall = { verb in
            guard verb.first == "answer" || verb.first == "send" else { return }
            let isFirst = await trace.enter(verb.first ?? "")
            if isFirst { await gate.wait() }
            await trace.exit()
        }
        let m = await manager(invoker)
        await poll(m)
        let r = router(m)

        let answerRequest = try RPCRequest(
            method: RPCMethod.remoteAnswer,
            params: RemoteAnswerParams(provider: "agentbox", sessionID: "s-1", promptID: "p-1", answer: Self.allowAnswer))
        let sendRequest = try RPCRequest(
            method: RPCMethod.remoteSendMessage,
            params: RemoteSendMessageParams(provider: "agentbox", sessionID: "s-1", text: "next"))
        async let first = r.handle(answerRequest)
        let firstEntered = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await trace.events == ["in:answer"]
        }
        async let second = r.handle(sendRequest)
        let secondQueued = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await r.remoteSendMessageSerializer.admittedCount == 2
        }
        let eventsWhileHeld = await trace.events
        await gate.open()

        let responses = await [first, second]
        #expect(firstEntered == .satisfied)
        #expect(secondQueued == .satisfied)
        #expect(eventsWhileHeld == ["in:answer"])
        let allSucceeded = responses.allSatisfy { $0.success }
        #expect(allSucceeded)
        #expect(await trace.events == ["in:answer", "out", "in:send", "out"])
    }

    private actor Trace {
        private(set) var events: [String] = []
        private var entries = 0
        /// Returns whether this is the first entry.
        func enter(_ verb: String) -> Bool {
            events.append("in:\(verb)")
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
