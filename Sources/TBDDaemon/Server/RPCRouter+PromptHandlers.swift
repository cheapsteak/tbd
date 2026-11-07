import Foundation
import os
import TBDShared

private let promptLog = Logger(subsystem: "com.tbd.daemon", category: "pendingPrompt")

/// Where an answer's authority to decide a prompt in a person's name comes
/// from. The answer's flag is checked first either way.
enum AnswerAuthority: Sendable {
    /// A request on the daemon socket. `promptAnswerPeerRefusal` must find
    /// that the connection is the TBD app's own; a nil context is refused.
    case socket(RPCConnectionContext?)
    /// A gesture from a paired phone, which the phone bridge has verified
    /// against its pairing. There is no socket peer, so no socket check runs.
    /// The answer's actuation row records `ActuationActor.phone(deviceID:)`
    /// with this device, whatever actor the caller passes, so the recorded
    /// device and the authority cannot disagree.
    case pairedPhone(deviceID: UUID)
}

/// Answering prompts from the transcript
/// (`docs/specs/2026-10-20-mod-channel-prompt-answer-design.md`).
///
/// A "prompt" here is an open Claude Code dialog — an `AskUserQuestion`
/// picker or a tool permission prompt — held in `PendingPromptStore`. It is
/// unrelated to `PendingPromptCoordinator`'s queued first message.
///
/// The session's TBD mod opens, waits on, receipts and closes prompts over
/// the mod channel. The app answers through `prompt.answer`, which returns
/// once the mod has receipted the decision, the terminal has answered first,
/// or the wait for either ran out.
extension RPCRouter {
    static let promptAnswerDisabledRefusal =
        "answering prompts from the transcript is off (config.transcript_prompt_answer_enabled)"
    /// No wait request picked the decision up within the pickup window, as
    /// when the session's mod is reconnecting. The prompt stays open.
    static let promptHookDetachedRefusal = "the prompt's session is not picking up answers right now; try again"
    static let promptAnswerNotFromAppRefusal = "prompts are answered only from the TBD app"

    /// Nil when this connection is the TBD app's own, otherwise the refusal to
    /// return.
    ///
    /// `prompt.answer` and `remote.answer` decide a permission prompt in a
    /// person's name, so they take the same authority `terminal.send`'s
    /// envelope suppression does, through the same check: the kernel-named
    /// peer pid must be the recorded app identity, re-verified
    /// (`authenticatesEnvelopeSuppression`). A nil context — every non-socket
    /// caller — is refused, as is any other process on the socket. A paired
    /// phone's `.pairedPhone` authority never reaches this check.
    func promptAnswerPeerRefusal(
        connection: RPCConnectionContext?, method: String
    ) async -> RPCResponse? {
        switch await authenticatesEnvelopeSuppression(connection: connection) {
        case .authenticated:
            return nil
        case .refused(let reason):
            promptLog.debug(
                "\(method, privacy: .public) refused: \(reason, privacy: .public)")
            return RPCResponse(error: Self.promptAnswerNotFromAppRefusal)
        }
    }

    private func promptAnswerEnabled() async throws -> Bool {
        try await db.config.get().transcriptPromptAnswerEnabled
    }

    /// Publishes each terminal whose prompt set changed.
    func broadcastPendingPrompts(terminals: Set<UUID>) async {
        for terminalID in terminals {
            await broadcastPendingPrompts(terminalID: terminalID)
        }
    }

    // MARK: - prompt.answer

    /// The app's answer to a local prompt. Returns a `PromptAnswerResult`:
    /// - `delivered` – the mod receipted the decision.
    /// - `already_resolved` – the prompt was gone or answered, or the
    ///   terminal answered first.
    /// - `unknown` – no receipt within the store's ack timeout; the decision
    ///   may have reached Claude.
    ///
    /// Errors: the flag is off (`promptAnswerDisabledRefusal`), the caller is
    /// not the TBD app (`promptAnswerNotFromAppRefusal`), no wait request
    /// picked the decision up in time (`promptHookDetachedRefusal`,
    /// retryable), or the answer does not fit the prompt (`invalid_params: …`).
    func handlePromptAnswer(
        _ paramsData: Data, actor: ActuationActor?, connection: RPCConnectionContext?
    ) async throws -> RPCResponse {
        let p = try decoder.decode(PromptAnswerParams.self, from: paramsData)
        return try await answerPrompt(p, actor: actor, authority: .socket(connection))
    }

    /// The core of `prompt.answer`, for every caller past its own edge: the
    /// socket handler above and the phone bridge. Same results and errors as
    /// `handlePromptAnswer`, except that it never throws a decode error (the
    /// handler decodes) and, under `.pairedPhone`, never returns
    /// `promptAnswerNotFromAppRefusal`. `authority` decides whether the socket
    /// peer check runs, right after the flag check, and whose answer the row
    /// records: `actor` under `.socket`, and under `.pairedPhone` the phone
    /// that authority names, whatever `actor` says.
    func answerPrompt(
        _ p: PromptAnswerParams, actor: ActuationActor?, authority: AnswerAuthority
    ) async throws -> RPCResponse {
        guard try await promptAnswerEnabled() else {
            return RPCResponse(error: Self.promptAnswerDisabledRefusal)
        }
        let recordedActor: ActuationActor?
        switch authority {
        case .socket(let connection):
            if let refusal = await promptAnswerPeerRefusal(
                connection: connection, method: RPCMethod.promptAnswer) {
                return refusal
            }
            recordedActor = actor
        case .pairedPhone(let deviceID):
            recordedActor = ActuationActor.phone(deviceID: deviceID)
        }
        let terminal = try? await db.terminals.get(id: p.terminalID)
        let target = ActuationTarget(
            worktree: terminal?.worktreeID.uuidString, terminal: p.terminalID.uuidString)
        let answerJSON = (try? JSONEncoder().encode(p.answer)).flatMap { String(data: $0, encoding: .utf8) }
        let actuationID = try await beginActuation(
            .promptAnswer, actor: recordedActor, target: target, message: answerJSON)

        guard terminal != nil else {
            await finishActuation(actuationID, .refused(.notFound), error: "terminal not found")
            return try RPCResponse(result: PromptAnswerResult(outcome: .alreadyResolved))
        }

        let (outcome, changed) = await pendingQuestions.answer(
            terminalID: p.terminalID, promptID: p.promptID, answer: p.answer)
        await broadcastPendingPrompts(terminals: changed)
        promptLog.debug(
            "prompt.answer id=\(p.promptID, privacy: .public) outcome=\(String(describing: outcome), privacy: .public)")

        switch outcome {
        case .delivered:
            await finishActuation(actuationID, .dispatched)
            return try RPCResponse(result: PromptAnswerResult(outcome: .delivered))
        case .alreadyResolved:
            await finishActuation(actuationID, .refused(.notEligible), error: "already_resolved")
            return try RPCResponse(result: PromptAnswerResult(outcome: .alreadyResolved))
        case .deliveryUnconfirmed:
            await finishActuation(actuationID, .transportFailed, error: "outcome unknown: no delivery receipt")
            return try RPCResponse(result: PromptAnswerResult(outcome: .unknown))
        case .hookDetached:
            await finishActuation(actuationID, .refused(.notEligible), error: Self.promptHookDetachedRefusal)
            return RPCResponse(error: Self.promptHookDetachedRefusal)
        case .invalid(let validation):
            await finishActuation(actuationID, .refused(.notEligible), error: validation.message)
            return RPCResponse(error: validation.message)
        }
    }
}
