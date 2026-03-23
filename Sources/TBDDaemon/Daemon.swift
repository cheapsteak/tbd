import Foundation
import TBDShared

/// Top-level daemon orchestrator.
///
/// Coordinates all subsystems: database, managers, servers, and subscriptions.
/// Provides `start()` and `stop()` for lifecycle management.
public final class Daemon: Sendable {
    public nonisolated(unsafe) var db: TBDDatabase?
    public nonisolated(unsafe) var router: RPCRouter?
    public nonisolated(unsafe) var socketServer: SocketServer?
    public nonisolated(unsafe) var httpServer: HTTPServer?
    public nonisolated(unsafe) var subscriptions: StateSubscriptionManager?
    public nonisolated(unsafe) var sshRefreshTask: Task<Void, Never>?
    public let pidFile: PIDFile
    public let startTime: Date

    public init() {
        self.pidFile = PIDFile()
        self.startTime = Date()
    }

    /// Start the daemon: create config directory, clean up stale state,
    /// initialize database and all managers, start servers, reconcile worktrees.
    public func start() async throws {
        // 1. Create ~/.tbd/ directory if needed
        let configDir = TBDConstants.configDir.path
        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir) {
            try fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }

        // 2. Clean up stale PID/socket files
        pidFile.cleanupIfStale()

        // 3. Check if another daemon is already running
        if let existingPID = pidFile.read() {
            // Process is alive (kill(pid, 0) == 0 means it exists)
            if kill(existingPID, 0) == 0 {
                print("[Daemon] Another daemon is already running (PID \(existingPID)). Exiting.")
                Foundation.exit(1)
            }
        }

        // 4. Write PID file
        try pidFile.write()

        // 4a. Resolve SSH agent symlink and update daemon's own environment
        let sshResolver = SSHAgentResolver()
        if await sshResolver.resolve() {
            setenv("SSH_AUTH_SOCK", sshResolver.symlinkPath, 1)
            print("[Daemon] SSH agent symlink resolved: \(sshResolver.symlinkPath)")
        }

        // 4b. Start periodic SSH agent refresh (every 60s)
        self.sshRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if !sshResolver.isValid() {
                    if await sshResolver.resolve() {
                        print("[Daemon] SSH agent symlink refreshed")
                    }
                }
            }
        }

        // 5. Initialize database
        let database = try TBDDatabase(path: TBDConstants.databasePath)
        self.db = database

        // 6. Initialize state subscriptions (before lifecycle/router so they can broadcast)
        let subs = StateSubscriptionManager()
        self.subscriptions = subs

        // 7. Initialize managers
        let git = GitManager()
        let tmux = TmuxManager()
        let hooks = HookResolver()
        let lifecycle = WorktreeLifecycle(db: database, git: git, tmux: tmux, hooks: hooks, subscriptions: subs)

        // 8. Initialize RPC router
        let rpcRouter = RPCRouter(
            db: database,
            lifecycle: lifecycle,
            tmux: tmux,
            git: git,
            startTime: startTime,
            subscriptions: subs
        )
        self.router = rpcRouter

        // 9. Start socket server
        let sock = SocketServer(router: rpcRouter)
        self.socketServer = sock
        try await sock.start()

        // 10. Start HTTP server
        let http = HTTPServer(router: rpcRouter)
        self.httpServer = http
        try await http.start()

        // 11. Reconcile worktrees for all known repos
        do {
            let repos = try await database.repos.list()
            for repo in repos {
                do {
                    try await lifecycle.reconcile(repoID: repo.id)
                } catch {
                    print("[Daemon] Warning: Failed to reconcile repo \(repo.displayName): \(error)")
                }
            }
        } catch {
            print("[Daemon] Warning: Failed to list repos for reconciliation: \(error)")
        }

        print("[Daemon] Started successfully (PID \(ProcessInfo.processInfo.processIdentifier))")

        // 12. Refresh git statuses for all repos in background (cold recovery)
        Task {
            let allRepos = (try? await database.repos.list()) ?? []
            for repo in allRepos {
                await lifecycle.refreshGitStatuses(repoID: repo.id)
            }
        }
    }

    /// Stop the daemon: shut down servers, remove PID and socket files.
    public func stop() async {
        print("[Daemon] Shutting down...")

        // Cancel SSH refresh
        sshRefreshTask?.cancel()

        // Stop servers
        if let sock = socketServer {
            await sock.stop()
        }
        if let http = httpServer {
            await http.stop()
        }

        // Remove PID file
        pidFile.remove()

        // Remove port file
        try? FileManager.default.removeItem(atPath: TBDConstants.portFilePath)

        print("[Daemon] Stopped.")
        Foundation.exit(0)
    }
}
