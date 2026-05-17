import Foundation
import TBDShared

extension RPCRouter {

    func handleTerminalSuspend(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalSuspendParams.self, from: paramsData)
        let result = await suspendResumeCoordinator.manualSuspend(terminalID: params.terminalID)
        switch result {
        case .ok, .alreadySuspended:
            return .ok()
        case .notClaudeTerminal:
            return RPCResponse(error: "Not a Claude terminal")
        case .notFound:
            return RPCResponse(error: "Terminal not found")
        }
    }

    func handleTerminalResume(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalResumeParams.self, from: paramsData)
        let result = await suspendResumeCoordinator.manualResume(terminalID: params.terminalID)
        switch result {
        case .ok, .notSuspended:
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

        let claudeTerminals = terminals.filter { $0.isClaudeResumable && $0.suspendedAt == nil }

        // Fire in background — RPC returns immediately so the app can show
        // the suspending overlay while the daemon does its work.
        Task {
            for terminal in claudeTerminals {
                _ = await suspendResumeCoordinator.manualSuspend(terminalID: terminal.id)
            }
        }

        return .ok()
    }

    func handleWorktreeResume(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeResumeParams.self, from: paramsData)
        guard let terminals = try? await db.terminals.list(worktreeID: params.worktreeID) else {
            return RPCResponse(error: "Worktree not found")
        }

        let suspendedTerminals = terminals.filter { $0.isClaudeResumable && $0.suspendedAt != nil }

        // Sequential — the coordinator is an actor so calls serialize anyway
        for terminal in suspendedTerminals {
            _ = await suspendResumeCoordinator.manualResume(terminalID: terminal.id)
        }

        return .ok()
    }
}
