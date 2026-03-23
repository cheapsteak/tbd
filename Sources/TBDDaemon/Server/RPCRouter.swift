import Foundation
import TBDShared

/// Maps RPC method names to handler functions.
/// Decodes raw JSON params, dispatches to the appropriate subsystem, and returns an RPCResponse.
public final class RPCRouter: Sendable {
    public let db: TBDDatabase
    public let lifecycle: WorktreeLifecycle
    public let tmux: TmuxManager
    public let git: GitManager
    public let startTime: Date
    public let subscriptions: StateSubscriptionManager

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(
        db: TBDDatabase,
        lifecycle: WorktreeLifecycle,
        tmux: TmuxManager,
        git: GitManager = GitManager(),
        startTime: Date = Date(),
        subscriptions: StateSubscriptionManager = StateSubscriptionManager()
    ) {
        self.db = db
        self.lifecycle = lifecycle
        self.tmux = tmux
        self.git = git
        self.startTime = startTime
        self.subscriptions = subscriptions
    }

    /// Handle a raw JSON Data blob representing an RPCRequest.
    /// Returns an RPCResponse.
    public func handleRaw(_ data: Data) async -> RPCResponse {
        do {
            let request = try decoder.decode(RPCRequest.self, from: data)
            return await handle(request)
        } catch {
            return RPCResponse(error: "Failed to decode request: \(error.localizedDescription)")
        }
    }

    /// Handle a decoded RPCRequest and return an RPCResponse.
    public func handle(_ request: RPCRequest) async -> RPCResponse {
        do {
            switch request.method {
            case RPCMethod.repoAdd:
                return try await handleRepoAdd(request.paramsData)
            case RPCMethod.repoRemove:
                return try await handleRepoRemove(request.paramsData)
            case RPCMethod.repoList:
                return try await handleRepoList()
            case RPCMethod.worktreeCreate:
                return try await handleWorktreeCreate(request.paramsData)
            case RPCMethod.worktreeList:
                return try await handleWorktreeList(request.paramsData)
            case RPCMethod.worktreeArchive:
                return try await handleWorktreeArchive(request.paramsData)
            case RPCMethod.worktreeRevive:
                return try await handleWorktreeRevive(request.paramsData)
            case RPCMethod.worktreeRename:
                return try await handleWorktreeRename(request.paramsData)
            case RPCMethod.worktreeMerge:
                return try await handleWorktreeMerge(request.paramsData)
            case RPCMethod.worktreeMergeStatus:
                return try await handleWorktreeMergeStatus(request.paramsData)
            case RPCMethod.terminalCreate:
                return try await handleTerminalCreate(request.paramsData)
            case RPCMethod.terminalList:
                return try await handleTerminalList(request.paramsData)
            case RPCMethod.terminalSend:
                return try await handleTerminalSend(request.paramsData)
            case RPCMethod.notify:
                return try await handleNotify(request.paramsData)
            case RPCMethod.daemonStatus:
                return try handleDaemonStatus()
            case RPCMethod.resolvePath:
                return try await handleResolvePath(request.paramsData)
            case RPCMethod.notificationsList:
                return try await handleNotificationsList()
            case RPCMethod.notificationsMarkRead:
                return try await handleNotificationsMarkRead(request.paramsData)
            case RPCMethod.cleanup:
                return try await handleCleanup()
            default:
                return RPCResponse(error: "Unknown method: \(request.method)")
            }
        } catch {
            return RPCResponse(error: "\(error)")
        }
    }

    // MARK: - Repo Handlers

    private func handleRepoAdd(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(RepoAddParams.self, from: paramsData)

        // Resolve to absolute path
        let path = (params.path as NSString).standardizingPath

        // Validate it's a git repo
        guard await git.isGitRepo(path: path) else {
            return RPCResponse(error: "Not a git repository: \(path)")
        }

        // Check if already registered
        if let existing = try await db.repos.findByPath(path: path) {
            // Ensure main worktree exists (may be missing if repo was added via reconciliation)
            let mainWts = try await db.worktrees.list(repoID: existing.id, status: .main)
            if mainWts.isEmpty {
                let serverName = TmuxManager.serverName(forRepoPath: existing.path)
                _ = try await db.worktrees.createMain(
                    repoID: existing.id,
                    name: existing.defaultBranch,
                    branch: existing.defaultBranch,
                    path: existing.path,
                    tmuxServer: serverName
                )
            }
            return try RPCResponse(result: existing)
        }

        // Detect default branch and remote URL
        let defaultBranch: String
        do {
            defaultBranch = try await git.detectDefaultBranch(repoPath: path)
        } catch {
            defaultBranch = "main"
        }

        let remoteURL = await git.getRemoteURL(repoPath: path)

        // Derive display name from last path component
        let displayName = (path as NSString).lastPathComponent

        let repo = try await db.repos.create(
            path: path,
            displayName: displayName,
            defaultBranch: defaultBranch,
            remoteURL: remoteURL
        )

        // Create synthetic "main" worktree entry pointing at repo root
        let tmuxServer = TmuxManager.serverName(forRepoPath: repo.path)
        _ = try await db.worktrees.createMain(
            repoID: repo.id,
            name: defaultBranch,
            branch: defaultBranch,
            path: path,
            tmuxServer: tmuxServer
        )

        // Reconcile existing git worktrees into the DB
        try? await lifecycle.reconcile(repoID: repo.id)

        subscriptions.broadcast(delta: .repoAdded(RepoDelta(
            repoID: repo.id, path: repo.path, displayName: repo.displayName
        )))

        return try RPCResponse(result: repo)
    }

