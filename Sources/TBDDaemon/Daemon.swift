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
    /// Orphan-GC hourly sweep task (agent worktrees + scratchpads). `nil` in
    /// mock mode. See `orphanGC` for the actor it drives.
    public nonisolated(unsafe) var gcTask: Task<Void, Never>?
    /// Orphan-GC actor. Owned here so `gc.*` RPC handlers (Task 9) can reach
    /// it the same way they reach `rpcRouter.hibernationCoordinator`. `nil`
    /// in mock mode (never constructed).
    public nonisolated(unsafe) var orphanGC: OrphanGC?
    /// Remote-backends actor (Task 7). Owned here so shutdown can reach it —
    /// the events supervisor's own supervision task retains the manager
    /// strongly, so without an explicit `shutdown()` call it (and its child
    /// processes) would outlive the daemon process. `nil` when
    /// `config.remoteBackendsEnabled` was off at boot (mock mode, or the
    /// flag genuinely off) — constructed only once, at startup; flipping the
    /// flag on later takes effect on the next restart.
    public nonisolated(unsafe) var remoteManager: RemoteProviderManager?
    /// Deferred `remoteManager.start()` task (see call site below). Stored so
    /// `stop()` can cancel it — otherwise a SIGTERM inside the boot window
    /// leaves `loadRegistryAndDescribe` spawning `describe` child processes
    /// after `shutdown()` has already torn down the manager, orphaning them.
    public nonisolated(unsafe) var remoteStartTask: Task<Void, Never>?
    public nonisolated(unsafe) var claudeUsagePoller: ClaudeUsagePoller?
    public nonisolated(unsafe) var oauthUsagePoller: OAuthProfileUsagePoller?
    /// Session-limit auto-resume scheduler. Owned here so it can be stopped
    /// on shutdown; `nil` in mock mode.
    public nonisolated(unsafe) var limitResumeScheduler: LimitResumeScheduler?
    public nonisolated(unsafe) var daywatchRunner: DaywatchRunner?
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

        // 3. Check if another daemon is already running. Verify the pid is a
        // live TBDDaemon, not merely a live process: after a reboot the recorded
        // pid can be recycled by something unrelated, and a bare kill(pid, 0)
        // would make this fresh daemon abort forever until that pid frees —
        // exactly the multi-minute "disconnected on restart" gap. cleanupIfStale
        // above already removed the pid/socket in that case, so read() is nil.
        if let existingPID = pidFile.read(),
           ProcessLiveness.isLiveNamedProcess(pid: existingPID, name: ProcessLiveness.daemonExecutableName) {
            daemonLogger.error("Another daemon is already running (PID \(existingPID, privacy: .public)). Exiting.")
            Foundation.exit(1)
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
                // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
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
        // Input activity tracker: records the timestamp of the last keystroke
        // routed to each pane so the idle sweep can veto a park if input arrived
        // after the session went idle (pending-input detection).
        let inputActivity = InputActivityTracker()
        // Input router with the health sink wired to the state-delta broadcast
        // (#318 polish): edge-triggered per-pane input-delivery transitions
        // ride the same subscription channel the app already listens on.
        let controlModeInputRouter = ControlModeInputRouter(
            commandProvider: { [supervisor = controlModeSupervisor] server in
                await supervisor.command(server: server)
            },
            onHealthChange: { [subs] worktreeID, paneID, healthy, generation in
                subs.broadcast(delta: .controlModeInputHealthChanged(ControlModeInputHealthDelta(
                    worktreeID: worktreeID, paneID: paneID, healthy: healthy,
                    generation: generation)))
            },
            onInput: { [inputActivity] paneID in
                inputActivity.recordInput(paneID: paneID)
            }
        )
        let controlModeBridge = TmuxControlModeBridge(
            supervisor: controlModeSupervisor,
            tmuxVersion: tmuxVersion,
            fdVending: fdVendingServer,
            inputRouter: controlModeInputRouter,
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

        // Orphan-GC: constructed here — before `lifecycle` gets copied into
        // the RPC router / auto-archive coordinator below (both take a
        // value-type snapshot at their own init) — so the archive-event
        // callback reaches every consumer of `lifecycle`. `nil` in mock mode,
        // mirroring every other background-task guard in this method; the
        // periodic sweep task itself is started later, alongside the reaper,
        // inside the main `if mockMode == nil` block.
        if mockMode == nil {
            let gc = OrphanGC(db: database, git: git, broadcast: { [subs] delta in subs.broadcast(delta: delta) })
            self.orphanGC = gc
            lifecycle.onWorktreeRemoved = { [gc] path, repoPath in
                await gc.scratchpadCleanup(forRemovedWorktreePath: path, repoPath: repoPath)
            }
        }

        // Remote backends (Task 7): constructed at boot ONLY when the flag
        // is already on — a user flipping `config.setRemoteBackends` on
        // without restarting will see `remote.*` RPCs degrade to "remote
        // backends disabled" (RPCRouter+RemoteHandlers.swift) rather than a
        // crash, until the next restart picks it up. Skipped in mock mode,
        // like every other background-task guard in this method.
        //
        // `self.remoteManager` is assigned IMMEDIATELY, before `start()` is
        // even called (start() is deferred below, off the boot critical
        // path, alongside the reaper/GC tasks) — so a SIGTERM that lands
        // while `start()` is still describing providers still finds a
        // non-nil `remoteManager` and `stop()` can reach `shutdown()`.
        // Assigning only after an awaited `start()` would leave a mid-start
        // shutdown request with nothing to call, orphaning the manager and
        // any provider child processes it spawned.
        var remoteManager: RemoteProviderManager?
        if mockMode == nil, (try? await database.config.get())?.remoteBackendsEnabled == true {
            let manager = RemoteProviderManager(
                db: database, subscriptions: subs, runner: ProviderRunner(),
                registryURL: URL(fileURLWithPath: TBDConstants.agentProvidersPath))
            self.remoteManager = manager
            remoteManager = manager
        }

        let prManager = PRStatusManager()

        // Hydrate PR status cache from the DB so PR icons survive restart, then
        // persist future updates back to the DB.
        let persistedPRStatuses = (try? await database.worktrees.allPRStatuses()) ?? [:]
        await prManager.hydrate(persistedPRStatuses)
        await prManager.setOnStatusPersist { worktreeID, status in
            try? await database.worktrees.setPRStatus(id: worktreeID, status: status)
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
            pendingQuestions: pendingQuestions,
            remoteManager: remoteManager
        )
        // Wire the shared input activity tracker to the coordinator
        await rpcRouter.hibernationCoordinator.setInputActivity(inputActivity)
        rpcRouter.controlMode = controlModeBridge
        // The wake path recreates a terminal's tmux server/window when the
        // window is gone (e.g. post-reboot); give the recreated server the
        // same gated control-mode connection as every other ensureServer
        // call site.
        await rpcRouter.hibernationCoordinator.setOnServerCreated { server in
            await controlModeBridge.enableIfGated(serverName: server)
        }

        // 8a. Wire the merged-PR transition fan-out. When a worktree's cached PR
        // state transitions into `.merged`, the dispatcher evaluates auto-archive
        // (archive supersedes hibernate) and, if the worktree survives, auto-park
        // its idle Claude sessions. `PRStatusManager.onMergedTransition` is a
        // SINGLE callback, so the dispatcher owns both coordinators.
        //
        // ORDERING CONSTRAINT — do NOT move this earlier: the hibernate
        // coordinator needs `rpcRouter.hibernationCoordinator`, which only exists
        // after the RPCRouter is constructed above. It's safe here because the
        // only thing that fires a merged transition is `PRStatusManager.fetchAll`
        // / `refresh`, both reachable ONLY via the `pr.list` / `pr.refresh` RPC
        // handlers — and the socket server that serves those doesn't start until
        // step 9 below. So no merge can be observed between construction and here.
        let autoArchiveCoordinator = AutoArchiveOnMergeCoordinator(
            db: database, lifecycle: lifecycle, subscriptions: subs)
        let autoHibernateCoordinator = AutoHibernateOnMergeCoordinator(
            db: database, hibernation: rpcRouter.hibernationCoordinator, subscriptions: subs)
        let mergedTransitionDispatcher = MergedTransitionDispatcher(
            archive: autoArchiveCoordinator, hibernate: autoHibernateCoordinator)
        await prManager.setOnMergedTransition { worktreeID, prNumber in
            await mergedTransitionDispatcher.handleMergedTransition(worktreeID: worktreeID, prNumber: prNumber)
        }

        self.router = rpcRouter
        // Post-construction wiring, same shape as `claudeUsagePoller` below:
        // `orphanGC` was constructed earlier (before `lifecycle`) so the
        // archive-event callback could reach it; the `gc.*` handlers reach it
        // through the router the same way they reach `hibernationCoordinator`.
        rpcRouter.orphanGC = orphanGC

        // Shared foreground gate: the app reports its active/inactive state via
        // `app.setForegroundState`; the periodic git tasks below slow their
        // cadence when no app is foreground (see GitPollCadence). MUST be wired
        // before the socket starts serving — the app pushes its state once per
        // (re)connect, and a push landing on a nil gate would be silently
        // dropped, leaving a foreground app at background cadence.
        let appForeground = AppForegroundState()
        rpcRouter.appForegroundState = appForeground

        // 8b. Migrate legacy per-repo claude_settings_overlay column values
        // (v53, PR #452) to their file-backed home under
        // `~/tbd/repos/<repoID>/claude-settings.json`. Idempotent; converges
        // to a no-op once every row is NULL. MUST run before the servers
        // start serving (steps 9/10): spawn RPCs read the overlay file, and a
        // spawn landing before the sweep would miss a legacy column value.
        await database.repos.sweepClaudeSettingsOverlayColumnToFiles()

        // 8c. One-time export of legacy DB note content to its file-backed
        // home (`~/tbd/notes/<worktreeID>/<noteID>.md`). Unlike 8b the DB
        // column is NOT cleared — it stays as a dormant fallback/backup; the
        // file wins once it exists. Idempotent (file-exists guard), so no
        // migration or marker is needed. Best-effort, never blocks startup.
        await database.notes.exportContentColumnToFiles()

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
        // The router is the bridge's (built above with the health sink, wired
        // to `controlModeSupervisor`'s correlators).
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
                    // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled else { break }
                    await reaper.sweep(servers: await ownedServers())
                }
            }

            // 11a-gc. Orphan-GC: reap abandoned agent worktrees + scratchpads
            // (event-driven cleanup already runs via `lifecycle.onWorktreeRemoved`
            // above; this periodic sweep catches everything else — worktrees
            // orphaned outside a TBD-initiated remove, e.g. manual `rm -rf`).
            // Constructed above (guarded the same `mockMode == nil` check), so
            // `orphanGC` is always non-nil here.
            if let orphanGC {
                self.gcTask = Task {
                    // Sweep once immediately (cold recovery), then every hour.
                    _ = await orphanGC.sweep()
                    while !Task.isCancelled {
                        // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
                        try? await Task.sleep(for: .seconds(3600))
                        guard !Task.isCancelled else { break }
                        _ = await orphanGC.sweep()
                    }
                }
            }

            // 11a-remote. Remote backends (Task 7): `manager.start()` runs a
            // sequential `describe` (10s timeout each) per registered
            // provider, then spawns poll loops. Fired off the boot critical
            // path — same shape as the reaper/GC tasks above — so N slow or
            // hung providers don't delay the RPC listener coming up.
            // `remoteManager` was already assigned on `self` above, so a
            // shutdown request racing this task still has a live handle to
            // call `shutdown()` on (see the `shuttingDown` guard in
            // `spawnPollLoops()`).
            if let remoteManager {
                self.remoteStartTask = Task {
                    await remoteManager.start()
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
            // snapshots for the spawn-time account picker, DB-cached so
            // restarts show last-known bars instead of "usage unavailable").
            let configDirManager = rpcRouter.configDirManager
            let oauthPoller = OAuthProfileUsagePoller(
                profilesProvider: { [database] in try await database.modelProfiles.list() },
                loginIdentity: { id in configDirManager.loginIdentity(forProfileID: id) },
                configDirPath: { id in configDirManager.configDirectory(forProfileID: id).path },
                fetcher: LiveProfileUsageFetcher(),
                broadcast: { [weak subs] in subs?.broadcast(delta: .modelProfilesChanged) },
                loadPersisted: { [database] in
                    (try? await database.oauthUsageSnapshots.loadAll()) ?? [:]
                },
                persist: { [database] id, snapshot in
                    try? await database.oauthUsageSnapshots.upsert(profileID: id, snapshot: snapshot)
                },
                prunePersisted: { [database] eligibleIDs in
                    try? await database.oauthUsageSnapshots.deleteExcept(profileIDs: eligibleIDs)
                }
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
                // swiftlint:disable:next no_raw_task_sleep - already seamed: this closure IS the production value of `LimitResumeActuator`'s non-defaulted `waiter:` parameter (the seam itself), exercised by Tests/TBDDaemonTests/LimitResumeActuatorTests.swift which injects `waiter: { _ in }` at 5 construction sites; see docs/specs/2026-07-24-test-hardening-design.md
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
                        if resume.limitType == ScheduledResume.apiErrorLimitType {
                            (type, message) = (.limitReached, "Auto-continued Claude after a transient API error")
                        } else {
                            (type, message) = (.limitReached, "Auto-resumed Claude after the limit reset")
                        }
                    case .failed(let reason):
                        if resume.limitType == ScheduledResume.apiErrorLimitType {
                            (type, message) = (.attentionNeeded,
                                "Auto-continue failed — \(reason). Claude may still be stopped on an API error.")
                        } else {
                            (type, message) = (.attentionNeeded,
                                "Auto-resume failed — \(reason). Claude may still be parked at the limit screen.")
                        }
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

            // 12e. Start daywatch runner (autonomous fleet babysitter loop).
            let skillDir = PluginDirWriter.pluginDirPath + "/skills/nightwatch"
            let executor = ProcessDaywatchExecutor(skillDir: skillDir)

            // Phase A: Create desk session manager for visible worker
            let deskSessionManager = DeskSessionManager(
                db: database,
                lifecycle: lifecycle,
                tmux: tmux,
                skillDir: skillDir,
                subscriptions: subs
            )

            let runner = DaywatchRunner(
                executor: executor,
                deskSessionManager: deskSessionManager,
                interval: DaywatchRunner.defaultInterval
            )
            self.daywatchRunner = runner
            rpcRouter.daywatchRunner = runner
            // Boot-reconcile: if nightwatch mode was persisted, restart the loop.
            do {
                let config = try await database.config.get()
                await runner.apply(mode: config.nightwatchMode)
            } catch {
                reconcileLogger.error("Failed to restore daywatch mode on boot: \(String(describing: error), privacy: .public)")
            }

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
                    // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
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

    /// Sleep in `tick`-sized steps (default `GitPollCadence.pollTick`) until the
    /// gated interval has elapsed. `interval` is re-evaluated every tick, so a foreground
    /// transition or app disconnect changes the effective cadence within one
    /// tick instead of one full background interval (e.g. after a daemon
    /// restart under a foregrounded app, the first fetch still lands at ~60s
    /// rather than the 5min sampled before the app reconnected). Returns
    /// promptly on task cancellation.
    ///
    /// - Parameters:
    ///   - tick: how long to wait between re-evaluations of `interval`.
    ///     Injectable so a test can cross a threshold in two or three clock
    ///     advances instead of a production-sized chain.
    ///   - clock: delay seam (`Tests/CLAUDE.md`, "Clock and date seams"). This
    ///     loop is pure `Duration` accumulation, so the existential's inability
    ///     to express `Instant` math never bites.
    static func sleepThroughGatedInterval(
        _ interval: @Sendable () async -> Duration,
        tick: Duration = GitPollCadence.pollTick,
        clock: any Clock<Duration> = ContinuousClock()
    ) async {
        var waited = Duration.zero
        while !Task.isCancelled {
            // `try?` swallows the cancellation error rather than checking for it;
            // the loop head is what observes cancellation. A cancelled sleep
            // therefore costs one extra `interval()` evaluation, which is
            // side-effect-free today. That stops holding if `interval` ever gains
            // side effects or if the `while` condition stops re-checking
            // `Task.isCancelled`.
            try? await clock.sleep(for: tick)
            waited += tick
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

        // Cancel the deferred remote-backends boot task BEFORE tearing down
        // the manager, and AWAIT it here rather than merely signalling it
        // (see the old bug this replaces, on `remoteStartTask?.cancel()`
        // further down): `start()` runs `loadRegistryAndDescribe()` then
        // `spawnPollLoops()` in sequence, and a SIGTERM landing in the first
        // few seconds of boot can catch it mid `describe` — before
        // `spawnPollLoops()` has ever run, `remoteManager.shutdown()` alone
        // tears down loops/supervisors that don't exist yet and does
        // nothing for the in-flight child. `runBoundedProcess` now wires
        // outer-task cancellation into its own deadline (`CancellationRelay`
        // in `BoundedProcessRunner.swift`), so `cancel()` here interrupts an
        // in-flight `describe` immediately rather than only being observed
        // between providers in `loadRegistryAndDescribe`'s loop — but that
        // interruption still runs ON this task, so it needs the daemon
        // process (and the `SubprocessWatchdog` thread that reaps the killed
        // child) to still be alive to finish unwinding. Awaiting `.value`
        // here, before `Foundation.exit(0)` below, is what guarantees that;
        // without it the process could tear down mid-unwind and orphan the
        // child exactly as before.
        remoteStartTask?.cancel()
        await remoteStartTask?.value

        // Stop remote-backends poll loops / events supervisors. Required,
        // not optional: the events supervisor's supervision task retains
        // the manager strongly, so without this call the manager and its
        // child provider processes are immortal. `shutdown()` (not the bare
        // `stopAll()`) takes the manager's own reconfigure lock so this
        // can't interleave with an in-flight `start()`/`spawnPollLoops()`.
        if let remoteManager {
            await remoteManager.shutdown()
        }

        // Stop daywatch runner.
        if let runner = daywatchRunner {
            await runner.apply(mode: .off)
        }

        // Stop any tmux control-mode connections (no-op when the gate is off).
        await controlModeSupervisor.stopAll()

        // Stop the FD-vending sidecar (closes the listener + any client).
        await fdVendingServer.stop()

        // Cancel background tasks. `remoteStartTask` is cancelled (and
        // awaited) earlier, above — see that comment for why it can't wait
        // until here.
        sshRefreshTask?.cancel()
        gitFetchTask?.cancel()
        gitStatusTask?.cancel()
        reaperTask?.cancel()
        hibernationSweepTask?.cancel()
        gcTask?.cancel()

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
