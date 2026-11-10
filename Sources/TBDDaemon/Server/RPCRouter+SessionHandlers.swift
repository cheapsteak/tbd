import Foundation
import os
import TBDShared

private let perfTranscriptLog = Logger(subsystem: "com.tbd.daemon", category: "perf-transcript")

extension RPCRouter {

    func handleSessionList(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(SessionListParams.self, from: paramsData)

        guard let worktree = try await db.worktrees.getLocal(id: params.worktreeID) else {
            return try RPCResponse(result: [SessionSummary]())
        }

        let reconciler = LocalAgentSessionReconciler(db: db)
        for terminal in try await db.terminals.list(worktreeID: worktree.id) where terminal.kind == .codex {
            await reconciler.reconcile(terminalID: terminal.id)
        }

        var byIdentity: [AgentSessionIdentity: SessionSummary] = [:]
        if let projectDir = ClaudeProjectDirectory.resolve(worktreePath: worktree.path) {
            for summary in ClaudeSessionScanner.listSessions(projectDir: projectDir) {
                if let existing = byIdentity[summary.identity], existing.lastMessageAt > summary.lastMessageAt { continue }
                byIdentity[summary.identity] = summary
            }
        }
        for session in try await db.localAgentSessions.list(worktreeID: worktree.id)
            where session.identity.agentKind == .codex {
            let summary = CodexSessionScanner.summary(session)
            byIdentity[summary.identity] = summary
        }
        let summaries = byIdentity.values.sorted {
            if $0.lastMessageAt != $1.lastMessageAt { return $0.lastMessageAt > $1.lastMessageAt }
            return $0.id < $1.id
        }
        return try RPCResponse(result: summaries)
    }

    func handleSessionMessages(_ paramsData: Data) async throws -> RPCResponse {
        perfTranscriptLog.debug("rpc.handle.start method=sessionMessages")
        let start = ContinuousClock.now
        var responseBytes = 0
        var itemsCount = 0
        defer {
            let elapsed = ContinuousClock.now - start
            let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            perfTranscriptLog.debug("rpc.handle.end method=sessionMessages elapsed_ms=\(ms, privacy: .public) response_bytes=\(responseBytes, privacy: .public) items=\(itemsCount, privacy: .public)")
        }

        let params = try decoder.decode(SessionMessagesParams.self, from: paramsData)

        if let identity = params.identity, identity.agentKind == .codex {
            guard let worktreeID = params.worktreeID,
                  try await db.worktrees.getLocal(id: worktreeID) != nil,
                  let session = try await db.localAgentSessions.get(worktreeID: worktreeID, identity: identity) else {
                return RPCResponse(error: "Codex session is not associated with this worktree")
            }
            let messages = try await CodexSessionScanner.messages(session, tailLimit: params.tailLimit) {
                try await self.db.localAgentSessions.get(worktreeID: worktreeID, identity: identity)
            }
            let response = try RPCResponse(result: messages)
            responseBytes = response.result?.utf8.count ?? 0
            itemsCount = messages.count
            return response
        }
        guard let filePath = params.filePath else {
            return RPCResponse(error: "A Claude transcript path or a Codex session identity is required")
        }

        // Constrain path to ~/.claude/projects/ — same trust boundary as
        // handleTerminalTranscript. The app supplies these via SessionSummary
        // entries that the daemon itself produced, but a crafted RPC could
        // ask for any user-accessible file otherwise.
        //
        // Resolved through the same single point as
        // `ClaudeProjectDirectory.resolve`, so the guard and the resolver
        // cannot disagree about where the store is. They did while this one
        // hand-built the path: under `scripts/test.sh` the resolver honoured
        // `TBD_CLAUDE_HOST_HOME` and this rejected everything it returned.
        // With the variable unset both read `~/.claude/projects` — the
        // boundary is unchanged in production.
        let projectsBase = ClaudeProfileConfigDirManager.resolveHostBaseDirectory()
            .appendingPathComponent("projects", isDirectory: true)
            .standardizedFileURL.path
        let candidate = URL(fileURLWithPath: filePath).standardizedFileURL.path
        guard candidate.hasPrefix(projectsBase + "/") else {
            return RPCResponse(error: "Refusing to read path outside ~/.claude/projects/: \(filePath)")
        }

        let messages: [TranscriptItem]
        if let limit = params.tailLimit {
            messages = TranscriptParser.parseTail(filePath: filePath, limit: max(0, limit))
        } else if let cached = await TranscriptParseCache.shared.get(filePath: filePath) {
            messages = cached
        } else {
            messages = TranscriptParser.parse(filePath: filePath)
            await TranscriptParseCache.shared.put(filePath: filePath, result: messages)
        }
        let response = try RPCResponse(result: messages)
        responseBytes = response.result?.utf8.count ?? 0
        itemsCount = messages.count
        return response
    }
}
