import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Tier 1 — `PendingPromptStore`'s open prompts as the session mod drives
/// them: open, wait, receipt and close, keyed by `(terminal, tool call id)`,
/// and every way a prompt resolves
/// (`docs/specs/2026-10-20-mod-channel-prompt-answer-design.md`, "Daemon: the
/// store"). Each store takes an `EventDrivenTestClock`, so neither a wait's
/// hold, the 60 s pickup window nor the 5 s receipt timeout can fire on wall
/// time; the tests that cross them advance the clock explicitly.
@Suite(.clockDriven)
struct PendingPromptResolutionTests {

    static let bashInput = #"{"command":"ls"}"#
    static let questionInput = #"""
    {"questions":[{"question":"Pick one","header":"Choice","multiSelect":false,"options":[{"label":"A"},{"label":"B"}]}]}
    """#
    static let allow = PromptAnswer.permission(decision: .allow, message: nil)

    // MARK: Helpers

    private func makeStore(
        clock: EventDrivenTestClock = EventDrivenTestClock(),
        dates: TestDateSource = TestDateSource()
    ) -> PendingPromptStore {
        PendingPromptStore(now: dates.provider, clock: clock)
    }

    @discardableResult
    private func open(
        _ store: PendingPromptStore, terminal: UUID, toolUseID: String = "toolu_1",
        session: String = "s1", tool: String = "Bash",
        input: String = PendingPromptResolutionTests.bashInput, suggestions: String? = nil
    ) async -> Set<UUID> {
        await store.open(
            terminalID: terminal, sessionID: session, toolUseID: toolUseID, toolName: tool,
            toolInputJSON: input, suggestionsJSON: suggestions)
    }

    /// Starts a wait request and returns once it is attached.
    private func attachWaiter(
        _ store: PendingPromptStore, terminal: UUID, toolUseID: String = "toolu_1",
        token: UUID = UUID(), hold: Duration = .seconds(25),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Task<PendingPromptStore.WaitResult, Never> {
        let waiter = Task {
            await store.waitForAnswer(terminalID: terminal, toolUseID: toolUseID, token: token, hold: hold)
        }
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await store.isWaiterAttached(terminalID: terminal, toolUseID: toolUseID)
        }
        if outcome == .timedOut {
            Issue.record("the waiter for \(toolUseID) never attached", sourceLocation: sourceLocation)
        }
        return waiter
    }

    /// Takes the held decision with a wait request and then delivers a receipt,
    /// all in one turn on the store's executor: a held decision returns without
    /// suspending, so a parked `answer` cannot resume between the two.
    private func pickUpThenReceipt(
        _ store: isolated PendingPromptStore, terminal: UUID, toolUseID: String = "toolu_1"
    ) async -> PendingPromptStore.WaitResult {
        let picked = await store.waitForAnswer(
            terminalID: terminal, toolUseID: toolUseID, token: UUID(), hold: .seconds(25))
        _ = store.receipt(terminalID: terminal, toolUseID: toolUseID)
        return picked
    }

    /// As `pickUpThenReceipt`, but the terminal closes the prompt instead.
    private func pickUpThenClosed(
        _ store: isolated PendingPromptStore, terminal: UUID, toolUseID: String = "toolu_1"
    ) async -> PendingPromptStore.WaitResult {
        let picked = await store.waitForAnswer(
            terminalID: terminal, toolUseID: toolUseID, token: UUID(), hold: .seconds(25))
        _ = store.closed(terminalID: terminal, toolUseID: toolUseID)
        return picked
    }

    private func decision(
        _ answer: PromptAnswer = PendingPromptResolutionTests.allow,
        input: String = PendingPromptResolutionTests.bashInput
    ) throws -> String {
        try PromptDecisionEncoder.decisionJSON(
            answer: answer, kind: .permission, toolInputJSON: input, suggestionsJSON: nil)
    }

    private func openIDs(_ store: PendingPromptStore, _ terminal: UUID) async -> [String] {
        await store.prompts(forTerminal: terminal).map(\.id)
    }

    // MARK: Open

    @Test func openPublishesPromptKeyedByToolUseID() async {
        let dates = TestDateSource()
        let store = makeStore(dates: dates)
        let terminal = UUID()
        let before = await store.snapshot(forTerminal: terminal).revision

        let changed = await open(store, terminal: terminal, toolUseID: "toolu_bash",
                                 suggestions: #"[{"type":"addRules"}]"#)
        await open(store, terminal: terminal, toolUseID: "toolu_q",
                   tool: "AskUserQuestion", input: Self.questionInput)

        #expect(changed == [terminal])
        let prompts = await store.prompts(forTerminal: terminal)
        #expect(prompts.map(\.id) == ["toolu_bash", "toolu_q"])
        let bash = prompts.first
        #expect(bash?.toolUseID == "toolu_bash", "the id and the tool call id are the same value")
        #expect(bash?.kind == .permission)
        #expect(bash?.toolName == "Bash")
        #expect(bash?.toolInputJSON == Self.bashInput)
        #expect(bash?.suggestionsJSON == #"[{"type":"addRules"}]"#)
        #expect(bash?.createdAt == dates.now)
        #expect(prompts.last?.kind == .question)
        #expect(await store.snapshot(forTerminal: terminal).revision > before)
        #expect(await store.terminalsWithOpenPrompts() == [terminal])
    }

    /// The mod re-posts its open dialogs after any reconnect: the repeat is
    /// the same prompt, so its card keeps its place and its wait request
    /// stays attached.
    @Test func reopenKeepsCreatedAtAndWaiter() async {
        let dates = TestDateSource()
        let store = makeStore(dates: dates)
        let terminal = UUID()
        let opened = dates.now
        await open(store, terminal: terminal)
        let waiter = await attachWaiter(store, terminal: terminal)
        let revision = await store.snapshot(forTerminal: terminal).revision

        dates.advance(by: 30)
        let changed = await open(store, terminal: terminal, input: #"{"command":"ls -la"}"#)

        #expect(changed == [terminal])
        let prompts = await store.prompts(forTerminal: terminal)
        #expect(prompts.count == 1)
        #expect(prompts.first?.createdAt == opened)
        #expect(prompts.first?.toolInputJSON == #"{"command":"ls -la"}"#, "the repeat refreshes the payload")
        #expect(await store.isWaiterAttached(terminalID: terminal, toolUseID: "toolu_1"))
        #expect(await store.snapshot(forTerminal: terminal).revision > revision)

        await store.resolveAll()
        #expect(await waiter.value == .resolved)
    }

    // MARK: Answering

    @Test func answerWithWaiterThenReceiptIsDelivered() async throws {
        let store = makeStore()
        let terminal = UUID()
        await open(store, terminal: terminal)
        let waiter = await attachWaiter(store, terminal: terminal)
        let answer = PromptAnswer.permission(decision: .deny, message: "not now")

        let answering = Task { await store.answer(terminalID: terminal, promptID: "toolu_1", answer: answer) }
        #expect(await waiter.value == .decision(try decision(answer)))

        let receipted = await store.receipt(terminalID: terminal, toolUseID: "toolu_1")
        let result = await answering.value

        #expect(receipted == [terminal])
        #expect(result.outcome == .delivered)
        #expect(result.changed == [terminal])
        #expect(await openIDs(store, terminal).isEmpty)
    }

    /// Review Focus 1: the terminal's No races TBD's Allow. The mod aborts
    /// mid-answer and posts closed in place of a receipt, so the answer must
    /// read already-resolved, never delivered.
    @Test func answerThenClosedIsAlreadyResolved() async throws {
        let store = makeStore()
        let terminal = UUID()
        await open(store, terminal: terminal)
        let waiter = await attachWaiter(store, terminal: terminal)

        let answering = Task { await store.answer(terminalID: terminal, promptID: "toolu_1", answer: Self.allow) }
        #expect(await waiter.value == .decision(try decision()))

        let closed = await store.closed(terminalID: terminal, toolUseID: "toolu_1")
        let result = await answering.value

        #expect(closed == [terminal])
        #expect(result.outcome == .alreadyResolved)
        #expect(await openIDs(store, terminal).isEmpty)
        // A receipt arriving after the close finds nothing to settle.
        #expect(await store.receipt(terminalID: terminal, toolUseID: "toolu_1").isEmpty)
    }

    @Test func answerWithoutReceiptIsUnknownAfterFiveSeconds() async throws {
        let clock = EventDrivenTestClock()
        let store = makeStore(clock: clock)
        let terminal = UUID()
        await open(store, terminal: terminal)
        let waiter = await attachWaiter(store, terminal: terminal)

        let answering = Task { await store.answer(terminalID: terminal, promptID: "toolu_1", answer: Self.allow) }
        _ = await waiter.value
        // The hand-over cancelled the wait's hold, so the receipt timer is
        // the only sleeper.
        try await clock.requireAdvanceWhenArmed(by: .seconds(5))
        let result = await answering.value

        #expect(result.outcome == .deliveryUnconfirmed, "no receipt within 5 s may still mean Claude had it")
        #expect(result.changed == [terminal])
        #expect(await openIDs(store, terminal).isEmpty)

        let retry = await store.answer(terminalID: terminal, promptID: "toolu_1", answer: Self.allow)
        #expect(retry.outcome == .alreadyResolved, "the timed-out prompt is resolved, so a retry cannot answer twice")
    }

    /// A second answer racing the first one's receipt timeout must come back
    /// too: the timeout ends the prompt in its own actor turn, so the second
    /// answer finds it answered or gone and never parks on it.
    @Test func secondAnswerAfterReceiptTimeoutReturns() async throws {
        let clock = EventDrivenTestClock()
        let store = makeStore(clock: clock)
        let terminal = UUID()
        await open(store, terminal: terminal)
        let waiter = await attachWaiter(store, terminal: terminal)

        let first = Task { await store.answer(terminalID: terminal, promptID: "toolu_1", answer: Self.allow) }
        _ = await waiter.value
        try await clock.requireAdvanceWhenArmed(by: .seconds(5))
        let second = await store.answer(terminalID: terminal, promptID: "toolu_1", answer: Self.allow)

        #expect(second.outcome == .alreadyResolved)
        #expect(await first.value.outcome == .deliveryUnconfirmed)
        #expect(await openIDs(store, terminal).isEmpty)
    }

    /// A receipt landing after a wait request took the held decision but
    /// before the answer parks for its receipt still settles it as delivered.
    /// `pickUpThenReceipt` runs both on the store's executor, so the answer cannot
    /// resume in between.
    @Test func receiptBetweenPickupAndReceiptParkIsDelivered() async throws {
        let clock = EventDrivenTestClock()
        let store = makeStore(clock: clock)
        let terminal = UUID()
        await open(store, terminal: terminal)
        let answering = Task { await store.answer(terminalID: terminal, promptID: "toolu_1", answer: Self.allow) }
        try await clock.requireSleeperArmed()

        let picked = await pickUpThenReceipt(store, terminal: terminal)

        #expect(picked == .decision(try decision()))
        #expect(await answering.value.outcome == .delivered)
        #expect(await openIDs(store, terminal).isEmpty)
    }

    /// The same gap with a close instead: the terminal answered first.
    @Test func closedBetweenPickupAndReceiptParkIsAlreadyResolved() async throws {
        let clock = EventDrivenTestClock()
        let store = makeStore(clock: clock)
        let terminal = UUID()
        await open(store, terminal: terminal)
        let answering = Task { await store.answer(terminalID: terminal, promptID: "toolu_1", answer: Self.allow) }
        try await clock.requireSleeperArmed()

        let picked = await pickUpThenClosed(store, terminal: terminal)

        #expect(picked == .decision(try decision()))
        #expect(await answering.value.outcome == .alreadyResolved)
        #expect(await openIDs(store, terminal).isEmpty)
    }

    /// No wait request is attached when the answer arrives (the mod is
    /// between polls): the decision is held, and the next wait request
    /// within the pickup window takes it at once.
    @Test func answerHeldUntilNextWaitPicksItUp() async throws {
        let clock = EventDrivenTestClock()
        let store = makeStore(clock: clock)
        let terminal = UUID()
        await open(store, terminal: terminal)

        let answering = Task { await store.answer(terminalID: terminal, promptID: "toolu_1", answer: Self.allow) }
        // The pickup window's timer is armed, so the decision is held.
        try await clock.requireSleeperArmed()

        let picked = await store.waitForAnswer(
            terminalID: terminal, toolUseID: "toolu_1", token: UUID(), hold: .seconds(25))
        #expect(picked == .decision(try decision()))

        await store.receipt(terminalID: terminal, toolUseID: "toolu_1")
        #expect(await answering.value.outcome == .delivered)
        #expect(await openIDs(store, terminal).isEmpty)
    }

    @Test func answerWithdrawnAfterSixtySecondsIsHookDetached() async throws {
        let clock = EventDrivenTestClock()
        let store = makeStore(clock: clock)
        let terminal = UUID()
        await open(store, terminal: terminal)

        let answering = Task { await store.answer(terminalID: terminal, promptID: "toolu_1", answer: Self.allow) }
        try await clock.requireAdvanceWhenArmed(by: .seconds(60))
        let result = await answering.value

        #expect(result.outcome == .hookDetached)
        #expect(result.changed.isEmpty)
        #expect(await openIDs(store, terminal) == ["toolu_1"], "a withdrawn answer is retryable, so the prompt stays open")

        // The withdrawn decision is gone: the next wait request holds and
        // comes back empty.
        let waiter = await attachWaiter(store, terminal: terminal)
        try await clock.requireAdvanceWhenArmed(by: .seconds(25))
        #expect(await waiter.value == .pending)
    }

    @Test func secondAnswerIsAlreadyResolved() async throws {
        let store = makeStore()
        let terminal = UUID()
        await open(store, terminal: terminal)
        let waiter = await attachWaiter(store, terminal: terminal)

        let first = Task { await store.answer(terminalID: terminal, promptID: "toolu_1", answer: Self.allow) }
        _ = await waiter.value

        // While the first answer waits for its receipt…
        let racing = await store.answer(terminalID: terminal, promptID: "toolu_1", answer: Self.allow)
        #expect(racing.outcome == .alreadyResolved)
        #expect(racing.changed.isEmpty)

        await store.receipt(terminalID: terminal, toolUseID: "toolu_1")
        #expect(await first.value.outcome == .delivered)

        // …and after it was delivered.
        let late = await store.answer(terminalID: terminal, promptID: "toolu_1", answer: Self.allow)
        #expect(late.outcome == .alreadyResolved)
    }

    @Test func answerFromOtherTerminalIsAlreadyResolved() async {
        let store = makeStore()
        let terminal = UUID()
        await open(store, terminal: terminal)
        let waiter = await attachWaiter(store, terminal: terminal)

        let result = await store.answer(terminalID: UUID(), promptID: "toolu_1", answer: Self.allow)

        #expect(result.outcome == .alreadyResolved)
        #expect(await store.isWaiterAttached(terminalID: terminal, toolUseID: "toolu_1"),
                "a misaddressed answer must not touch the prompt")
        await store.resolveAll()
        #expect(await waiter.value == .resolved)
    }

    @Test func invalidAnswerLeavesPromptOpen() async {
        let store = makeStore()
        let terminal = UUID()
        await open(store, terminal: terminal, tool: "AskUserQuestion", input: Self.questionInput)
        let waiter = await attachWaiter(store, terminal: terminal)

        let wrongKind = await store.answer(terminalID: terminal, promptID: "toolu_1", answer: Self.allow)
        #expect(wrongKind.outcome == .invalid(.kindMismatch))
        let missing = await store.answer(terminalID: terminal, promptID: "toolu_1",
                                         answer: .question(answers: [:]))
        #expect(missing.outcome == .invalid(.missingAnswer(question: "Pick one")))

        #expect(await openIDs(store, terminal) == ["toolu_1"])
        #expect(await store.isWaiterAttached(terminalID: terminal, toolUseID: "toolu_1"),
                "an invalid answer must not consume the waiter")
        await store.resolveAll()
        #expect(await waiter.value == .resolved)
    }

    // MARK: Waiting

    @Test func waitReturnsPendingAfterHold() async throws {
        let clock = EventDrivenTestClock()
        let store = makeStore(clock: clock)
        let terminal = UUID()
        await open(store, terminal: terminal)

        let waiter = await attachWaiter(store, terminal: terminal, hold: .seconds(25))
        try await clock.requireAdvanceWhenArmed(by: .seconds(25))

        #expect(await waiter.value == .pending)
        #expect(await store.isWaiterAttached(terminalID: terminal, toolUseID: "toolu_1") == false)
        #expect(await openIDs(store, terminal) == ["toolu_1"], "an empty hold never resolves the prompt")
    }

    @Test func newerWaitReplacesAnOlderOne() async throws {
        let store = makeStore()
        let terminal = UUID()
        await open(store, terminal: terminal)
        let staleToken = UUID()
        let stale = await attachWaiter(store, terminal: terminal, token: staleToken)

        let freshToken = UUID()
        let fresh = Task {
            await store.waitForAnswer(terminalID: terminal, toolUseID: "toolu_1", token: freshToken, hold: .seconds(25))
        }
        #expect(await stale.value == .pending)

        // The stale request's token no longer detaches anything.
        await store.waiterGone(token: staleToken)
        #expect(await store.isWaiterAttached(terminalID: terminal, toolUseID: "toolu_1"))
        let answering = Task { await store.answer(terminalID: terminal, promptID: "toolu_1", answer: Self.allow) }
        #expect(await fresh.value == .decision(try decision()))
        await store.receipt(terminalID: terminal, toolUseID: "toolu_1")
        #expect(await answering.value.outcome == .delivered)
    }

    /// Review Focus 3: the mod aborted its fetch. The waiter detaches and the
    /// prompt stays open; the next wait request takes the answer.
    @Test func waiterGoneDoesNotResolve() async throws {
        let store = makeStore()
        let terminal = UUID()
        await open(store, terminal: terminal)
        let token = UUID()
        let gone = await attachWaiter(store, terminal: terminal, token: token)

        await store.waiterGone(token: token)

        #expect(await gone.value == .pending)
        #expect(await store.isWaiterAttached(terminalID: terminal, toolUseID: "toolu_1") == false)
        #expect(await openIDs(store, terminal) == ["toolu_1"])

        let next = await attachWaiter(store, terminal: terminal)
        let answering = Task { await store.answer(terminalID: terminal, promptID: "toolu_1", answer: Self.allow) }
        #expect(await next.value == .decision(try decision()))
        await store.receipt(terminalID: terminal, toolUseID: "toolu_1")
        #expect(await answering.value.outcome == .delivered)
    }

    /// The server cancels a wait request whose connection closed. Cancelling
    /// the awaiting task detaches the waiter with `.pending` and leaves the
    /// prompt open, like `waiterGone`.
    @Test func waitReleasedWhenTaskCancelled() async throws {
        let store = makeStore()
        let terminal = UUID()
        await open(store, terminal: terminal)
        let waiter = await attachWaiter(store, terminal: terminal)

        waiter.cancel()

        #expect(await waiter.value == .pending)
        #expect(await store.isWaiterAttached(terminalID: terminal, toolUseID: "toolu_1") == false)
        #expect(await openIDs(store, terminal) == ["toolu_1"], "a cancelled wait never resolves the prompt")

        let next = await attachWaiter(store, terminal: terminal)
        let answering = Task { await store.answer(terminalID: terminal, promptID: "toolu_1", answer: Self.allow) }
        #expect(await next.value == .decision(try decision()))
        await store.receipt(terminalID: terminal, toolUseID: "toolu_1")
        #expect(await answering.value.outcome == .delivered)
    }

    /// A wait request cancelled before it reaches the store — its connection
    /// closed while it was still authenticating — never attaches, and does
    /// not take a decision nobody would receive.
    @Test func waitCancelledBeforeAttachingTakesNothing() async throws {
        let clock = EventDrivenTestClock()
        let store = makeStore(clock: clock)
        let terminal = UUID()
        await open(store, terminal: terminal)
        let answering = Task { await store.answer(terminalID: terminal, promptID: "toolu_1", answer: Self.allow) }
        // The answer is parked for pickup once its timeout is armed.
        try await clock.requireSleeperArmed()

        let cancelled = Task { () -> PendingPromptStore.WaitResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.waitForAnswer(
                terminalID: terminal, toolUseID: "toolu_1", token: UUID(), hold: .seconds(25))
        }
        #expect(await cancelled.value == .pending)
        #expect(await store.isWaiterAttached(terminalID: terminal, toolUseID: "toolu_1") == false)

        // The decision is still there for the next request.
        let picked = await pickUpThenReceipt(store, terminal: terminal)
        #expect(picked == .decision(try decision()))
        #expect(await answering.value.outcome == .delivered)
    }

    @Test func waitOnClosedPromptIsResolved() async {
        let store = makeStore()
        let terminal = UUID()
        await open(store, terminal: terminal)
        let waiter = await attachWaiter(store, terminal: terminal)

        #expect(await store.closed(terminalID: terminal, toolUseID: "toolu_1") == [terminal])
        #expect(await waiter.value == .resolved, "a held request ends when the terminal answers")
        #expect(await store.waitForAnswer(
            terminalID: terminal, toolUseID: "toolu_1", token: UUID(), hold: .seconds(25)) == .resolved)
        #expect(await store.waitForAnswer(
            terminalID: terminal, toolUseID: "toolu_never", token: UUID(), hold: .seconds(25)) == .resolved)
    }

    // MARK: Terminals stay apart

    /// Review Focus 5: two terminals resumed into one Claude session each
    /// open a dialog for the same tool call and input. They are two prompts,
    /// and an answer for one never reaches the other.
    @Test func sameToolUseInputInTwoTerminalsStaysApart() async throws {
        let store = makeStore()
        let a = UUID()
        let b = UUID()
        await open(store, terminal: a, session: "shared")
        await open(store, terminal: b, session: "shared")
        #expect(await openIDs(store, a) == ["toolu_1"])
        #expect(await openIDs(store, b) == ["toolu_1"])
        let waiterA = await attachWaiter(store, terminal: a)
        let waiterB = await attachWaiter(store, terminal: b)

        let answering = Task { await store.answer(terminalID: a, promptID: "toolu_1", answer: Self.allow) }
        #expect(await waiterA.value == .decision(try decision()))
        #expect(await store.isWaiterAttached(terminalID: b, toolUseID: "toolu_1"),
                "terminal B's request must not see terminal A's answer")

        // B's receipt or close never settles A's answer either.
        #expect(await store.closed(terminalID: b, toolUseID: "toolu_1") == [b])
        #expect(await waiterB.value == .resolved)
        await store.receipt(terminalID: a, toolUseID: "toolu_1")
        #expect(await answering.value.outcome == .delivered)
        #expect(await store.terminalsWithOpenPrompts().isEmpty)
    }

    // MARK: Bulk resolution

    @Test func resolvePromptsKeepsCaptures() async {
        let store = makeStore()
        let terminal = UUID()
        let other = UUID()
        await store.set(terminalID: terminal, PendingAskUserQuestion(
            toolUseID: "toolu_capture", inputJSON: "{}", timestamp: Date(timeIntervalSince1970: 1)))
        await open(store, terminal: terminal)
        await open(store, terminal: terminal, toolUseID: "toolu_2")
        await open(store, terminal: other)
        let waiter = await attachWaiter(store, terminal: terminal)

        let changed = await store.resolvePrompts(terminalID: terminal, .sessionEnded)

        #expect(changed == [terminal])
        #expect(await waiter.value == .resolved)
        #expect(await openIDs(store, terminal).isEmpty)
        #expect(await store.entries(forTerminal: terminal).map(\.toolUseID) == ["toolu_capture"])
        #expect(await openIDs(store, other) == ["toolu_1"])
        #expect(await store.terminalsWithOpenPrompts() == [other])
        #expect(await store.resolvePrompts(terminalID: terminal, .modDisconnected).isEmpty)
    }

    @Test func clearTerminalResolvesItsPromptsAndCaptures() async {
        let store = makeStore()
        let gone = UUID()
        let kept = UUID()
        await store.set(terminalID: gone, PendingAskUserQuestion(
            toolUseID: "toolu_capture", inputJSON: "{}", timestamp: Date(timeIntervalSince1970: 1)))
        await open(store, terminal: gone)
        await open(store, terminal: kept)
        let goneWaiter = await attachWaiter(store, terminal: gone)
        let keptWaiter = await attachWaiter(store, terminal: kept)

        await store.clear(terminalID: gone)

        #expect(await goneWaiter.value == .resolved)
        #expect(await openIDs(store, gone).isEmpty)
        #expect(await store.entries(forTerminal: gone).isEmpty)
        #expect(await openIDs(store, kept) == ["toolu_1"])
        await store.resolveAll()
        #expect(await keptWaiter.value == .resolved)
    }

    @Test func resolveAllReleasesWaitersAndAcks() async throws {
        let store = makeStore()
        let waiting = UUID()
        let answered = UUID()
        await open(store, terminal: waiting)
        await open(store, terminal: answered)
        let held = await attachWaiter(store, terminal: waiting)
        let handedOver = await attachWaiter(store, terminal: answered)
        let answering = Task { await store.answer(terminalID: answered, promptID: "toolu_1", answer: Self.allow) }
        _ = await handedOver.value

        let changed = await store.resolveAll()

        #expect(changed == [waiting, answered])
        #expect(await held.value == .resolved)
        #expect(await answering.value.outcome == .alreadyResolved,
                "an answer waiting for its receipt at shutdown leaves the terminal in charge")
        #expect(await store.terminalsWithOpenPrompts().isEmpty)
    }

    // MARK: Revision and broadcast

    @Test func everyPromptMutationBumpsRevision() async {
        let store = makeStore()
        let terminal = UUID()
        var seen: [UInt64] = []

        await open(store, terminal: terminal)
        seen.append(await store.snapshot(forTerminal: terminal).revision)
        await open(store, terminal: terminal)
        seen.append(await store.snapshot(forTerminal: terminal).revision)
        await open(store, terminal: terminal, toolUseID: "toolu_2")
        seen.append(await store.snapshot(forTerminal: terminal).revision)
        await store.closed(terminalID: terminal, toolUseID: "toolu_1")
        seen.append(await store.snapshot(forTerminal: terminal).revision)
        await store.receipt(terminalID: terminal, toolUseID: "toolu_2")
        seen.append(await store.snapshot(forTerminal: terminal).revision)

        #expect(seen == seen.sorted(), "revisions must never go backwards: \(seen)")
        #expect(Set(seen).count == seen.count, "every mutation is a distinct revision: \(seen)")
        #expect(await openIDs(store, terminal).isEmpty)
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
        await open(store, terminal: terminal)

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
        #expect(delta?.prompts.map(\.id) == ["toolu_1"])
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
