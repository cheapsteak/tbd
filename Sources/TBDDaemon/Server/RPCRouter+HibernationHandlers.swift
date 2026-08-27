import Foundation
import TBDShared

extension RPCRouter {

    /// The message for a wake aimed at an unparked row whose pane disagrees.
    /// Shared by `terminal.wake` and `terminal.resume` so the two verbs cannot
    /// describe the same state differently. Always names
    /// `tbd terminal conversation`, which still reads a dead session's messages
    /// — context can be rebuilt before the terminal is closed.
    static func unparkedWakeMessage(
        paneID: String, detail: UnparkedPaneDisagreement
    ) -> String {
        let cause: String
        switch detail {
        case .paneMissing:
            cause = "its tmux pane (\(paneID)) is gone"
        case .processExited:
            cause = "its tmux pane (\(paneID)) is still there but its process has exited"
        case .paneBelongsToAnotherTerminal(let actual):
            cause = "its pane coordinate (\(paneID)) now points at a different terminal (\(actual))"
        }
        return """
            TBD's row says this terminal is awake, but \(cause) — so nothing was woken and any \
            prompt was NOT delivered. Its conversation is still readable with `tbd terminal \
            conversation <id>`, so context can be rebuilt before closing it.
            """
    }

    /// The message for a wake whose pane consultation could not reach the tmux
    /// server. Shared by `terminal.wake` and `terminal.resume` for the same
    /// reason `unparkedWakeMessage` is.
    ///
    /// Deliberately says nothing about whether the session is alive, and
    /// carries no `terminalSessionGone` code: that code's contract is a pane
    /// that POSITIVELY disagreed, and this is a read that never happened. The
    /// text is retryable on purpose — the failure mode this exists to stop is a
    /// caller reading a failed read as a dead session and giving up on live
    /// work.
    static func unreadablePaneWakeMessage(paneID: String, server: String) -> String {
        """
        Could not reach tmux server \(server) to check pane \(paneID), so nothing was woken \
        and any prompt was NOT delivered. This is a failed read, not a missing session — the \
        terminal may well be running. Retry; if it persists, check that the daemon and your \
        shell resolve the same tmux socket.
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
        switch result {
        case .ok:
            return try RPCResponse(result: TerminalWakeResult(woken: true))
        case .notHibernated, .inFlight:
            // Benign no-ops for an idempotent wake — but report woken: false so
            // autonomous callers know their `prompt` was NOT delivered (the
            // terminal is live; pasting into it now could hit a human session).
            return try RPCResponse(result: TerminalWakeResult(woken: false))
        case .sessionGone(let paneID, let detail):
            // NOT a benign no-op: the row claims awake but its pane disagrees,
            // so there was nothing live to deliver `prompt` to. An error (not
            // `woken: false`) is what lets an autonomous caller tell this apart
            // from "already awake and healthy".
            return RPCResponse(
                error: RPCRouter.unparkedWakeMessage(paneID: paneID, detail: detail),
                code: RPCErrorCode.terminalSessionGone.rawValue)
        case .paneUnreadable(let paneID, let server):
            // An error, so the caller knows its prompt went nowhere — but
            // pointedly NOT `terminalSessionGone`, which claims the session is
            // gone. Nothing established that.
            return RPCResponse(
                error: RPCRouter.unreadablePaneWakeMessage(paneID: paneID, server: server))
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
