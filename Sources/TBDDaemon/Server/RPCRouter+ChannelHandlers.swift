import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "channels.rpc")

extension RPCRouter {
    func handleChannelsPost(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ChannelsPostParams.self, from: paramsData)

        // Resolve identity. Either explicit overrides, or via terminalID lookup.
        let fromSession: String
        let fromLabel: String
        if let s = params.fromSession, let l = params.fromLabel {
            fromSession = s
            fromLabel = l
        } else if let terminalID = params.terminalID {
            guard let terminal = try await db.terminals.get(id: terminalID) else {
                return RPCResponse(error: "Unknown terminalID \(terminalID.uuidString)")
            }
            guard let session = terminal.claudeSessionID, !session.isEmpty else {
                return RPCResponse(error: "Terminal \(terminalID.uuidString) has no recorded sessionID yet (SessionStart hook hasn't fired)")
            }
            guard let worktree = try await db.worktrees.get(id: terminal.worktreeID) else {
                return RPCResponse(error: "Worktree \(terminal.worktreeID.uuidString) not found")
            }
            fromSession = session
            fromLabel = worktree.displayName
        } else {
            return RPCResponse(error: "Either terminalID or (fromSession + fromLabel) must be provided")
        }

        do {
            let result = try await channelStore.post(
                name: params.name,
                body: params.body,
                fromSession: fromSession,
                fromLabel: fromLabel
            )
            return try RPCResponse(result: ChannelsPostResult(name: result.name, seq: result.seq, ts: result.ts))
        } catch {
            logger.error("channels.post failed: \(String(describing: error), privacy: .public)")
            return RPCResponse(error: "channels.post failed: \(error)")
        }
    }

    func handleChannelsList(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ChannelsListParams.self, from: paramsData)
        let entries = try await db.channels.list(includeArchived: params.includeArchived)
        let summaries = entries.map {
            ChannelSummary(
                name: $0.name,
                createdAt: $0.createdAt,
                lastMessageAt: $0.lastMessageAt,
                messageCount: $0.messageCount
            )
        }
        return try RPCResponse(result: ChannelsListResult(channels: summaries))
    }

    func handleChannelsArchive(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ChannelsArchiveParams.self, from: paramsData)
        do {
            let path = try await channelStore.archive(name: params.name)
            return try RPCResponse(result: ChannelsArchiveResult(archivedPath: path))
        } catch {
            logger.error("channels.archive failed: \(String(describing: error), privacy: .public)")
            return RPCResponse(error: "channels.archive failed: \(error)")
        }
    }
}
