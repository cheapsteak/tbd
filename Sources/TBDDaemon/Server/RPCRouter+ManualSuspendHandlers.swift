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
        }
    }

    func handleWorktreeSuspend(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeSuspendParams.self, from: paramsData)
        guard let terminals = try? await db.terminals.list(worktreeID: params.worktreeID) else {
            return RPCResponse(error: "Worktree not found")
        }

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
