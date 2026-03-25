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

        let shellCommand = params.cmd ?? (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        let window = try await tmux.createWindow(
            server: worktree.tmuxServer,
            session: "main",
            cwd: worktree.path,
            shellCommand: shellCommand
        )

        let terminal = try await db.terminals.create(
            worktreeID: params.worktreeID,
            tmuxWindowID: window.windowID,
            tmuxPaneID: window.paneID,
            label: params.cmd
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
