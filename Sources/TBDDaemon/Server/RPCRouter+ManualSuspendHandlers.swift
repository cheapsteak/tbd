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
        // A successful park cancels any pending auto-resume inside the coordinator
        // (spec §Cancellation, mirrored on the hibernate path); wake the scheduler
        // so it re-reads pending rows instead of sleeping until a stale fire time.
        let result = await hibernationCoordinator.manualHibernate(terminalID: params.terminalID)
        switch result {
        case .ok:
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
