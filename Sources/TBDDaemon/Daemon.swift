import Foundation
import TBDShared
import os

private let daemonLogger = Logger(subsystem: "com.tbd.daemon", category: "startup")
private let reconcileLogger = Logger(subsystem: "com.tbd.daemon", category: "reconcile")

struct RuntimeIntegrationRefresher {
    var writeFallbackSkill: () throws -> Void
    var writeClaudePlugin: () throws -> Void
    var ensureCodexProfilePlugin: () throws -> Void
    var writeClaudeHookOverlay: () -> Void

    static func production() -> RuntimeIntegrationRefresher {
        RuntimeIntegrationRefresher(
            writeFallbackSkill: { try SkillFileWriter().writeFallback() },
            writeClaudePlugin: { try PluginDirWriter().writePlugin() },
            ensureCodexProfilePlugin: { _ = try CodexHomeManager().ensureProfilePlugin() },
            writeClaudeHookOverlay: { ClaudeHookOverlay.writeOverlay() }
        )
    }

    func refresh() {
        do {
            try writeFallbackSkill()
        } catch {
            Logger(subsystem: "com.tbd.daemon", category: "skill")
                .error("Failed to write fallback skill file: \(String(describing: error), privacy: .public)")
        }

        do {
            try writeClaudePlugin()
        } catch {
            Logger(subsystem: "com.tbd.daemon", category: "plugin")
                .error("Failed to write TBD plugin: \(String(describing: error), privacy: .public)")
        }

        do {
            try ensureCodexProfilePlugin()
        } catch {
            Logger(subsystem: "com.tbd.daemon", category: "codex-integration")
                .error("Failed to refresh Codex profile plugin: \(String(describing: error), privacy: .public)")
        }

        writeClaudeHookOverlay()
    }
}

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
    public nonisolated(unsafe) var reaperTask: Task<Void, Never>?
    public nonisolated(unsafe) var claudeUsagePoller: ClaudeUsagePoller?
    /// Per-daemon tmux control-mode supervisor. Owned here so it can be stopped
    /// on shutdown; the gate (`ControlModeGate.shouldEnable`) keeps it dormant
    /// unless `TBD_TMUX_CONTROL_MODE` is opted in and tmux is ≥ 3.2.
    let controlModeSupervisor = TmuxControlSupervisor()
    public let pidFile: PIDFile
    public let startTime: Date

    public init() {
        self.pidFile = PIDFile()
        self.startTime = Date()
    }

    /// Remove inherited agent-routing environment variables from the daemon's
    /// own process environment. Called at startup before any tmux server is spawned.
    ///
    /// Rationale: tmux servers persist the env they were spawned with as their
    /// global environment, and that env is then injected into every new window
    /// (including reboot-recovery recreations). If the daemon inherits e.g.
    /// `TBD_WORKTREE_ID=<main-uuid>` or `CODEX_CI=1` from a managed launcher
    /// shell, every recreated pane would inherit stale routing/noninteractive
    /// state.
    public static func scrubInheritedTBDEnv() {
        unsetenv("TBD_WORKTREE_ID")
        unsetenv("TBD_PROMPT_CONTEXT")
        unsetenv("TBD_PROMPT_INSTRUCTIONS")
        unsetenv("TBD_PROMPT_RENAME")
        unsetenv("CODEX_CI")
        unsetenv("CODEX_THREAD_ID")
    }

    /// Raise the process's `RLIMIT_NOFILE` soft limit so every tmux server the
    /// daemon spawns inherits a generous file-descriptor budget. Called at
    /// startup before any tmux server is created.
    ///
    /// Rationale: macOS hands LaunchServices-spawned apps a 256-fd soft limit.
    /// The daemon inherits it from the App, and tmux inherits it from the
    /// daemon. A tmux server hosting dozens of pty panes can exhaust 256
    /// descriptors and `exit(1)`, taking every session with it.
    ///
    /// Modern macOS shells default to 524,288. Large monorepos (e.g. Elastic
    /// Path's commerce-manager with ~18k directories) cause Claude CLI to walk
    /// past 10k file descriptors during startup, so a ceiling around the macOS
    /// shell default keeps spawned `claude` processes from hitting that wall.
    ///
    /// Best-effort: a `getrlimit`/`setrlimit` failure is logged and ignored —
    /// the daemon must still start. Returns the resulting limit (for tests).
    @discardableResult
    public static func raiseFileDescriptorLimit() -> rlimit {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
            daemonLogger.warning("getrlimit(RLIMIT_NOFILE) failed: \(String(cString: strerror(errno)), privacy: .public)")
            return limit
        }
        let target = min(limit.rlim_max, rlim_t(524_288))
        if limit.rlim_cur < target {
            let previous = limit.rlim_cur
            limit.rlim_cur = target
            if setrlimit(RLIMIT_NOFILE, &limit) == 0 {
                daemonLogger.info("Raised RLIMIT_NOFILE soft limit \(previous, privacy: .public) → \(target, privacy: .public)")
            } else {
                daemonLogger.warning("setrlimit(RLIMIT_NOFILE) failed: \(String(cString: strerror(errno)), privacy: .public)")
                limit.rlim_cur = previous
            }
        } else {
            daemonLogger.info("RLIMIT_NOFILE soft limit already \(limit.rlim_cur, privacy: .public) (≥ \(target, privacy: .public))")
        }
        return limit
    }

    /// Start the daemon: create config directory, clean up stale state,
    /// initialize database and all managers, start servers, reconcile worktrees.
    public func start() async throws {
        // 0. Raise the file-descriptor limit before any tmux server is spawned.
        Self.raiseFileDescriptorLimit()

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
                daemonLogger.error("Another daemon is already running (PID \(existingPID, privacy: .public)). Exiting.")
                Foundation.exit(1)
            }
        }

        // 4. Write PID file
        try pidFile.write()

        // Refresh the agent runtime integration assets up front so both
        // Claude and Codex sessions pick up the current TBD hook/plugin state
        // even before any new terminal spawn path runs.
        RuntimeIntegrationRefresher.production().refresh()

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
            daemonLogger.info("SSH agent symlink resolved: \(sshResolver.symlinkPath, privacy: .public)")
        }

        // 4c. Start periodic SSH agent refresh (every 60s)
        self.sshRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if !(await sshResolver.isValid()) {
                    if await sshResolver.resolve() {
                        daemonLogger.info("SSH agent symlink refreshed")
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
        let modelProfileResolver = ModelProfileResolver(
            profiles: database.modelProfiles,
            repos: database.repos,
            config: database.config
        )
        let pendingQuestions = PendingQuestionStore()

        // Detect the local tmux version once. The control-mode bridge is shared
        // by lifecycle + router so every `ensureServer()` call site can open a
        // gated control connection through a single supervisor. When the gate
        // is off (the default), `enableIfGated` is a no-op.
        let tmuxVersion = await TmuxVersion.detect()
        let controlModeBridge = TmuxControlModeBridge(
            supervisor: controlModeSupervisor,
            tmuxVersion: tmuxVersion
        )

        var lifecycle = WorktreeLifecycle(
            db: database, git: git, tmux: tmux, hooks: hooks,
            subscriptions: subs,
            modelProfileResolver: modelProfileResolver,
            pendingQuestions: pendingQuestions
        )
        lifecycle.controlMode = controlModeBridge
        let prManager = PRStatusManager()

        // Hydrate PR status cache from the DB so PR icons survive restart, then
        // persist future updates back to the DB.
        let persistedPRStatuses = (try? await database.worktrees.allPRStatuses()) ?? [:]
        await prManager.hydrate(persistedPRStatuses)
        await prManager.setOnStatusPersist { worktreeID, status in
            try? await database.worktrees.setPRStatus(id: worktreeID, status: status)
        }

        // 7a. Wire auto-archive-on-merge: when a worktree's cached PR state
        // transitions into `.merged`, the coordinator evaluates the effective
        // setting and archives the worktree (no active children) in the
        // background.
        let autoArchiveCoordinator = AutoArchiveOnMergeCoordinator(
            db: database, lifecycle: lifecycle, subscriptions: subs)
        await prManager.setOnMergedTransition { worktreeID, prNumber in
            await autoArchiveCoordinator.handleMergedTransition(worktreeID: worktreeID, prNumber: prNumber)
        }

        // 8. Initialize RPC router
        let rpcRouter = RPCRouter(
            db: database,
            lifecycle: lifecycle,
            tmux: tmux,
            git: git,
            startTime: startTime,
            subscriptions: subs,
            prManager: prManager,
            modelProfileResolver: modelProfileResolver,
            pendingQuestions: pendingQuestions
        )
        rpcRouter.controlMode = controlModeBridge
        self.router = rpcRouter

        // 9. Start socket server
        let sock = SocketServer(router: rpcRouter)
        self.socketServer = sock
        // Wire the live connected-client count into daemon.status (the router
        // is built above, before the server exists, so it can't be an init dep).
        rpcRouter.connectedClientsProvider = { [weak sock] in sock?.connectedClients ?? 0 }
        try await sock.start()

        // 10. Start HTTP server
        let http = HTTPServer(router: rpcRouter)
        self.httpServer = http
        try await http.start()

        // 11. Reconcile worktrees for all known repos
        await rpcRouter.suspendResumeCoordinator.reconcileOnStartup()
        // Break any cyclic parent pointers in the worktree tree (manual sqlite
        // edits, future regressions). Once at startup only — the cycle guard
        // in WorktreeStore.move prevents new cycles via normal operations.
        do {
            try await database.worktrees.breakCyclicParents()
        } catch {
            daemonLogger.warning("breakCyclicParents failed at startup: \(error.localizedDescription, privacy: .public)")
        }
        // Resolve worktree rows stranded in `.creating` by a daemon restart
        // mid-pre-session-wait. Must run BEFORE the per-repo reconcile loop so
        // orphaned rows are deleted/flipped first — reconcile only sees
        // `.active` rows and would otherwise trip the UNIQUE path constraint
        // re-adopting a stranded checkout. Resumed waits run detached and
        // never block startup.
        await lifecycle.recoverCreatingWorktrees()
        do {
            let repos = try await database.repos.list()
            for repo in repos {
                do {
                    try await lifecycle.reconcile(repoID: repo.id)
                } catch {
                    reconcileLogger.warning("Failed to reconcile repo \(repo.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            reconcileLogger.warning("Failed to list repos for reconciliation: \(error.localizedDescription, privacy: .public)")
        }

        // 11a-reaper. Reap orphaned/wedged agent processes: sweep now, then periodically.
        let reaper = AgentReaper(tmux: tmux, signaller: ProductionProcessSignaller())
        let ownedServers: () async -> [String] = { [database] in
            guard let repos = try? await database.repos.list() else { return [] }
            return Array(Set(repos.map { TmuxManager.serverName(forRepoPath: $0.path) }))
        }
        self.reaperTask = Task {
            // Sweep once immediately (cold recovery), then every 60s.
            await reaper.sweep(servers: await ownedServers())
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await reaper.sweep(servers: await ownedServers())
            }
        }

        // 11a-pre. Prune per-session Claude `fallbackModel` overlay files
        // orphaned by crashes or teardown paths that didn't clean up. Keep only
        // files whose key matches a live terminal. Best-effort.
        do {
            let liveTerminalIDs = try await database.terminals.list().map { $0.id.uuidString }
            ClaudeHookOverlay.pruneOrphanedSessionOverlays(liveSessionKeys: liveTerminalIDs)
        } catch {
            daemonLogger.warning("Failed to prune orphaned per-session overlays: \(error.localizedDescription, privacy: .public)")
        }

        // 11a. Backfill archived worktrees whose branch is missing — repairs
        // rows whose branch was renamed before archive captured the new name.
        // Idempotent and best-effort; never throws.
        await ArchivedWorktreeBackfill(db: database, git: git).run()

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
                        reconcileLogger.warning("Background fetch failed for \(repo.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }

        // 12b. Start Claude OAuth usage poller (30-min cadence, 30s stagger).
        let poller = ClaudeUsagePoller(
            profiles: database.modelProfiles,
            usage: database.modelProfileUsage,
            keychain: { id in try ModelProfileKeychain.load(id: id) },
            fetcher: LiveClaudeUsageFetcher(),
            clock: SystemPollerClock(),
            broadcast: { [weak subs] row in subs?.broadcastModelProfileUsage(row) }
        )
        self.claudeUsagePoller = poller
        rpcRouter.claudeUsagePoller = poller
        await poller.start()

        daemonLogger.info("Started successfully (PID \(ProcessInfo.processInfo.processIdentifier, privacy: .public))")

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
        daemonLogger.info("Shutting down...")

        // Stop Claude usage poller before other background tasks.
        if let poller = claudeUsagePoller {
            await poller.stop()
        }

        // Stop any tmux control-mode connections (no-op when the gate is off).
        await controlModeSupervisor.stopAll()

        // Cancel background tasks
        sshRefreshTask?.cancel()
        gitFetchTask?.cancel()
        gitStatusTask?.cancel()
        reaperTask?.cancel()

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

        daemonLogger.info("Stopped.")
        Foundation.exit(0)
    }
}
