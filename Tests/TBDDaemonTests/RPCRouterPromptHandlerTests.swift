import Clocks
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 1 — the prompt RPCs through `RPCRouter`: `prompt.note`,
/// `prompt.register`, `prompt.answer`, `prompt.ack`, and the socket-only
/// `prompt.await` entry points (`awaitPrompt`, `promptAwaitConnectionClosed`,
/// `promptAwaitDelivered`). Both branches of `transcript_prompt_answer_enabled`
/// for each RPC, every `prompt.answer` outcome, and the delivery ack's three
/// endings: acknowledged, refused, timed out.
/// (`docs/specs/2026-10-09-transcript-prompt-answer-design.md`.)
///
/// The store takes a `TestClock`, so the 5 s ack timeout fires only when a
/// test advances it.
@Suite(.clockDriven)
struct RPCRouterPromptHandlerTests {

    static let bashInput = #"{"command":"ls"}"#

    struct Fixture {
        let db: TBDDatabase
        let router: RPCRouter
        let store: PendingPromptStore
        let clock: TestClock<Duration>
        let terminalID: UUID
        let worktreeID: UUID
        let logPath: String
    }

    private func makeFixture(flagOn: Bool) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-prompt-rpc-\(UUID().uuidString)", isDirectory: true)
        let logPath = directory.appendingPathComponent("actuations.jsonl").path
        let db = try TBDDatabase(inMemory: true)
        let clock = TestClock<Duration>()
        let store = PendingPromptStore(clock: clock)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            pendingQuestions: store,
            recordedAppIdentity: { SendHarness.AuthenticatedApp.identity },
            processSignaller: SendHarness.AuthenticatedApp.Signaller(),
            actuationLog: ActuationLog(path: logPath))
        if flagOn {
            try await db.config.setTranscriptPromptAnswerEnabled(true)
        }
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)", displayName: "test-repo", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test-wt-\(UUID().uuidString)", tmuxServer: "tbd-test")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@mock-0", tmuxPaneID: "%mock-0")
        return Fixture(
            db: db, router: router, store: store, clock: clock,
            terminalID: terminal.id, worktreeID: worktree.id, logPath: logPath)
    }

    // MARK: Requests

    private func note(
        _ f: Fixture, session: String = "s1", phase: PromptNotePhase = .pre,
        toolUseID: String = "toolu_1", input: String = RPCRouterPromptHandlerTests.bashInput
    ) async throws -> RPCResponse {
        let params = PromptNoteParams(
            terminalID: f.terminalID, sessionID: session, phase: phase, toolUseID: toolUseID,
            toolName: "Bash", inputHash: phase == .pre ? PromptInputHash.of(toolInputJSON: input) : nil)
        return await f.router.handle(try RPCRequest(method: RPCMethod.promptNote, params: params))
    }

    private func register(
        _ f: Fixture, session: String = "s1", input: String = RPCRouterPromptHandlerTests.bashInput,
        suggestions: String? = nil
    ) async throws -> PromptRegisterResult {
        let params = PromptRegisterParams(
            terminalID: f.terminalID, sessionID: session, toolName: "Bash", toolInputJSON: input,
            suggestionsJSON: suggestions, inputHash: PromptInputHash.of(toolInputJSON: input))
        let response = await f.router.handle(try RPCRequest(method: RPCMethod.promptRegister, params: params))
        #expect(response.success, "register failed: \(response.error ?? "none")")
        return try response.decodeResult(PromptRegisterResult.self)
    }

    /// Registers a paired prompt (a note first, so no late-note timer shares
    /// the store's clock with the ack timer) and returns its id.
    private func registeredPromptID(_ f: Fixture, session: String = "s1") async throws -> String {
        _ = try await note(f, session: session)
        let result = try await register(f, session: session)
        guard case .registered(let id, _) = result else {
            Issue.record("expected a registered prompt, got \(result)")
            return ""
        }
        return id
    }

    /// Answers as the TBD app unless `connection` says otherwise.
    private func answer(
        _ f: Fixture, promptID: String,
        _ answer: PromptAnswer = .permission(decision: .allow, message: nil),
        connection: RPCConnectionContext? = SendHarness.AuthenticatedApp.connection
    ) async throws -> RPCResponse {
        let params = PromptAnswerParams(terminalID: f.terminalID, promptID: promptID, answer: answer)
        return await f.router.handle(
            try RPCRequest(method: RPCMethod.promptAnswer, params: params, actor: .app),
            connection: connection)
    }

    private func ack(_ f: Fixture, token: UUID, delivered: Bool) async throws -> RPCResponse {
        await f.router.handle(
            try RPCRequest(method: RPCMethod.promptAck, params: PromptAckParams(token: token, delivered: delivered)))
    }

    /// Starts the socket-side await for `promptID` and returns once its waiter
    /// is attached.
    private func attachAwait(
        _ f: Fixture, promptID: String, token: UUID = UUID(),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> Task<RPCResponse, Never> {
        let paramsData = try JSONEncoder().encode(PromptAwaitParams(promptID: promptID))
        let router = f.router
        let waiter = Task { await router.awaitPrompt(paramsData, token: token) }
        let store = f.store
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await store.isWaiterAttached(promptID: promptID)
        }
        if outcome == .timedOut {
            Issue.record("the waiter for \(promptID) never attached", sourceLocation: sourceLocation)
        }
        return waiter
    }

    private func reply(of response: RPCResponse) throws -> PromptAwaitReply {
        try response.decodeResult(PromptAwaitReply.self)
    }

    private func isOpen(_ f: Fixture, _ promptID: String) async -> Bool {
        await f.store.prompts(forTerminal: f.terminalID).contains { $0.id == promptID }
    }

    // MARK: prompt.note

    @Test func noteIsANoOpWhileFlagOff() async throws {
        let f = try await makeFixture(flagOn: false)
        #expect(try await note(f).success)
        // Turn the flag on afterwards: a note that had been kept would pair.
        try await f.db.config.setTranscriptPromptAnswerEnabled(true)
        guard case .registered(let id, _) = try await register(f) else {
            Issue.record("register refused with the flag on")
            return
        }
        let payload = await f.store.prompts(forTerminal: f.terminalID).first { $0.id == id }
        #expect(payload?.toolUseID == nil, "a note sent while the flag was off was kept")
    }

    @Test func noteIsKeptWhileFlagOn() async throws {
        let f = try await makeFixture(flagOn: true)
        #expect(try await note(f, toolUseID: "toolu_kept").success)
        guard case .registered(let id, _) = try await register(f) else {
            Issue.record("register refused with the flag on")
            return
        }
        let payload = await f.store.prompts(forTerminal: f.terminalID).first { $0.id == id }
        #expect(payload?.toolUseID == "toolu_kept")
    }

    @Test func postNoteResolvesTheOpenPrompt() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = try await registeredPromptID(f)
        #expect(await isOpen(f, id))
        #expect(try await note(f, phase: .post).success)
        #expect(await isOpen(f, id) == false, "the terminal answered; the prompt is over")
    }

    /// Turning the flag off must not strand a prompt registered while it was
    /// on: its hook is still parked, and the terminal's answer (a post note)
    /// is what resolves it.
    @Test func postNoteResolvesAnOpenPromptAfterTheFlagIsTurnedOff() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = try await registeredPromptID(f)
        try await f.db.config.setTranscriptPromptAnswerEnabled(false)
        #expect(await isOpen(f, id))
        #expect(try await note(f, phase: .post).success)
        #expect(await isOpen(f, id) == false, "a post note while the flag is off left the prompt open")
    }

    // MARK: prompt.register

    @Test func registerIsDisabledWhileFlagOff() async throws {
        let f = try await makeFixture(flagOn: false)
        #expect(try await register(f) == .disabled)
        #expect(await f.store.prompts(forTerminal: f.terminalID).isEmpty)
    }

    @Test func registerReturnsPromptIDWhileFlagOn() async throws {
        let f = try await makeFixture(flagOn: true)
        let deltas = PromptDeltaRecorder()
        _ = f.router.registerSubscription { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data),
               case .terminalPendingPromptsChanged(let d) = delta {
                deltas.append(d)
            }
            return true
        }
        let result = try await register(f)
        guard case .registered(let id, _) = result else {
            Issue.record("expected registered, got \(result)")
            return
        }
        #expect(await isOpen(f, id))
        let published = deltas.all
        #expect(published.count == 1)
        #expect(published.first?.terminalID == f.terminalID)
        #expect(published.first?.prompts.map(\.id) == [id])
    }

    // MARK: prompt.answer

    @Test func answerIsRefusedWhileFlagOff() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = try await registeredPromptID(f)
        try await f.db.config.setTranscriptPromptAnswerEnabled(false)
        let response = try await answer(f, promptID: id)
        #expect(response.success == false)
        #expect(response.error == RPCRouter.promptAnswerDisabledRefusal)
        #expect(await isOpen(f, id), "a refused answer leaves the prompt open")
    }

    @Test func answerDeliversThroughAwaitAndAck() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = try await registeredPromptID(f)
        let token = UUID()
        let waiter = try await attachAwait(f, promptID: id, token: token)

        let answering = Task { try await answer(f, promptID: id) }
        let awaited = try reply(of: await waiter.value)
        guard case .answered(let hookOutput) = awaited.result else {
            Issue.record("expected an answered reply, got \(awaited.result)")
            return
        }
        #expect(hookOutput.contains(#""behavior":"allow""#))
        #expect(awaited.deliveryToken == token, "the reply names the token prompt.ack must carry")

        #expect(try await ack(f, token: token, delivered: true).success)
        let response = try await answering.value
        #expect(response.success, "error: \(response.error ?? "none")")
        #expect(try response.decodeResult(PromptAnswerResult.self).outcome == .delivered)
        #expect(await isOpen(f, id) == false)

        let rows = ActuationRecordReader(activePath: f.logPath).readRows()
        let request = try #require(rows.first { $0.method == RPCMethod.promptAnswer })
        #expect(request.kind == .send)
        #expect(request.target?.terminal == f.terminalID.uuidString)
        #expect(request.target?.worktree == f.worktreeID.uuidString)
        let outcome = try #require(rows.first { $0.confirms == request.id })
        #expect(outcome.result == .synchronous(.dispatched))
    }

    @Test func refusedAckAnswersAlreadyResolved() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = try await registeredPromptID(f)
        let token = UUID()
        let waiter = try await attachAwait(f, promptID: id, token: token)

        let answering = Task { try await answer(f, promptID: id) }
        _ = await waiter.value
        #expect(try await ack(f, token: token, delivered: false).success)
        let response = try await answering.value
        #expect(try response.decodeResult(PromptAnswerResult.self).outcome == .alreadyResolved)
        #expect(await isOpen(f, id) == false)
    }

    @Test func failedReplyWriteAnswersAlreadyResolved() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = try await registeredPromptID(f)
        let token = UUID()
        let waiter = try await attachAwait(f, promptID: id, token: token)

        let answering = Task { try await answer(f, promptID: id) }
        _ = await waiter.value
        // What the socket reports when it cannot write the reply.
        await f.router.promptAwaitDelivered(token: token, delivered: false)
        let response = try await answering.value
        #expect(try response.decodeResult(PromptAnswerResult.self).outcome == .alreadyResolved)
    }

    @Test func missingAckTimesOutAsAlreadyResolved() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = try await registeredPromptID(f)
        #expect(await f.store.isLateNoteWindowOpen(promptID: id) == false)
        let waiter = try await attachAwait(f, promptID: id)

        let answering = Task { try await answer(f, promptID: id) }
        _ = await waiter.value
        await f.clock.advanceWhenSuspended(by: .seconds(5))
        let response = try await answering.value
        #expect(try response.decodeResult(PromptAnswerResult.self).outcome == .alreadyResolved,
                "no ack within 5 s means the hook never had the decision")
        #expect(await isOpen(f, id) == false)
    }

    @Test func answerWithNoAttachedWaiterIsRetryableError() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = try await registeredPromptID(f)
        let response = try await answer(f, promptID: id)
        #expect(response.success == false)
        #expect(response.error == RPCRouter.promptHookDetachedRefusal)
        #expect(await isOpen(f, id), "a reconnecting hook keeps its prompt")
    }

    @Test func secondAnswerIsAlreadyResolvedResult() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = try await registeredPromptID(f)
        let token = UUID()
        let waiter = try await attachAwait(f, promptID: id, token: token)
        let first = Task { try await answer(f, promptID: id) }
        _ = await waiter.value
        _ = try await ack(f, token: token, delivered: true)
        #expect(try await first.value.decodeResult(PromptAnswerResult.self).outcome == .delivered)

        let second = try await answer(f, promptID: id, .permission(decision: .deny, message: nil))
        #expect(second.success)
        #expect(try second.decodeResult(PromptAnswerResult.self).outcome == .alreadyResolved)
    }

    @Test func invalidAnswerIsInvalidParamsError() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = try await registeredPromptID(f)
        // No suggestions were offered, so "don't ask again" does not fit.
        let response = try await answer(f, promptID: id, .permission(decision: .allowAlways, message: nil))
        #expect(response.success == false)
        #expect(response.error == PromptAnswerValidation.allowAlwaysWithoutSuggestions.message)
        #expect(response.error?.hasPrefix("invalid_params:") == true)
        #expect(await isOpen(f, id), "an invalid answer leaves the prompt open")
    }

    @Test func answerForAMissingTerminalRowIsAlreadyResolved() async throws {
        let f = try await makeFixture(flagOn: true)
        let params = PromptAnswerParams(
            terminalID: UUID(), promptID: "nope", answer: .permission(decision: .allow, message: nil))
        let response = await f.router.handle(
            try RPCRequest(method: RPCMethod.promptAnswer, params: params),
            connection: SendHarness.AuthenticatedApp.connection)
        #expect(try response.decodeResult(PromptAnswerResult.self).outcome == .alreadyResolved)
    }

    // MARK: prompt.answer — only the TBD app may answer

    /// Another process on the socket — an agent in some other session — is
    /// refused, even declaring itself the app, and the prompt stays open.
    @Test func answerFromAnotherSocketPeerIsRefused() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = try await registeredPromptID(f)
        let response = try await answer(f, promptID: id, connection: RPCConnectionContext(peerPID: 4321))
        #expect(response.success == false)
        #expect(response.error == RPCRouter.promptAnswerNotFromAppRefusal)
        #expect(await isOpen(f, id))
    }

    /// No connection context — every non-socket caller — and the HTTP
    /// transport's entry point, `handleRaw` without a connection, are refused.
    @Test func answerWithoutAConnectionIsRefused() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = try await registeredPromptID(f)
        let response = try await answer(f, promptID: id, connection: nil)
        #expect(response.error == RPCRouter.promptAnswerNotFromAppRefusal)

        let request = try RPCRequest(
            method: RPCMethod.promptAnswer,
            params: PromptAnswerParams(
                terminalID: f.terminalID, promptID: id, answer: .permission(decision: .allow, message: nil)),
            actor: .app)
        let raw = await f.router.handleRaw(try JSONEncoder().encode(request))
        #expect(raw.error == RPCRouter.promptAnswerNotFromAppRefusal)
        #expect(await isOpen(f, id))
    }

    // MARK: prompt.await

    @Test func awaitThroughHandleIsRefused() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = try await registeredPromptID(f)
        let request = try RPCRequest(method: RPCMethod.promptAwait, params: PromptAwaitParams(promptID: id))
        let response = await f.router.handle(request)
        #expect(response.success == false)
        #expect(response.error == RPCRouter.promptAwaitSocketOnlyRefusal)
        // `handleRaw` is the HTTP server's entry point; it must refuse too.
        let raw = await f.router.handleRaw(try JSONEncoder().encode(request))
        #expect(raw.error == RPCRouter.promptAwaitSocketOnlyRefusal)
        #expect(await f.store.isWaiterAttached(promptID: id) == false)
    }

    @Test func awaitOnAnUnknownPromptReturnsResolvedElsewhere() async throws {
        let f = try await makeFixture(flagOn: true)
        let response = await f.router.awaitPrompt(
            try JSONEncoder().encode(PromptAwaitParams(promptID: "unknown")), token: UUID())
        let awaited = try reply(of: response)
        #expect(awaited.result == .resolvedElsewhere)
        #expect(awaited.deliveryToken == nil)
    }

    @Test func connectionCloseResolvesThePrompt() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = try await registeredPromptID(f)
        let token = UUID()
        let waiter = try await attachAwait(f, promptID: id, token: token)

        await f.router.promptAwaitConnectionClosed(token: token)
        #expect(try reply(of: await waiter.value).result == .resolvedElsewhere)
        #expect(await isOpen(f, id) == false)
    }

    @Test func connectionClosedBeforeAttachStillResolves() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = try await registeredPromptID(f)
        // The close already happened, so `waiterClosed` had nothing to find;
        // the attach itself must see the mark.
        let response = await f.router.awaitPrompt(
            try JSONEncoder().encode(PromptAwaitParams(promptID: id)), token: UUID(),
            connectionClosed: { true })
        #expect(try reply(of: response).result == .resolvedElsewhere)
        #expect(await isOpen(f, id) == false)
    }

    @Test func connectionCloseAfterDeliveryIsHarmless() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = try await registeredPromptID(f)
        let token = UUID()
        let waiter = try await attachAwait(f, promptID: id, token: token)
        let answering = Task { try await answer(f, promptID: id) }
        _ = await waiter.value
        // The hook printed, then its await connection closed before the ack.
        await f.router.promptAwaitConnectionClosed(token: token)
        _ = try await ack(f, token: token, delivered: true)
        #expect(try await answering.value.decodeResult(PromptAnswerResult.self).outcome == .delivered)
    }

    // MARK: prompt.ack

    @Test func ackForAnUnknownTokenIsOK() async throws {
        let f = try await makeFixture(flagOn: false)
        #expect(try await ack(f, token: UUID(), delivered: true).success)
    }
}

/// Collects the pending-prompt deltas a router broadcast.
private final class PromptDeltaRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TerminalPendingPromptsDelta] = []
    func append(_ delta: TerminalPendingPromptsDelta) {
        lock.lock(); defer { lock.unlock() }
        storage.append(delta)
    }
    var all: [TerminalPendingPromptsDelta] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
