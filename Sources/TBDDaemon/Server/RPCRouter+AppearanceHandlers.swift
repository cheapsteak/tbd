import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "appearanceHandlers")

extension RPCRouter {
    /// Update the COLORFGBG environment variable in all known tmux servers.
    /// This is a best-effort operation — failures on individual servers are logged
    /// but do not prevent updates from being attempted on other servers.
    func handleAppearanceUpdateColorFgBg(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(AppearanceUpdateColorFgBgParams.self, from: paramsData)

        // Discover all known tmux servers from worktrees.
        let worktrees = try await db.worktrees.list()
        var attemptedServers = Set<String>()
        var failureCount = 0

        for worktree in worktrees {
            let server = worktree.tmuxServer
            // Only attempt each server once (multiple worktrees may share a server).
            guard !attemptedServers.contains(server) else { continue }
            attemptedServers.insert(server)

            do {
                // Use the public setGlobalEnv method to set the variable.
                // This notifies all running shells that the color scheme has changed.
                try await tmux.setGlobalEnv(server: server, name: "COLORFGBG", value: params.value)
                logger.debug("Set COLORFGBG=\(params.value, privacy: .public) on server \(server, privacy: .public)")
            } catch {
                failureCount += 1
                logger.warning("Failed to set COLORFGBG on server \(server, privacy: .public): \(error, privacy: .public)")
                // Continue to next server on failure — best-effort fan-out.
            }
        }

        if failureCount > 0 {
            logger.debug("COLORFGBG update completed with \(failureCount) server failures out of \(attemptedServers.count)")
        }

        return .ok()
    }
}
