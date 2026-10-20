import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 1 — `prompt.answer` through `RPCRouter`, with the session mod's side
/// (open, wait, receipt, close) driven on the store directly: both branches
/// of `transcript_prompt_answer_enabled`, every outcome, the refusals, and
/// the receipt's three endings — receipted, closed instead, timed out.
/// (`docs/specs/2026-10-20-mod-channel-prompt-answer-design.md`.)
///
/// The store takes an `EventDrivenTestClock`, so the 5 s receipt timeout and
/// the 60 s pickup window fire only when a test advances it.
@Suite(.clockDriven)
struct RPCRouterPromptHandlerTests {

    static let bashInput = #"{"command":"ls"}"#

    struct Fixture {
        let db: TBDDatabase
        let router: RPCRouter
        let store: PendingPromptStore
        let clock: EventDrivenTestClock
        let terminalID: UUID
        let worktreeID: UUID
        let logPath: String
    }

    private func makeFixture(flagOn: Bool) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-prompt-rpc-\(UUID().uuidString)", isDirectory: true)
        let logPath = directory.appendingPathComponent("actuations.jsonl").path
        let db = try TBDDatabase(inMemory: true)
        let clock = EventDrivenTestClock()
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

    /// Opens a prompt the way the mod does and returns its id.
    private func openedPromptID(_ f: Fixture, toolUseID: String = "toolu_1") async -> String {
        await f.store.open(
            terminalID: f.terminalID, sessionID: "s1", toolUseID: toolUseID, toolName: "Bash",
            toolInputJSON: Self.bashInput, suggestionsJSON: nil)
        return toolUseID
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

    /// Starts the mod's wait request for `promptID` and returns once it is
    /// attached.
    private func attachWait(
        _ f: Fixture, promptID: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Task<PendingPromptStore.WaitResult, Never> {
        let store = f.store
        let terminalID = f.terminalID
        let waiter = Task {
            await store.waitForAnswer(terminalID: terminalID, toolUseID: promptID, token: UUID(), hold: .seconds(25))
        }
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await store.isWaiterAttached(terminalID: terminalID, toolUseID: promptID)
        }
        if outcome == .timedOut {
            Issue.record("the wait for \(promptID) never attached", sourceLocation: sourceLocation)
        }
        return waiter
    }

    private func isOpen(_ f: Fixture, _ promptID: String) async -> Bool {
        await f.store.prompts(forTerminal: f.terminalID).contains { $0.id == promptID }
    }

    // MARK: prompt.answer

    @Test func answerIsRefusedWhileFlagOff() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = await openedPromptID(f)
        try await f.db.config.setTranscriptPromptAnswerEnabled(false)
        let response = try await answer(f, promptID: id)
        #expect(response.success == false)
        #expect(response.error == RPCRouter.promptAnswerDisabledRefusal)
        #expect(await isOpen(f, id), "a refused answer leaves the prompt open")
    }

