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

        // Constrain path to ~/.claude/projects/ — same trust boundary as
        // handleTerminalTranscript. The app supplies these via SessionSummary
        // entries that the daemon itself produced, but a crafted RPC could
        // ask for any user-accessible file otherwise.
        let projectsBase = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")
            .standardizedFileURL.path
        let candidate = URL(fileURLWithPath: params.filePath).standardizedFileURL.path
        guard candidate.hasPrefix(projectsBase + "/") else {
            return RPCResponse(error: "Refusing to read path outside ~/.claude/projects/: \(params.filePath)")
        }

        let messages: [TranscriptItem]
        if let cached = await TranscriptParseCache.shared.get(filePath: params.filePath) {
            messages = cached
        } else {
            messages = TranscriptParser.parse(filePath: params.filePath)
            await TranscriptParseCache.shared.put(filePath: params.filePath, result: messages)
        }
        return try RPCResponse(result: messages)
    }
}
