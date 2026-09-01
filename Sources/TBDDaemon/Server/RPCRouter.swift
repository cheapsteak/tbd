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
    /// Fleet supervision's single writer of `~/tbd/supervision/` — the
    /// operator's file, the ledger beside it, and the coverage decisions that
    /// connect them. Wired post-construction by `Daemon.swift` (mirrors
    /// `orphanGC`); `nil` in mock mode / unit tests that don't need it, where
    /// the `supervise.*` handlers refuse with a named condition rather than
    /// crashing. Never defaulted to a store built on `TBDConstants`: that
    /// default is the "helper ignores its caller's injected seam" shape, and
    /// every router a test constructs would share the developer's real
    /// `~/tbd/supervision`.
    public nonisolated(unsafe) var supervision: SupervisionStore?
    /// The out-of-band `status.json` heartbeat. The brake handler publishes an
    /// edge through it and arms or disarms its timer to match, so the timer's
    /// lifetime is tied to the brake rather than to daemon boot. Wired
    /// post-construction by `Daemon.swift` like `supervision`; `nil` in mock
    /// mode and in tests, where the brake still moves and simply publishes
    /// nothing.
    public nonisolated(unsafe) var supervisionHeartbeat: SupervisionHeartbeat?
    /// The last leg of the brief pipe — the seam briefing delivery plugs into
    /// in slice 5. Overridable post-construction like `supervision`, but not an
    /// optional: the shipped deliverer resolves the project's supervisor, finds
    /// none, and answers `no-live-supervisor`, which is the honest answer today
    /// and safe in mock mode and in every test that never touches it. A test
    /// injects its own to reach `transport-failed`, which nothing else can
    /// produce.
    public nonisolated(unsafe) var supervisionBriefingDeliverer:
        any SupervisionBriefingDelivering = SupervisorBriefingDeliverer()
    /// Orphan-GC actor. `nil` in mock mode / unit tests that don't need it;
    /// set post-construction by `Daemon.swift` (mirrors `claudeUsagePoller`).
    /// The `gc.*` handlers return an error response rather than crashing when
    /// this is nil.
    public nonisolated(unsafe) var orphanGC: OrphanGC?
    /// The named reconciler for a shadow peer's helper process, socket and
    /// record. Read-only from here: `peer.status` reports what its last sweep
    /// found, and nothing on the RPC surface triggers or steers a sweep.
    /// `nil` in mock mode / unit tests, where the answer simply carries no
    /// sweep — which is honest, since none has run.
    public nonisolated(unsafe) var shadowPeerReconciler: ShadowPeerReconciler?
    /// Remote-backends actor. Constructed at boot ONLY when
    /// `config.remoteBackendsEnabled` is true (see `Daemon.swift`); `nil`
    /// otherwise, including when a user flips the flag on without
    /// restarting. `remote.*` handlers return an error response rather than
    /// crashing when this is nil — see `RPCRouter+RemoteHandlers.swift`.
    let remoteManager: RemoteProviderManager?
    /// Whether the daemon wired the built-in `claude-cloud` provider at boot.
    /// Captured rather than recomputed, because the answer is about what
    /// happened at construction time and cannot change without a restart.
    let claudeCloudLive: Bool
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
    /// Owner of the prompt parked at worktree creation (design 2026-08-10).
    /// `worktree.setPendingPrompt` routes to it and `terminal.sessionEvent`
    /// feeds it the readiness signal. `nil` in mock mode and in tests that do
    /// not exercise the feature, where the handler refuses and the hook is a
    /// no-op. Set post-construction like `claudeUsagePoller`, because the
    /// coordinator has to exist before the `WorktreeLifecycle` snapshot this
    /// router is built from.
    nonisolated(unsafe) var pendingPromptCoordinator: PendingPromptCoordinator?
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

    /// Runaway-detection counters (design §13): turns appended per session and
    /// hook events received per session, over one observation window. The
    /// hook-driven handlers increment it; `session.states` samples it. An actor
    /// reference held here so the whole daemon keeps one set of books.
    ///
    /// It reports numbers and nothing acts on them — see the actor's doc
    /// comment for why no threshold lives in compiled TBD.
    let sessionCounters = SessionCountersTracker()
    /// Single-flights concurrent `pr.list` RPCs so a poll storm collapses into
    /// one git enumeration + gh fetch instead of N overlapping ones.
    let prListCoordinator = PRListCoordinator()
    /// TTL cache for the per-worktree branch facts PR matching needs (upstream
    /// and `@{push}`), so `pr.list` stops spawning git subprocesses per worktree
    /// on every poll — and so the poll and an on-select refresh agree.
    let branchTrackingCache: BranchTrackingCache
    /// The daemon-side timer that drives `runPollPass`, wired at the end of
    /// `init`. The pass itself stays here because `pr.refresh` and the timer
    /// must never enumerate differently, and the router keeps the timer because
    /// `Daemon.start()` reaches it through the router to start the loop.
    public let prPoller: PRPoller
    /// Coalesces fetch operations per repo using a TTL cache + singleflight.
    let fetchCache = FetchCache()
    /// Binding policy for the multi-PR-per-worktree bindings — repo validation,
    /// dedupe, tombstones, cap.
    let prBindingCoordinator: PRBindingCoordinator
    /// The worktree's own `owner`/`name` and the host they live on. The
    /// coordinator is built on this same closure, so a caller that must name a
    /// repo before it can form a PR reference (`pr.attach 412`) agrees with the
    /// policy that validates it. Production resolves it via `PRStatusManager`'s
    /// TTL cache; tests inject a stub through the init parameter of the same
    /// name.
    let prBindingRepoResolver: @Sendable (UUID) async -> (owner: String, name: String, host: String)?
    /// Whether a worktree's host is one the user configured `glab` for — nil
    /// when there is no local directory to put the question in. The coordinator
    /// is built on this same closure, so the guard that refuses a `github.com`
    /// URL on a GitLab checkout and the composer that picks `/-/merge_requests/`
    /// over `/pull/` agree about the forge.
    let prBindingForgeResolver: @Sendable (UUID, String) async -> Bool?
    /// Queues concurrent `terminal.send` RPCs per terminal so two payloads
    /// never interleave in one composer. Different terminals still send in
    /// parallel — see `TerminalSendSerializer`.
    let terminalSendSerializer = TerminalSendSerializer()
    /// Daemon-lifetime incremental transcript baselines used only to enrich
    /// terminal-list responses for Codex presentation state.
    let codexActivityTracker = CodexTranscriptActivityTracker()
    /// Which Claude terminals owe a delegation sample, and what their last
    /// sample claimed. Marked at every idle report; read during `terminal.list`.
    let claudeDelegationTracker = ClaudeDelegationTracker()
    /// Opt-in tmux control-mode wiring. `nil` when the daemon did not provide
    /// one (tests, older callers); when present, terminal handlers open a gated
    /// logging-only `tmux -CC` connection after each `ensureServer()`.
    ///
    /// Set by `Daemon` after construction (`internal`, so the public init's
    /// signature does not leak the internal bridge type).
    nonisolated(unsafe) var controlMode: TmuxControlModeBridge?

    /// The daemon's single owner of every live `HolderReader`. `terminal.output`
    /// renders a holder-backed session from it; every other transport ignores
    /// it entirely. Set by `Daemon` after construction, from the same value the
    /// lifecycle's spawn path registers into — one registry per daemon, because
    /// two would each drain their own dup of a session's pty master and steal
    /// bytes from each other. `nil` in mock mode and in tests that never
    /// exercise the transport, where a holder row reports that it has no live
    /// reader rather than crashing.
    nonisolated(unsafe) var holderRegistry: HolderRegistry?

    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    /// Date seam for facts the router *persists*. A stored observed-at is data,
    /// not behavior, so this is the `now: @Sendable () -> Date` seam rather
    /// than a `Clock` — tests pin it and assert the exact stamp instead of a
    /// tolerance window. Only handlers that write an observation may read it;
    /// it is not a general-purpose "what time is it".
    let now: @Sendable () -> Date

    /// Where a named tmux server's socket file lives. Held as an injected
    /// collaborator rather than read ad hoc, so `terminal.attachCommand` can be
    /// tested against a pinned `TMUX_TMPDIR` and uid without `setenv` — which
    /// `Tests/CLAUDE.md` forbids outside `TBDHomeSerialized`. The default reads
    /// the daemon's own environment, which is the environment the servers it
    /// spawned were created under.
    let tmuxSocketPathResolver: TmuxSocketPathResolver
    /// How a session transcript is measured when a prompt is recorded against
    /// it. A seam, not a clock: a file's modification time is data, so it
    /// follows the same rule as `now` rather than the `Clock` rule.
    let transcriptFingerprinter: TranscriptFingerprinter
    /// How the records a transcript gained since a stored fingerprint are read
    /// and attributed. Paired with the fingerprinter: the stat says the file
    /// moved, this says whether the session itself did.
    let transcriptDeltaInspector: TranscriptDeltaInspector

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
        claudeCloudLive: Bool = false,
        codexExecutableResolver: (@Sendable () throws -> String)? = nil,
        codexHomeEnsurer: (@Sendable () throws -> URL)? = nil,
        prBindingRepoResolver: (@Sendable (UUID) async -> (owner: String, name: String, host: String)?)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        tmuxSocketPathResolver: TmuxSocketPathResolver = TmuxSocketPathResolver(),
        transcriptFingerprinter: @escaping TranscriptFingerprinter = TranscriptFingerprinting.live,
        transcriptDeltaInspector: @escaping TranscriptDeltaInspector
            = TranscriptDeltaInspection.live,
        actuationLog: ActuationLog
    ) {
        self.now = now
        self.tmuxSocketPathResolver = tmuxSocketPathResolver
        self.transcriptFingerprinter = transcriptFingerprinter
        self.transcriptDeltaInspector = transcriptDeltaInspector
        self.actuationLog = actuationLog
        self.db = db
        self.lifecycle = lifecycle
        self.tmux = tmux
        self.git = git
        self.startTime = startTime
        self.subscriptions = subscriptions
        self.prManager = prManager
        // One cache instance, shared by the on-select refresh path and the
        // poller's enumeration: a poll and a refresh judging the same worktree
        // against different candidate lists is what the cache exists to stop.
        let branchCache = BranchTrackingCache()
        self.branchTrackingCache = branchCache
        self.prPoller = PRPoller()
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
        // `getLocal` rather than `get`: resolving a repo identity means running
        // git in the worktree's directory, which a remote row does not have on
        // this machine. Its nil is the correct "nothing here to resolve".
        let repoResolver = prBindingRepoResolver ?? { [db, prManager] worktreeID in
            guard let worktree = try? await db.worktrees.getLocal(id: worktreeID) else { return nil }
            return await prManager.repoIdentity(repoPath: worktree.path)
        }
        self.prBindingRepoResolver = repoResolver
        // The forge half of the same seam, captured the same way. `getLocal`
        // again, and its nil is the same "nothing here to ask in": `glab` reads
        // its configuration from the checkout's own directory, which a remote
        // row does not have on this machine.
        let forgeResolver: @Sendable (UUID, String) async -> Bool? = { [db, prManager] worktreeID, host in
            guard let worktree = try? await db.worktrees.getLocal(id: worktreeID) else { return nil }
            return await prManager.isGitLabHost(host, repoPath: worktree.path)
        }
        self.prBindingForgeResolver = forgeResolver
        self.prBindingCoordinator = PRBindingCoordinator(
            store: db.prBindings, resolveRepo: repoResolver, isGitLabHost: forgeResolver,
            // The cached status is the only evidence about a worktree's PRs
            // that survives `gh` being unavailable, which is when `detach`
            // needs it — see `PRBindingCoordinator.detach`. Parsed to a full
            // identity rather than passed as a bare number, so corroboration
            // cannot be satisfied by a coincidence of numbering.
            cachedPRIdentity: { [db] worktreeID in
                guard let url = try? await db.worktrees.get(id: worktreeID)?.prStatus?.url
                else { return nil }
                return PRBindingExtractor.parsePRURLs(in: url).first
            })
        self.pendingQuestions = pendingQuestions
        self.repoSerializer = repoSerializer
        self.configDirManager = configDirManager
        self.controlMode = nil
        self.claudeCredentialsKeychain = claudeCredentialsKeychain
        self.loginSessions = loginSessions
        self.panelCoordinator = PanelCoordinator(
            db: db, broadcast: { [subscriptions] delta in subscriptions.broadcast(delta: delta) })
        self.remoteManager = remoteManager
        self.claudeCloudLive = claudeCloudLive
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
        // The poller is a timer and nothing else; the pass it drives is
        // `runPollPass`, which lives here because `pr.refresh` and the on-select
        // path share its enumeration helpers. Wired at the end of `init` rather
        // than handed to the initializer because the closure needs the fully
        // formed router. `weak`, so a discarded router (every test that builds
        // one) is not kept alive by its own poller; a pass on a deallocated
        // router is a no-op, which is the honest answer.
        prPoller.installPass { [weak self] in try await self?.runPollPass() }
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
            case RPCMethod.terminalAttachCommand:
                return try await handleTerminalAttachCommand(request.paramsData)
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
            case RPCMethod.terminalSessionEnded:
                return try await handleTerminalSessionEnded(request.paramsData)
            case RPCMethod.terminalNotificationEvent:
                return try await handleTerminalNotificationEvent(request.paramsData)
            case RPCMethod.sessionStates:
                return try await handleSessionStates(request.paramsData)
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
            case RPCMethod.prBindingsAll:
                return try await handlePRBindingsAll()
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
            case RPCMethod.terminalAskUserQuestionSatisfied:
                return try await handleTerminalAskUserQuestionSatisfied(request.paramsData)
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
            case RPCMethod.configSetRemoteCreateDefaults:
                return try await handleConfigSetRemoteCreateDefaults(request.paramsData)
            case RPCMethod.repoSetRemoteCreateDefaults:
                return try await handleRepoSetRemoteCreateDefaults(request.paramsData)
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
            case RPCMethod.worktreeSetPendingPrompt:
                return try await handleWorktreeSetPendingPrompt(request.paramsData)
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
            case RPCMethod.configSetQueuedPrompt:
                return try await handleConfigSetQueuedPrompt(request.paramsData)
            case RPCMethod.configSetClaudeCloud:
                return try await handleConfigSetClaudeCloud(request.paramsData)
            case RPCMethod.configSetAutoCreateNotes:
                return try await handleConfigSetAutoCreateNotes(request.paramsData)
            case RPCMethod.configSetAutoCloseSetup:
                return try await handleConfigSetAutoCloseSetup(request.paramsData)
            case RPCMethod.configSetAutoTrustWorktrees:
                return try await handleConfigSetAutoTrustWorktrees(request.paramsData)
            case RPCMethod.configSetGCEnabled:
                return try await handleConfigSetGCEnabled(request.paramsData)
            case RPCMethod.configSetGCProfileDirsEnabled:
                return try await handleConfigSetGCProfileDirsEnabled(request.paramsData)
            case RPCMethod.configSetGCOrphanProcessesEnabled:
                return try await handleConfigSetGCOrphanProcessesEnabled(request.paramsData)
            case RPCMethod.configSetSupervisionEnabled:
                return try await handleConfigSetSupervisionEnabled(request.paramsData)
            case RPCMethod.remoteProviders:
                return try await handleRemoteProviders()
            case RPCMethod.remoteSessions:
                return try await handleRemoteSessions()
            case RPCMethod.remoteCreate:
                return try await handleRemoteCreate(request.paramsData, actor: request.actor)
            case RPCMethod.remoteStop:
                return try await handleRemoteStop(request.paramsData, actor: request.actor)
            case RPCMethod.remoteArchive:
                return try await handleRemoteArchive(request.paramsData, actor: request.actor)
            case RPCMethod.remoteUnarchive:
                return try await handleRemoteUnarchive(request.paramsData, actor: request.actor)
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
            case RPCMethod.configSetRemotePeerMessagingEnabled:
                return try await handleConfigSetRemotePeerMessagingEnabled(request.paramsData)
            case RPCMethod.configSetPtyHolderEnabled:
                return try await handleConfigSetPtyHolderEnabled(request.paramsData)
            case RPCMethod.peerStatus:
                return try await handlePeerStatus()
            case RPCMethod.gcList:
                return try await handleGCList(request.paramsData)
            case RPCMethod.gcRestore:
                return try await handleGCRestore(request.paramsData)
            case RPCMethod.gcSweepNow:
                return try await handleGCSweepNow(request.paramsData)
            case RPCMethod.superviseStatus:
                return try await handleSuperviseStatus()
            case RPCMethod.superviseSetProjectMark:
                return try await handleSuperviseSetProjectMark(request.paramsData)
            case RPCMethod.superviseSetMode:
                return try await handleSuperviseSetMode(request.paramsData)
            case RPCMethod.superviseProjectList:
                return try await handleSuperviseProjectList()
            case RPCMethod.superviseProjectCreate:
                return try await handleSuperviseProjectCreate(request.paramsData)
            case RPCMethod.superviseProjectDelete:
                return try await handleSuperviseProjectDelete(request.paramsData)
            case RPCMethod.superviseProjectMove:
                return try await handleSuperviseProjectMove(request.paramsData)
            case RPCMethod.supervisePlaybook:
                return try await handleSupervisePlaybook(request.paramsData)
            case RPCMethod.supervisePlaybookCustomize:
                return try await handleSupervisePlaybookCustomize(request.paramsData)
            case RPCMethod.superviseReadout:
                return try await handleSuperviseReadout(request.paramsData)
            case RPCMethod.superviseLedger:
                return try await handleSuperviseLedger(request.paramsData)
            case RPCMethod.superviseBrief:
                return try await handleSuperviseBrief(request.paramsData)
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
            remoteBackendsLive: remoteManager != nil,
            queuedPromptEnabled: config.queuedPromptEnabled,
            claudeCloudEnabled: config.claudeCloudEnabled,
            claudeCloudLive: claudeCloudLive))
    }

    // MARK: - PR Status

    private func handlePRList() async throws -> RPCResponse {
        // Single-flight: while one enumeration is in flight, concurrent polls
        // await it and share the snapshot instead of each starting their own
        // git enumeration + gh fetch.
        let result = try await prListCoordinator.run { [self] in
            await computePRList()
        }
        return try RPCResponse(result: result)
    }

    /// Return the daemon's PR snapshot. Serving only — this handler never
    /// drives a fetch.
    ///
    /// `PRPoller` owns the clock, and it owns it alone. That is not tidiness:
    /// the merged-PR transition is edge-triggered on a cache change, so
    /// whichever path updates the cache consumes the edge. A second periodic
    /// driver here would swallow edges the first one's consumers (auto-archive,
    /// auto-hibernate-on-merge) are waiting for, and they would silently never
    /// fire.
    private func computePRList() async -> PRListResult {
        PRListResult(statuses: await prManager.allStatuses(),
                     observations: await prManager.allObservations())
    }

    /// One poll pass: enumerate active worktrees, enrich each with its (cached)
    /// branch facts, refresh PR status, and settle every binding that pass
    /// implies. Throws on a DB enumeration failure — `PRPoller.tick` logs it and
    /// waits for the next tick rather than tearing its loop down.
    ///
    /// Lives here rather than in `PRPoller` because `pr.refresh` and the
    /// on-select path share `pollWorkingDirectory` and `branchFacts` with it: an
    /// enumeration that drifted between the timer and a user gesture would let a
    /// worktree be polled under one candidate list and healed under another.
    func runPollPass() async throws {
        // Open the pass BEFORE anything can observe a merge. One pass raises
        // both merge edges for a worktree whose already-merged PR is discovered
        // with nothing bound yet — `fetchAll` fires the un-bound fallback, then
        // `refreshBindingStatuses` judges the binding this pass just created —
        // and the trigger dedupes the fan-out within the pass it is told about.
        await mergeTrigger?.beginPollPass()
        // Fetch fresh PR data for all active worktrees before returning the cache.
        let worktrees = Self.pollableWorktrees(try await db.worktrees.list(status: .active))
        let infos = await pollEntries(worktrees, repos: try await db.repos.list())
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
        // Prune at the END so we never drop an entry this pass just populated,
        // and **unconditionally** — including when the enumeration came back
        // empty, which is the pass that has the most to prune.
        await branchTrackingCache.retain(active: infos.map { (worktreePath: $0.worktreePath, branch: $0.branch) })
        // Same contract, same reason, for the PR facts themselves: the outcome
        // of an attempt on a worktree that has left the fleet is not a fact
        // anyone can act on, and every `pr.list` payload would carry it.
        await prManager.retain(active: Set(infos.map(\.id)))
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
        // Report the whole polled population before the early return, not just
        // the part with bindings. `evaluate` below only ever sees worktrees that
        // HAVE live bindings, so a worktree whose last binding was detached
        // could never re-arm itself — and a subsequent `tbd pr attach` would be
        // judged against a fired-guard that still held it.
        await mergeTrigger?.retainBound(
            polled: polled, bound: Set(bindings.map(\.worktreeID)))
        guard !bindings.isEmpty else { return }

        let observations = await prManager.refreshBindings(bindings, repoPath: repoPath)
        var refreshed: [PRBinding] = []
        refreshed.reserveCapacity(bindings.count)
        for binding in bindings {
            let updated = Self.folding(binding, onto: observations[binding.id])
            // `sameValue`, never `!=`: a fresh reading of an unchanged PR
            // differs only in its `observedAt`, and letting a freshness stamp
            // decide "changed" would make an idle poll write every binding row
            // every tick.
            if !updated.sameValue(as: binding) {
                try? await db.prBindings.updateObservation(
                    bindingID: binding.id, status: updated.status,
                    headBranch: updated.headBranch, baseRef: updated.baseRef,
                    title: updated.title)
            }
            refreshed.append(updated)
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
                  current.prStatus?.sameValue(as: update.status) != true else { continue }
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

    /// The binding a pass's observation implies — the row to persist AND the
    /// value the merge rule is judged on, which must be the same thing.
    ///
    /// An absent observation means "not observed this pass": keep the binding
    /// exactly as stored rather than clearing a status a transient failure hid.
    /// A present one carries the freshly observed head and base refs as well as
    /// the status, so the ownership arm of the merge rule judges against the
    /// head branch this pass actually saw. Folding only the status would leave
    /// the pass that FIRST observes a head ref judging against the nil it
    /// replaced — the gate would stay shut for one poll for no reason, and the
    /// in-memory binding would disagree with the row just written.
    ///
    /// Pure and static so a test can fold exactly what the poll folds, like
    /// `worktreePRStatusUpdates`.
    static func folding(
        _ binding: PRBinding, onto observed: PRStatusManager.PRBindingObservation?
    ) -> PRBinding {
        guard let observed else { return binding }
        return binding.withObservation(status: observed.status,
                                       headBranch: observed.headBranch,
                                       baseRef: observed.baseRef,
                                       title: observed.title)
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
    /// Remote rows ARE pollable: a lane carries a PR badge like any other row.
    /// Everything downstream is keyed on the *branch*, and the directory it runs
    /// in comes from `pollWorkingDirectory` — the repo's own checkout for a
    /// remote row — so no caller ever sees the synthetic `remote://` path.
    static func pollableWorktrees(_ worktrees: [Worktree]) -> [Worktree] {
        worktrees.filter(isPollable)
    }

    /// Whether one row is asked about at all. The single predicate behind BOTH
    /// the sweep's enumeration and `pr.refresh`, because the two disagreeing is
    /// itself the bug: a scratch row the sweep skips forever used to be queried
    /// the moment it was selected, the query failed in a directory that is not a
    /// checkout, and the failure was recorded as `.undetermined`, which every PR
    /// surface renders as "PR status unknown" for a row that cannot have a pull
    /// request. Then the next sweep's `prManager.retain(active:)` evicted the
    /// observation again, so the indicator blinked on select and off ~30s later.
    ///
    /// A scratch row is repo-less and branch-less by construction, so "no pull
    /// request applies here" is settled knowledge and the right answer is to make
    /// no attempt at all: not `.none` (which claims the forge answered), and not
    /// `.undetermined` (which claims someone tried and could not tell).
    static func isPollable(_ worktree: Worktree) -> Bool {
        !worktree.isScratch
    }

    /// The directory this row's poll runs `git` and `gh` in, or nil when there
    /// is none and the row must be skipped.
    ///
    /// A local row uses its own checkout. A remote row has no checkout on this
    /// machine, so it uses its repo's — which is correct because everything the
    /// poll asks is a *repo* fact keyed on a *branch*, never a worktree-local
    /// one: `git config --get branch.<b>.merge` and `git rev-parse <b>@{push}`
    /// both read config shared by every worktree of the repo and name the branch
    /// explicitly rather than reading HEAD, and `gh` uses the directory only to
    /// learn which GitHub repo it is talking to (auth is host-scoped).
    ///
    /// The remote arm cannot return `localPath`, which for a remote row is the
    /// synthetic `remote://<provider>/<sessionID>` URI from
    /// `WorktreeLocation.storagePath` and is not a directory at all. That is the
    /// structural guard: it is unreachable here rather than filtered out
    /// downstream. A remote row whose repo is unknown (deleted, or a row with no
    /// `repoID`) yields nil, and its caller skips the row entirely.
    ///
    /// **Several rows now resolve to the same string, and that is safe by
    /// construction rather than by luck.** Every lane of one repo shares its
    /// checkout, so the path stops being a per-row identifier — but no consumer
    /// ever used it as one. `PollWorktree.worktreePath` feeds exactly two kinds
    /// of site: a working directory for a `git`/`gh` subprocess, and a key into
    /// a *repo-identity* lookup (`PRStatusManager.ownerRepoCache`, and the
    /// `Set(...map(\.worktreePath))` resolutions and `groupNumberedByRepo`
    /// grouping built on it). Both answer questions about the repo, so rows that
    /// share a repo must get the same answer; collapsing them removes duplicate
    /// `gh repo view` spawns and changes nothing else. Every per-row result —
    /// the status cache, `lastDirectUpdate`, `headRefVerifiedIDs`, every match
    /// tuple — is keyed on the worktree `id`, which stays unique. And
    /// `branchTrackingCache` is keyed on `(path, branch)`, where the facts it
    /// caches (`branch.<b>.merge`, `<b>@{push}`) are themselves functions of
    /// `(repo, branch)`: collapsing the path makes that key *more* faithful to
    /// what it stores, not less.
    ///
    /// The local arm rejects an empty path, which is the other half of the
    /// guard `LocalWorktree.init?` carries and which `handlePRRefresh` used to
    /// get for free from `getLocal`. No daemon-written row has one today — the
    /// empty-path `.creating` placeholder is the app's optimistic in-memory row
    /// (`AppState+Worktrees`), never a DB row — so this is defense in depth
    /// rather than a reachable bug. It is worth the line because the failure it
    /// prevents is silent: `URL(fileURLWithPath: "")` resolves to the *daemon's
    /// own* working directory, so an empty path would run `git` and `gh`
    /// somewhere plausible and cache the wrong branch facts under that row,
    /// rather than failing loudly the way the synthetic `remote://` URI does.
    static func pollWorkingDirectory(
        _ worktree: Worktree, repoPathByID: [UUID: String]
    ) -> String? {
        switch worktree.location {
        case .local:
            return worktree.localPath.isEmpty ? nil : worktree.localPath
        case .remote:
            return worktree.repoID.flatMap { repoPathByID[$0] }
        }
    }

    /// Compose one poll pass's input: the branch facts and working directory
    /// each pollable row is judged on.
    ///
    /// Split out of `computePRList` so a test can assert what the poll *is*
    /// given a set of rows, rather than inferring it from whatever `gh` was
    /// asked afterwards. `repos` is read once per pass rather than per row:
    /// `defaultBranch` tells a tracked BASE from a rename-push target (see
    /// `PRStatusManager.branchCandidates`, and `headRefMismatchedMatches` for
    /// why a stale value can only cost a missed heal), and `path` is the
    /// directory a remote row's poll runs in.
    func pollEntries(
        _ worktrees: [Worktree], repos: [Repo]
    ) async -> [PRStatusManager.PollWorktree] {
        let defaultBranchByRepo = Dictionary(
            uniqueKeysWithValues: repos.map { ($0.id, $0.defaultBranch) })
        let pathByRepo = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0.path) })
        var infos: [PRStatusManager.PollWorktree] = []
        infos.reserveCapacity(worktrees.count)
        for wt in worktrees {
            // The one place a row's poll working directory is chosen. A remote
            // row whose repo is gone resolves to nil and is simply not polled —
            // there is no directory to run `git` or `gh` in.
            guard let workingDirectory = Self.pollWorkingDirectory(wt, repoPathByID: pathByRepo) else {
                continue
            }
            let (upstreamBranch, pushBranch) = await branchFacts(
                worktreePath: workingDirectory, branch: wt.branch)
            infos.append((
                id: wt.id,
                branch: wt.branch,
                upstreamBranch: upstreamBranch,
                defaultBranch: wt.repoID.flatMap { defaultBranchByRepo[$0] },
                pushBranch: pushBranch,
                worktreePath: workingDirectory,
                prNumber: wt.prNumber
            ))
        }
        return infos
    }

    private func handlePRRefresh(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PRRefreshParams.self, from: paramsData)

        // Run a targeted refresh for one row and try the tracked upstream branch
        // when needed. The working directory comes from `pollWorkingDirectory`,
        // exactly as the poll's does, so a remote row refreshes against its
        // repo's checkout and its own branch. A row with no working directory —
        // an unknown id, or a remote row whose repo is gone — gets "nothing to
        // report".
        guard let wt = try await db.worktrees.get(id: params.worktreeID) else {
            // No observation: no attempt was made, which is a third thing again
            // from `.none` and `.undetermined` and must not be dressed as either.
            return try RPCResponse(result: PRRefreshResult(status: nil, observation: nil))
        }
        // The same predicate the sweep enumerates through. A scratch row is not
        // polled, so it must not be refreshed either: no attempt is made, and
        // "no attempt" is reported rather than a failure invented by asking a
        // question that has no answer here.
        guard Self.isPollable(wt) else {
            return try RPCResponse(result: PRRefreshResult(status: nil, observation: nil))
        }
        var repo: Repo?
        if let repoID = wt.repoID {
            repo = try await db.repos.get(id: repoID)
        }
        guard let workingDirectory = Self.pollWorkingDirectory(
            wt, repoPathByID: repo.map { [$0.id: $0.path] } ?? [:]) else {
            return try RPCResponse(result: PRRefreshResult(status: nil))
        }
        // Read the branch facts through the SAME cache the poll uses. Reading
        // git directly here would let a user refresh attach a PR that the very
        // next poll — still inside the cache's TTL, still holding the older
        // facts — judges by a different candidate list and clears again.
        let (upstreamBranch, pushBranch) = await branchFacts(
            worktreePath: workingDirectory, branch: wt.branch)

        let status = await prManager.refresh(
            worktreeID: wt.id,
            branch: wt.branch,
            upstreamBranch: upstreamBranch,
            defaultBranch: repo?.defaultBranch,
            pushBranch: pushBranch,
            repoPath: workingDirectory,
            prNumber: wt.prNumber
        )
        return try RPCResponse(result: PRRefreshResult(
            status: status, observation: await prManager.observation(for: wt.id)))
    }

    // MARK: - PR bindings

    private func handlePRBindings(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PRBindingsParams.self, from: paramsData)
        // Read live and tombstoned rows in ONE query and partition here, so the
        // reported counts cannot disagree with each other the way two separate
        // SELECTs racing a concurrent detach could. `detachedCount` is what lets
        // the app tell "nothing is bound" from "the user unbound everything" —
        // see `PRBindingsResult.detachedCount`.
        let all = try await db.prBindings.list(worktreeID: params.worktreeID, includeDetached: true)
        let live = all.filter { !$0.detached }
        return try RPCResponse(result: PRBindingsResult(
            bindings: live, detachedCount: all.count - live.count))
    }

    /// Every worktree's bindings in one call — the app's poll.
    ///
    /// No worktree parameter, deliberately. The app cannot name the worktrees to
    /// ask about: a worktree whose only PR was bound by the `gh pr create` hook,
    /// on a branch it never checked out, is in no branch-derived status cache,
    /// so any per-worktree fan-out can only ever reach worktrees already known
    /// to have PRs — and the hook-bound case is precisely the one multi-PR
    /// exists to make visible. One indexed read of the whole table costs less
    /// than the N round trips it replaces.
    ///
    /// Entries are sorted by worktree id so the response is byte-stable across
    /// calls with unchanged data; the bindings inside each entry keep bind order.
    private func handlePRBindingsAll() async throws -> RPCResponse {
        let all = try await db.prBindings.listAllByWorktree()
        let worktreeIDs = Set(all.live.keys).union(all.detachedCounts.keys)
        let entries = worktreeIDs
            .sorted { $0.uuidString < $1.uuidString }
            .map { worktreeID in
                PRBindingsAllEntry(worktreeID: worktreeID,
                                   bindings: all.live[worktreeID] ?? [],
                                   detachedCount: all.detachedCounts[worktreeID] ?? 0)
            }
        return try RPCResponse(result: PRBindingsAllResult(worktrees: entries))
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
        // Detach-only fallthrough: see `resolvePRRef`. Untracking the wrong PR
        // is reversible; binding one silently is not.
        switch await resolvePRRef(params, numberFallback: true) {
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
    ///
    /// With `numberFallback`, a URL that does not parse **falls through to the
    /// number** rather than failing outright, which is what makes sending both
    /// worth doing. The status bar's untrack gesture names a PR by whatever its
    /// chip holds, and a chip lifted from a cached `Worktree.prStatus` can hold
    /// a URL `PRBindingExtractor` will not accept. It parses two shapes and
    /// only two: `https://github.com/<owner>/<repo>/pull/<n>`, host-locked to
    /// github.com, and `/-/merge_requests/<iid>` on any host. So a pull request
    /// served by GitHub Enterprise, Bitbucket, Gitea or Codeberg parses under
    /// neither, every synthetic chip on such a worktree is in that state, and a
    /// url-only reference would make the xmark fail every time on exactly the
    /// worktrees that only ever have synthetic chips. A reference with a bad
    /// URL and no number is still unresolvable; nothing is guessed.
    ///
    /// **Off by default, and detach-only on purpose.** The fallthrough re-reads
    /// the number against *this* worktree's repo, so for an attach a URL naming
    /// #412 on some other host would silently bind this repo's #412 — a
    /// different pull request, bound with no error. Removing a wrong
    /// association is recoverable; creating one quietly is the failure the
    /// wrong-repo guard exists to prevent, so attach keeps the strict form.
    private func resolvePRRef(_ params: PRBindingRefParams,
                              numberFallback: Bool = false) async -> PRRefResolution {
        if let url = params.url, !url.isEmpty {
            if let parsed = PRBindingExtractor.parsePRURLs(in: url).first {
                return .resolved(parsed)
            }
            guard numberFallback else { return .unresolvable }
        }
        guard let number = params.number, number > 0 else { return .unresolvable }
        guard let parsed = await prRef(worktreeID: params.worktreeID, number: number) else {
            return .unknownRepo
        }
        return .resolved(parsed)
    }

    /// A bare PR or MR number as a `ParsedPRURL` in the worktree's own repo.
    ///
    /// Resolved through the same seam the coordinator validates with, so a
    /// number can never synthesise a URL the policy would then reject as
    /// wrong-repo. Returns nil when the worktree's repo cannot be named — the
    /// caller defers rather than guessing an owner or a host.
    ///
    /// This is the one path that must establish the forge rather than read it,
    /// because there is no URL yet to read it from: GitLab writes
    /// `/<namespace…>/<project>/-/merge_requests/<iid>` where GitHub writes
    /// `/owner/name/pull/<n>`, and composing one shape for every host yields a
    /// URL that points at nothing on the hosts that speak the other.
    ///
    /// So it asks the only component that can know. `PRStatusManager` answers
    /// from `GitLabHostResolver`, which reads the hosts the user configured
    /// `glab` for — a declaration, not an inference. The GitLab shape is
    /// composed only for a host named there; every other host keeps `/pull/`,
    /// which is what a GitHub Enterprise, Bitbucket, Gitea or Codeberg
    /// checkout serves and what github.com has always been given. Reading the
    /// hostname's own shape instead would hand all four of those fleets a
    /// merge-request URL that 404s.
    private func prRef(worktreeID: UUID, number: Int) async -> ParsedPRURL? {
        guard let own = await prBindingRepoResolver(worktreeID) else { return nil }
        // Two independent lookups have to succeed, and this is the second: the
        // repo names the coordinate, the forge names the shape. Either one
        // failing leaves a URL that could only be guessed.
        guard let isGitLab = await isGitLabWorktree(worktreeID: worktreeID, host: own.host) else {
            return nil
        }
        let path = "https://\(own.host)/\(own.owner)/\(own.name)"
        let url = isGitLab
            ? "\(path)/-/merge_requests/\(number)"
            : "\(path)/pull/\(number)"
        return ParsedPRURL(
            host: own.host, owner: own.owner, repo: own.name, number: number, url: url)
    }

    /// Whether this worktree's host speaks GitLab, asked in the worktree's own
    /// directory because that is where `glab` reads its configuration from —
    /// or nil when the question could not be put at all.
    ///
    /// Nil is a third answer and not a soft "no". A worktree with no local row
    /// — a remote one, or one deleted between the resolve and this call —
    /// cannot supply that directory, so nothing has answered, and answering
    /// "not GitLab" there is a guess that composes `/pull/<n>` on a host that
    /// may well serve `/-/merge_requests/<n>`: a binding whose URL 404s and
    /// whose label reads "PR", persisted. `prRef` defers on nil instead, the
    /// same way it defers when the repo cannot be named.
    ///
    /// A resolver that positively answers "this host is not GitLab" returns
    /// `false` and still gets `/pull/<n>` — the shape github.com has always
    /// been given and the one a GitHub Enterprise, Bitbucket, Gitea or
    /// Codeberg checkout serves. `github.com` never reaches a subprocess: the
    /// resolver short-circuits it.
    private func isGitLabWorktree(worktreeID: UUID, host: String) async -> Bool? {
        await prBindingForgeResolver(worktreeID, host)
    }
}
