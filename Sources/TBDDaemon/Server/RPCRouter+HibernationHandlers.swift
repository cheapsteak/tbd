import Foundation
import TBDShared

extension RPCRouter {

    /// The message for a wake aimed at an unparked row whose holder's job has
    /// exited. Shared by `terminal.wake` and `terminal.resume` so the two verbs
    /// cannot describe the same state differently. Always names
    /// `tbd terminal conversation`, which still reads a dead session's messages
    /// — context can be rebuilt before the terminal is closed.
    static let unparkedWakeMessage = """
        TBD's row says this terminal is awake, but its holder-backed session has exited — so \
        nothing was woken and any prompt was NOT delivered. Its conversation is still readable \
        with `tbd terminal conversation <id>`, so context can be rebuilt before closing it.
        """

    /// `terminal.hibernate` — manually hibernate one Claude terminal (end its
    /// process, keep its row resumable). Honors the running/permission rails. It
    /// does not wait for the session mod to vouch for an unsent draft: a
    /// manual park of a session whose mod is not confirmed goes ahead.
    func handleTerminalHibernate(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalHibernateParams.self, from: paramsData)
        let actuationID = try await beginActuation(
            .terminalHibernate, actor: actor,
            target: await resolvedTerminalTarget(params.terminalID))
        let result = await hibernationCoordinator.manualHibernate(
            terminalID: params.terminalID)
        await finishActuation(
            actuationID, ActuationOutcome.classify(result),
            error: ActuationOutcome.detail(result))
        switch result {
        case .ok:
            // Hibernating cancels any pending auto-resume inside the
            // coordinator (spec §Cancellation); wake the scheduler so it
            // re-reads pending rows instead of sleeping until a stale fire time.
            await limitResumeScheduler?.wake()
            return .ok()
        case .alreadyHibernated:
            return .ok()
        case .notEligible(let reason):
            return RPCResponse(error: reason)
        case .onTmux(let reason):
            return RPCResponse(error: reason, code: RPCErrorCode.terminalOnTmux.rawValue)
        case .notFound:
            return RPCResponse(error: "Terminal not found")
        }
    }

    /// The success payload for a wake outcome, or nil for an outcome that is an
    /// RPC error rather than a result.
    ///
    /// Pure and static so the rows that matter — woken with an id, woken
    /// without one, and each no-op — are statable without a
    /// coordinator, a database or a tmux server.
    static func wakeResultPayload(for result: WakeResult) -> TerminalWakeResult? {
        switch result {
        case .ok(let incarnationID):
            return TerminalWakeResult(woken: true, sessionIncarnationID: incarnationID)
        case .notHibernated, .inFlight:
            // Benign no-ops for an idempotent wake — `woken: false` so an
            // autonomous caller knows its `prompt` was NOT delivered (the
            // terminal is live; pasting into it now could hit a human session),
            // and no incarnation, because no spawn happened to name.
            return TerminalWakeResult(woken: false)
        case .conditionNotMet:
            // Not an error: a caller that names a condition expects some rows to
            // stop meeting it, and no spawn happened here either.
            return TerminalWakeResult(woken: false)
        case .sessionGone, .notFound, .noSessionID, .notAClaudeTab, .respawnFailed,
            .onTmux, .worktreeMissing, .profileMissing:
            // RPC errors, not results — the caller-facing switch in
            // handleTerminalWake maps each to its own RPCResponse(error:).
            // Named explicitly (not `default:`) so a new WakeResult case must
            // be classified deliberately in BOTH switches.
            return nil
        }
    }

    /// `terminal.wake` — respawn `claude --resume <id>` (or the Codex resume)
    /// for a parked terminal on the pty holder. Idempotent.
    ///
    /// A person's wake of a row parked on the tmux transport moves it to the
    /// pty holder first and then wakes it there (`moveParkedTmuxRowBeforeWake`).
    /// A rail's wake of one is refused by the coordinator and moves nothing.
    ///
    /// `condition` is for the in-process caller that chose its rows earlier, the
    /// session restore pass. `terminal.wake` has no parameter for it.
    func handleTerminalWake(
        _ paramsData: Data, actor: ActuationActor? = nil,
        condition: SessionRestoreCondition? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalWakeParams.self, from: paramsData)
        let actuationID = try await beginActuation(
            .terminalWake, actor: actor,
            target: await resolvedTerminalTarget(params.terminalID),
            prompt: params.prompt)
        // Start admission: checked only when this wake would start an agent.
        // A wake of a live terminal falls through to its no-op answer below.
        if let held = await holdWakeIfDenied(
            actuationID, actor: actor, terminalID: params.terminalID) {
            return held
        }
        if let refused = await moveParkedTmuxRowBeforeWake(
            actuationID, actor: actor, terminalID: params.terminalID) {
            return refused
        }
        let result = await hibernationCoordinator.wake(
            terminalID: params.terminalID, cols: params.cols, rows: params.rows,
            allowDefaultProfileFallback: params.fallbackToDefaultProfile ?? false,
            initialPrompt: params.prompt,
            condition: condition
        )
        await finishActuation(
            actuationID, ActuationOutcome.classify(result),
            error: ActuationOutcome.detail(result))
        if let payload = Self.wakeResultPayload(for: result) {
            return try RPCResponse(result: payload)
        }
        switch result {
        case .sessionGone:
            // NOT a benign no-op: the row claims awake but its session has
            // exited, so there was nothing live to deliver `prompt` to. An
            // error (not `woken: false`) is what lets an autonomous caller tell
            // this apart from "already awake and healthy".
            return RPCResponse(
                error: RPCRouter.unparkedWakeMessage,
                code: RPCErrorCode.terminalSessionGone.rawValue)
        case .notFound:
            return RPCResponse(error: "Terminal not found")
        case .noSessionID:
            return RPCResponse(error: "No session ID to resume")
        case .notAClaudeTab(let kind):
            return RPCResponse(error: ClaudeResumeDecision.notAClaudeTabReason(kind))
        case .respawnFailed(let reason):
            // The terminal row exists, and the wake stopped for one of the
            // causes `WakeResult.respawnFailed` lists: a holder spawn that
            // failed, or a decline that started nothing. Surface the real
            // cause, never "Terminal not found".
            return RPCResponse(error: reason)
        case .onTmux(let reason):
            return RPCResponse(error: reason, code: RPCErrorCode.terminalOnTmux.rawValue)
        case .worktreeMissing(let path):
            return RPCResponse(error: "Worktree directory missing on disk: \(path). Restore the directory (or relocate the repo), then retry — the session stays parked and resumable.")
        case .profileMissing(let profileID):
            return RPCResponse(
                error: "This session was pinned to an account profile (\(profileID.uuidString)) that no longer exists. It stays parked and resumable — wake it on your default account, or restore the profile and retry.",
                code: RPCErrorCode.profileMissing.rawValue)
        case .ok, .notHibernated, .inFlight, .conditionNotMet:
            // Unreachable: `wakeResultPayload` returns non-nil for exactly
            // these cases and this function already returned above.
            // Kept explicit (rather than `default:`) so a new WakeResult case
            // added later must be classified deliberately in BOTH switches.
            //
            // Fails SOFT rather than trapping. If the two switches ever drift
            // apart, the caller gets an error naming the drift and the daemon —
            // which is serving every other session on this machine — keeps
            // running. A `preconditionFailure` here would take the whole fleet
            // down over one wake.
            return RPCResponse(
                error: "terminal.wake produced an unclassified result (\(result)) — this is a "
                    + "daemon bug: the wake may have happened. Re-read the terminal's state "
                    + "before retrying.")
        }
    }

    /// `terminal.setKeepWarm` — pin/unpin a terminal against auto-hibernation.
    func handleTerminalSetKeepWarm(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalSetKeepWarmParams.self, from: paramsData)
        let ok = await hibernationCoordinator.setKeepWarm(
            terminalID: params.terminalID, keepWarm: params.keepWarm
        )
        return ok ? .ok() : RPCResponse(error: "Terminal not found")
    }

    /// `config.setAutoHibernate` — master enable + idle-timeout minutes. The
    /// idle sweep is automatic parking, which holds the composer-draft feature
    /// on, so the write re-syncs the plugin when it changes the features on.
    func handleConfigSetAutoHibernate(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetAutoHibernateParams.self, from: paramsData)
        try await writeAffectingAutomaticParking {
            try await db.config.setAutoHibernate(
                enabled: params.enabled, idleMinutes: params.idleMinutes)
        }
        // Reuse the config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }
}
