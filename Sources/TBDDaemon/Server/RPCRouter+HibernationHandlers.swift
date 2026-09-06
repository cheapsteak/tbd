import Foundation
import TBDShared

extension RPCRouter {

    /// The message for a wake aimed at an unparked row whose pane disagrees.
    /// Shared by `terminal.wake` and `terminal.resume` so the two verbs cannot
    /// describe the same state differently. Always names
    /// `tbd terminal conversation`, which still reads a dead session's messages
    /// — context can be rebuilt before the terminal is closed.
    ///
    /// An empty `paneID` is a holder-backed row rather than a nameless pane:
    /// those carry `tmuxPaneID == ""` by construction, and the classification
    /// that produced this result asked the process table, not tmux. Naming "its
    /// tmux pane ()" there would send a reader looking for a coordinate that
    /// was never supposed to exist.
    static func unparkedWakeMessage(
        paneID: String, detail: UnparkedPaneDisagreement
    ) -> String {
        let subject = paneID.isEmpty
            ? "its holder-backed session"
            : "its tmux pane (\(paneID))"
        let cause: String
        switch detail {
        case .paneMissing:
            cause = "\(subject) is gone"
        case .processExited:
            cause = paneID.isEmpty
                ? "\(subject) has exited"
                : "\(subject) is still there but its process has exited"
        case .paneBelongsToAnotherTerminal(let actual):
            cause = paneID.isEmpty
                ? "\(subject) now belongs to a different terminal (\(actual))"
                : "its pane coordinate (\(paneID)) now points at a different terminal (\(actual))"
        }
        return """
            TBD's row says this terminal is awake, but \(cause) — so nothing was woken and any \
            prompt was NOT delivered. Its conversation is still readable with `tbd terminal \
            conversation <id>`, so context can be rebuilt before closing it.
            """
    }

    /// `terminal.hibernate` — manually hibernate one Claude terminal (kill its
    /// process, keep the tmux window). Honors the running/permission rails.
    func handleTerminalHibernate(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalHibernateParams.self, from: paramsData)
        let actuationID = try await beginActuation(
            .terminalHibernate, actor: actor,
            target: await resolvedTerminalTarget(params.terminalID))
        let result = await hibernationCoordinator.manualHibernate(terminalID: params.terminalID)
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
        case .notFound:
            return RPCResponse(error: "Terminal not found")
        }
    }

    /// The success payload for a wake outcome, or nil for an outcome that is an
    /// RPC error rather than a result.
    ///
    /// Pure and static so the four rows that matter — woken with an id, woken
    /// without one, and each idempotent no-op — are statable without a
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
        case .sessionGone, .notFound, .noSessionID, .respawnFailed, .worktreeMissing,
            .profileMissing, .holderTransport, .paneBusy:
            // RPC errors, not results — the caller-facing switch in
            // handleTerminalWake maps each to its own RPCResponse(error:).
            // Named explicitly (not `default:`) so a new WakeResult case must
            // be classified deliberately in BOTH switches.
            return nil
        }
    }

    /// `terminal.wake` — respawn `claude --resume <id>` in the hibernated
    /// terminal's kept-alive window. Idempotent.
    func handleTerminalWake(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalWakeParams.self, from: paramsData)
        let actuationID = try await beginActuation(
            .terminalWake, actor: actor,
            target: await resolvedTerminalTarget(params.terminalID),
            prompt: params.prompt)
        let result = await hibernationCoordinator.wake(
            terminalID: params.terminalID, cols: params.cols, rows: params.rows,
            allowDefaultProfileFallback: params.fallbackToDefaultProfile ?? false,
            initialPrompt: params.prompt
        )
        await finishActuation(
            actuationID, ActuationOutcome.classify(result),
            error: ActuationOutcome.detail(result))
        if let payload = Self.wakeResultPayload(for: result) {
            return try RPCResponse(result: payload)
        }
        switch result {
        case .sessionGone(let paneID, let detail):
            // NOT a benign no-op: the row claims awake but its pane disagrees,
            // so there was nothing live to deliver `prompt` to. An error (not
            // `woken: false`) is what lets an autonomous caller tell this apart
            // from "already awake and healthy".
            return RPCResponse(
                error: RPCRouter.unparkedWakeMessage(paneID: paneID, detail: detail),
                code: RPCErrorCode.terminalSessionGone.rawValue)
        case .notFound:
            return RPCResponse(error: "Terminal not found")
        case .noSessionID:
            return RPCResponse(error: "No session ID to resume")
        case .respawnFailed(let reason):
            // The terminal row exists — the tmux respawn/recreate failed.
            // Surface the real failure, never "Terminal not found".
            return RPCResponse(error: reason)
        case .worktreeMissing(let path):
            return RPCResponse(error: "Worktree directory missing on disk: \(path). Restore the directory (or relocate the repo), then retry — the session stays parked and resumable.")
        case .profileMissing(let profileID):
            return RPCResponse(
                error: "This session was pinned to an account profile (\(profileID.uuidString)) that no longer exists. It stays parked and resumable — wake it on your default account, or restore the profile and retry.",
                code: RPCErrorCode.profileMissing.rawValue)
        case .holderTransport:
            return RPCResponse(error: HibernationCoordinator.holderTransportRefusal)
        case .paneBusy(let pid):
            return RPCResponse(error: HibernationCoordinator.paneBusyRefusal(pid: pid))
        case .ok, .notHibernated, .inFlight:
            // Unreachable: `wakeResultPayload` returns non-nil for exactly
            // these three cases and this function already returned above.
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

    /// `config.setAutoHibernate` — master enable + idle-timeout minutes.
    func handleConfigSetAutoHibernate(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetAutoHibernateParams.self, from: paramsData)
        try await db.config.setAutoHibernate(enabled: params.enabled, idleMinutes: params.idleMinutes)
        // Reuse the config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }
}
