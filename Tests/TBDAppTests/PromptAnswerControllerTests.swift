import Foundation
import TestSupport
import Testing
@testable import TBDApp
import TBDShared

// Tier 1: `PromptAnswerController` against fake senders — answer assembly, the
// permission decision mapping, and the state each RPC outcome leaves. No clock:
// the controller arms no timer (holding an answered card is
// `PromptCardRetention`'s job). Design:
// docs/specs/2026-10-09-transcript-prompt-answer-design.md, "States".

/// What the fake senders and callbacks saw.
@MainActor
private final class Recorder {
    var localCalls: [(UUID, String, PromptAnswer)] = []
    var remoteCalls: [(String, String, String, PromptAnswer)] = []
    var delivered: [(String, String)] = []
    var synced: [RemoteSessionSelection] = []
    var localOutcomes: [PromptAnswerOutcome] = []
    var remoteOutcomes: [PromptAnswerOutcome] = []
    var pending: CheckedContinuation<PromptAnswerResult, Never>?
}

private struct HookReconnecting: Error, LocalizedError {
    var errorDescription: String? { "the prompt's hook is reconnecting; try again" }
}

@MainActor
@Suite("Prompt answer controller")
struct PromptAnswerControllerTests {
    typealias Fix = PromptFixtures
    typealias Controller = PromptAnswerController

    private func makeController(
        _ recorder: Recorder,
        local: [PromptAnswerOutcome] = [.delivered],
        remote: [PromptAnswerOutcome] = [.delivered],
        localError: (any Error)? = nil
    ) -> Controller {
        recorder.localOutcomes = local
        recorder.remoteOutcomes = remote
        return Controller(
            local: { terminalID, promptID, answer in
                recorder.localCalls.append((terminalID, promptID, answer))
                if let localError { throw localError }
                let outcome = recorder.localOutcomes.isEmpty ? .delivered : recorder.localOutcomes.removeFirst()
                return PromptAnswerResult(outcome: outcome)
            },
            remote: { provider, sessionID, promptID, answer in
                recorder.remoteCalls.append((provider, sessionID, promptID, answer))
                let outcome = recorder.remoteOutcomes.isEmpty ? .delivered : recorder.remoteOutcomes.removeFirst()
                return PromptAnswerResult(outcome: outcome)
            },
            onDelivered: { prompt, summary in recorder.delivered.append((prompt.promptID, summary)) },
            onRemoteDelivered: { selection in recorder.synced.append(selection) })
    }

    private var permission: PendingPromptPresentation { Fix.local(Fix.permissionPayload()) }

