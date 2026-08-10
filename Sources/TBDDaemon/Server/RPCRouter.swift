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
    /// Edge-triggered gate in front of the merged-PR fan-out (auto-archive,
    /// auto-hibernate): it fires when every PR bound to a worktree has resolved.
    /// Wired post-construction by `Daemon.swift` (mirrors `claudeUsagePoller`);
    /// `nil` in mock mode / unit tests, where a poll simply refreshes statuses
    /// and judges nothing.
    public nonisolated(unsafe) var mergeTrigger: AllResolvedMergeTrigger?
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
    /// Delivery acknowledgement (design §12). `terminal.send` hands a
    /// dispatched, verify-armed text send here and this is the only caller —
    /// see `DeliveryVerificationArming`. `nil` everywhere until the verifier
    /// lands; a nil verifier means the observation is simply never armed, and
    /// the act renders `unconfirmed` by `DeliveryRecord.statuses`, which is the
    /// honest answer rather than a claim. Set post-construction like
    /// `claudeUsagePoller`.
    nonisolated(unsafe) var deliveryVerifier: (any DeliveryVerificationArming)?
    /// Paces the keys of a `--keys` payload. A `var` so tests can inject a
    /// `TestClock`; production never replaces the default.
    nonisolated(unsafe) var pacedKeySender = PacedKeySender()
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
    /// TTL cache for the per-worktree branch facts PR matching needs (upstream
    /// and `@{push}`), so `pr.list` stops spawning git subprocesses per worktree
    /// on every poll — and so the poll and an on-select refresh agree.
    let branchTrackingCache = BranchTrackingCache()
    /// Coalesces fetch operations per repo using a TTL cache + singleflight.
    let fetchCache = FetchCache()
    /// Binding policy for the multi-PR-per-worktree bindings — repo validation,
    /// dedupe, tombstones, cap.
    let prBindingCoordinator: PRBindingCoordinator
    /// The worktree's own GitHub `owner`/`name`. The coordinator is built on
    /// this same closure, so a caller that must name a repo before it can form a
    /// PR reference (`pr.attach 412`) agrees with the policy that validates it.
    /// Production resolves it via `PRStatusManager`'s `gh repo view` TTL cache;
    /// tests inject a stub through the init parameter of the same name.
    let prBindingRepoResolver: @Sendable (UUID) async -> (owner: String, name: String)?
    /// Queues concurrent `terminal.send` RPCs per terminal so two payloads
    /// never interleave in one composer. Different terminals still send in
    /// parallel — see `TerminalSendSerializer`.
    let terminalSendSerializer = TerminalSendSerializer()
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
        prBindingRepoResolver: (@Sendable (UUID) async -> (owner: String, name: String)?)? = nil,
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
        // Captures the `db` / `prManager` parameters rather than `self`, so the
        // coordinator can be a `let` built during initialization.
        let repoResolver = prBindingRepoResolver ?? { [db, prManager] worktreeID in
            guard let worktree = try? await db.worktrees.get(id: worktreeID) else { return nil }
            return await prManager.repoIdentity(repoPath: worktree.path)
        }
        self.prBindingRepoResolver = repoResolver
        self.prBindingCoordinator = PRBindingCoordinator(
            store: db.prBindings, resolveRepo: repoResolver)
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
            case RPCMethod.prBindings:
                return try await handlePRBindings(request.paramsData)
            case RPCMethod.prAttach:
                return try await handlePRAttach(request.paramsData)
            case RPCMethod.prDetach:
                return try await handlePRDetach(request.paramsData)
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
            case RPCMethod.configSetDeliveryVerification:
                return try await handleConfigSetDeliveryVerification(request.paramsData)
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
        let version: TmuxVersion?
        if let bridge = controlMode {
            let gateState = await bridge.currentGateState()
            enabled = gateState.enabled
            version = gateState.tmuxVersion
        } else {
            enabled = false
            version = nil
        }
        let config = try await db.config.get()
        return try RPCResponse(result: DaemonCapabilitiesResult(
            controlModeEnabled: enabled,
            tmuxVersion: version?.description,
            controlModeSupported: version.map { $0 >= TmuxVersion.controlModeMinimum } ?? false,
            hibernateInputVetoEnabled: config.hibernateInputVetoEnabled,
            autoCloseSetupEnabled: config.autoCloseSetupEnabled,
            deliveryVerificationEnabled: config.deliveryVerificationEnabled,
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
        // Each repo's default branch, fetched once per pass rather than per
        // worktree. It tells a tracked BASE from a rename-push target — see
        // `PRStatusManager.branchCandidates`, and `headRefMismatchedMatches` for
        // why a stale value here can only cost a missed heal.
        let defaultBranchByRepo = Dictionary(
            uniqueKeysWithValues: (try await db.repos.list()).map { ($0.id, $0.defaultBranch) })
        var infos: [PRStatusManager.PollWorktree] = []
        infos.reserveCapacity(worktrees.count)
        for wt in worktrees {
            let (upstreamBranch, pushBranch) = await branchFacts(worktreePath: wt.localPath, branch: wt.branch)
            infos.append((
                id: wt.id,
                branch: wt.branch,
                upstreamBranch: upstreamBranch,
                defaultBranch: wt.repoID.flatMap { defaultBranchByRepo[$0] },
                pushBranch: pushBranch,
                worktreePath: wt.localPath,
                prNumber: wt.prNumber
            ))
        }
        let poll = await prManager.fetchAll(worktrees: infos)
        // A heal ran: the worktree was positively shown NOT to own this PR (its
        // head is a branch the worktree merely tracks, or the PR is in another
        // repo). Clearing the cache is not enough — a `branch` binding written
        // by an earlier pass is re-queried by number and no heal can see it, so
        // it would keep driving the icon and, on merge, auto-archive. Run before
        // the binds below so a pass that both disproves one PR and discovers
        // another leaves the discovery standing.
        for healed in poll.disproved {
            await prBindingCoordinator.healBranchMatch(worktreeID: healed.worktreeID,
                                                       parsed: healed.parsed)
        }
        // The branch matcher is one of the three binding discovery sources; the
        // coordinator owns the policy (repo validation, tombstones, cap), so a
        // match it rejects is simply not bound.
        for match in poll.discovered {
            _ = await prBindingCoordinator.bind(worktreeID: match.worktreeID,
                                                parsed: match.parsed, source: .branch)
        }
        await seedProvenanceBindings(worktrees)
        await refreshBindingStatuses(polled: infos, repoPath: infos.first?.worktreePath)
        // Prune at the END so we never drop an entry this pass just populated.
        await branchTrackingCache.retain(active: infos.map { (worktreePath: $0.worktreePath, branch: $0.branch) })
        return PRListResult(statuses: await prManager.allStatuses())
    }

    /// Bind the PR a worktree was *created from* — `Worktree.prNumber` — so a
    /// PR-row worktree behaves like any other multi-PR worktree.
    ///
    /// This runs on the poll rather than at creation because both populations
    /// need it: worktrees that predate bindings carry a number and no row, and
    /// creation-time seeding would leave every one of them stranded. It also
    /// costs a new worktree nothing in latency — its `Worktree.prStatus` is
    /// populated by this same poll, so a binding that appears here appears
    /// exactly when the PR does.
    ///
    /// Cheap in the steady state: the stored-number check is one indexed SELECT
    /// per PR-row worktree, and only a genuinely unseeded number pays a repo
    /// resolution. Detached numbers stay short-circuited here **and** are
    /// refused by `seedProvenance`, so a `tbd pr detach` is not undone by the
    /// next poll.
    private func seedProvenanceBindings(_ worktrees: [Worktree]) async {
        for worktree in worktrees {
            guard let number = worktree.prNumber else { continue }
            guard let recorded = try? await db.prBindings.list(worktreeID: worktree.id,
                                                               includeDetached: true),
                  !recorded.contains(where: { $0.number == number }) else { continue }
            guard let parsed = await prRef(worktreeID: worktree.id, number: number) else {
                continue
            }
            _ = await prBindingCoordinator.seedProvenance(worktreeID: worktree.id,
                                                          parsed: parsed)
        }
    }

    /// Refresh every binding of the polled worktrees and persist what came back.
    ///
    /// Costs nothing until something binds: with no bindings this is one indexed
    /// SELECT and no `gh` call at all.
    ///
    /// Two kinds of write, both skipped when the value is unchanged so an idle
    /// poll costs no UPDATE. Each binding's own row gets its fresh status, and
    /// the worktree's single `prStatus` column gets the worst of them so every
    /// existing single-status reader keeps working while the multi-PR surfaces
    /// are built.
    ///
    /// Takes the poll entries rather than the worktree rows because the merge
    /// rule below needs each worktree's branch candidates and provenance PR
    /// number, and `PollWorktree` is where the branch facts this pass gathered
    /// already live.
    private func refreshBindingStatuses(
        polled entries: [PRStatusManager.PollWorktree], repoPath: String?
    ) async {
        let polled = Set(entries.map(\.id))
        guard let live = try? await db.prBindings.listAll() else { return }
        let bindings = live.filter { polled.contains($0.worktreeID) }
        guard !bindings.isEmpty else { return }

        let observations = await prManager.refreshBindings(bindings, repoPath: repoPath)
        var refreshed: [PRBinding] = []
        refreshed.reserveCapacity(bindings.count)
        for binding in bindings {
            // Absent means "not observed this pass" — leave the stored row alone
            // rather than clearing a status a transient failure hid.
            guard let observed = observations[binding.id] else {
                refreshed.append(binding)
                continue
            }
            // A nil ref is likewise "not observed": keep what the row already
            // holds rather than blanking the branch column the CLI renders.
            let headBranch = observed.headBranch ?? binding.headBranch
            let baseRef = observed.baseRef ?? binding.baseRef
            if observed.status != binding.status
                || headBranch != binding.headBranch || baseRef != binding.baseRef {
                try? await db.prBindings.updateObservation(
                    bindingID: binding.id, status: observed.status,
                    headBranch: headBranch, baseRef: baseRef)
            }
            refreshed.append(binding.withStatus(observed.status))
        }
        // Compare against what the column holds NOW, not against the snapshot
        // read before this pass began. `fetchAll` → `apply` → `onStatusPersist`
        // writes this same column earlier in the pass, so a pre-poll snapshot
        // can equal the value we computed while the column holds something else
        // entirely — and the skip would then repeat on every poll, pinning a
        // green icon over a bound PR whose checks are failing. One indexed
        // SELECT per worktree that actually has bindings.
        for update in Self.worktreePRStatusUpdates(refreshed) {
            guard let current = try? await db.worktrees.get(id: update.worktreeID),
                  current.prStatus != update.status else { continue }
            try? await db.worktrees.setPRStatus(id: update.worktreeID, status: update.status)
        }

        // Judge the merge rule on the statuses this pass just observed — this is
        // the only place they are all in hand at once. The trigger owns the
        // edge, so calling it every poll costs a set lookup per worktree.
        //
        // Each worktree's own branch candidates and provenance number travel with
        // it: the rule fires only when a MERGED binding is the worktree's own
        // work, and those two facts are the only evidence of ownership there is.
        // An entry that somehow has no poll row is judged against no candidates
        // and no number, which fails the ownership arm closed.
        if let mergeTrigger {
            let entryByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            for (worktreeID, group) in Dictionary(grouping: refreshed, by: \.worktreeID) {
                let entry = entryByID[worktreeID]
                await mergeTrigger.evaluate(
                    worktreeID: worktreeID, bindings: group,
                    branchCandidates: entry.map { PRStatusManager.candidatesFor($0) } ?? [],
                    provenancePRNumber: entry?.prNumber)
            }
        }
    }

    /// The `Worktree.prStatus` write implied by a worktree's bindings: the worst
    /// of them, so one icon can stand for several PRs.
    ///
    /// `.merged` is deliberately never written, mirroring `PRStatusManager.apply`
    /// — it is the auto-archive trigger, and a persisted `.merged` would be
    /// hydrated at the next daemon start as an already-merged baseline, so a
    /// merge whose archive failed would never re-fire. A worktree whose worst
    /// binding is merged simply keeps its previous column value.
    ///
    /// Pure and static so the rule is unit-testable without git/gh machinery,
    /// like `pollableWorktrees`.
    static func worktreePRStatusUpdates(
        _ bindings: [PRBinding]
    ) -> [(worktreeID: UUID, status: PRStatus)] {
        Dictionary(grouping: bindings, by: \.worktreeID)
            .compactMap { worktreeID, group in
                guard let status = PRBinding.worst(of: group)?.status,
                      status.state != .merged else { return nil }
                return (worktreeID, status)
            }
    }

    /// The per-branch git facts PR matching needs: the branch this one tracks,
    /// and where git says it would push (`@{push}`). Both go through the TTL
    /// cache so a poll storm doesn't spawn two subprocesses per worktree per
    /// poll, and so every consumer — poll and on-select refresh alike — sees the
    /// same answer within a TTL window.
    private func branchFacts(
        worktreePath: String, branch: String
    ) async -> (upstream: String?, push: GitManager.PushBranchResolution) {
        let upstream = await branchTrackingCache.upstreamBranchName(
            worktreePath: worktreePath, branch: branch
        ) { [git] in
            await git.upstreamBranchName(worktreePath: worktreePath, branch: branch)
        }
        let push = await branchTrackingCache.pushBranch(
            worktreePath: worktreePath, branch: branch
        ) { [git] in
            await git.pushBranchName(worktreePath: worktreePath, branch: branch)
        }
        return (upstream, push)
    }

    /// Scratch spaces are repo-less and have no PR — exclude them so the
    /// poller only queries real checkouts (worktrees may span multiple repos;
    /// by-number lookups scope to each worktree's own repo). Pulled out
    /// as a pure function (rather than inlined `.filter` in `computePRList`)
    /// so it's directly unit-testable without spinning up git/gh machinery.
    ///
    /// Remote rows are excluded for a second reason: everything downstream is
    /// keyed on the worktree's path. `branchFacts` runs `git` inside it and
    /// caches the answer under that path, and `PRStatusManager` runs `gh` there
    /// — against a directory that does not exist on this machine. Polling a
    /// remote lane's PR is wanted eventually and needs to key on the BRANCH
    /// instead; until then, not polling is the only correct behavior.
    static func pollableWorktrees(_ worktrees: [Worktree]) -> [Worktree] {
        worktrees.filter { !$0.isScratch && $0.location.isLocal }
    }

    private func handlePRRefresh(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PRRefreshParams.self, from: paramsData)

        // Run targeted refresh in the worktree and try the tracked upstream
        // branch when needed. Local rows only, for the same reason
        // `pollableWorktrees` excludes remote ones: this runs `git` and `gh`
        // inside the worktree's path. A remote id gets the same "nothing to
        // report" answer as an unknown one.
        guard let wt = try await db.worktrees.getLocal(id: params.worktreeID) else {
            return try RPCResponse(result: PRRefreshResult(status: nil))
        }
        // Read the branch facts through the SAME cache the poll uses. Reading
        // git directly here would let a user refresh attach a PR that the very
        // next poll — still inside the cache's TTL, still holding the older
        // facts — judges by a different candidate list and clears again.
        let (upstreamBranch, pushBranch) = await branchFacts(worktreePath: wt.path, branch: wt.branch)
        var defaultBranch: String?
        if let repoID = wt.repoID {
            defaultBranch = try await db.repos.get(id: repoID)?.defaultBranch
        }

        let status = await prManager.refresh(
            worktreeID: wt.id,
            branch: wt.branch,
            upstreamBranch: upstreamBranch,
            defaultBranch: defaultBranch,
            pushBranch: pushBranch,
            repoPath: wt.path,
            prNumber: wt.prNumber
        )
        return try RPCResponse(result: PRRefreshResult(status: status))
    }

    // MARK: - PR bindings

    private func handlePRBindings(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PRBindingsParams.self, from: paramsData)
        let bindings = try await db.prBindings.list(worktreeID: params.worktreeID)
        return try RPCResponse(result: PRBindingsResult(bindings: bindings))
    }

    private func handlePRAttach(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PRBindingRefParams.self, from: paramsData)
        let parsed: ParsedPRURL
        switch await resolvePRRef(params) {
        case .resolved(let value):
            parsed = value
        case .unresolvable:
            return RPCResponse(error: PRBindingRefError.unresolvable.message)
        case .unknownRepo:
            // The user's input was valid; we just cannot name their repo yet.
            // Reported as the same deferral the coordinator uses, so the CLI
            // says "try again shortly" instead of calling a good PR number
            // malformed.
            return try RPCResponse(result: PRAttachResult(outcome: "deferredUnknownRepo"))
        }
        // An unrecognised source reads as `manual`, which is the conservative
        // choice for the wire: a hand-typed attach is the only thing that may
        // revive a tombstone, and a garbled value should not silently acquire
        // automatic-source semantics.
        let source = params.source.flatMap(PRBindingSource.init(rawValue:)) ?? .manual
        switch await prBindingCoordinator.bind(worktreeID: params.worktreeID,
                                               parsed: parsed, source: source) {
        case .bound(let binding):
            return try RPCResponse(result: PRAttachResult(outcome: "bound", binding: binding))
        case .alreadyBound:
            return try RPCResponse(result: PRAttachResult(outcome: "alreadyBound"))
        case .rejectedWrongRepo(let other):
            return try RPCResponse(result: PRAttachResult(outcome: "rejectedWrongRepo",
                                                          detail: other))
        case .deferredUnknownRepo:
            return try RPCResponse(result: PRAttachResult(outcome: "deferredUnknownRepo"))
        case .tombstoned:
            return try RPCResponse(result: PRAttachResult(outcome: "tombstoned"))
        case .capFull:
            return try RPCResponse(result: PRAttachResult(outcome: "capFull"))
        }
    }

    private func handlePRDetach(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PRBindingRefParams.self, from: paramsData)
        let parsed: ParsedPRURL
        switch await resolvePRRef(params) {
        case .resolved(let value):
            parsed = value
        case .unresolvable:
            return RPCResponse(error: PRBindingRefError.unresolvable.message)
        case .unknownRepo:
            return RPCResponse(error: PRBindingRefError.unknownRepo.message)
        }
        let detached = try await prBindingCoordinator.detach(worktreeID: params.worktreeID,
                                                             parsed: parsed)
        return try RPCResponse(result: PRDetachResult(detached: detached))
    }

    /// Why a `PRBindingRefParams` could not name one PR. Named rather than
    /// inlined so each message has a single definition across the two handlers
    /// that report it.
    private enum PRBindingRefError {
        /// Neither a URL nor a positive number was supplied — the input itself
        /// is unusable.
        case unresolvable
        /// The input was fine; the worktree's own repo could not be named yet.
        case unknownRepo

        var message: String {
            switch self {
            case .unresolvable:
                return "pr reference must be a github PR url or a number in the worktree's own repo"
            case .unknownRepo:
                return "could not resolve this worktree's repo yet; try again shortly"
            }
        }
    }

    /// What a `PRBindingRefParams` resolved to.
    ///
    /// The two failures are deliberately distinct. A bare number whose repo
    /// cannot be named yet — the ordinary state of a worktree seconds after
    /// creation — is not bad input, and collapsing it into `unresolvable` told
    /// the user that `tbd pr attach 412` was "not a PR number or a GitHub PR
    /// URL" while they were looking at the PR.
    private enum PRRefResolution {
        case resolved(ParsedPRURL)
        case unresolvable
        case unknownRepo
    }

    /// Turn a URL-or-number reference into a concrete `ParsedPRURL`.
    ///
    /// The bare-number form is resolved against the worktree's own repo through
    /// the same seam the coordinator validates with, so `pr.attach 412` cannot
    /// synthesise a URL the policy would then reject as wrong-repo.
    private func resolvePRRef(_ params: PRBindingRefParams) async -> PRRefResolution {
        if let url = params.url, !url.isEmpty {
            guard let parsed = PRBindingExtractor.parsePRURLs(in: url).first else {
                return .unresolvable
            }
            return .resolved(parsed)
        }
        guard let number = params.number, number > 0 else { return .unresolvable }
        guard let parsed = await prRef(worktreeID: params.worktreeID, number: number) else {
            return .unknownRepo
        }
        return .resolved(parsed)
    }

    /// A bare PR number as a `ParsedPRURL` in the worktree's own repo.
    ///
    /// Resolved through the same seam the coordinator validates with, so a
    /// number can never synthesise a URL the policy would then reject as
    /// wrong-repo. Returns nil when the worktree's repo cannot be named — the
    /// caller defers rather than guessing an owner.
    private func prRef(worktreeID: UUID, number: Int) async -> ParsedPRURL? {
        guard let own = await prBindingRepoResolver(worktreeID) else { return nil }
        return ParsedPRURL(
            host: "github.com", owner: own.owner, repo: own.name, number: number,
            url: "https://github.com/\(own.owner)/\(own.name)/pull/\(number)")
    }
}
