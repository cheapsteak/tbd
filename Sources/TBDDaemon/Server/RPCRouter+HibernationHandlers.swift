import Foundation
import TBDShared

extension RPCRouter {

    /// `terminal.hibernate` — manually hibernate one Claude terminal (kill its
    /// process, keep the tmux window). Honors the running/permission rails.
    func handleTerminalHibernate(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalHibernateParams.self, from: paramsData)
        let result = await hibernationCoordinator.manualHibernate(terminalID: params.terminalID)
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
    func handleTerminalWake(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalWakeParams.self, from: paramsData)
        let result = await hibernationCoordinator.wake(
            terminalID: params.terminalID, cols: params.cols, rows: params.rows,
            allowDefaultProfileFallback: params.fallbackToDefaultProfile ?? false
        )
        switch result {
        case .ok, .notHibernated, .inFlight:
            // notHibernated / inFlight are benign no-ops for an idempotent wake.
            return .ok()
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
            return RPCResponse(error: "This session was pinned to an account profile (\(profileID.uuidString)) that no longer exists. It stays parked and resumable — retry with the default-profile fallback to wake it on your default account.")
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