    private var remotePermission: PendingPromptPresentation {
        PendingPromptPresentation.remote(
            RemotePendingPrompt(id: "r1", kind: .permission, toolName: "Bash",
                                toolInputJSON: #"{"command":"touch x"}"#),
            selection: Fix.selection, capabilities: [RemoteCapability.answer],
            flagOn: true, now: Fix.when)
    }

    private let allow = PromptAnswer.permission(decision: .allow, message: nil)

    // MARK: - Outcomes

    @Test func deliveredMovesToAnsweredAndRetains() async {
        let recorder = Recorder()
        let retention = PromptCardRetention(retainFor: .seconds(30), clock: EventDrivenTestClock())
        let controller = Controller(
            local: { _, _, _ in PromptAnswerResult(outcome: .delivered) },
            remote: { _, _, _, _ in PromptAnswerResult(outcome: .delivered) },
            onDelivered: { prompt, summary in
                recorder.delivered.append((prompt.promptID, summary))
                retention.markAnswered(prompt, summary: summary)
            })

        await controller.submit(permission, answer: allow)

        #expect(controller.state(for: "p1") == .answered(summary: "Allowed"))
        #expect(recorder.delivered.map { $0.0 } == ["p1"])
        #expect(retention.heldPhase(for: "p1") == .answered(summary: "Allowed"))
    }

    @Test func localDeliveryGoesToTheTerminalWithThePromptID() async {
        let recorder = Recorder()
        let controller = makeController(recorder)
        await controller.submit(permission, answer: allow)
        #expect(recorder.localCalls.count == 1)
        #expect(recorder.localCalls.first?.0 == Fix.terminalID)
        #expect(recorder.localCalls.first?.1 == "p1")
        #expect(recorder.localCalls.first?.2 == allow)
        #expect(recorder.remoteCalls.isEmpty)
        #expect(recorder.synced.isEmpty, "a local delivery never requests a remote sync")
    }

    @Test func alreadyResolvedIsAnsweredElsewhere() async {
        let recorder = Recorder()
        let controller = makeController(recorder, local: [.alreadyResolved])
        await controller.submit(permission, answer: allow)
        #expect(controller.state(for: "p1") == .answeredElsewhere)
        #expect(recorder.delivered.isEmpty)
    }

    @Test func unknownOutcomeOffersRetry() async {
        let recorder = Recorder()
        let controller = makeController(recorder, remote: [.unknown])
        await controller.submit(remotePermission, answer: allow)
        #expect(controller.state(for: "r1") == .unknownOutcome)
        #expect(PromptCardFooter.resolve(remotePermission, state: controller.state(for: "r1")) == .unknownOutcome)
        #expect(recorder.synced.isEmpty, "only a delivered answer requests a sync")
    }

    @Test func retryThatAlreadyArrivedReadsAnsweredElsewhere() async {
        let recorder = Recorder()
        let controller = makeController(recorder, remote: [.unknown, .alreadyResolved])
        let deny = PromptAnswer.permission(decision: .deny, message: "no")
        await controller.submit(remotePermission, answer: deny)
        await controller.retry(remotePermission)
        #expect(controller.state(for: "r1") == .answeredElsewhere)
        #expect(recorder.remoteCalls.map { $0.3 } == [deny, deny], "retry resends the same answer")
    }

    @Test func localUnknownOutcomeOffersRetryThatReadsAnsweredElsewhere() async {
        let recorder = Recorder()
        let controller = makeController(recorder, local: [.unknown, .alreadyResolved])
        await controller.submit(permission, answer: allow)
        #expect(controller.state(for: "p1") == .unknownOutcome)
        #expect(PromptCardFooter.resolve(permission, state: controller.state(for: "p1")) == .unknownOutcome)
        #expect(recorder.delivered.isEmpty, "an unconfirmed delivery is not marked answered")
        await controller.retry(permission)
        #expect(controller.state(for: "p1") == .answeredElsewhere)
        #expect(recorder.localCalls.count == 2, "retry resends the same answer")
    }

    @Test func retryWithNothingSentDoesNothing() async {
        let recorder = Recorder()
        let controller = makeController(recorder)
        await controller.retry(permission)
        #expect(recorder.localCalls.isEmpty)
        #expect(controller.state(for: "p1") == .waiting)
    }

    @Test func thrownErrorIsFailedWithMessage() async {
        let recorder = Recorder()
        let controller = makeController(
            recorder,
            localError: DaemonClientError.rpcError("the prompt's hook is reconnecting; try again", code: nil))
        await controller.submit(permission, answer: allow)
        #expect(controller.state(for: "p1")
                == .failed(message: "the prompt's hook is reconnecting; try again", retryable: true))
    }

