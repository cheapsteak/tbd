import Foundation
import TBDShared

/// Backward-compat shims for the retired Suspend/Resume RPCs.
///
/// The Suspend feature merged into Hibernation (one unified "park" state). We
/// KEEP these RPC methods alive so old CLI/app builds that still call
/// `terminal.suspend` / `terminal.resume` / `worktree.suspend` /
/// `worktree.resume` keep working — but they now route to the unified
/// `HibernationCoordinator`:
///   - `terminal.suspend`  → `manualHibernate`
///   - `terminal.resume`   → `wake`
///   - `worktree.suspend`  → hibernate every eligible Claude terminal
///   - `worktree.resume`   → wake every parked Claude terminal
extension RPCRouter {

    func handleTerminalSuspend(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalSuspendParams.self, from: paramsData)
        // Parking (formerly suspend) routes to the unified HibernationCoordinator.
        // Cancel any pending auto-resume up-front and unconditionally (spec
        // §Cancellation, preserving #341's shim behavior): the intent to park
        // means "don't send an unattended resume", even if the actual park is
        // then refused (session-less, running, etc.). performHibernate also
        // cancels on a successful park; the up-front cancel covers the refused
        // case. Wake the scheduler so it re-reads pending rows.
        if (try? await db.scheduledResumes.cancelPending(terminalID: params.terminalID)) == true {
            await limitResumeScheduler?.wake()
        }
        let result = await hibernationCoordinator.manualHibernate(terminalID: params.terminalID)
        switch result {
        case .ok, .alreadyHibernated:
            return .ok()
        case .notEligible(let reason):
            return RPCResponse(error: reason)
        case .notFound:
            return RPCResponse(error: "Terminal not found")
        }
    }

    func handleTerminalResume(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalResumeParams.self, from: paramsData)
        let result = await hibernationCoordinator.wake(terminalID: params.terminalID)
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
        }
    }

    func handleWorktreeSuspend(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeSuspendParams.self, from: paramsData)
        guard let terminals = try? await db.terminals.list(worktreeID: params.worktreeID) else {
            return RPCResponse(error: "Worktree not found")
        }

        // Parking cancels any pending auto-resume (spec §Cancellation). Each
        // manualHibernate also cancels its own row, but cancel up-front so a
        // terminal that's ineligible to park (and thus skipped below) still has
        // its stale pending resume cleared, then wake the scheduler once.
        for terminal in terminals where terminal.pendingResumeAt != nil {
            _ = try? await db.scheduledResumes.cancelPending(terminalID: terminal.id)
        }
        await limitResumeScheduler?.wake()

        let eligible = terminals.filter { $0.isManuallyHibernatable }

        // Fire in background — RPC returns immediately so the app can show
        // the parking overlay while the daemon does its work.
        Task { [hibernationCoordinator] in
            for terminal in eligible {
                _ = await hibernationCoordinator.manualHibernate(terminalID: terminal.id)
            }
        }

        return .ok()
    }

    func handleWorktreeResume(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeResumeParams.self, from: paramsData)
        guard let terminals = try? await db.terminals.list(worktreeID: params.worktreeID) else {
            return RPCResponse(error: "Worktree not found")
        }

        // Wake every parked terminal (authoritative or legacy). The coordinator
        // is an actor so calls serialize anyway.
        let parked = terminals.filter { $0.isParked && $0.isClaudeResumable }
        for terminal in parked {
            _ = await hibernationCoordinator.wake(terminalID: terminal.id)
        }

        return .ok()
    }
}
