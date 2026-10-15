import Foundation
import os
import TBDShared

private let promptLog = Logger(subsystem: "com.tbd.daemon", category: "pendingPrompt")

/// Answering prompts from the transcript
/// (`docs/specs/2026-10-09-transcript-prompt-answer-design.md`).
///
/// A "prompt" here is an open Claude Code dialog — an `AskUserQuestion`
/// picker or a tool permission prompt — held in `PendingPromptStore`. It is
/// unrelated to `PendingPromptCoordinator`'s queued first message.
///
/// The hook side (`tbd prompt note`, `tbd prompt wait`) drives four methods:
/// - `prompt.note` – `PreToolUse` / `PostToolUse` record a tool call.
/// - `prompt.register` – the `PermissionRequest` hook registers its dialog.
/// - `prompt.await` – the same hook's long-poll, served only by
///   `SocketServer` around the RPC concurrency limiter (`awaitPrompt`).
/// - `prompt.ack` – the hook reports that it printed the decision.
///
/// The app answers through `prompt.answer`, which returns once the hook has
/// acknowledged delivery.
extension RPCRouter {
    static let promptAnswerDisabledRefusal =
        "answering prompts from the transcript is off (config.transcript_prompt_answer_enabled)"
    static let promptHookDetachedRefusal = "the prompt's hook is reconnecting; try again"
    static let promptAwaitSocketOnlyRefusal = "prompt.await is served only on the daemon socket"
    static let promptAnswerNotFromAppRefusal = "prompts are answered only from the TBD app"

    /// Nil when this connection is the TBD app's own, otherwise the refusal to
    /// return.
    ///
    /// `prompt.answer` and `remote.answer` decide a permission prompt in a
    /// person's name, so they take the same authority `terminal.send`'s
    /// envelope suppression does, through the same check: the kernel-named
    /// peer pid must be the recorded app identity, re-verified
    /// (`authenticatesEnvelopeSuppression`). A nil context — every non-socket
    /// caller, including the HTTP transport — is refused, as is any other
    /// process on the socket.
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
    private func broadcastPendingPrompts(terminals: Set<UUID>) async {
        for terminalID in terminals {
            await broadcastPendingPrompts(terminalID: terminalID)
        }
    }

    // MARK: - prompt.note

    /// Records a `PreToolUse` note, or applies a `PostToolUse` /
    /// `PostToolUseFailure` one. Never a decision.
    ///
    /// While the flag is off a `.pre` note is dropped: sessions that started
    /// while it was on still carry the hook until they restart, and no new
    /// prompt will register to pair with it. A `.post` note is applied
    /// regardless, because prompts registered before the flag was turned off
    /// are still open, their hooks still parked, and a post is how the
    /// terminal's answer resolves them.
    func handlePromptNote(_ paramsData: Data) async throws -> RPCResponse {
        let p = try decoder.decode(PromptNoteParams.self, from: paramsData)
        if p.phase == .pre {
            guard try await promptAnswerEnabled() else { return .ok() }
        }
        let changed = await pendingQuestions.note(
            terminalID: p.terminalID, sessionID: p.sessionID, phase: p.phase,
            toolUseID: p.toolUseID, toolName: p.toolName, inputHash: p.inputHash)
        await broadcastPendingPrompts(terminals: changed)

        // Hook traffic, counted like the AskUserQuestion hooks count theirs:
        // the session counter by the claimed terminal, the activity ledger
        // only when the row (and so its worktree) still resolves.
        let observedAt = now()
        await sessionCounters.recordHookEvent(terminalID: p.terminalID, at: observedAt)
        if let terminal = try? await db.terminals.get(id: p.terminalID) {
            await activityLedger.recordHookEvent(
                terminalID: terminal.id, worktreeID: terminal.worktreeID, at: observedAt)
        }
        return .ok()
    }

    // MARK: - prompt.register

    /// Registers the dialog a `PermissionRequest` hook is holding. While the
    /// flag is off the reply is `.disabled` and the hook exits silently.
    func handlePromptRegister(_ paramsData: Data) async throws -> RPCResponse {
        let p = try decoder.decode(PromptRegisterParams.self, from: paramsData)
        guard try await promptAnswerEnabled() else {
            return try RPCResponse(result: PromptRegisterResult.disabled)
        }
        let (outcome, changed) = await pendingQuestions.register(p)
        await broadcastPendingPrompts(terminals: changed)
        switch outcome {
        case .registered(let promptID, let toolUseID):
            return try RPCResponse(result: PromptRegisterResult.registered(promptID: promptID, toolUseID: toolUseID))
        }
    }

    // MARK: - prompt.await (socket only)

