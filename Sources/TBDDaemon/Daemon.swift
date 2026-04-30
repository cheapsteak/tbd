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
    public nonisolated(unsafe) var gitFetchTask: Task<Void, Never>?
    public nonisolated(unsafe) var gitStatusTask: Task<Void, Never>?
    public nonisolated(unsafe) var claudeUsagePoller: ClaudeUsagePoller?
    public let pidFile: PIDFile
    public let startTime: Date

    public init() {
        self.pidFile = PIDFile()
        self.startTime = Date()
    }

    /// Remove inherited TBD_* environment variables from the daemon's own
    /// process environment. Called at startup before any tmux server is spawned.
    ///
    /// Rationale: tmux servers persist the env they were spawned with as their
    /// global environment, and that env is then injected into every new window
    /// (including reboot-recovery recreations). If the daemon inherits e.g.
    /// `TBD_WORKTREE_ID=<main-uuid>` from a TBD-spawned launcher shell, every
    /// recreated pane in every sub-worktree would report itself as the main
    /// worktree, causing notifications to be misattributed.
    public static func scrubInheritedTBDEnv() {
        unsetenv("TBD_WORKTREE_ID")
        unsetenv("TBD_PROMPT_CONTEXT")
        unsetenv("TBD_PROMPT_INSTRUCTIONS")
        unsetenv("TBD_PROMPT_RENAME")
    }

    /// Start the daemon: create config directory, clean up stale state,
    /// initialize database and all managers, start servers, reconcile worktrees.
    public func start() async throws {
        // 1. Create ~/tbd/ directory if needed
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

        // 4a. Scrub inherited TBD_* env vars before any tmux server is spawned.
        // The daemon may have been launched from inside a TBD-spawned shell (e.g.
        // `scripts/restart.sh` run from a terminal pane), which exports per-worktree
        // TBD_* vars. Without this scrub, the first `tmux new-session` bakes those
        // vars into the tmux server's global env, poisoning every recreated pane
        // (notifications from sub-worktrees would route to whichever worktree the
        // daemon was last restarted from).
        Daemon.scrubInheritedTBDEnv()

        // 4b. Resolve SSH agent symlink and update daemon's own environment
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
        let claudeTokenResolver = ClaudeTokenResolver(
            tokens: database.claudeTokens,
            repos: database.repos,
            config: database.config
        )
        let lifecycle = WorktreeLifecycle(
            db: database, git: git, tmux: tmux, hooks: hooks,
            subscriptions: subs,
            claudeTokenResolver: claudeTokenResolver
        )
        let prManager = PRStatusManager()

        // 8. Initialize RPC router
        let rpcRouter = RPCRouter(
            db: database,
            lifecycle: lifecycle,
            tmux: tmux,
            git: git,
            startTime: startTime,
            subscriptions: subs,
            prManager: prManager,
            claudeTokenResolver: claudeTokenResolver
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
        await rpcRouter.suspendResumeCoordinator.reconcileOnStartup()
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

        // 11b. Validate repo health — flips repos with stale paths to .missing.
        //      Must come *after* reconcile so newly-discovered worktrees see the
        //      correct status, and *before* the periodic tasks so users get accurate
        //      [missing] tags as soon as the daemon is up.
        let healthValidator = RepoHealthValidator(git: git)
        await healthValidator.validateAll(db: database)

        // 12. Start periodic git fetch for all repos (every 60s)
        self.gitFetchTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                let allRepos = (try? await database.repos.list()) ?? []
                // Skip .missing repos so we don't spam errors against stale paths
                // until the user relocates them.
                for repo in allRepos where repo.status != .missing {
                    do {
                        try await git.fetch(repoPath: repo.path, branch: repo.defaultBranch)
                    } catch {
                        print("[Daemon] Background fetch failed for \(repo.displayName): \(error)")
                    }
                }
            }
        }

        // 12b. Start Claude OAuth usage poller (30-min cadence, 30s stagger).
        let poller = ClaudeUsagePoller(
            tokens: database.claudeTokens,
            usage: database.claudeTokenUsage,
            keychain: { id in try ClaudeTokenKeychain.load(id: id) },
            fetcher: LiveClaudeUsageFetcher(),
            clock: SystemPollerClock(),
            broadcast: { [weak subs] row in subs?.broadcastClaudeTokenUsage(row) }
        )
        self.claudeUsagePoller = poller
        rpcRouter.claudeUsagePoller = poller
        await poller.start()

        print("[Daemon] Started successfully (PID \(ProcessInfo.processInfo.processIdentifier))")

        // 13. Periodic git status refresh (branch sync, conflict detection)
        self.gitStatusTask = Task {
            // Run once immediately (cold recovery), then every 10s
            while !Task.isCancelled {
                let allRepos = (try? await database.repos.list()) ?? []
                // Skip .missing repos to match gitFetchTask — running git
                // against a stale path produces quiet 10s-cadence noise.
                for repo in allRepos where repo.status != .missing {
                    await lifecycle.refreshGitStatuses(repoID: repo.id)
                }
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { break }
            }
        }
    }

    /// Stop the daemon: shut down servers, remove PID and socket files.
    public func stop() async {
        print("[Daemon] Shutting down...")

        // Stop Claude usage poller before other background tasks.
        if let poller = claudeUsagePoller {
            await poller.stop()
        }

        // Cancel background tasks
        sshRefreshTask?.cancel()
        gitFetchTask?.cancel()
        gitStatusTask?.cancel()

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
