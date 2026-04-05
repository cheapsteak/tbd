import Foundation
import TBDShared

extension RPCRouter {

    // MARK: - Terminal Handlers

    func handleTerminalCreate(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalCreateParams.self, from: paramsData)

        // Look up the worktree to get tmux server and path
        guard let worktree = try await db.worktrees.get(id: params.worktreeID) else {
            return RPCResponse(error: "Worktree not found: \(params.worktreeID)")
        }

        // Ensure tmux server exists before creating window
        _ = try await tmux.ensureServer(
            server: worktree.tmuxServer,
            session: "main",
            cwd: worktree.path
        )

        let isClaudeType = params.type == .claude || params.resumeSessionID != nil
        let claudeSessionID: String?
        let shellCommand: String
        let label: String?

        if let resumeID = params.resumeSessionID {
            // Fork: resume from an existing session (creates a new session that shares context)
            claudeSessionID = resumeID
            shellCommand = "claude --resume \(resumeID) --dangerously-skip-permissions"
            label = "claude"
        } else if isClaudeType {
            let sessionID = UUID().uuidString
            claudeSessionID = sessionID
            shellCommand = "claude --session-id \(sessionID) --dangerously-skip-permissions"
            label = "claude"
        } else if let cmd = params.cmd {
            claudeSessionID = nil
            shellCommand = cmd
            label = cmd
        } else {
            claudeSessionID = nil
            shellCommand = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            label = nil
        }

        let window = try await tmux.createWindow(
            server: worktree.tmuxServer,
            session: "main",
            cwd: worktree.path,
            shellCommand: shellCommand,
            env: ["TBD_WORKTREE_ID": params.worktreeID.uuidString]
        )

        let terminal = try await db.terminals.create(
            worktreeID: params.worktreeID,
            tmuxWindowID: window.windowID,
            tmuxPaneID: window.paneID,
            label: label,
            claudeSessionID: claudeSessionID
        )

        subscriptions.broadcast(delta: .terminalCreated(TerminalDelta(
            terminalID: terminal.id, worktreeID: terminal.worktreeID, label: terminal.label
        )))