    /// Suspends until the prompt resolves and returns a `PromptAwaitReply`.
    ///
    /// Reached only from `SocketServer`, which owns the connection: `token`
    /// names this waiter, `connectionClosed` reports whether that connection
    /// has closed, and the socket calls `promptAwaitConnectionClosed(token:)`
    /// when it does. An `.answered` reply carries `token` as its delivery
    /// token; the hook acks it through `prompt.ack`, and the socket reports a
    /// failed write through `promptAwaitDelivered(token:delivered:)`.
    ///
    /// Not gated on the flag: a prompt only exists if a register was accepted
    /// while the flag was on, and an unknown id answers `.resolvedElsewhere`
    /// at once.
    func awaitPrompt(
        _ paramsData: Data, token: UUID,
        connectionClosed: @escaping @Sendable () -> Bool = { false }
    ) async -> RPCResponse {
        let p: PromptAwaitParams
        do {
            p = try decoder.decode(PromptAwaitParams.self, from: paramsData)
        } catch {
            return RPCResponse(error: "Failed to decode prompt.await params: \(error.localizedDescription)")
        }
        let terminalID = await pendingQuestions.terminalID(ofPrompt: p.promptID)
        let result = await pendingQuestions.awaitResolution(
            promptID: p.promptID, token: token, connectionClosed: connectionClosed)
        // A close that landed before the waiter attached is resolved inside
        // `awaitResolution` rather than by `waiterClosed`, so its broadcast
        // is owed here. Re-sending an unchanged set is harmless.
        if connectionClosed(), let terminalID {
            await broadcastPendingPrompts(terminalID: terminalID)
        }
        let reply: PromptAwaitReply
        switch result {
        case .answered:
            reply = PromptAwaitReply(result: result, deliveryToken: token)
        case .resolvedElsewhere:
            reply = PromptAwaitReply(result: result, deliveryToken: nil)
        }
        do {
            return try RPCResponse(result: reply)
        } catch {
            // `PromptAwaitReply` is strings and a UUID; encoding cannot fail.
            // Should it, the hook gets an error and prints nothing, and the
            // socket reports the answer undelivered.
            return RPCResponse(error: "Failed to encode prompt.await reply: \(error.localizedDescription)")
        }
    }

    /// The awaiting connection closed. Harmless after a delivered answer,
    /// whose record is already answered or gone.
    func promptAwaitConnectionClosed(token: UUID) async {
        let changed = await pendingQuestions.waiterClosed(token: token)
        await broadcastPendingPrompts(terminals: changed)
    }

    /// The socket's verdict on writing an `.answered` reply. Only a failure is
    /// reported this way; success is the hook's own `prompt.ack`, sent after
    /// it has printed the decision.
    func promptAwaitDelivered(token: UUID, delivered: Bool) async {
        await pendingQuestions.acknowledgeDelivery(token: token, delivered: delivered)
    }

    // MARK: - prompt.ack

    /// The hook printed the decision (`delivered: true`) or could not
    /// (`false`). Unknown and late tokens are ignored by the store. Not gated
    /// on the flag: an answer already handed to a hook must be able to settle.
    func handlePromptAck(_ paramsData: Data) async throws -> RPCResponse {
        let p = try decoder.decode(PromptAckParams.self, from: paramsData)
        await pendingQuestions.acknowledgeDelivery(token: p.token, delivered: p.delivered)
        return .ok()
    }

    // MARK: - prompt.answer

    /// The app's answer to a local prompt. Returns a `PromptAnswerResult`:
    /// - `delivered` – the hook acknowledged the decision.
    /// - `already_resolved` – the prompt was gone or answered, or the hook
    ///   reported it never got the decision.
    /// - `unknown` – no acknowledgement within the store's ack timeout; the
    ///   decision may have reached Claude.
    ///
    /// Errors: the flag is off (`promptAnswerDisabledRefusal`), the caller is
    /// not the TBD app (`promptAnswerNotFromAppRefusal`), no hook is attached
    /// right now (`promptHookDetachedRefusal`, retryable), or the answer does
    /// not fit the prompt (`invalid_params: …`).
    func handlePromptAnswer(
        _ paramsData: Data, actor: ActuationActor?, connection: RPCConnectionContext?
    ) async throws -> RPCResponse {
        let p = try decoder.decode(PromptAnswerParams.self, from: paramsData)
        guard try await promptAnswerEnabled() else {
            return RPCResponse(error: Self.promptAnswerDisabledRefusal)
        }
        if let refusal = await promptAnswerPeerRefusal(
            connection: connection, method: RPCMethod.promptAnswer) {
            return refusal
        }
        let terminal = try? await db.terminals.get(id: p.terminalID)
        let target = ActuationTarget(
            worktree: terminal?.worktreeID.uuidString, terminal: p.terminalID.uuidString)
        let answerJSON = (try? JSONEncoder().encode(p.answer)).flatMap { String(data: $0, encoding: .utf8) }
        let actuationID = try await beginActuation(
            .promptAnswer, actor: actor, target: target, message: answerJSON)

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
            await finishActuation(actuationID, .transportFailed, error: "outcome unknown: no delivery ack")
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
