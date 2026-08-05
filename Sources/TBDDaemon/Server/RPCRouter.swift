import Foundation
import os
import TBDShared

private let routerLogger = Logger(subsystem: "com.tbd.daemon", category: "rpcRouter")

/// Maps RPC method names to handler functions.
/// Decodes raw JSON params, dispatches to the appropriate subsystem, and returns an RPCResponse.
public final class RPCRouter: Sendable {
    public let db: TBDDatabase
    public let lifecycle: WorktreeLifecycle
    public let tmux: TmuxManager
    public let git: GitManager
    public let startTime: Date
    public let subscriptions: StateSubscriptionManager
    public let prManager: PRStatusManager
    public let hibernationCoordinator: HibernationCoordinator
    /// Append-only record of every state-changing actuation this router
    /// performs. Shared with the daemon-internal rails (see `Daemon.swift`) so
    /// the whole daemon writes one file. Handlers append a request row before
    /// their first mutating step and an outcome row after the act returns —
    /// see `RPCRouter+Actuation.swift`.
    public let actuationLog: ActuationLog
    public let usageFetcher: ClaudeUsageFetcher
    public let modelProfileResolver: ModelProfileResolver
    public nonisolated(unsafe) var daywatchRunner: DaywatchRunner?
    public nonisolated(unsafe) var claudeUsagePoller: ClaudeUsagePoller?
    /// Orphan-GC actor. `nil` in mock mode / unit tests that don't need it;
    /// set post-construction by `Daemon.swift` (mirrors `claudeUsagePoller`).
    /// The `gc.*` handlers return an error response rather than crashing when
    /// this is nil.
    public nonisolated(unsafe) var orphanGC: OrphanGC?
    /// Remote-backends actor. Constructed at boot ONLY when
    /// `config.remoteBackendsEnabled` is true (see `Daemon.swift`); `nil`
    /// otherwise, including when a user flips the flag on without
    /// restarting. `remote.*` handlers return an error response rather than
    /// crashing when this is nil — see `RPCRouter+RemoteHandlers.swift`.
    let remoteManager: RemoteProviderManager?
    /// In-memory per-profile OAuth usage poller. Wired post-construction by
    /// Daemon.swift (mirrors `claudeUsagePoller`); nil in unit tests / mock
    /// mode, where usage snapshots are simply absent.
    public nonisolated(unsafe) var oauthUsagePoller: OAuthProfileUsagePoller?
    /// Shared app-foreground gate for the daemon's periodic git tasks. Wired
    /// post-construction by Daemon.swift (mirrors `claudeUsagePoller`); `nil`
    /// in unit tests that don't exercise the foreground RPC.
    public nonisolated(unsafe) var appForegroundState: AppForegroundState?
    /// Session-limit auto-resume scheduler. `nil` in mock mode / tests that
    /// don't need it; set post-construction like `claudeUsagePoller`.
    public nonisolated(unsafe) var limitResumeScheduler: LimitResumeScheduler?
    /// Live connected-client count, supplied by the SocketServer after it is
    /// constructed (the router is built first in Daemon.swift, so it cannot
    /// take the server as an init dependency). Mirrors `claudeUsagePoller`
    /// post-construction wiring. `nil` for unit tests / HTTP-only paths, which
    /// report 0.
    public nonisolated(unsafe) var connectedClientsProvider: (@Sendable () -> Int)?
    /// Test-only injection seam: when set, `handleScratchPromote` awaits this
    /// immediately before the row migration (`promoteScratchMigration`). A
    /// throw simulates a mid-promote migration failure at the worst moment —
    /// AFTER the folder move and repo registration succeeded — so RPC-level
    /// tests can drive the full handler path and assert that both non-DB side
    /// effects get rolled back. Never set in production; when nil (always,
    /// outside tests) the promote path is unchanged.
    nonisolated(unsafe) var scratchPromoteMigrationFailureHook: (@Sendable () async throws -> Void)?
    public let pendingQuestions: PendingQuestionStore
    public let repoSerializer: RepoSerializer
    public let configDirManager: ClaudeProfileConfigDirManager
    /// Deletes per-profile Claude Code OAuth credential items from the login
    /// keychain on profile delete. Injected so tests can record the requested
    /// service name instead of touching the real keychain.
    public let claudeCredentialsKeychain: ClaudeCredentialsKeychainDeleting
    /// Auto-`/login` typing + login-completion watching for profile login
    /// sessions. Injected so tests can zero out the trigger delays.
    public let loginSessions: LoginSessionCoordinator
    /// Daemon-owned panel surface actor (spec C Phase 2). Gating lives inside
    /// the coordinator (§7.2) — `panel.*` handlers route to it and must not
    /// re-implement gating. Broadcasts through the same `subscriptions`
    /// channel every other mutating handler uses.
    public let panelCoordinator: PanelCoordinator
    /// Native Claude-to-Codex import seams. Production uses the installed
    /// Codex app-server; tests replace these before invoking the handler.
    nonisolated(unsafe) var codexExecutableResolver: @Sendable () throws -> String
    nonisolated(unsafe) var codexHomeEnsurer: @Sendable () throws -> URL
    nonisolated(unsafe) var codexProfileFlagResolver: @Sendable (String) -> String = { executable in
        CodexSpawnCommandBuilder.detectProfileFlag(executablePath: executable) { arguments in
            CodexSpawnCommandBuilder.commandOutput(arguments: arguments, timeout: 3)
        }
    }
    nonisolated(unsafe) var codexSessionImport: @Sendable (
        _ executablePath: String,
        _ codexHome: URL,
        _ transcriptPath: String,
        _ cwd: String,
        _ title: String?
    ) async throws -> String = { executablePath, codexHome, transcriptPath, cwd, title in
        try await CodexSessionImporter(
            executablePath: executablePath,
            codexHome: codexHome
        ).importSession(
            transcriptPath: transcriptPath,
            cwd: cwd,
            title: title)
    }

