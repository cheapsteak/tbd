import Foundation
import os
import TBDShared

private let remoteAnswerLogger = Logger(subsystem: "com.tbd.daemon", category: "remote")

/// `remote.answer` — the remote half of answering prompts from the transcript
/// (`docs/specs/2026-10-09-transcript-prompt-answer-design.md` § Remote
/// delivery). It follows `handleRemoteSendMessage` in shape: the same gates,
/// the same per-session lane, and the same three-way outcome that is never
/// retried.
extension RPCRouter {
    /// The contract's budget for `answer`.
    static let remoteAnswerTimeout: TimeInterval = 30

    /// The session has no mirror row, so there is no prompt to match the
    /// answer against.
    static let remoteAnswerNotMirroredRefusal = "session is not in the mirror; refresh and try again"

    /// Answers a remote session's open prompt through
    /// `answer <session_id> <prompt_id>`, the `PromptAnswer` JSON on stdin
    /// (`docs/remote-provider-contract.md` § `answer`). Returns a
    /// `PromptAnswerResult`.
    ///
    /// Refused, without invoking anything:
    /// - when remote backends or the cloud gate are off, as every
    ///   provider-named verb is;
    /// - while `config.transcriptPromptAnswerEnabled` is off;
    /// - unless the provider declares `answer` — a caller MUST NOT invoke an
    ///   undeclared verb;
    /// - when the provider's snapshot is stale;
    /// - when the session has no mirror row, or has exited;
    /// - when the answer does not fit the mirrored prompt (`invalid_params: …`).
    ///
    /// A prompt id that no longer matches the mirrored prompt answers
    /// `already_resolved` without a provider call: the dialog it named has
    /// closed. The `waiting_input` refusal `remote.sendMessage` applies is
    /// skipped here — answering that prompt is this verb's whole purpose.
    ///
    /// Runs in the same per-session lane as `remote.sendMessage`, so an answer
    /// never overlaps a typed message in one session's input.
    ///
    /// Outcomes, never retried. Exit 0 answers `.delivered`. The provider's
    /// `already_resolved` error answers `.alreadyResolved`. Any other non-zero
    /// exit is an RPC error carrying the provider's code and message
    /// (`invalid_params`, `not_found`, …). A call that ended without an exit
    /// status — the timeout fired, or the provider died of a signal — answers
    /// `.unknown`: the decision may already have reached the dialog.
    ///
    /// The daemon does not refresh the transcript afterwards; the app asks for
    /// that with `remote.transcriptSync`, as the composer does after a send.
    func handleRemoteAnswer(_ paramsData: Data, actor: ActuationActor? = nil) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteAnswerParams.self, from: paramsData)
        if let refusal = try await cloudGate(provider: params.provider) { return refusal }
        guard try await db.config.get().transcriptPromptAnswerEnabled else {
            return RPCResponse(error: Self.promptAnswerDisabledRefusal)
        }
        guard await declaredCapabilities(manager, provider: params.provider)
            .contains(RemoteCapability.answer) else {
            return Self.missingCapabilityResponse(
                provider: params.provider, capability: RemoteCapability.answer,
                section: "answer <session_id> <prompt_id>")
        }
        return try await remoteSendMessageSerializer.run(
            provider: params.provider, sessionID: params.sessionID
        ) {
            try await self.remoteAnswer(params, manager: manager, actor: actor)
        }
    }

    /// One serialized `remote.answer`, from the mirror checks to the actuation
    /// outcome.
    private func remoteAnswer(
        _ params: RemoteAnswerParams, manager: RemoteProviderManager, actor: ActuationActor?
    ) async throws -> RPCResponse {
        if await manager.hasStaleSnapshot(provider: params.provider) {
            return Self.staleSnapshotMutationResponse(provider: params.provider)
        }
        guard let row = try await db.remoteSessions.row(
            provider: params.provider, sessionID: params.sessionID) else {
            return RPCResponse(error: Self.remoteAnswerNotMirroredRefusal)
        }
        if row.gone
            || row.state == RemoteProcessState.exited.rawValue
            || row.agentState == RemoteAgentState.exited.rawValue {
            return RPCResponse(error: Self.sendMessageExitedRefusal)
        }
        guard let prompt = row.decodedPayload?.effectivePendingPrompt, prompt.id == params.promptID else {
            return try RPCResponse(result: PromptAnswerResult(outcome: .alreadyResolved))
        }
        if let invalid = Self.validationFailure(params.answer, against: prompt) {
            return RPCResponse(error: invalid.message)
        }

        let stdin = try Self.answerJSON(params.answer)
        let actuationID = try await beginActuation(
            .remoteAnswer, actor: actor,
            target: .remote(provider: params.provider, session: params.sessionID),
            message: String(data: stdin, encoding: .utf8))
        let result: ProviderResult
        do {
            result = try await manager.invoke(
                providerName: params.provider,
                verb: RemoteVerb.answer(sessionID: params.sessionID, promptID: params.promptID),
                stdin: stdin, timeout: Self.remoteAnswerTimeout,
                healthNeutralErrorCodes: Self.answerVerbErrorCodes)
        } catch let error as ProviderRunError {
            // No exit status: the decision may have reached the dialog before
            // the deadline killed the provider. Unknown, and never retried.
            remoteAnswerLogger.error(
                "remote.answer provider=\(params.provider, privacy: .public) timed out; outcome unknown")
            let message = Self.friendlyMessage(for: error, provider: params.provider)
            await finishActuation(actuationID, .transportFailed, error: "outcome unknown: \(message)")
            return try RPCResponse(result: PromptAnswerResult(outcome: .unknown))
        } catch {
            // Any other throw comes before the provider ran, so nothing was
            // answered. Recorded before it propagates.
            await finishActuation(actuationID, .transportFailed, error: "\(error)")
            throw error
        }
        if result.terminatedBySignal {
            remoteAnswerLogger.error(
                "remote.answer provider=\(params.provider, privacy: .public) died of signal \(result.exitCode, privacy: .public); outcome unknown")
            await finishActuation(
                actuationID, .transportFailed,
                error: "outcome unknown: provider died of signal \(result.exitCode)")
            return try RPCResponse(result: PromptAnswerResult(outcome: .unknown))
        }
        if result.failureClass != nil {
            let providerError = result.decodedError
            if providerError?.code == Self.alreadyResolvedCode {
                await finishActuation(actuationID, .refused(.notEligible), error: Self.alreadyResolvedCode)
                return try RPCResponse(result: PromptAnswerResult(outcome: .alreadyResolved))
            }
            let message = providerError.map { "\($0.code): \($0.message)" }
                ?? "answer failed (exit \(result.exitCode))"
            remoteAnswerLogger.error(
                "remote.answer provider=\(params.provider, privacy: .public) failed: \(message, privacy: .public)")
            let outcome: ActuationOutcome = providerError?.code == "not_found"
                ? .refused(.notFound) : .transportFailed
            await finishActuation(actuationID, outcome, error: message)
            return RPCResponse(error: message)
        }
        await finishActuation(actuationID, .dispatched)
        return try RPCResponse(result: PromptAnswerResult(outcome: .delivered))
    }

    /// The provider error code for a prompt that is no longer pending.
    static let alreadyResolvedCode = "already_resolved"

    /// The `answer` verb's own error codes. Each describes this one answer —
    /// the prompt moved on, the payload did not fit, the session is unknown —
    /// and never the provider, so none counts against provider health.
    static let answerVerbErrorCodes: Set<String> = [alreadyResolvedCode, "invalid_params", "not_found"]

    /// Why `answer` does not fit the mirrored prompt, or nil when it does —
    /// the same check `prompt.answer` makes locally. A question prompt's
    /// answers are keyed on each question's full text, read through
    /// `effectiveQuestions` exactly as the card reads them (so a prompt whose
    /// questions arrive only in `tool_input` validates too); `allow_always`
    /// needs the "don't ask again" suggestions the prompt offered.
    static func validationFailure(
        _ answer: PromptAnswer, against prompt: RemotePendingPrompt
    ) -> PromptAnswerValidation? {
        let questions = prompt.effectiveQuestions
        let hasSuggestions = PermissionSuggestionSummary.sessionScoped(fromJSON: prompt.suggestionsJSON) != nil
        do {
            try answer.validate(kind: prompt.kind, questions: questions, hasSuggestions: hasSuggestions)
            return nil
        } catch let validation as PromptAnswerValidation {
            return validation
        } catch {
            return .kindMismatch
        }
    }

    /// The answer as the verb's stdin: compact JSON with sorted keys, so the
    /// actuation row records exactly the bytes the provider was handed.
    static func answerJSON(_ answer: PromptAnswer) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(answer)
    }
}
