import Foundation
import TBDShared

extension RPCRouter {

    func handleSessionList(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(SessionListParams.self, from: paramsData)

        guard let worktree = try await db.worktrees.get(id: params.worktreeID) else {
            return try RPCResponse(result: [SessionSummary]())
        }

        guard let projectDir = ClaudeProjectDirectory.resolve(worktreePath: worktree.path) else {
            return try RPCResponse(result: [SessionSummary]())
        }

        let summaries = ClaudeSessionScanner.listSessions(projectDir: projectDir)
        return try RPCResponse(result: summaries)
    }

    func handleSessionMessages(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(SessionMessagesParams.self, from: paramsData)
        let messages = ClaudeSessionScanner.loadMessages(filePath: params.filePath)
        return try RPCResponse(result: messages)
    }
}
