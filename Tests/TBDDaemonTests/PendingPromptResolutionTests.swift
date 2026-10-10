import Clocks
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Tier 1 — `PendingPromptStore`'s open prompts: pairing a `PermissionRequest`
/// register with its `PreToolUse` note, and every way a prompt resolves
/// (`docs/specs/2026-10-09-transcript-prompt-answer-design.md`, "Daemon:
/// `PendingPromptStore`"). Each store takes a `TestClock` so neither the 5 s
/// late-note window nor the 5 s delivery-ack timeout can fire on wall time;
/// the tests that cross them advance the clock explicitly.
@Suite(.clockDriven)
struct PendingPromptResolutionTests {

    static let bashInput = #"{"command":"ls"}"#
    static let otherBashInput = #"{"command":"rm -rf build"}"#
    static let questionInput = #"""
    {"questions":[{"question":"Pick one","header":"Choice","multiSelect":false,"options":[{"label":"A"},{"label":"B"}]}]}
    """#

    // MARK: Helpers

    private func makeStore(
        clock: TestClock<Duration> = TestClock(),
        dates: TestDateSource = TestDateSource()
    ) -> PendingPromptStore {
        PendingPromptStore(now: dates.provider, clock: clock)
    }

    private func params(
        terminal: UUID, session: String, tool: String = "Bash", input: String = PendingPromptResolutionTests.bashInput,
        suggestions: String? = nil, knownPromptID: String? = nil, knownToolUseID: String? = nil
    ) -> PromptRegisterParams {
        PromptRegisterParams(
            terminalID: terminal, sessionID: session, toolName: tool, toolInputJSON: input,
            suggestionsJSON: suggestions, inputHash: PromptInputHash.of(toolName: tool, toolInputJSON: input),
            knownPromptID: knownPromptID, knownToolUseID: knownToolUseID)
    }

    private func preNote(
        _ store: PendingPromptStore, terminal: UUID, session: String, toolUseID: String,
        tool: String = "Bash", input: String = PendingPromptResolutionTests.bashInput
    ) async -> Set<UUID> {
        await store.note(
            terminalID: terminal, sessionID: session, phase: .pre, toolUseID: toolUseID,
            toolName: tool, inputHash: PromptInputHash.of(toolName: tool, toolInputJSON: input))
    }

    private func register(
        _ store: PendingPromptStore, _ params: PromptRegisterParams
    ) async -> (id: String, changed: Set<UUID>) {
        let result = await store.register(params)
        switch result.outcome {
        case .registered(let id, _): return (id, result.changed)
        }
    }

    private func payload(_ store: PendingPromptStore, terminal: UUID, id: String) async -> PendingPromptPayload? {
        await store.prompts(forTerminal: terminal).first { $0.id == id }
    }

    /// Starts a hook's `prompt.await` and returns once it is attached.
    private func attachWaiter(
        _ store: PendingPromptStore, id: String, token: UUID = UUID(),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Task<PromptAwaitResult, Never> {
        let waiter = Task { await store.awaitResolution(promptID: id, token: token) }
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await store.isWaiterAttached(promptID: id)
        }
        if outcome == .timedOut {
            Issue.record("the waiter for \(id) never attached", sourceLocation: sourceLocation)
        }
        return waiter
    }

    // MARK: Pairing

    /// No note carries this input, but the session has exactly one note for
    /// the tool, so the register pairs with it — never with a newer note of
    /// another tool.
    @Test func registerFallsBackToTheOnlyNoteForTheTool() async {
        let store = makeStore()
        let terminal = UUID()
        _ = await preNote(store, terminal: terminal, session: "s1", toolUseID: "toolu_bash",
                          input: Self.otherBashInput)
        _ = await preNote(store, terminal: terminal, session: "s1", toolUseID: "toolu_read",
                          tool: "Read", input: #"{"file_path":"/tmp/x"}"#)

        let (id, changed) = await register(store, params(
            terminal: terminal, session: "s1", input: #"{"command":"whoami"}"#))

        #expect(changed == [terminal])
        let prompt = await payload(store, terminal: terminal, id: id)
        #expect(prompt?.toolUseID == "toolu_bash")
        #expect(prompt?.kind == .permission)
    }

    /// No note carries this input and two notes share the tool: recency
    /// cannot say which call the dialog shows, so the prompt stays unpaired
    /// and both notes stay for registers that do match.
    @Test func registerWithTwoSameToolNotesAndNoHashMatchStaysUnpaired() async {
        let store = makeStore()
        let terminal = UUID()
        _ = await preNote(store, terminal: terminal, session: "s1", toolUseID: "toolu_old",
                          input: Self.otherBashInput)
        _ = await preNote(store, terminal: terminal, session: "s1", toolUseID: "toolu_new",
                          input: #"{"command":"pwd"}"#)

        let (id, _) = await register(store, params(
            terminal: terminal, session: "s1", input: #"{"command":"whoami"}"#))
        #expect(await payload(store, terminal: terminal, id: id)?.toolUseID == nil)

        let matched = await register(store, params(terminal: terminal, session: "s1", input: Self.otherBashInput))
        #expect(await payload(store, terminal: terminal, id: matched.id)?.toolUseID == "toolu_old")
    }

    @Test func pairsOnInputHashBeforeRecency() async {
        let store = makeStore()
        let terminal = UUID()
        // Two Bash calls in one assistant message: both notes land before the
        // first dialog opens.
        _ = await preNote(store, terminal: terminal, session: "s1", toolUseID: "toolu_first",
                          input: Self.bashInput)
        _ = await preNote(store, terminal: terminal, session: "s1", toolUseID: "toolu_second",
                          input: Self.otherBashInput)

        let first = await register(store, params(terminal: terminal, session: "s1", input: Self.bashInput))
        #expect(await payload(store, terminal: terminal, id: first.id)?.toolUseID == "toolu_first",
                "the dialog showing the first call's input binds to the first call, not the newest note")

        let second = await register(store, params(terminal: terminal, session: "s1", input: Self.otherBashInput))
        #expect(await payload(store, terminal: terminal, id: second.id)?.toolUseID == "toolu_second")
    }

    @Test func notesNeverCrossSessions() async {
        let store = makeStore()
        let terminalA = UUID()
        let terminalB = UUID()
        let terminalC = UUID()
        _ = await preNote(store, terminal: terminalA, session: "sA", toolUseID: "toolu_A")
        _ = await preNote(store, terminal: terminalB, session: "sB", toolUseID: "toolu_B")

        async let registeredA = register(store, params(terminal: terminalA, session: "sA"))
        async let registeredB = register(store, params(terminal: terminalB, session: "sB"))
        async let registeredC = register(store, params(terminal: terminalC, session: "sC"))
        let (a, b, c) = await (registeredA, registeredB, registeredC)

        #expect(await payload(store, terminal: terminalA, id: a.id)?.toolUseID == "toolu_A")
        #expect(await payload(store, terminal: terminalB, id: b.id)?.toolUseID == "toolu_B")
        let unpaired = await payload(store, terminal: terminalC, id: c.id)
        #expect(unpaired != nil)
        #expect(unpaired?.toolUseID == nil, "a session with no note of its own must not borrow another's")
    }

    @Test func unpairedPromptGetsFreshIDAndNilToolUseID() async {
        let store = makeStore()
        let terminal = UUID()
        let (id, _) = await register(store, params(
            terminal: terminal, session: "s1", tool: "AskUserQuestion", input: Self.questionInput))

        #expect(UUID(uuidString: id) != nil, "an unpaired prompt gets a fresh UUID id: \(id)")
        let prompt = await payload(store, terminal: terminal, id: id)
        #expect(prompt?.toolUseID == nil)
        #expect(prompt?.kind == .question)
    }

    @Test func lateNoteAttachesToUnpairedPrompt() async {
        let store = makeStore()
        let terminal = UUID()
        let (id, _) = await register(store, params(terminal: terminal, session: "s1"))
        let before = await store.snapshot(forTerminal: terminal).revision
        #expect(await store.isLateNoteWindowOpen(promptID: id))

        let changed = await preNote(store, terminal: terminal, session: "s1", toolUseID: "toolu_late")

        #expect(changed == [terminal], "an attached late note changes the set and must be broadcast")
        #expect(await payload(store, terminal: terminal, id: id)?.toolUseID == "toolu_late")
        #expect(await store.snapshot(forTerminal: terminal).revision > before)
        #expect(await store.isLateNoteWindowOpen(promptID: id) == false)
    }

    @Test func lateNoteAfterFiveSecondsDoesNotAttach() async {
        let clock = TestClock<Duration>()
        let store = makeStore(clock: clock)
        let terminal = UUID()
        let (id, _) = await register(store, params(terminal: terminal, session: "s1"))
        #expect(await store.isLateNoteWindowOpen(promptID: id))

        await clock.advanceWhenSuspended(by: .seconds(5))
        let closed = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await store.isLateNoteWindowOpen(promptID: id) == false
        }
        if closed == .timedOut { Issue.record("the late-note window never closed after 5 s") }

        let changed = await preNote(store, terminal: terminal, session: "s1", toolUseID: "toolu_late")
        #expect(changed.isEmpty)
        #expect(await payload(store, terminal: terminal, id: id)?.toolUseID == nil)
    }

    @Test func reRegisterAfterRestartKeepsIDWithoutToolUseID() async {
        // A fresh store stands in for a restarted daemon: no notes survive.
        let store = makeStore()
        let terminal = UUID()
        let (id, _) = await register(store, params(
            terminal: terminal, session: "s1", knownPromptID: "prompt-before-restart"))

        #expect(id == "prompt-before-restart")
        #expect(await payload(store, terminal: terminal, id: id)?.toolUseID == nil)
        #expect(await store.isLateNoteWindowOpen(promptID: id) == false)
    }

    @Test func registerReplyCarriesThePairing() async {
        let store = makeStore()
        let terminal = UUID()
        _ = await preNote(store, terminal: terminal, session: "s1", toolUseID: "toolu_1")
        let result = await store.register(params(terminal: terminal, session: "s1"))
        let id: String
        let toolUseID: String?
        switch result.outcome {
        case .registered(let promptID, let pairedToolUseID):
            id = promptID
            toolUseID = pairedToolUseID
        }
        #expect(toolUseID == "toolu_1", "the hook needs the pairing to hand back after a restart")

        // A fresh store stands in for the restarted daemon: the hook's
        // re-register hands the pairing back and the prompt keeps it.
        let restarted = makeStore()
        let again = await restarted.register(params(
            terminal: terminal, session: "s1", knownPromptID: id, knownToolUseID: toolUseID))
        #expect(again.outcome == .registered(promptID: id, toolUseID: "toolu_1"))
        #expect(await payload(restarted, terminal: terminal, id: id)?.toolUseID == "toolu_1")
    }

    @Test func postNoteClosesAnUnpairedPromptByInputHash() async {
        let store = makeStore()
        let terminal = UUID()
        let (id, _) = await register(store, params(
            terminal: terminal, session: "s1", knownPromptID: "prompt-before-restart"))
        #expect(await payload(store, terminal: terminal, id: id)?.toolUseID == nil)
        let waiter = await attachWaiter(store, id: id)

        let changed = await store.note(
            terminalID: terminal, sessionID: "s1", phase: .post, toolUseID: "toolu_unknown",
            toolName: "Bash", inputHash: PromptInputHash.of(toolInputJSON: Self.bashInput))

        #expect(changed == [terminal])
        #expect(await waiter.value == .resolvedElsewhere)
        #expect(await store.prompts(forTerminal: terminal).isEmpty)
    }

    /// A question's `PostToolUse` input carries the merged `answers` beside
    /// `questions`; the hash covers `questions` alone, so the post still
    /// closes the unpaired question the terminal answered.
    @Test func postNoteWithAnswersClosesAnUnpairedQuestion() async {
        let store = makeStore()
        let terminal = UUID()
        let (id, _) = await register(store, params(
            terminal: terminal, session: "s1", tool: "AskUserQuestion", input: Self.questionInput,
            knownPromptID: "question-before-restart"))
        #expect(await payload(store, terminal: terminal, id: id)?.toolUseID == nil)
        let waiter = await attachWaiter(store, id: id)

        let answeredInput = #"""
        {"answers":{"Pick one":"A"},"questions":[{"question":"Pick one","header":"Choice","multiSelect":false,"options":[{"label":"A"},{"label":"B"}]}]}
        """#
        let changed = await store.note(
            terminalID: terminal, sessionID: "s1", phase: .post, toolUseID: "toolu_unknown",
            toolName: "AskUserQuestion",
            inputHash: PromptInputHash.of(toolName: "AskUserQuestion", toolInputJSON: answeredInput))

        #expect(changed == [terminal])
        #expect(await waiter.value == .resolvedElsewhere)
        #expect(await store.prompts(forTerminal: terminal).isEmpty)
    }

    @Test func postNoteForAnotherInputLeavesAnUnpairedPromptOpen() async {
        let store = makeStore()
        let terminal = UUID()
        let (id, _) = await register(store, params(
            terminal: terminal, session: "s1", knownPromptID: "prompt-before-restart"))

        let changed = await store.note(
            terminalID: terminal, sessionID: "s1", phase: .post, toolUseID: "toolu_other",
            toolName: "Bash", inputHash: PromptInputHash.of(toolInputJSON: Self.otherBashInput))

        #expect(changed.isEmpty)
        #expect(await store.prompts(forTerminal: terminal).map(\.id) == [id])
    }

    // MARK: Answering

    @Test func answerDeliversDecisionToWaiter() async throws {
        let store = makeStore()
        let terminal = UUID()
        _ = await preNote(store, terminal: terminal, session: "s1", toolUseID: "toolu_1")
        let (id, _) = await register(store, params(terminal: terminal, session: "s1"))
        let token = UUID()
        let waiter = await attachWaiter(store, id: id, token: token)

        let answer = PromptAnswer.permission(decision: .deny, message: "not now")
        let answering = Task { await store.answer(terminalID: terminal, promptID: id, answer: answer) }
        let awaited = await waiter.value
        let expected = try PromptDecisionEncoder.hookOutput(
            answer: answer, kind: .permission, toolInputJSON: Self.bashInput, suggestionsJSON: nil)
        #expect(awaited == .answered(hookOutput: expected))

        await store.acknowledgeDelivery(token: token, delivered: true)
        let result = await answering.value

        #expect(result.outcome == .delivered)
        #expect(result.changed == [terminal])
        #expect(await store.prompts(forTerminal: terminal).isEmpty)
    }

    @Test func failedDeliveryAnswersAlreadyResolved() async {
        let store = makeStore()
        let terminal = UUID()
        let (id, _) = await register(store, params(terminal: terminal, session: "s1"))
        let token = UUID()
        let waiter = await attachWaiter(store, id: id, token: token)

        let answering = Task {
            await store.answer(terminalID: terminal, promptID: id,
                               answer: .permission(decision: .allow, message: nil))
        }
        _ = await waiter.value
        await store.acknowledgeDelivery(token: token, delivered: false)

        #expect(await answering.value.outcome == .alreadyResolved,
                "a hook that never got the payload leaves the terminal in charge")
        #expect(await store.prompts(forTerminal: terminal).isEmpty)
    }

    @Test func secondAnswerIsAlreadyResolved() async {
        let store = makeStore()
        let terminal = UUID()
        let (id, _) = await register(store, params(terminal: terminal, session: "s1"))
        let token = UUID()
        let waiter = await attachWaiter(store, id: id, token: token)
        let allow = PromptAnswer.permission(decision: .allow, message: nil)

        let first = Task { await store.answer(terminalID: terminal, promptID: id, answer: allow) }
        _ = await waiter.value

        // While the first answer waits for its ack…
        let racing = await store.answer(terminalID: terminal, promptID: id, answer: allow)
        #expect(racing.outcome == .alreadyResolved)
        #expect(racing.changed.isEmpty)

        await store.acknowledgeDelivery(token: token, delivered: true)
        #expect(await first.value.outcome == .delivered)

        // …and after it was delivered.
        let late = await store.answer(terminalID: terminal, promptID: id, answer: allow)
        #expect(late.outcome == .alreadyResolved)
    }

    @Test func answerForAnotherTerminalIsAlreadyResolved() async {
        let store = makeStore()
        let terminal = UUID()
        let (id, _) = await register(store, params(terminal: terminal, session: "s1"))
        let waiter = await attachWaiter(store, id: id)

        let result = await store.answer(terminalID: UUID(), promptID: id,
                                        answer: .permission(decision: .allow, message: nil))

        #expect(result.outcome == .alreadyResolved)
        #expect(await store.isWaiterAttached(promptID: id), "a misaddressed answer must not touch the prompt")
        await store.resolveAll()
        #expect(await waiter.value == .resolvedElsewhere)
    }

    @Test func answerWithNoAttachedWaiterIsHookDetached() async {
        let store = makeStore()
        let terminal = UUID()
        let (id, _) = await register(store, params(terminal: terminal, session: "s1"))
        let allow = PromptAnswer.permission(decision: .allow, message: nil)

        let detached = await store.answer(terminalID: terminal, promptID: id, answer: allow)
        #expect(detached.outcome == .hookDetached)
        #expect(await store.prompts(forTerminal: terminal).map(\.id) == [id],
                "a detached answer is retryable, so the prompt stays open")

        // The retry, once the hook has reattached, goes through.
        let token = UUID()
        let waiter = await attachWaiter(store, id: id, token: token)
        let retry = Task { await store.answer(terminalID: terminal, promptID: id, answer: allow) }
        guard case .answered = await waiter.value else {
            Issue.record("the retried answer never reached the reattached waiter")
            return
        }
        await store.acknowledgeDelivery(token: token, delivered: true)
        #expect(await retry.value.outcome == .delivered)
    }

    @Test func invalidAnswerLeavesPromptOpen() async {
        let store = makeStore()
        let terminal = UUID()
        let (id, _) = await register(store, params(
            terminal: terminal, session: "s1", tool: "AskUserQuestion", input: Self.questionInput))
        let waiter = await attachWaiter(store, id: id)

        let wrongKind = await store.answer(terminalID: terminal, promptID: id,
                                           answer: .permission(decision: .allow, message: nil))
        #expect(wrongKind.outcome == .invalid(.kindMismatch))
        let missing = await store.answer(terminalID: terminal, promptID: id,
                                         answer: .question(answers: [:]))
        #expect(missing.outcome == .invalid(.missingAnswer(question: "Pick one")))

        #expect(await store.prompts(forTerminal: terminal).map(\.id) == [id])
        #expect(await store.isWaiterAttached(promptID: id), "an invalid answer must not consume the waiter")
        await store.resolveAll()
        #expect(await waiter.value == .resolvedElsewhere)
    }

    @Test func ackTimeoutAnswersDeliveryUnconfirmed() async {
        let clock = TestClock<Duration>()
        let store = makeStore(clock: clock)
        let terminal = UUID()
        // Paired, so no late-note timer shares the clock with the ack timer.
        _ = await preNote(store, terminal: terminal, session: "s1", toolUseID: "toolu_1")
        let (id, _) = await register(store, params(terminal: terminal, session: "s1"))
        #expect(await store.isLateNoteWindowOpen(promptID: id) == false)
        let waiter = await attachWaiter(store, id: id)

        let answering = Task {
            await store.answer(terminalID: terminal, promptID: id,
                               answer: .permission(decision: .allow, message: nil))
        }
        _ = await waiter.value
        await clock.advanceWhenSuspended(by: .seconds(5))
        let result = await answering.value

        #expect(result.outcome == .deliveryUnconfirmed, "no ack within 5 s may still mean the hook had it")
        #expect(result.changed == [terminal])
        #expect(await store.prompts(forTerminal: terminal).isEmpty)

        let retry = await store.answer(terminalID: terminal, promptID: id,
                                       answer: .permission(decision: .allow, message: nil))
        #expect(retry.outcome == .alreadyResolved, "the timed-out prompt is resolved, so a retry cannot answer twice")
    }

    // MARK: Other resolutions

    @Test func postNoteResolvesWithToolFinished() async {
        let store = makeStore()
        let terminal = UUID()
        _ = await preNote(store, terminal: terminal, session: "s1", toolUseID: "toolu_1")
        let (id, _) = await register(store, params(terminal: terminal, session: "s1"))
        let waiter = await attachWaiter(store, id: id)

        let changed = await store.note(terminalID: terminal, sessionID: "s1", phase: .post,
                                       toolUseID: "toolu_1", toolName: "Bash", inputHash: nil)

        #expect(changed == [terminal])
        #expect(await waiter.value == .resolvedElsewhere)
        #expect(await store.prompts(forTerminal: terminal).isEmpty)
    }

    @Test func postNoteForAnotherCallLeavesPromptOpen() async {
        let store = makeStore()
        let terminal = UUID()
        _ = await preNote(store, terminal: terminal, session: "s1", toolUseID: "toolu_1")
        let (id, _) = await register(store, params(terminal: terminal, session: "s1"))

        let changed = await store.note(terminalID: terminal, sessionID: "s1", phase: .post,
                                       toolUseID: "toolu_other", toolName: "Bash", inputHash: nil)

        #expect(changed.isEmpty)
        #expect(await store.prompts(forTerminal: terminal).map(\.id) == [id])
    }

    @Test func newRegisterInSessionSupersedesOld() async {
        let store = makeStore()
        let terminal = UUID()
        let old = await register(store, params(terminal: terminal, session: "s1"))
        let oldWaiter = await attachWaiter(store, id: old.id)

        let new = await register(store, params(terminal: terminal, session: "s1", input: Self.otherBashInput))

        #expect(new.id != old.id)
        #expect(new.changed == [terminal])
        #expect(await oldWaiter.value == .resolvedElsewhere)
        #expect(await store.prompts(forTerminal: terminal).map(\.id) == [new.id])
    }

    /// Two terminals sharing one session id (`--resume` without
    /// `--fork-session`) each show their own dialog: a register in one never
    /// supersedes the other's, and neither pairs with the other's note.
    @Test func terminalsSharingASessionIDStayApart() async {
        let store = makeStore()
        let terminalA = UUID()
        let terminalB = UUID()
        _ = await preNote(store, terminal: terminalA, session: "shared", toolUseID: "toolu_A")

        let a = await register(store, params(terminal: terminalA, session: "shared"))
        let waiterA = await attachWaiter(store, id: a.id)
        let b = await register(store, params(terminal: terminalB, session: "shared"))

        #expect(b.changed == [terminalB], "terminal A's prompt must not be superseded")
        #expect(await store.prompts(forTerminal: terminalA).map(\.id) == [a.id])
        #expect(await payload(store, terminal: terminalA, id: a.id)?.toolUseID == "toolu_A")
        #expect(await payload(store, terminal: terminalB, id: b.id)?.toolUseID == nil)

        // B's post for its own call leaves A's open prompt alone.
        let changed = await store.note(
            terminalID: terminalB, sessionID: "shared", phase: .post, toolUseID: "toolu_B",
            toolName: "Bash", inputHash: PromptInputHash.of(toolName: "Bash", toolInputJSON: Self.bashInput))
        #expect(changed == [terminalB])
        #expect(await store.prompts(forTerminal: terminalA).map(\.id) == [a.id])
        #expect(await store.prompts(forTerminal: terminalB).isEmpty)
        await store.clear(terminalID: terminalA)
        _ = await waiterA.value
    }

    @Test func registerInAnotherSessionDoesNotSupersede() async {
        let store = makeStore()
        let terminal = UUID()
        let first = await register(store, params(terminal: terminal, session: "s1"))
        let second = await register(store, params(terminal: terminal, session: "s2"))

        #expect(Set(await store.prompts(forTerminal: terminal).map(\.id)) == [first.id, second.id])
    }

    @Test func reRegisterWithSameIDKeepsPromptOpen() async {
        let store = makeStore()
        let terminal = UUID()
        _ = await preNote(store, terminal: terminal, session: "s1", toolUseID: "toolu_1")
        let (id, _) = await register(store, params(terminal: terminal, session: "s1"))
        let before = await store.snapshot(forTerminal: terminal).revision

        let again = await register(store, params(terminal: terminal, session: "s1", knownPromptID: id))

        #expect(again.id == id)
        #expect(again.changed == [terminal])
        let prompts = await store.prompts(forTerminal: terminal)
        #expect(prompts.map(\.id) == [id], "a reconnect must never resolve its own prompt")
        #expect(prompts.first?.toolUseID == "toolu_1", "a reconnect keeps the pairing it had")
        #expect(await store.snapshot(forTerminal: terminal).revision > before)
    }

    @Test func reRegisterWithAnotherTerminalsIDIsAFreshRegister() async {
        let store = makeStore()
        let owner = UUID()
        let stranger = UUID()
        let (id, _) = await register(store, params(terminal: owner, session: "s1"))
        let waiter = await attachWaiter(store, id: id)
        let before = await store.snapshot(forTerminal: owner).revision

        let foreign = await register(store, params(
            terminal: stranger, session: "s1", input: Self.otherBashInput, knownPromptID: id))

        #expect(foreign.id != id, "another terminal's prompt id is not this hook's to reclaim")
        #expect(foreign.changed == [stranger])
        let ownerPrompts = await store.prompts(forTerminal: owner)
        #expect(ownerPrompts.map(\.id) == [id])
        #expect(ownerPrompts.first?.toolInputJSON == Self.bashInput, "the original prompt is not refreshed")
        #expect(await store.snapshot(forTerminal: owner).revision == before)
        #expect(await store.terminalID(ofPrompt: id) == owner)
        #expect(await store.isWaiterAttached(promptID: id), "the original waiter stays attached")
        #expect(await store.prompts(forTerminal: stranger).map(\.id) == [foreign.id])

        await store.resolveAll()
        #expect(await waiter.value == .resolvedElsewhere)
    }

    @Test func closedWaiterResolvesWithHookClosed() async {
        let store = makeStore()
        let terminal = UUID()
        let (id, _) = await register(store, params(terminal: terminal, session: "s1"))
        let token = UUID()
        let waiter = await attachWaiter(store, id: id, token: token)

        #expect(await store.waiterClosed(token: UUID()).isEmpty, "an unknown token closes nothing")
        let changed = await store.waiterClosed(token: token)

        #expect(changed == [terminal])
        #expect(await waiter.value == .resolvedElsewhere)
        #expect(await store.prompts(forTerminal: terminal).isEmpty)
    }

    @Test func staleWaiterIsReleasedWhenANewOneAttaches() async {
        let store = makeStore()
        let terminal = UUID()
        let (id, _) = await register(store, params(terminal: terminal, session: "s1"))
        let staleToken = UUID()
        let stale = await attachWaiter(store, id: id, token: staleToken)

        let freshToken = UUID()
        let fresh = Task { await store.awaitResolution(promptID: id, token: freshToken) }
        // The stale waiter is released only once the fresh one has attached.
        #expect(await stale.value == .resolvedElsewhere)

        #expect(await store.waiterClosed(token: staleToken).isEmpty,
                "the stale connection closing must not resolve a prompt another waiter now holds")
        #expect(await store.prompts(forTerminal: terminal).map(\.id) == [id])

        let answering = Task {
            await store.answer(terminalID: terminal, promptID: id,
                               answer: .permission(decision: .allow, message: nil))
        }
        guard case .answered = await fresh.value else {
            Issue.record("the answer did not reach the fresh waiter")
            return
        }
        await store.acknowledgeDelivery(token: freshToken, delivered: true)
        #expect(await answering.value.outcome == .delivered)
    }

    @Test func clearTerminalResolvesItsPrompts() async {
        let store = makeStore()
        let gone = UUID()
        let kept = UUID()
        _ = await preNote(store, terminal: gone, session: "sGone", toolUseID: "toolu_gone_spare",
                          tool: "Write", input: #"{"file_path":"/tmp/y"}"#)
        let goneID = await register(store, params(terminal: gone, session: "sGone")).id
        let keptID = await register(store, params(terminal: kept, session: "sKept")).id
        let goneWaiter = await attachWaiter(store, id: goneID)
        let keptWaiter = await attachWaiter(store, id: keptID)

        await store.clear(terminalID: gone)

        #expect(await goneWaiter.value == .resolvedElsewhere)
        #expect(await store.prompts(forTerminal: gone).isEmpty)
        #expect(await store.prompts(forTerminal: kept).map(\.id) == [keptID])

        // The terminal's notes went with it.
        let after = await register(store, params(
            terminal: gone, session: "sGone", tool: "Write", input: #"{"file_path":"/tmp/y"}"#))
        #expect(await payload(store, terminal: gone, id: after.id)?.toolUseID == nil)

        await store.resolveAll()
        #expect(await keptWaiter.value == .resolvedElsewhere)
    }

    @Test func detachedSweepResolvesAfterAnHour() async {
        let dates = TestDateSource()
        let store = makeStore(dates: dates)
        let terminal = UUID()
        let start = dates.now
        let (id, _) = await register(store, params(terminal: terminal, session: "s1"))

        let early = await store.sweepDetachedPrompts(
            now: start.addingTimeInterval(3599), maxDetached: .seconds(3600))
        #expect(early.isEmpty)
        #expect(await store.prompts(forTerminal: terminal).map(\.id) == [id])

        let due = await store.sweepDetachedPrompts(
            now: start.addingTimeInterval(3600), maxDetached: .seconds(3600))
        #expect(due == [terminal])
        #expect(await store.prompts(forTerminal: terminal).isEmpty)
    }

    @Test func attachedPromptSurvivesTheSweep() async {
        let dates = TestDateSource()
        let store = makeStore(dates: dates)
        let terminal = UUID()
        let (id, _) = await register(store, params(terminal: terminal, session: "s1"))
        let waiter = await attachWaiter(store, id: id)

        let swept = await store.sweepDetachedPrompts(
            now: dates.now.addingTimeInterval(7200), maxDetached: .seconds(3600))

        #expect(swept.isEmpty)
        #expect(await store.prompts(forTerminal: terminal).map(\.id) == [id])
        await store.resolveAll()
        #expect(await waiter.value == .resolvedElsewhere)
    }

    @Test func resolveAllReleasesEveryWaiter() async {
        let store = makeStore()
        let a = UUID()
        let b = UUID()
        let idA = await register(store, params(terminal: a, session: "sA")).id
        let idB = await register(store, params(terminal: b, session: "sB")).id
        let waiterA = await attachWaiter(store, id: idA)
        let waiterB = await attachWaiter(store, id: idB)

        let changed = await store.resolveAll()

        #expect(changed == [a, b])
        #expect(await waiterA.value == .resolvedElsewhere)
        #expect(await waiterB.value == .resolvedElsewhere)
    }

    @Test func awaitOnUnknownPromptReturnsAtOnce() async {
        let store = makeStore()
        #expect(await store.awaitResolution(promptID: "nope", token: UUID()) == .resolvedElsewhere)
    }

    // MARK: Revision and broadcast

    @Test func everyPromptMutationBumpsRevision() async {
        let store = makeStore()
        let terminal = UUID()
        var seen: [UInt64] = []

        let (id, _) = await register(store, params(terminal: terminal, session: "s1"))
        seen.append(await store.snapshot(forTerminal: terminal).revision)

        _ = await preNote(store, terminal: terminal, session: "s1", toolUseID: "toolu_late")
        seen.append(await store.snapshot(forTerminal: terminal).revision)

        _ = await register(store, params(terminal: terminal, session: "s1", knownPromptID: id))
        seen.append(await store.snapshot(forTerminal: terminal).revision)

        _ = await store.note(terminalID: terminal, sessionID: "s1", phase: .post,
                             toolUseID: "toolu_late", toolName: "Bash", inputHash: nil)
        seen.append(await store.snapshot(forTerminal: terminal).revision)

        #expect(seen == seen.sorted(), "revisions must never go backwards: \(seen)")
        #expect(Set(seen).count == seen.count, "every mutation is a distinct revision: \(seen)")
        #expect(await store.prompts(forTerminal: terminal).isEmpty)
    }

    @Test func broadcastCarriesCapturesAndPrompts() async {
        let captured = CapturedPromptDeltas()
        let subs = StateSubscriptionManager()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                captured.append(delta)
            }
            return true
        }
        let store = makeStore()
        let terminal = UUID()
        await store.set(terminalID: terminal, PendingAskUserQuestion(
            toolUseID: "toolu_capture", inputJSON: "{}", timestamp: Date(timeIntervalSince1970: 1)))
        let (id, _) = await register(store, params(terminal: terminal, session: "s1"))

        await subs.broadcastPendingPrompts(terminalID: terminal, from: store)

        let deltas = captured.all
        let promptDeltas: [TerminalPendingPromptsDelta] = deltas.compactMap {
            if case .terminalPendingPromptsChanged(let d) = $0 { return d }
            return nil
        }
        let legacy = deltas.filter {
            if case .terminalPendingQuestionsChanged = $0 { return true }
            return false
        }
        #expect(legacy.isEmpty, "the daemon no longer sends the pending-questions delta")
        #expect(promptDeltas.count == 1)
        let delta = promptDeltas.first
        #expect(delta?.terminalID == terminal)
        #expect(delta?.captures.map(\.toolUseID) == ["toolu_capture"])
        #expect(delta?.prompts.map(\.id) == [id])
        #expect(delta?.revision == (await store.snapshot(forTerminal: terminal)).revision)
    }
}

/// Collects every delta a manager broadcast.
private final class CapturedPromptDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [StateDelta] = []
    func append(_ delta: StateDelta) {
        lock.lock(); defer { lock.unlock() }
        storage.append(delta)
    }
    var all: [StateDelta] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