        return try RPCResponse(result: terminal)
    }

    func handleTerminalList(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalListParams.self, from: paramsData)
        let terminals = try await db.terminals.list(worktreeID: params.worktreeID)
        return try RPCResponse(result: terminals)
    }


    func handleTerminalDelete(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalDeleteParams.self, from: paramsData)

        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            return RPCResponse(error: "Terminal not found: \(params.terminalID)")
        }

        // Kill the tmux window
        if let worktree = try await db.worktrees.get(id: terminal.worktreeID) {
            try? await tmux.killWindow(server: worktree.tmuxServer, windowID: terminal.tmuxWindowID)
        }

        // Delete from DB
        try await db.terminals.delete(id: params.terminalID)

        subscriptions.broadcast(delta: .terminalRemoved(TerminalIDDelta(
            terminalID: terminal.id
        )))

        return .ok()
    }

    func handleTerminalSetPin(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalSetPinParams.self, from: paramsData)
        let pinnedAt: Date? = params.pinned ? Date() : nil
        try await db.terminals.setPin(id: params.terminalID, pinned: params.pinned, at: pinnedAt ?? Date())
        subscriptions.broadcast(delta: .terminalPinChanged(TerminalPinDelta(
            terminalID: params.terminalID, pinnedAt: pinnedAt
        )))
        return .ok()
    }

    func handleTerminalRecreateWindow(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalRecreateWindowParams.self, from: paramsData)

        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            return RPCResponse(error: "Terminal not found: \(params.terminalID)")
        }

        guard let worktree = try await db.worktrees.get(id: terminal.worktreeID) else {
            return RPCResponse(error: "Worktree not found for terminal: \(params.terminalID)")
        }

        // Kill the old window if it still exists (avoids orphans)
        try? await tmux.killWindow(server: worktree.tmuxServer, windowID: terminal.tmuxWindowID)

        // Ensure tmux server exists
        _ = try await tmux.ensureServer(
            server: worktree.tmuxServer,
            session: "main",
            cwd: worktree.path
        )

        // Create a new tmux window with a default shell
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let window = try await tmux.createWindow(
            server: worktree.tmuxServer,
            session: "main",
            cwd: worktree.path,
            shellCommand: shell
        )

        // Update the terminal record with new window/pane IDs and clear stale
        // Claude metadata — the recreated window runs a plain shell, not Claude.
        try await db.terminals.updateTmuxIDs(
            id: params.terminalID,
            windowID: window.windowID,
            paneID: window.paneID
        )
        try await db.terminals.clearRecreated(id: params.terminalID)

        // Return updated terminal
        guard let updated = try await db.terminals.get(id: params.terminalID) else {
            return RPCResponse(error: "Terminal not found after update")
        }

        return try RPCResponse(result: updated)
    }

    func handleTerminalOutput(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalOutputParams.self, from: paramsData)

        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            return RPCResponse(error: "Terminal not found: \(params.terminalID)")
        }

        guard let worktree = try await db.worktrees.get(id: terminal.worktreeID) else {
            return RPCResponse(error: "Worktree not found for terminal: \(params.terminalID)")
        }

        let rawOutput = try await tmux.capturePaneOutput(
            server: worktree.tmuxServer,
            paneID: terminal.tmuxPaneID
        )

        let lines = params.lines ?? 50
        let outputLines = rawOutput.split(separator: "\n", omittingEmptySubsequences: false)
        let trimmed = outputLines.suffix(lines).joined(separator: "\n")

        return try RPCResponse(result: TerminalOutputResult(output: trimmed))
    }

    func handleTerminalConversation(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalConversationParams.self, from: paramsData)

        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            return RPCResponse(error: "Terminal not found: \(params.terminalID)")
        }

        guard let sessionID = terminal.claudeSessionID else {
            return RPCResponse(error: "No Claude session ID for terminal \(params.terminalID)")
        }

        let count = params.messages ?? 1
        let messages = Self.readSessionMessages(sessionID: sessionID, count: count)
        return try RPCResponse(result: TerminalConversationResult(messages: messages, sessionID: sessionID))
    }

    // MARK: - Session JSONL Parsing (Codable)

    private struct SessionEntry: Decodable {
        let type: String
        let message: SessionMessage?
    }

    private struct SessionMessage: Decodable {
        let role: String?
        let content: [ContentBlock]?
    }

    private struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }

    /// Search `~/.claude/projects/` for a session JSONL file matching the given session ID,
    /// parse it, and return the last N assistant messages with text content.
    static func readSessionMessages(sessionID: String, count: Int) -> [ConversationMessage] {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: claudeDir.path) else {
            return []
        }

        var sessionPath: URL?
        for dir in projectDirs {
            let candidate = claudeDir
                .appendingPathComponent(dir)
                .appendingPathComponent("\(sessionID).jsonl")
            if fm.fileExists(atPath: candidate.path) {
                sessionPath = candidate
                break
            }
        }

        guard let path = sessionPath,
              let data = fm.contents(atPath: path.path),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        var allMessages: [ConversationMessage] = []

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(SessionEntry.self, from: lineData) else {
                continue
            }

            guard entry.type == "assistant" || entry.type == "user",
                  let blocks = entry.message?.content else {
                continue
            }

            let textParts = blocks.compactMap { $0.type == "text" ? $0.text : nil }
            if !textParts.isEmpty {
                allMessages.append(ConversationMessage(
                    role: entry.type,
                    content: textParts.joined(separator: "\n")
                ))
            }
        }

        return Array(allMessages.suffix(count))
    }

    func handleTerminalSend(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalSendParams.self, from: paramsData)

        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            return RPCResponse(error: "Terminal not found: \(params.terminalID)")
        }

        // Look up the worktree to get the tmux server name
        guard let worktree = try await db.worktrees.get(id: terminal.worktreeID) else {
            return RPCResponse(error: "Worktree not found for terminal: \(params.terminalID)")
        }

        try await tmux.sendKeys(
            server: worktree.tmuxServer,
            paneID: terminal.tmuxPaneID,
            text: params.text
        )

        return .ok()
    }

    // MARK: - Notification Handler

    func handleNotify(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(NotifyParams.self, from: paramsData)

        guard let worktreeID = params.worktreeID else {
            return RPCResponse(error: "worktreeID is required for notifications")
        }

        let notification = try await db.notifications.create(
            worktreeID: worktreeID,
            type: params.type,
            message: params.message
        )

        subscriptions.broadcast(delta: .notificationReceived(NotificationDelta(
            notificationID: notification.id, worktreeID: notification.worktreeID,
            type: notification.type, message: notification.message
        )))

        // Signal the suspend/resume coordinator that Claude finished a response
        if params.type == .responseComplete {
            await suspendResumeCoordinator.responseCompleted(worktreeID: worktreeID)
        }

        return try RPCResponse(result: notification)
    }

    // MARK: - Notifications List

    func handleNotificationsList() async throws -> RPCResponse {
        let notifications = try await db.notifications.allUnreadByWorktree()
        return try RPCResponse(result: NotificationsListResult(notifications: notifications))
    }

    // MARK: - Notifications Mark Read

    func handleNotificationsMarkRead(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(NotificationsMarkReadParams.self, from: paramsData)
        try await db.notifications.markRead(worktreeID: params.worktreeID)
        return .ok()
    }

    // MARK: - Cleanup

    func handleCleanup() async throws -> RPCResponse {
        let repos = try await db.repos.list()
        var errors: [String] = []
        var worktreesReconciled = 0

        for repo in repos {
            // Prune stale worktree tracking entries
            do {
                try await git.worktreePrune(repoPath: repo.path)
            } catch {
                errors.append("Prune failed for \(repo.displayName): \(error)")
            }

            // Reconcile DB against actual git worktree list
            do {
                let beforeCount = try await db.worktrees.list(repoID: repo.id, status: .active).count
                try await lifecycle.reconcile(repoID: repo.id)
                let afterCount = try await db.worktrees.list(repoID: repo.id, status: .active).count
                let delta = abs(beforeCount - afterCount)
                worktreesReconciled += delta
            } catch {
                errors.append("Reconcile failed for \(repo.displayName): \(error)")
            }
        }

        let result = CleanupResult(
            reposProcessed: repos.count,
            worktreesReconciled: worktreesReconciled,
            errors: errors
        )
        return try RPCResponse(result: result)
    }

    // MARK: - Daemon Status

    func handleDaemonStatus() throws -> RPCResponse {
        let uptime = Date().timeIntervalSince(startTime)
        let status = DaemonStatusResult(
            version: TBDConstants.version,
            uptime: uptime,
            connectedClients: 0  // Will be updated when socket server is implemented
        )
        return try RPCResponse(result: status)
    }

    // MARK: - Resolve Path

    func handleResolvePath(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ResolvePathParams.self, from: paramsData)
        let path = (params.path as NSString).standardizingPath

        // Walk up from the given path and try to match against known repos/worktrees
        var currentPath = path

        while currentPath != "/" && currentPath != "" {
            // Check if this path matches a worktree
            if let worktree = try await db.worktrees.findByPath(path: currentPath) {
                let result = ResolvedPathResult(repoID: worktree.repoID, worktreeID: worktree.id)
                return try RPCResponse(result: result)
            }

            // Check if this path matches a repo
            if let repo = try await db.repos.findByPath(path: currentPath) {
                let result = ResolvedPathResult(repoID: repo.id, worktreeID: nil)
                return try RPCResponse(result: result)
            }

            // Move up one directory
            currentPath = (currentPath as NSString).deletingLastPathComponent
        }

        // No match found
        let result = ResolvedPathResult(repoID: nil, worktreeID: nil)
        return try RPCResponse(result: result)
    }
}
