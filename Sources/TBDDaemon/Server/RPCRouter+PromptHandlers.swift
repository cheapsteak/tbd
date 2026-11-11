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
    /// The setting for answering prompts is off. TBD's own words with its
    /// code (`RPCErrorCode.promptAnswerOff`).
    static let promptAnswerDisabledRefusal = PromptAnswerRefusal.disabled
    /// The setting could not be read. TBD's own words with its code
    /// (`RPCErrorCode.promptAnswerSettingUnread`).
    static let promptAnswerSettingUnreadRefusal = PromptAnswerRefusal.settingUnread
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

    /// Nil while `config.transcriptPromptAnswerEnabled` is on, otherwise the
    /// refusal `method` returns before it acts on the answer:
    /// `promptAnswerDisabledRefusal` while the setting is off, and
    /// `promptAnswerSettingUnreadRefusal` when the config row could not be
    /// read (`configForAnswer(method:)`).
    func promptAnswerSettingRefusal(method: String) async throws -> RPCResponse? {
        guard let config = try await configForAnswer(method: method) else {
            return Self.promptAnswerSettingUnreadRefusal.response
        }
        return Self.promptAnswerSettingRefusal(config)
    }

    /// Nil while `config` has the setting for answering prompts on,
    /// otherwise `promptAnswerDisabledRefusal`.
    static func promptAnswerSettingRefusal(_ config: Config) -> RPCResponse? {
        config.transcriptPromptAnswerEnabled ? nil : promptAnswerDisabledRefusal.response
    }

    /// The config row an answer's checks read, before the answer acts; nil,
    /// logged, when the read failed, which the caller refuses with
    /// `promptAnswerSettingUnreadRefusal`. So a failed read refuses the
    /// answer, as the setting being off does, rather than failing the call,
    /// which a caller cannot tell from a failure after the answer went out.
    /// Only this read becomes a refusal, and a cancelled read still throws.
    func configForAnswer(method: String) async throws -> Config? {
        do {
            return try await db.config.get()
        } catch let cancelled as CancellationError {
            throw cancelled
        } catch {
            promptLog.error(
                "\(method, privacy: .public) refused: could not read the setting for answering prompts: \(String(describing: type(of: error)), privacy: .public): \(error.localizedDescription, privacy: .private)")
            return nil
        }
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
    /// Errors: the flag is off (`promptAnswerDisabledRefusal`), the flag
    /// could not be read (`promptAnswerSettingUnreadRefusal`, retryable), the
    /// caller is not the TBD app (`promptAnswerNotFromAppRefusal`), no wait request
    /// picked the decision up in time (`promptHookDetachedRefusal`,
    /// retryable), or the answer does not fit the prompt (`invalid_params: …`,
    /// with `RPCErrorCode.answerDoesNotFit`). The flag's two refusals carry
    /// their codes too (`PromptAnswerRefusal`).
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
        if let refusal = try await promptAnswerSettingRefusal(method: RPCMethod.promptAnswer) {
            return refusal
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
            return RPCResponse(error: validation.message, code: validation.code.rawValue)
        }
    }
}