    @Test func nonRPCErrorUsesItsDescription() async {
        let recorder = Recorder()
        let controller = makeController(recorder, localError: HookReconnecting())
        await controller.submit(permission, answer: allow)
        #expect(controller.state(for: "p1")
                == .failed(message: "the prompt's hook is reconnecting; try again", retryable: true))
    }

    /// A refusal's code, never its words, decides whether "Try again" shows:
    /// an answer that does not fit and the setting being off cannot change on
    /// a retry, and everything else may, including the setting that could not
    /// be read, a code this build does not know, a refusal with no code in
    /// the very words of one that has a code, and a dropped connection.
    @Test func refusalsARetryCannotChangeAreNotRetryable() {
        let doesNotFit = "invalid_params: no answer for the question \"Which?\""
        let off = "answering prompts from the transcript is off (config.transcript_prompt_answer_enabled)"
        let notRetryable: [any Error] = [
            DaemonClientError.rpcError(doesNotFit, code: RPCErrorCode.answerDoesNotFit.rawValue),
            DaemonClientError.rpcError(off, code: RPCErrorCode.promptAnswerOff.rawValue),
        ]
        let retryable: [any Error] = [
            DaemonClientError.rpcError(
                "the setting for answering prompts could not be read",
                code: RPCErrorCode.promptAnswerSettingUnread.rawValue),
            DaemonClientError.rpcError("the remote session has exited", code: RPCErrorCode.remoteSessionExited.rawValue),
            DaemonClientError.rpcError(doesNotFit, code: "acmeUnknownCode"),
            DaemonClientError.rpcError(doesNotFit, code: nil),
            DaemonClientError.rpcError(off, code: nil),
            DaemonClientError.rpcError("the prompt's hook is reconnecting; try again", code: nil),
            DaemonClientError.connectionFailed("refused"),
            HookReconnecting(),
        ]

        for error in notRetryable {
            #expect(!Controller.isRetryable(error), "\(error)")
        }
        for error in retryable {
            #expect(Controller.isRetryable(error), "\(error)")
        }
    }

    /// A submit the daemon refuses with a code a retry cannot change fails
    /// with the refusal's words and no "Try again".
    @Test func aSubmitRefusedWithACodeARetryCannotChangeIsNotRetryable() async {
        let message = "invalid_params: no answer for the question \"Which?\""
        let controller = makeController(
            Recorder(),
            localError: DaemonClientError.rpcError(message, code: RPCErrorCode.answerDoesNotFit.rawValue))
        await controller.submit(permission, answer: allow)
        #expect(controller.state(for: "p1") == .failed(message: message, retryable: false))
    }

    @Test func remoteDeliveryRequestsATranscriptSync() async {
        let recorder = Recorder()
        let controller = makeController(recorder)
        await controller.submit(remotePermission, answer: allow)
        #expect(controller.state(for: "r1") == .answered(summary: "Allowed"))
        #expect(recorder.synced == [Fix.selection])
        #expect(recorder.remoteCalls.first?.0 == "acme")
        #expect(recorder.remoteCalls.first?.1 == "s1")
        #expect(recorder.remoteCalls.first?.2 == "r1")
        #expect(recorder.localCalls.isEmpty)
    }

    @Test func aSecondSubmitWhileSendingIsIgnored() async {
        let recorder = Recorder()
        let controller = Controller(
            local: { terminalID, promptID, answer in
                recorder.localCalls.append((terminalID, promptID, answer))
                return await withCheckedContinuation { recorder.pending = $0 }
            },
            remote: { _, _, _, _ in PromptAnswerResult(outcome: .delivered) })
        let prompt = permission
        let answer = allow
        let first = Task { await controller.submit(prompt, answer: answer) }
        for _ in 0..<200 where recorder.pending == nil { await Task.yield() }
        #expect(controller.state(for: "p1") == .sending)

        await controller.submit(prompt, answer: answer)
        #expect(recorder.localCalls.count == 1, "the second submit must not send")

        recorder.pending?.resume(returning: PromptAnswerResult(outcome: .delivered))
        await first.value
        #expect(controller.state(for: "p1") == .answered(summary: "Allowed"))
    }

    /// A submit still travelling when its prompt is forgotten writes nothing
    /// back: no resurrected state, and no answered card held again.
    @Test func aSubmitInFlightWhenForgottenWritesNothingBack() async {
        let recorder = Recorder()
        let controller = Controller(
            local: { terminalID, promptID, answer in
                recorder.localCalls.append((terminalID, promptID, answer))
                return await withCheckedContinuation { recorder.pending = $0 }
            },
            remote: { _, _, _, _ in PromptAnswerResult(outcome: .delivered) },
            onDelivered: { prompt, summary in recorder.delivered.append((prompt.promptID, summary)) })
        let prompt = permission
        let answer = allow
        let first = Task { await controller.submit(prompt, answer: answer) }
        for _ in 0..<200 where recorder.pending == nil { await Task.yield() }
        #expect(controller.state(for: "p1") == .sending)

        controller.forget(["p1"])
        recorder.pending?.resume(returning: PromptAnswerResult(outcome: .delivered))
        await first.value

        #expect(controller.state(for: "p1") == .waiting)
        #expect(recorder.delivered.isEmpty)
    }

    @Test func forgetDropsStateAndDraft() async {
        let recorder = Recorder()
        let controller = makeController(recorder)
        controller.updateDraft(for: "p1") { $0.denyReasonOpen = true }
        await controller.submit(permission, answer: allow)
        controller.forget(["p1"])
        #expect(controller.state(for: "p1") == .waiting)
        #expect(controller.draft(for: "p1") == Controller.Draft())
    }

    @Test func draftSurvivesCardRecreation() {
        let controller = makeController(Recorder())
        let question = PromptQuestion(text: "Which?", options: [.init(label: "A"), .init(label: "B")])
        controller.updateDraft(for: "q1") { $0.choose("B", in: question) }
        // A recycled cell asks again, by prompt id, with nothing of its own.
        let reread = controller.draft(for: "q1")
        #expect(reread.isChosen("B", in: question))
        #expect(controller.draft(for: "other") == Controller.Draft())
    }

    // MARK: - Answer assembly

    private let single = PromptQuestion(
        text: "Which?", header: "Pick", multiSelect: false,
        options: [.init(label: "A", description: "d"), .init(label: "B")])
    private let multi = PromptQuestion(
        text: "Features?", multiSelect: true,
        options: [.init(label: "X"), .init(label: "Y"), .init(label: "Z")])

    @Test func singleSelectAnswersTheChosenLabel() {
        var draft = Controller.Draft()
        draft.choose("A", in: single)
        draft.choose("B", in: single)
        #expect(Controller.questionAnswer(questions: [single], draft: draft)
                == .question(answers: ["Which?": "B"]))
    }

    @Test func questionAnswerJoinsMultiSelectWithCommaSpace() {
        var draft = Controller.Draft()
        draft.choose("Z", in: multi)
        draft.choose("X", in: multi)
        draft.choose("Y", in: multi)
        draft.choose("Y", in: multi)   // toggled back off
        #expect(Controller.questionAnswer(questions: [multi], draft: draft)
                == .question(answers: ["Features?": "X, Z"]), "labels join in option order")
    }

    @Test func multiSelectOtherContributesItsText() {
        var draft = Controller.Draft()
        draft.choose("X", in: multi)
        draft.setOtherText("  W  ", in: multi)
        #expect(Controller.questionAnswer(questions: [multi], draft: draft)
                == .question(answers: ["Features?": "X, W"]))
    }

    @Test func otherTextWinsForItsQuestion() {
        var draft = Controller.Draft()
        draft.choose("A", in: single)
        draft.setOtherText("something else", in: single)
        #expect(draft.isOtherChosen(in: single))
        #expect(!draft.isChosen("A", in: single), "typing into Other deselects the option")
        #expect(Controller.questionAnswer(questions: [single], draft: draft)
                == .question(answers: ["Which?": "something else"]))

        // Picking an option again takes Other back off.
        draft.choose("B", in: single)
        #expect(Controller.questionAnswer(questions: [single], draft: draft)
                == .question(answers: ["Which?": "B"]))
    }

    @Test func otherChosenButEmptyIsNoAnswer() {
        var draft = Controller.Draft()
        draft.chooseOther(in: single)
        draft.setOtherText("   ", in: single)
        #expect(Controller.questionAnswer(questions: [single], draft: draft) == nil)
    }

    @Test func incompleteDraftHasNoAnswer() {
        var draft = Controller.Draft()
        draft.choose("A", in: single)
        #expect(Controller.questionAnswer(questions: [single, multi], draft: draft) == nil,
                "every question needs a value")
        draft.choose("Y", in: multi)
        #expect(Controller.questionAnswer(questions: [single, multi], draft: draft)
                == .question(answers: ["Which?": "A", "Features?": "Y"]))
        #expect(Controller.questionAnswer(questions: [], draft: draft) == nil)
    }

    @Test func questionSummaryJoinsValuesInQuestionOrder() {
        let answer = PromptAnswer.question(answers: ["Features?": "X, Z", "Which?": "A"])
        #expect(Controller.summary(for: answer, questions: [single, multi]) == "A; X, Z")
    }

    // MARK: - Permission decisions

    @Test func permissionDecisionMapping() {
        #expect(Controller.permissionAnswer(.allow) == .permission(decision: .allow, message: nil))
        #expect(Controller.permissionAnswer(.allowForSession)
                == .permission(decision: .allowAlways, message: nil))
        #expect(Controller.permissionAnswer(.deny, denyReason: "  too risky ")
                == .permission(decision: .deny, message: "too risky"))
        #expect(Controller.permissionAnswer(.deny, denyReason: "   ")
                == .permission(decision: .deny, message: nil), "a blank reason sends no message")
        // The allow buttons ignore a reason typed into the deny field.
        #expect(Controller.permissionAnswer(.allow, denyReason: "x")
                == .permission(decision: .allow, message: nil))
    }

    @Test func permissionSummaries() {
        #expect(Controller.summary(for: .permission(decision: .allow, message: nil), questions: []) == "Allowed")
        #expect(Controller.summary(for: .permission(decision: .allowAlways, message: nil), questions: [])
                == "Allowed for this session")
        #expect(Controller.summary(for: .permission(decision: .deny, message: "x"), questions: []) == "Denied")
    }

    // MARK: - Footer precedence

    @Test func footerFollowsStateWhileOpen() {
        let prompt = permission
        #expect(PromptCardFooter.resolve(prompt, state: .waiting) == .controls)
        #expect(PromptCardFooter.resolve(prompt, state: .sending) == .sending)
        #expect(PromptCardFooter.resolve(prompt, state: .answeredElsewhere) == .answeredElsewhere)
        #expect(PromptCardFooter.resolve(prompt, state: .failed(message: "m", retryable: false))
                == .failed(message: "m", retryable: false))
    }

    @Test func footerForAHeldCardShowsItsPhase() {
        var answered = permission
        answered.phase = .answered(summary: "Denied")
        #expect(PromptCardFooter.resolve(answered, state: .waiting) == .answered(summary: "Denied"))
        var closed = permission
        closed.phase = .closed
        #expect(PromptCardFooter.resolve(closed, state: .waiting) == .answeredElsewhere)
    }

    @Test func footerForAReadOnlyCardShowsItsNote() {
        let readOnly = PendingPromptPresentation.remote(
            RemotePendingPrompt(id: "r1", kind: .permission, toolName: "Bash"),
            selection: Fix.selection, capabilities: ["events"], flagOn: true, now: Fix.when)
        #expect(PromptCardFooter.resolve(readOnly, state: .waiting) == .readOnly(note: "Attach to answer"))
    }
}
