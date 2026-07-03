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
    public nonisolated(unsafe) var hibernationSweepTask: Task<Void, Never>?
    public nonisolated(unsafe) var claudeUsagePoller: ClaudeUsagePoller?
    public nonisolated(unsafe) var oauthUsagePoller: OAuthProfileUsagePoller?
    /// Session-limit auto-resume scheduler. Owned here so it can be stopped
    /// on shutdown; `nil` in mock mode.
    public nonisolated(unsafe) var limitResumeScheduler: LimitResumeScheduler?
    /// Per-daemon tmux control-mode supervisor. Owned here so it can be stopped
    /// on shutdown; the gate (`ControlModeGate.shouldEnable`) keeps it dormant
    /// unless `TBD_TMUX_CONTROL_MODE` is opted in and tmux is ≥ 3.2.
    let controlModeSupervisor = TmuxControlSupervisor()
    /// Sidecar Unix socket server that vends per-pane file descriptors to the
    /// app (SCM_RIGHTS). Owned here so it can be stopped on shutdown.
    let fdVendingServer = FDVendingServer()
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

    /// Decode the mock scenario at `fixturePath` and seed it into `database`.
    /// Fail-loud: any decode or seed failure is re-thrown, aborting daemon
    /// startup. A half-seeded database (e.g. repo 2 of 2 tripped a UNIQUE
    /// constraint) would silently serve a wrong scenario, so we refuse to
    /// start rather than render partial state. The error is logged before
    /// rethrowing so the failure survives in daemon.log even as the process exits.
    static func seedMockDatabase(_ database: TBDDatabase, fixturePath: String) async throws {
        let url = URL(fileURLWithPath: fixturePath)
        do {
            let data = try Data(contentsOf: url)
            let scenario = try JSONDecoder().decode(MockScenario.self, from: data)
            try await MockSeeder().seed(
                scenario: scenario, into: database,
                fixtureDirectory: url.deletingLastPathComponent())
            daemonLogger.info("Mock mode: seeded fixture \(fixturePath, privacy: .public)")
        } catch {
            daemonLogger.error("Mock seeding failed for \(fixturePath, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// The DB-mutating startup reconciliation, gated on mock mode. Extracted
    /// from `start()` so the mock-mode branch is unit-testable without spawning
    /// the socket/HTTP servers or background tasks. In mock mode this is a
    /// no-op so hand-seeded fixtures render exactly as authored.
    func performStartupReconciliation(
        mockMode: MockMode?, database: TBDDatabase, git: GitManager, lifecycle: WorktreeLifecycle
    ) async {
        guard mockMode == nil else {
            daemonLogger.info("Mock mode: skipping startup reconciliation")
            return
        }
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
        // Backfill archived worktrees whose branch is missing — repairs
        // rows whose branch was renamed before archive captured the new name.
        // Idempotent and best-effort; never throws.
        await ArchivedWorktreeBackfill(db: database, git: git).run()
        // Validate repo health — flips repos with stale paths to .missing.
        // Must come *after* reconcile so newly-discovered worktrees see the
        // correct status, and *before* the periodic tasks so users get accurate
        // [missing] tags as soon as the daemon is up.
        let healthValidator = RepoHealthValidator(git: git)
        await healthValidator.validateAll(db: database)
    }

    /// Recreate the base scratch directory if it's missing. Safe to call every startup.
    static func ensureScratchDir() {
        let fm = FileManager.default
        let dir = TBDConstants.scratchDir.path
        if !fm.fileExists(atPath: dir) {
            do {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            } catch {
                daemonLogger.warning("Failed to recreate scratch dir at \(dir, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Start the daemon: create config directory, clean up stale state,
    /// initialize database and all managers, start servers, reconcile worktrees.
    public func start() async throws {
        // 0. Raise the file-descriptor limit before any tmux server is spawned.
        Self.raiseFileDescriptorLimit()

        // Mock harness: when TBD_MOCK is set, this daemon seeds a fixture and
        // skips all live reconciliation so hand-authored state renders as
        // written. Runs against an isolated TBD_HOME — never the real ~/tbd.
        let mockMode = MockMode.fromEnvironment(ProcessInfo.processInfo.environment)

        // 1. Create ~/tbd/ directory if needed
        let configDir = TBDConstants.configDir.path
        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir) {
            try fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }
        Self.ensureScratchDir()

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

        // 5a. Mock seeding: populate the freshly-migrated DB before servers
        // accept traffic, so the app never sees an empty-then-populated flash.
        if case let .enabled(fixturePath) = mockMode {
            try await Self.seedMockDatabase(database, fixturePath: fixturePath)
        }

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
            tmuxVersion: tmuxVersion,
            fdVending: fdVendingServer,
            // Live provider, not a snapshot: the gate re-reads the persisted
            // Settings flag on every attach decision (M5), so a toggle takes
            // effect without a daemon restart.
            persistedFlagProvider: { [config = database.config] in
                (try? await config.get().controlModeEnabled) ?? false
            }
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

        // Wire nightwatch evaluation: when a PR status is refreshed, evaluate it through
        // the merge gate and log the decision to the audit store (evaluate-only, no merging).
        await prManager.setOnPRStatusComputed { worktreeID, status, repoPath in
            let config = try? await database.config.get()
            guard let config, config.nightwatchMode != .off else { return }

            // Load policy from .nightwatch/policy.json (conservative defaults if absent/malformed)
            let policy = NightwatchPolicy.load(repoPath: repoPath)
            let gate = MergeGate(policy: policy)

            // Build gate input from PR status. For Phase 1, we make conservative assumptions:
            // - hasApprovedReview = false (not fetched yet, Phase 1 is evaluate-only)
            // - checksClean = false (not fetched yet)
            // - files/commits/author = nil (not fetched yet)
            // This ensures Phase 1 gates are conservative (most PRs will escalate).
            let input = GateInput(
                prNumber: status.number,
                repo: repoPath,
                headSHA: "unknown",  // Not available in PRStatus
                isDraft: status.state == .draft,
                hasApprovedReview: false,
                checksClean: status.state == .mergeable || status.state == .merged,
                files: nil,
                commits: nil,
                authorWorktreeID: nil,
                approvedSHA: nil,
                touchesCI: false
            )

            let decision = gate.evaluate(input: input)
            let action: AuditAction
            let details: String

            switch decision {
            case .wouldMerge(clearanceID: let cid):
                action = .wouldMerge
                details = "Phase 1: would-merge marker (\(cid))"
            case .hold(let reason):
                action = .hold
                details = "Hold reason: \(reason)"
            case .escalate(let reason):
                action = .escalate
                details = "Escalate reason: \(reason)"
            }

            let entry = AuditLogEntry(
                action: action,
                prNumber: status.number,
                repo: repoPath,
                headSHA: "unknown",
                timestamp: Date(),
                details: details
            )
            try? await database.audit.logAction(entry)
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

        // Shared foreground gate: the app reports its active/inactive state via
        // `app.setForegroundState`; the periodic git tasks below slow their
        // cadence when no app is foreground (see GitPollCadence). MUST be wired
        // before the socket starts serving — the app pushes its state once per
        // (re)connect, and a push landing on a nil gate would be silently
        // dropped, leaving a foreground app at background cadence.
        let appForeground = AppForegroundState()
        rpcRouter.appForegroundState = appForeground

        // 9. Start socket server
        let sock = SocketServer(router: rpcRouter)
        self.socketServer = sock
        // Wire the live connected-client count into daemon.status (the router
        // is built above, before the server exists, so it can't be an init dep).
        rpcRouter.connectedClientsProvider = { [weak sock] in sock?.connectedClients ?? 0 }
        try await sock.start()

        // 9a. Install the app → daemon input sink BEFORE the sidecar listens:
        // each adopted connection captures `onInput` at adopt time (M2.1
        // contract), so wiring it after `listen` would miss the app's connect.
        // The router is the bridge's (default-wired to `controlModeSupervisor`).
        await fdVendingServer.setOnInput { [inputRouter = controlModeBridge.inputRouter] header, bytes in
            inputRouter.enqueue(header: header, bytes: bytes)
        }
        // Bulk pastes ride the SAME router (and thus the same ordered stream) so
        // a keystroke after a paste stays FIFO-behind it (the M2 paste ruling).
        await fdVendingServer.setOnPaste { [inputRouter = controlModeBridge.inputRouter] header, bytes in
            inputRouter.enqueuePaste(header: header, bytes: bytes)
        }

        // 9b. Start the FD-vending sidecar socket (SCM_RIGHTS channel to the
        // app). Failure is non-fatal: control-mode attaches will fail and the
        // app falls back to grouped sessions.
        do {
            try await fdVendingServer.listen(on: TBDConstants.vendSocketPath)
        } catch {
            daemonLogger.error("failed to start FD vending sidecar: \(error.localizedDescription, privacy: .public)")
        }

        // 10. Start HTTP server
        let http = HTTPServer(router: rpcRouter)
        self.httpServer = http
        try await http.start()

        if mockMode == nil {
            // 11. Reconcile parked (hibernated / legacy-suspended) state: clear a
            // stale parked timestamp for any terminal whose Claude is still alive.
            await rpcRouter.hibernationCoordinator.reconcileOnStartup()
        }

        // 11. Perform DB-mutating reconciliation (skipped in mock mode so fixtures render as authored)
        await performStartupReconciliation(mockMode: mockMode, database: database, git: git, lifecycle: lifecycle)

        if mockMode == nil {
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

            // Effective foreground for the git cadence gates: the app-reported
            // state AND at least one live client connection, so a crashed or
            // force-quit app (which never reports `false`) can't pin the fast
            // cadence forever. See GitPollCadence.isEffectivelyForeground.
            let connectedClients = rpcRouter.connectedClientsProvider
            let effectivelyForeground: @Sendable () async -> Bool = {
                GitPollCadence.isEffectivelyForeground(
                    reportedForeground: await appForeground.isForeground,
                    connectedClients: connectedClients?() ?? 0
                )
            }

            // 12. Start periodic git fetch for all repos (60s foreground,
            // 5min background — GitPollCadence.fetchInterval).
            self.gitFetchTask = Task {
                while !Task.isCancelled {
                    await Daemon.sleepThroughGatedInterval {
                        GitPollCadence.fetchInterval(isForeground: await effectivelyForeground())
                    }
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

            // 12c. Start per-profile OAuth usage poller (90s cadence,
            // in-memory snapshots for the spawn-time account picker).
            let configDirManager = rpcRouter.configDirManager
            let oauthPoller = OAuthProfileUsagePoller(
                profilesProvider: { [database] in try await database.modelProfiles.list() },
                loginIdentity: { id in configDirManager.loginIdentity(forProfileID: id) },
                configDirPath: { id in configDirManager.configDirectory(forProfileID: id).path },
                fetcher: LiveProfileUsageFetcher(),
                broadcast: { [weak subs] in subs?.broadcast(delta: .modelProfilesChanged) }
            )
            self.oauthUsagePoller = oauthPoller
            rpcRouter.oauthUsagePoller = oauthPoller
            await oauthPoller.start()

            // 12d. Session-limit auto-resume scheduler (spec 2026-07-03).
            // Pending rows reload on start; past-due rows fire immediately
            // (covers Mac sleep and multi-day weekly-limit waits).
            let resumeActuator = LimitResumeActuator(
                db: database,
                tmux: tmux,
                inspector: ProductionPaneProcessInspector(),
                readTranscript: { path in FileManager.default.contents(atPath: path) },
                waiter: { duration in _ = try? await Task.sleep(for: duration) }
            )
            let resumeScheduler = LimitResumeScheduler(
                store: database.scheduledResumes,
                config: database.config,
                actuator: resumeActuator,
                clock: SystemPollerClock(),
                onOutcome: { [weak subs, database] resume, outcome in
                    let (type, message): (NotificationType, String)
                    switch outcome {
                    case .sent:
                        (type, message) = (.limitReached, "Auto-resumed Claude after the limit reset")
                    case .failed(let reason):
                        (type, message) = (.attentionNeeded,
                            "Auto-resume failed — \(reason). Claude may still be parked at the limit screen.")
                    }
                    guard let notification = try? await database.notifications.create(
                        worktreeID: resume.worktreeID, type: type,
                        message: message, terminalID: resume.terminalID)
                    else { return }
                    subs?.broadcast(delta: .notificationReceived(NotificationDelta(
                        notificationID: notification.id, worktreeID: notification.worktreeID,
                        type: notification.type, message: notification.message,
                        terminalID: notification.terminalID)))
                }
            )
            self.limitResumeScheduler = resumeScheduler
            rpcRouter.limitResumeScheduler = resumeScheduler
            await resumeScheduler.start()

            // 13. Periodic git status refresh (branch sync, conflict detection).
            // 10s foreground, 60s background (GitPollCadence.statusInterval);
            // per-worktree conflict checks are additionally dirty-gated inside
            // refreshGitStatuses so an unchanged worktree costs no subprocess.
            self.gitStatusTask = Task {
                // Run once immediately (cold recovery), then at the gated cadence
                while !Task.isCancelled {
                    let allRepos = (try? await database.repos.list()) ?? []
                    // Skip .missing repos to match gitFetchTask — running git
                    // against a stale path produces quiet 10s-cadence noise.
                    for repo in allRepos where repo.status != .missing {
                        await lifecycle.refreshGitStatuses(repoID: repo.id)
                    }
                    await Daemon.sleepThroughGatedInterval {
                        GitPollCadence.statusInterval(isForeground: await effectivelyForeground())
                    }
                }
            }

            // 14. Auto-hibernate idle sweep. Cheap poll every 30s; the actual
            // kill decision is made against the configured idle window (default
            // 30 min) with a debounce, inside the coordinator. The feature's
            // master switch is read from config on each sweep, so toggling it
            // off takes effect without a restart.
            let hibernationCoordinator = rpcRouter.hibernationCoordinator
            self.hibernationSweepTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { break }
                    await hibernationCoordinator.sweep()
                }
            }
        } else {
            daemonLogger.info("Mock mode: skipping periodic background tasks")
        }

        daemonLogger.info("Started successfully (PID \(ProcessInfo.processInfo.processIdentifier, privacy: .public))")
    }

    /// Sleep in `GitPollCadence.pollTick` ticks until the gated interval has
    /// elapsed. `interval` is re-evaluated every tick, so a foreground
    /// transition or app disconnect changes the effective cadence within one
    /// tick instead of one full background interval (e.g. after a daemon
    /// restart under a foregrounded app, the first fetch still lands at ~60s
    /// rather than the 5min sampled before the app reconnected). Returns
    /// promptly on task cancellation.
    static func sleepThroughGatedInterval(_ interval: @Sendable () async -> Duration) async {
        var waited = Duration.zero
        while !Task.isCancelled {
            try? await Task.sleep(for: GitPollCadence.pollTick)
            waited += GitPollCadence.pollTick
            let due = await interval()
            if waited >= due { return }
        }
    }

    /// Stop the daemon: shut down servers, remove PID and socket files.
    public func stop() async {
        daemonLogger.info("Shutting down...")

        // Stop Claude usage pollers before other background tasks.
        if let poller = claudeUsagePoller {
            await poller.stop()
        }
        if let poller = oauthUsagePoller {
            await poller.stop()
        }

        if let resumeScheduler = limitResumeScheduler {
            await resumeScheduler.stop()
        }

        // Stop any tmux control-mode connections (no-op when the gate is off).
        await controlModeSupervisor.stopAll()

        // Stop the FD-vending sidecar (closes the listener + any client).
        await fdVendingServer.stop()

        // Cancel background tasks
        sshRefreshTask?.cancel()
        gitFetchTask?.cancel()
        gitStatusTask?.cancel()
        reaperTask?.cancel()
        hibernationSweepTask?.cancel()

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