    @Test func answerDeliversThroughWaitAndReceipt() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = await openedPromptID(f)
        let deltas = PromptDeltaRecorder()
        _ = f.router.registerSubscription { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data),
               case .terminalPendingPromptsChanged(let d) = delta {
                deltas.append(d)
            }
            return true
        }
        let waiter = await attachWait(f, promptID: id)

        let answering = Task { try await answer(f, promptID: id) }
        guard case .decision(let decisionJSON) = await waiter.value else {
            Issue.record("the wait request never got the decision")
            return
        }
        #expect(decisionJSON.contains(#""behavior":"allow""#))

        await f.store.receipt(terminalID: f.terminalID, toolUseID: id)
        let response = try await answering.value
        #expect(response.success, "error: \(response.error ?? "none")")
        #expect(try response.decodeResult(PromptAnswerResult.self).outcome == .delivered)
        #expect(await isOpen(f, id) == false)
        #expect(deltas.all.last?.prompts.isEmpty == true, "the resolved prompt is retracted from the app")

        let rows = ActuationRecordReader(activePath: f.logPath).readRows()
        let request = try #require(rows.first { $0.method == RPCMethod.promptAnswer })
        #expect(request.kind == .send)
        #expect(request.target?.terminal == f.terminalID.uuidString)
        #expect(request.target?.worktree == f.worktreeID.uuidString)
        let outcome = try #require(rows.first { $0.confirms == request.id })
        #expect(outcome.result == .synchronous(.dispatched))
    }

    @Test func closedInsteadOfReceiptAnswersAlreadyResolved() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = await openedPromptID(f)
        let waiter = await attachWait(f, promptID: id)

        let answering = Task { try await answer(f, promptID: id) }
        _ = await waiter.value
        await f.store.closed(terminalID: f.terminalID, toolUseID: id)
        let response = try await answering.value
        #expect(try response.decodeResult(PromptAnswerResult.self).outcome == .alreadyResolved)
        #expect(await isOpen(f, id) == false)
    }

    @Test func missingReceiptTimesOutAsUnknown() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = await openedPromptID(f)
        let waiter = await attachWait(f, promptID: id)

        let answering = Task { try await answer(f, promptID: id) }
        _ = await waiter.value
        try await f.clock.requireAdvanceWhenArmed(by: .seconds(5))
        let response = try await answering.value
        #expect(try response.decodeResult(PromptAnswerResult.self).outcome == .unknown,
                "no receipt within 5 s may still mean Claude had the decision")
        #expect(await isOpen(f, id) == false)

        let retry = try await answer(f, promptID: id)
        #expect(try retry.decodeResult(PromptAnswerResult.self).outcome == .alreadyResolved)
    }

    /// No wait request picked the decision up within 60 s: a retryable error,
    /// and the prompt stays open.
    @Test func answerNobodyPicksUpIsRetryableError() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = await openedPromptID(f)
        let answering = Task { try await answer(f, promptID: id) }
        try await f.clock.requireAdvanceWhenArmed(by: .seconds(60))
        let response = try await answering.value
        #expect(response.success == false)
        #expect(response.error == RPCRouter.promptHookDetachedRefusal)
        #expect(await isOpen(f, id), "an answer nobody picked up keeps its prompt")
    }

    @Test func secondAnswerIsAlreadyResolvedResult() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = await openedPromptID(f)
        let waiter = await attachWait(f, promptID: id)
        let first = Task { try await answer(f, promptID: id) }
        _ = await waiter.value
        await f.store.receipt(terminalID: f.terminalID, toolUseID: id)
        #expect(try await first.value.decodeResult(PromptAnswerResult.self).outcome == .delivered)

        let second = try await answer(f, promptID: id, .permission(decision: .deny, message: nil))
        #expect(second.success)
        #expect(try second.decodeResult(PromptAnswerResult.self).outcome == .alreadyResolved)
    }

    @Test func invalidAnswerIsInvalidParamsError() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = await openedPromptID(f)
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
        let id = await openedPromptID(f)
        let response = try await answer(f, promptID: id, connection: RPCConnectionContext(peerPID: 4321))
        #expect(response.success == false)
        #expect(response.error == RPCRouter.promptAnswerNotFromAppRefusal)
        #expect(await isOpen(f, id))
    }

    /// No connection context — every non-socket caller — and the HTTP
    /// transport's entry point, `handleRaw` without a connection, are refused.
    @Test func answerWithoutAConnectionIsRefused() async throws {
        let f = try await makeFixture(flagOn: true)
        let id = await openedPromptID(f)
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

    // MARK: The removed hook path

    /// The hook-era methods are gone: nothing on the socket bypasses the
    /// concurrency limiter but `state.subscribe`.
    @Test func onlyStateSubscribeBypassesTheLimiter() {
        #expect(SocketServer.bypassesConcurrencyLimiter(method: RPCMethod.stateSubscribe))
        for method in [RPCMethod.promptAnswer, "prompt.await", "prompt.ack", "prompt.note",
                       "prompt.register", "worktree.list"] {
            #expect(!SocketServer.bypassesConcurrencyLimiter(method: method), "\(method)")
        }
        #expect(!SocketServer.bypassesConcurrencyLimiter(method: nil))
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