    /// Single-flights concurrent `pr.list` RPCs so a poll storm collapses into
    /// one git enumeration + gh fetch instead of N overlapping ones.
    let prListCoordinator = PRListCoordinator()
    /// TTL cache for per-worktree upstream branch lookups, so `pr.list` stops
    /// spawning a `git config` subprocess per worktree on every poll.
    let upstreamBranchCache = UpstreamBranchCache()
    /// Coalesces fetch operations per repo using a TTL cache + singleflight.
    let fetchCache = FetchCache()
    /// Opt-in tmux control-mode wiring. `nil` when the daemon did not provide
    /// one (tests, older callers); when present, terminal handlers open a gated
    /// logging-only `tmux -CC` connection after each `ensureServer()`.
    ///
    /// Set by `Daemon` after construction (`internal`, so the public init's
    /// signature does not leak the internal bridge type).
    nonisolated(unsafe) var controlMode: TmuxControlModeBridge?

    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    public init(
        db: TBDDatabase,
        lifecycle: WorktreeLifecycle,
        tmux: TmuxManager,
        git: GitManager = GitManager(),
        startTime: Date = Date(),
        subscriptions: StateSubscriptionManager = StateSubscriptionManager(),
        prManager: PRStatusManager = PRStatusManager(),
        usageFetcher: ClaudeUsageFetcher = LiveClaudeUsageFetcher(),
        modelProfileResolver: ModelProfileResolver? = nil,
        pendingQuestions: PendingQuestionStore = PendingQuestionStore(),
        repoSerializer: RepoSerializer = RepoSerializer(),
        configDirManager: ClaudeProfileConfigDirManager = ClaudeProfileConfigDirManager(),
        claudeCredentialsKeychain: ClaudeCredentialsKeychainDeleting = SecItemClaudeCredentialsKeychain(),
        loginSessions: LoginSessionCoordinator = LoginSessionCoordinator(),
        remoteManager: RemoteProviderManager? = nil,
        codexExecutableResolver: (@Sendable () throws -> String)? = nil,
        codexHomeEnsurer: (@Sendable () throws -> URL)? = nil,
        actuationLog: ActuationLog
    ) {
        self.actuationLog = actuationLog
        self.db = db
        self.lifecycle = lifecycle
        self.tmux = tmux
        self.git = git
        self.startTime = startTime
        self.subscriptions = subscriptions
        self.prManager = prManager
        let resolvedModelProfileResolver = modelProfileResolver ?? ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config
        )
        self.modelProfileResolver = resolvedModelProfileResolver
        self.hibernationCoordinator = HibernationCoordinator(
            db: db, tmux: tmux, modelProfileResolver: resolvedModelProfileResolver,
            subscriptions: subscriptions, configDirManager: configDirManager,
            actuationLog: actuationLog
        )
        self.usageFetcher = usageFetcher
        self.pendingQuestions = pendingQuestions
        self.repoSerializer = repoSerializer
        self.configDirManager = configDirManager
        self.controlMode = nil
        self.claudeCredentialsKeychain = claudeCredentialsKeychain
        self.loginSessions = loginSessions
        self.panelCoordinator = PanelCoordinator(
            db: db, broadcast: { [subscriptions] delta in subscriptions.broadcast(delta: delta) })
        self.remoteManager = remoteManager
        self.codexExecutableResolver = codexExecutableResolver ?? {
            if tmux.dryRun { return "/opt/tbd-test/bin/codex" }
            return try CodexExecutableResolver.resolve()
        }
        self.codexHomeEnsurer = codexHomeEnsurer ?? {
            if tmux.dryRun {
                return URL(fileURLWithPath: "/tmp/tbd-dry-run-codex-home", isDirectory: true)
            }
            return try CodexHomeManager().ensureProfilePlugin()
        }
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
                return try await handleRepoRemove(request.paramsData, actor: request.actor)
            case RPCMethod.repoList:
                return try await handleRepoList()
            case RPCMethod.scratchCreate:
                return try await handleScratchCreate(request.paramsData, actor: request.actor)
            case RPCMethod.scratchDelete:
                return try await handleScratchDelete(request.paramsData, actor: request.actor)
            case RPCMethod.scratchPromote:
                return try await handleScratchPromote(request.paramsData)
            case RPCMethod.scratchArchive:
                return try await handleScratchArchive(request.paramsData, actor: request.actor)
            case RPCMethod.scratchRevive:
                return try await handleScratchRevive(request.paramsData)
            case RPCMethod.repoUpdateInstructions:
                return try await handleRepoUpdateInstructions(request.paramsData)
            case RPCMethod.repoRelocate:
                return try await handleRepoRelocate(request.paramsData)
            case RPCMethod.repoRename:
                return try await handleRepoRename(request.paramsData)
            case RPCMethod.repoSetHidden:
                return try await handleRepoSetHidden(request.paramsData)
            case RPCMethod.repoSetExpanded:
                return try await handleRepoSetExpanded(request.paramsData)
            case RPCMethod.repoListBranches:
                return try await handleRepoListBranches(request.paramsData)
            case RPCMethod.repoListOpenPRs:
                return try await handleRepoListOpenPRs(request.paramsData)
            case RPCMethod.worktreeCreate:
                return try await handleWorktreeCreate(request.paramsData, actor: request.actor)
            case RPCMethod.worktreeList:
                return try await handleWorktreeList(request.paramsData)
            case RPCMethod.worktreeArchive:
                return try await handleWorktreeArchive(request.paramsData, actor: request.actor)
            case RPCMethod.worktreeRerunPreSession:
                return try await handleWorktreeRerunPreSession(request.paramsData, actor: request.actor)
            case RPCMethod.worktreeRevive:
                return try await handleWorktreeRevive(request.paramsData, actor: request.actor)
            case RPCMethod.worktreeReviveConversationFresh:
                return try await handleWorktreeReviveConversationFresh(request.paramsData, actor: request.actor)
            case RPCMethod.worktreeAdopt:
                return try await handleWorktreeAdopt(request.paramsData)
            case RPCMethod.worktreeRename:
                return try await handleWorktreeRename(request.paramsData)
            case RPCMethod.worktreeReorder:
                return try await handleWorktreeReorder(request.paramsData)
            case RPCMethod.worktreeMove:
                return try await handleWorktreeMove(request.paramsData)
            case RPCMethod.worktreeForget:
                return try await handleWorktreeForget(request.paramsData, actor: request.actor)
            case RPCMethod.terminalCreate:
                return try await handleTerminalCreate(request.paramsData, actor: request.actor)
            case RPCMethod.terminalContinueInCodex:
                return try await handleTerminalContinueInCodex(request.paramsData, actor: request.actor)
            case RPCMethod.terminalList:
                return try await handleTerminalList(request.paramsData)
            case RPCMethod.terminalSend:
                return try await handleTerminalSend(request.paramsData, actor: request.actor)
            case RPCMethod.terminalDelete:
                return try await handleTerminalDelete(request.paramsData, actor: request.actor)
            case RPCMethod.terminalSetPin:
                return try await handleTerminalSetPin(request.paramsData)
            case RPCMethod.terminalSwapProfile:
                return try await handleTerminalSwapProfile(request.paramsData, actor: request.actor)
            case RPCMethod.terminalSessionEvent:
                return try await handleTerminalSessionEvent(request.paramsData)
            case RPCMethod.terminalActivityEvent:
                return try await handleTerminalActivityEvent(request.paramsData)
            case RPCMethod.notify:
                return try await handleNotify(request.paramsData)
            case RPCMethod.terminalFocus:
                return try await handleTerminalFocus(request.paramsData)
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
            case RPCMethod.prList:
                return try await handlePRList()
            case RPCMethod.prRefresh:
                return try await handlePRRefresh(request.paramsData)
            case RPCMethod.claudeSetSpawnPreferences:
                return try await handleSetClaudeSpawnPreferences(request.paramsData)
            case RPCMethod.claudeRateLimitDetected:
                return try await handleRateLimitDetected(request.paramsData)
            case RPCMethod.claudeTransientApiErrorDetected:
                return try await handleTransientApiErrorDetected(request.paramsData)
            case RPCMethod.terminalCancelScheduledResume:
                return try await handleCancelScheduledResume(request.paramsData)
            case RPCMethod.attachRequest:
                return try await handleAttachRequest(request.paramsData)
            case RPCMethod.attachReady:
                return try await handleAttachReady(request.paramsData)
            case RPCMethod.paneDetach:
                return try await handlePaneDetach(request.paramsData)
            case RPCMethod.paneResize:
                return try await handlePaneResize(request.paramsData)
            case RPCMethod.daemonCapabilities:
                return try await handleDaemonCapabilities()
            case RPCMethod.terminalSuspend:
                return try await handleTerminalSuspend(request.paramsData, actor: request.actor)
            case RPCMethod.terminalResume:
                return try await handleTerminalResume(request.paramsData, actor: request.actor)
            case RPCMethod.worktreeSuspend:
                return try await handleWorktreeSuspend(request.paramsData, actor: request.actor)
            case RPCMethod.worktreeResume:
                return try await handleWorktreeResume(request.paramsData, actor: request.actor)
            case RPCMethod.terminalRecreateWindow:
                return try await handleTerminalRecreateWindow(request.paramsData, actor: request.actor)
            case RPCMethod.noteCreate:
                return try await handleNoteCreate(request.paramsData)
            case RPCMethod.noteGet:
                return try await handleNoteGet(request.paramsData)
            case RPCMethod.noteUpdate:
                return try await handleNoteUpdate(request.paramsData)
            case RPCMethod.noteDelete:
                return try await handleNoteDelete(request.paramsData)
            case RPCMethod.noteList:
                return try await handleNoteList(request.paramsData)
            case RPCMethod.terminalHistoryList:
                return try await handleTerminalHistoryList(request.paramsData)
            case RPCMethod.terminalHistoryRevive:
                return try await handleTerminalHistoryRevive(request.paramsData, actor: request.actor)
            case RPCMethod.terminalOutput:
                return try await handleTerminalOutput(request.paramsData)
            case RPCMethod.terminalConversation:
                return try await handleTerminalConversation(request.paramsData)
            case RPCMethod.terminalTranscript:
                return try await handleTerminalTranscript(request.paramsData)
            case RPCMethod.terminalTranscriptItemFullBody:
                return try await handleTerminalTranscriptItemFullBody(request.paramsData)
            case RPCMethod.terminalAskUserQuestionPending:
                return try await handleTerminalAskUserQuestionPending(request.paramsData)
            case RPCMethod.terminalAskUserQuestionCleared:
                return try await handleTerminalAskUserQuestionCleared(request.paramsData)
            case RPCMethod.modelProfileList:
                return try await handleModelProfileList()
            case RPCMethod.modelProfileAdd:
                return try await handleModelProfileAdd(request.paramsData)
            case RPCMethod.modelProfileDelete:
                return try await handleModelProfileDelete(request.paramsData)
            case RPCMethod.modelProfileRename:
                return try await handleModelProfileRename(request.paramsData)
            case RPCMethod.modelProfileUpdateEndpoint:
                return try await handleModelProfileUpdateEndpoint(request.paramsData)
            case RPCMethod.modelProfileUpdateBedrock:
                return try await handleModelProfileUpdateBedrock(request.paramsData)
            case RPCMethod.modelProfileSetGlobalDefault:
                return try await handleModelProfileSetGlobalDefault(request.paramsData)
            case RPCMethod.modelProfileSetPrimaryAgentPreference:
                return try await handleModelProfileSetPrimaryAgentPreference(request.paramsData)
            case RPCMethod.codexUsageFetch:
                return try await handleCodexUsageFetch()
            case RPCMethod.modelProfileSetRepoOverride:
                return try await handleModelProfileSetRepoOverride(request.paramsData)
            case RPCMethod.modelProfileReorder:
                return try await handleModelProfileReorder(request.paramsData)
            case RPCMethod.configSetEnvOverrides:
                return try await handleConfigSetEnvOverrides(request.paramsData)
            case RPCMethod.repoSetEnvOverrides:
                return try await handleRepoSetEnvOverrides(request.paramsData)
            case RPCMethod.modelProfileSetEnvOverrides:
                return try await handleModelProfileSetEnvOverrides(request.paramsData)
            case RPCMethod.modelProfileFetchUsage:
                return try await handleModelProfileFetchUsage(request.paramsData)
            case RPCMethod.modelProfileUsageRefresh:
                return try await handleModelProfileUsageRefresh(request.paramsData)
            case RPCMethod.modelProfileHealthCheck:
                return try await handleModelProfileHealthCheck(request.paramsData)
            case RPCMethod.modelProfilePrepareConfigDir:
                return try await handleModelProfilePrepareConfigDir(request.paramsData)
            case RPCMethod.appSetForegroundState:
                let params = try decoder.decode(AppSetForegroundStateParams.self, from: request.paramsData)
                await claudeUsagePoller?.onFocusChanged(isForeground: params.isForeground)
                await appForegroundState?.set(isForeground: params.isForeground)
                return .ok()
            case RPCMethod.appearanceUpdateColorFgBg:
                return try await handleAppearanceUpdateColorFgBg(request.paramsData)
            case RPCMethod.setMainAreaSize:
                return try await handleSetMainAreaSize(request.paramsData)
            case RPCMethod.sessionList:
                return try await handleSessionList(request.paramsData)
            case RPCMethod.sessionMessages:
                return try await handleSessionMessages(request.paramsData)
            case RPCMethod.stateSubscribe:
                return RPCResponse(error: "state.subscribe must be handled by SocketServer")
            case RPCMethod.daemonLegacyHooksStatus:
                return try await handleDaemonLegacyHooksStatus()
            case RPCMethod.daemonRemoveLegacyGlobalHooks:
                return try await handleDaemonRemoveLegacyGlobalHooks()
            case RPCMethod.tabSetLabel:
                return try await handleTabSetLabel(request.paramsData)
            case RPCMethod.tabSetOrder:
                return try await handleTabSetOrder(request.paramsData)
            case RPCMethod.tabList:
                return try await handleTabList(request.paramsData)
            case RPCMethod.worktreeSetActiveTab:
                return try await handleWorktreeSetActiveTab(request.paramsData)
            case RPCMethod.worktreeSetAutoArchive:
                return try await handleWorktreeSetAutoArchive(request.paramsData)
            case RPCMethod.worktreeSetAutoHibernate:
                return try await handleWorktreeSetAutoHibernate(request.paramsData)
            case RPCMethod.worktreeSetPin:
                return try await handleWorktreeSetPin(request.paramsData)
            case RPCMethod.worktreeReorderPins:
                return try await handleWorktreeReorderPins(request.paramsData)
            case RPCMethod.configGet:
                return try await handleConfigGet()
            case RPCMethod.configSetAutoArchiveOnMergeDefault:
                return try await handleConfigSetAutoArchiveDefault(request.paramsData)
            case RPCMethod.configSetAutoHibernateOnMergeDefault:
                return try await handleConfigSetAutoHibernateDefault(request.paramsData)
            case RPCMethod.configSetAutoResumeOnLimitReset:
                return try await handleConfigSetAutoResumeOnLimitReset(request.paramsData)
            case RPCMethod.configSetAutoResumeOnApiError:
                return try await handleConfigSetAutoResumeOnApiError(request.paramsData)
            case RPCMethod.configSetScratchInstructions:
                return try await handleConfigSetScratchInstructions(request.paramsData)
            case RPCMethod.configSetScratchRenamePrompt:
                return try await handleConfigSetScratchRenamePrompt(request.paramsData)
            case RPCMethod.configSetScratchProfileOverride:
                return try await handleConfigSetScratchProfileOverride(request.paramsData)
            case RPCMethod.nightwatchSetMode:
                return try await handleSetNightwatchMode(request.paramsData)
            case RPCMethod.nightwatchLeaseStatus:
                return try await handleNightwatchLeaseStatus(request.paramsData)
            case RPCMethod.nightwatchLeaseAcquire:
                return try await handleNightwatchLeaseAcquire(request.paramsData)
            case RPCMethod.nightwatchLeaseValidate:
                return try await handleNightwatchLeaseValidate(request.paramsData)
            case RPCMethod.nightwatchLeaseRenew:
                return try await handleNightwatchLeaseRenew(request.paramsData)
            case RPCMethod.nightwatchLeaseTransfer:
                return try await handleNightwatchLeaseTransfer(request.paramsData)
            case RPCMethod.nightwatchLeaseRelease:
                return try await handleNightwatchLeaseRelease(request.paramsData)
            case RPCMethod.terminalHibernate:
                return try await handleTerminalHibernate(request.paramsData, actor: request.actor)
            case RPCMethod.terminalWake:
                return try await handleTerminalWake(request.paramsData, actor: request.actor)
            case RPCMethod.terminalSetKeepWarm:
                return try await handleTerminalSetKeepWarm(request.paramsData)
            case RPCMethod.configSetAutoHibernate:
                return try await handleConfigSetAutoHibernate(request.paramsData)
            case RPCMethod.configSetControlMode:
                return try await handleConfigSetControlMode(request.paramsData)
            case RPCMethod.configSetHibernateInputVeto:
                return try await handleConfigSetHibernateInputVeto(request.paramsData)
            case RPCMethod.configSetAutoCloseSetup:
                return try await handleConfigSetAutoCloseSetup(request.paramsData)
            case RPCMethod.configSetAutoTrustWorktrees:
                return try await handleConfigSetAutoTrustWorktrees(request.paramsData)
            case RPCMethod.configSetGCEnabled:
                return try await handleConfigSetGCEnabled(request.paramsData)
            case RPCMethod.remoteProviders:
                return try await handleRemoteProviders()
            case RPCMethod.remoteSessions:
                return try await handleRemoteSessions()
            case RPCMethod.remoteCreate:
                return try await handleRemoteCreate(request.paramsData, actor: request.actor)
            case RPCMethod.remoteStop:
                return try await handleRemoteStop(request.paramsData, actor: request.actor)
            case RPCMethod.remoteSend:
                return try await handleRemoteSend(request.paramsData, actor: request.actor)
            case RPCMethod.remoteLog:
                return try await handleRemoteLog(request.paramsData)
            case RPCMethod.remoteRename:
                return try await handleRemoteRename(request.paramsData)
            case RPCMethod.remoteDismiss:
                return try await handleRemoteDismiss(request.paramsData)
            case RPCMethod.remoteSetPin:
                return try await handleRemoteSetPin(request.paramsData)
            case RPCMethod.remoteReportAttachExit:
                return try await handleRemoteReportAttachExit(request.paramsData)
            case RPCMethod.configSetRemoteBackends:
                return try await handleConfigSetRemoteBackends(request.paramsData)
            case RPCMethod.gcList:
                return try await handleGCList(request.paramsData)
            case RPCMethod.gcRestore:
                return try await handleGCRestore(request.paramsData)
            case RPCMethod.gcSweepNow:
                return try await handleGCSweepNow(request.paramsData)
            case RPCMethod.panelGet:
                return try await handlePanelGet(request.paramsData)
            case RPCMethod.panelApply:
                return try await handlePanelApply(request.paramsData)
            case RPCMethod.panelImportLegacy:
                return try await handlePanelImportLegacy(request.paramsData)
            default:
                return RPCResponse(error: "Unknown method: \(request.method)")
            }
        } catch {
            routerLogger.error("RPC \(request.method, privacy: .public) failed: \(error, privacy: .public)")
            return RPCResponse(error: "\(error)")
        }
    }

    // MARK: - Capabilities

    /// Report daemon feature flags the app cannot derive locally. The app is
    /// launched via `open` (LaunchServices), which drops shell env — so the
    /// control-mode gate state must be asked for, not mirrored. The gate is
    /// re-evaluated per call (env || persisted flag), so a Settings toggle is
    /// visible on the next fetch without a daemon restart.
    func handleDaemonCapabilities() async throws -> RPCResponse {
        let enabled: Bool
        if let bridge = controlMode {
            enabled = await bridge.gateEnabled()
        } else {
            enabled = false
        }
        let version = controlMode?.tmuxVersion
        let config = try await db.config.get()
        return try RPCResponse(result: DaemonCapabilitiesResult(
            controlModeEnabled: enabled,
            tmuxVersion: version?.description,
            controlModeSupported: version.map { $0 >= TmuxVersion.controlModeMinimum } ?? false,
            hibernateInputVetoEnabled: config.hibernateInputVetoEnabled,
            autoCloseSetupEnabled: config.autoCloseSetupEnabled,
            autoTrustWorktrees: config.autoTrustWorktrees,
            panelSurfaceEnabled: config.panelSurfaceEnabled,
            remoteBackendsEnabled: config.remoteBackendsEnabled,
            remoteBackendsLive: remoteManager != nil))
    }

    // MARK: - PR Status

    private func handlePRList() async throws -> RPCResponse {
        // Single-flight: while one enumeration is in flight, concurrent polls
        // await it and share the snapshot instead of each starting their own
        // git enumeration + gh fetch.
        let result = try await prListCoordinator.run { [self] in
            try await computePRList()
        }
        return try RPCResponse(result: result)
    }

    /// Enumerate active worktrees, enrich each with its (cached) upstream branch,
    /// refresh PR status, and return the snapshot. Throws on a DB enumeration
    /// failure so the app sees an RPC error instead of a silently-stale snapshot;
    /// `PRListCoordinator` propagates the error to every concurrent caller.
    private func computePRList() async throws -> PRListResult {
        // Fetch fresh PR data for all active worktrees before returning the cache.
        let worktrees = Self.pollableWorktrees(try await db.worktrees.list(status: .active))
        var infos: [(id: UUID, branch: String, upstreamBranch: String?, worktreePath: String, prNumber: Int?)] = []
        infos.reserveCapacity(worktrees.count)
        for wt in worktrees {
            // Route the per-worktree `git config` lookup through the TTL cache
            // so a poll storm doesn't spawn one subprocess per worktree per poll.
            let upstreamBranch = await upstreamBranchCache.upstreamBranchName(
                worktreePath: wt.path,
                branch: wt.branch
            ) { [git] in
                await git.upstreamBranchName(worktreePath: wt.path, branch: wt.branch)
            }
            infos.append((
                id: wt.id,
                branch: wt.branch,
                upstreamBranch: upstreamBranch,
                worktreePath: wt.path,
                prNumber: wt.prNumber
            ))
        }
        await prManager.fetchAll(worktrees: infos)
        // Prune at the END so we never drop an entry this pass just populated.
        await upstreamBranchCache.retain(active: infos.map { (worktreePath: $0.worktreePath, branch: $0.branch) })
        return PRListResult(statuses: await prManager.allStatuses())
    }

    /// Scratch spaces are repo-less and have no PR — exclude them so the
    /// poller only queries real checkouts (worktrees may span multiple repos;
    /// by-number lookups scope to each worktree's own repo). Pulled out
    /// as a pure function (rather than inlined `.filter` in `computePRList`)
    /// so it's directly unit-testable without spinning up git/gh machinery.
    static func pollableWorktrees(_ worktrees: [Worktree]) -> [Worktree] {
        worktrees.filter { !$0.isScratch }
    }

    private func handlePRRefresh(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PRRefreshParams.self, from: paramsData)

        // Run targeted refresh in the worktree and try the tracked upstream branch when needed.
        guard let wt = try await db.worktrees.get(id: params.worktreeID) else {
            return try RPCResponse(result: PRRefreshResult(status: nil))
        }
        let upstreamBranch = await git.upstreamBranchName(
            worktreePath: wt.path,
            branch: wt.branch
        )

        let status = await prManager.refresh(
            worktreeID: wt.id,
            branch: wt.branch,
            upstreamBranch: upstreamBranch,
            repoPath: wt.path,
            prNumber: wt.prNumber
        )
        return try RPCResponse(result: PRRefreshResult(status: status))
    }
}