    private func handleRepoRemove(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(RepoRemoveParams.self, from: paramsData)

        guard let repo = try await db.repos.get(id: params.repoID) else {
            return RPCResponse(error: "Repository not found: \(params.repoID)")
        }

        // Check for active worktrees
        let activeWorktrees = try await db.worktrees.list(repoID: repo.id, status: .active)

        if !activeWorktrees.isEmpty {
            if params.force {
                // Cascade-archive all active worktrees
                for wt in activeWorktrees {
                    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)
                }
            } else {
                return RPCResponse(
                    error: "Repository has \(activeWorktrees.count) active worktree(s). Use force to archive them first."
                )
            }
        }

        // Delete any remaining worktrees (e.g. main worktree) for this repo
        try await db.worktrees.deleteForRepo(repoID: params.repoID)

        try await db.repos.remove(id: params.repoID)

        subscriptions.broadcast(delta: .repoRemoved(RepoIDDelta(repoID: params.repoID)))

        return .ok()
    }

    private func handleRepoList() async throws -> RPCResponse {
        let repos = try await db.repos.list()
        return try RPCResponse(result: repos)
    }

    // MARK: - Worktree Handlers

    private func handleWorktreeCreate(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeCreateParams.self, from: paramsData)
        let worktree = try await lifecycle.createWorktree(repoID: params.repoID, name: params.name)

        subscriptions.broadcast(delta: .worktreeCreated(WorktreeDelta(
            worktreeID: worktree.id, repoID: worktree.repoID,
            name: worktree.name, path: worktree.path
        )))

        return try RPCResponse(result: worktree)
    }

    private func handleWorktreeList(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeListParams.self, from: paramsData)
        let worktrees = try await db.worktrees.list(repoID: params.repoID, status: params.status)
        return try RPCResponse(result: worktrees)
    }

    private func handleWorktreeArchive(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeArchiveParams.self, from: paramsData)
        try await lifecycle.archiveWorktree(worktreeID: params.worktreeID, force: params.force)

        subscriptions.broadcast(delta: .worktreeArchived(WorktreeIDDelta(
            worktreeID: params.worktreeID
        )))

        return .ok()
    }

    private func handleWorktreeRevive(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeReviveParams.self, from: paramsData)
        let worktree = try await lifecycle.reviveWorktree(worktreeID: params.worktreeID)

        subscriptions.broadcast(delta: .worktreeRevived(WorktreeDelta(
            worktreeID: worktree.id, repoID: worktree.repoID,
            name: worktree.name, path: worktree.path
        )))

        return try RPCResponse(result: worktree)
    }

    private func handleWorktreeRename(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeRenameParams.self, from: paramsData)
        try await db.worktrees.rename(id: params.worktreeID, displayName: params.displayName)

        subscriptions.broadcast(delta: .worktreeRenamed(WorktreeRenameDelta(
            worktreeID: params.worktreeID, displayName: params.displayName
        )))

        return .ok()
    }

    private func handleWorktreeMerge(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeMergeParams.self, from: paramsData)
        try await lifecycle.mergeWorktree(
            worktreeID: params.worktreeID,
            archiveAfter: params.archiveAfter
        )

        // Mark the merged worktree's git status
        try await db.worktrees.updateGitStatus(id: params.worktreeID, gitStatus: .merged)

        subscriptions.broadcast(delta: .worktreeMerged(WorktreeIDDelta(
            worktreeID: params.worktreeID
        )))
        subscriptions.broadcast(delta: .worktreeGitStatusChanged(
            WorktreeGitStatusDelta(worktreeID: params.worktreeID, gitStatus: .merged)
        ))

        // Refresh all other active worktrees in background (main just moved)
        if let mergedWt = try await db.worktrees.get(id: params.worktreeID) {
            Task {
                await lifecycle.refreshGitStatuses(repoID: mergedWt.repoID)
            }
        }

        return .ok()
    }

    private func handleWorktreeMergeStatus(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeMergeStatusParams.self, from: paramsData)
        let status = try await lifecycle.checkWorktreeMergeability(worktreeID: params.worktreeID)
        let result = WorktreeMergeStatusResult(
            canMerge: status.canMerge,
            reason: status.reason,
            commitCount: status.commitCount
        )
        return try RPCResponse(result: result)
    }

    // MARK: - Terminal Handlers

    private func handleTerminalCreate(_ paramsData: Data) async throws -> RPCResponse {
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

    private func handleTerminalList(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalListParams.self, from: paramsData)
        let terminals = try await db.terminals.list(worktreeID: params.worktreeID)
        return try RPCResponse(result: terminals)
    }

    private func handleTerminalSend(_ paramsData: Data) async throws -> RPCResponse {
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

    private func handleNotify(_ paramsData: Data) async throws -> RPCResponse {
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

    private func handleNotificationsList() async throws -> RPCResponse {
        let notifications = try await db.notifications.allUnreadByWorktree()
        return try RPCResponse(result: NotificationsListResult(notifications: notifications))
    }

    // MARK: - Notifications Mark Read

    private func handleNotificationsMarkRead(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(NotificationsMarkReadParams.self, from: paramsData)
        try await db.notifications.markRead(worktreeID: params.worktreeID)
        return .ok()
    }

    // MARK: - Cleanup

    private func handleCleanup() async throws -> RPCResponse {
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

    private func handleDaemonStatus() throws -> RPCResponse {
        let uptime = Date().timeIntervalSince(startTime)
        let status = DaemonStatusResult(
            version: TBDConstants.version,
            uptime: uptime,
            connectedClients: 0  // Will be updated when socket server is implemented
        )
        return try RPCResponse(result: status)
    }

    // MARK: - Resolve Path

    private func handleResolvePath(_ paramsData: Data) async throws -> RPCResponse {
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
