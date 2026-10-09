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
    /// Exact-token SessionStart rendezvous for Codex-to-Claude replacement
    /// and its Codex rollback/recovery process.
    let continueInClaudeReadiness = ContinueInClaudeReadinessCoordinator()
    /// Behavior deadline for one replacement or rollback readiness wait.
    /// Production keeps the design's 15-second bound; focused tests shorten it.
    nonisolated(unsafe) var continueInClaudeReadinessTimeout: Duration = .seconds(15)
    /// Append-only record of every state-changing actuation this router
    /// performs. Shared with the daemon-internal rails (see `Daemon.swift`) so
    /// the whole daemon writes one file. Handlers append a request row before
    /// their first mutating step and an outcome row after the act returns —
    /// see `RPCRouter+Actuation.swift`.
    public let actuationLog: ActuationLog
    public let usageFetcher: ClaudeUsageFetcher
    public let modelProfileResolver: ModelProfileResolver
    /// Injected for the rate-limit handler's profile suggestion; a seam like
    /// `limitResumeScheduler` so tests can install one after construction.
    public nonisolated(unsafe) var profilePoolCandidateSource: ProfilePoolCandidateSource?
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
    /// Periodic comparison of this build against the remote's `main`. `nil`
    /// when nothing wired one (mock mode, unit tests), in which case
    /// `daemon.status` carries no `update` field and `daemon.checkForUpdate`
    /// answers "nothing observed" rather than failing. Set post-construction
    /// like `claudeUsagePoller`.
    public nonisolated(unsafe) var updateChecker: UpdateChecker?
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
    /// Login-completion watching for profile login sessions. Injected so
    /// tests can shrink the watcher's poll timings.
    public let loginSessions: LoginSessionCoordinator
    /// Daemon-owned panel surface actor (spec C Phase 2). Gating lives inside
    /// the coordinator (§7.2) — `panel.*` handlers route to it and must not
    /// re-implement gating. Broadcasts through the same `subscriptions`
    /// channel every other mutating handler uses.
    public let panelCoordinator: PanelCoordinator
    /// Native Claude-to-Codex import seams. Production uses the installed
    /// Codex app-server; tests replace these before invoking the handler.
    nonisolated(unsafe) var codexExecutableResolver: @Sendable () throws -> String
    /// Whether a recorded holder pid still names a running `TBDHolder` — the
    /// holder half of `HolderChildDisposition.sessionHasEnded`, consulted only
    /// when a holder attach is refused. Tests replace it.
    nonisolated(unsafe) var holderProcessIsLive: @Sendable (Int32) -> Bool = { pid in
        HolderSpawner.isLiveHolder(pid: pid)
    }
    /// How the attach path's "ended" answer reads a recorded child pid's
    /// identity. Tests replace it with a scripted process table.
    nonisolated(unsafe) var holderChildSignaller: any ProcessSignaller = ProductionProcessSignaller()
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
    /// The budgeted PR schedule that replaces `prPoller` when
    /// `pr_poll_schedule_enabled` is set. Exactly one of the two is started
    /// (`PRPollDriver`, from `Daemon.start()`); the other stays inert. Its
    /// facts and its pass live here for the reason `runPollPass` does — the
    /// enumeration helpers are shared with `pr.refresh` — and are installed at
    /// the end of `init`.
    public let prPollScheduler: PRPollScheduler
    /// In-memory hook and selection stamps the schedule reads activity from.
    public let activityLedger: WorktreeActivityLedger
    /// Starts the one PR driver at daemon start (`Daemon.start()`, step 12f)
    /// and swaps it live when `config.setPRPollScheduleEnabled` changes the
    /// flag. Inert until the daemon arms it, so a router built in a test never
    /// starts a driver because a flag was written.
    public let prPollDriverSwitch: PRPollDriverSwitch
    /// When a scheduled pass last pruned the branch-facts cache against the
    /// whole fleet. A scheduled pass composes poll entries for the due rows
    /// only, and `branchTrackingCache.retain` over that subset would evict
    /// every row that merely was not due, so the full prune runs at most
    /// hourly instead (`runScheduledPass`).
    let lastFullPrune = OSAllocatedUnfairLock<Date?>(initialState: nil)
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
    /// Queues concurrent `remote.sendMessage` RPCs per remote session, the
    /// same way — see `RemoteSendMessageSerializer`.
    let remoteSendMessageSerializer = RemoteSendMessageSerializer()
    /// Per-session fetch lanes behind `remote.transcriptSync`. Built over
    /// `remoteManager`, so it is `nil` exactly when that is — and the handler
    /// is refused by `remoteGate()` before it would need one.
    let remoteTranscriptSync: RemoteTranscriptSync?
    /// The latest transcript hint each remote session reported, read by
    /// `remoteTranscriptSync`'s tail-or-forward decision. Always built, and
    /// empty after every daemon start until the first sightings.
    let remoteTranscriptHints: RemoteTranscriptHints
    /// Keeps unopened remote sessions' transcript caches current, fed the
    /// sightings `remoteManager` processes through the observer `Daemon`
    /// installs. Built over `remoteTranscriptSync`, so it is `nil` exactly
    /// when that is.
    let remoteTranscriptBackgroundSync: RemoteTranscriptBackgroundSync?
    /// Daemon-lifetime incremental transcript baselines used only to enrich
    /// terminal-list responses for Codex presentation state.
    let codexActivityTracker = CodexTranscriptActivityTracker()
    /// Which Claude terminals owe a delegation sample, and what their last
    /// sample claimed. Marked at every idle report; read during `terminal.list`.
    let claudeDelegationTracker = ClaudeDelegationTracker()
    /// Answers `terminal.completions`. Holds the per-session inventory cache for
    /// the daemon's lifetime, which is why it is a stored collaborator rather
    /// than something the handler builds per request.
    let completionInventory: CompletionInventoryService
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

    /// The daemon's `ModelProxySupervisor`, set by `Daemon` after construction
    /// from the same value the lifecycle and the hibernation coordinator hold.
    /// Two things read it: `daemon.capabilities`, which reports whether this
    /// daemon can route at all, and the terminal teardown path, which retires
    /// the route of a row it is about to delete. `nil` in mock mode and in tests
    /// that never exercise the proxy — capabilities then answer "unsupported,
    /// no port, no version", which is the honest reading of a daemon that
    /// cannot route.
    nonisolated(unsafe) var modelProxySupervisor: (any ModelProxySupervising)?

    /// How the swap paths build the scheduler that recaptures a resumed
    /// session's ID. `nil` in production, which builds the ordinary
    /// `SessionRecaptureScheduler(db:tmux:)`. The mirror of
    /// `WorktreeLifecycle.sessionRecaptureFactory`, for the same reason.
    ///
    /// A seam because the branch it feeds — which target a fork tab's recapture
    /// is scheduled against — is otherwise unobservable from outside. A real
    /// scheduler's only trace is a database write five wall seconds later, made
    /// only if a live Claude process answers; "it was scheduled against the
    /// pane" and "it was scheduled against the holder's child" look identical
    /// from the row. Injecting the scheduler makes the decision itself the
    /// observable, on virtual time.
    nonisolated(unsafe) var sessionRecaptureFactory: (
        @Sendable (TBDDatabase, TmuxManager) -> SessionRecaptureScheduler
    )?

    /// The instant between the two halves of a holder in-place profile swap,
    /// opened for a test to act in. `holderInPlaceSwap` awaits it with the
    /// terminal's id once the park has succeeded and the parked row has been
    /// re-read, and before `reHomeParkedRow` writes anything. **A test seam
    /// only** — production never sets it, and nil means the arm awaits nothing.
    ///
    /// It exists because the spec's second failure outcome — a re-home that
    /// fails after a successful park leaves the row parked on its OLD profile
    /// — has no other observable staging point. The park needs a reader over a
    /// real pty, so only the live suite can reach this arm at all, and by the
    /// time the RPC returns the whole composition has run: there is no moment
    /// from outside at which the worktree row, the terminal row or the CAS
    /// snapshot can be made stale in the narrow window `reHomeParkedRow`
    /// guards. A test sets this to change the worktree's status out from under
    /// the status the handler captured at entry, which is exactly what the
    /// lock's `allowedStatuses` check refuses, and then asserts the row is
    /// still parked and still on the account it started on.
    ///
    /// Deliberately an interposition point and nothing more: it takes no
    /// decision, returns nothing, and neither the response nor any actuation
    /// reads it.
    nonisolated(unsafe) var holderSwapBetweenParkAndReHome: (@Sendable (UUID) async -> Void)?

    /// Delivers `terminal.send` to a holder-backed session, routed by who is
    /// reading its pty. Set by `Daemon` after construction, beside the registry
    /// and the sidecar it is built from. `nil` in mock mode and in tests that
    /// never exercise the transport, where a holder row is told there is no
    /// input path in this daemon rather than being silently dropped.
    nonisolated(unsafe) var holderInjectionCourier: HolderInjectionCourier?

    /// Answers what modes a holder-backed session's child is in, for the send
    /// path to compose against. A **test seam only** — production leaves it
    /// nil and `performHolderSend` falls through to the registry's own reader,
    /// which is the single source the design names.
    ///
    /// It exists because the alternative is worse: reaching the three answers
    /// (`daemon`, `staleDaemon`, and no answer at all) through a real registry
    /// means a real holder, a real pty and a real attach for what is a pure
    /// question about which bytes get composed. The registry-backed path is
    /// exercised live; this is how the composition's own branches are pinned.
    ///
    /// `nil` from the seam means the same thing as no reader: nothing answered.
    nonisolated(unsafe) var holderModeOracle: (@Sendable (UUID) async -> TerminalModeReading?)?

    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    /// Date seam for facts the router *persists*. A stored observed-at is data,
    /// not behavior, so this is the `now: @Sendable () -> Date` seam rather
    /// than a `Clock` — tests pin it and assert the exact stamp instead of a
    /// tolerance window. Only handlers that write an observation may read it;
    /// it is not a general-purpose "what time is it".
    let now: @Sendable () -> Date

    /// How a session transcript is measured when a prompt is recorded against
    /// it. A seam, not a clock: a file's modification time is data, so it
    /// follows the same rule as `now` rather than the `Clock` rule.
    let transcriptFingerprinter: TranscriptFingerprinter
    /// How the records a transcript gained since a stored fingerprint are read
    /// and attributed. Paired with the fingerprinter: the stat says the file
    /// moved, this says whether the session itself did.
    let transcriptDeltaInspector: TranscriptDeltaInspector

    /// How the daemon asks whether Claude owns a pane's foreground process
    /// group. The same seam the limit-resume actuator uses, held here so the
    /// send path can refuse a pane whose agent has left without any test
    /// needing a real `ps`. A process-table fact, never screen text.
    let paneProcessInspector: any PaneProcessInspecting

    /// The identity the FD-vending sidecar recorded for its current client.
    ///
    /// That client is the app: it connects the sidecar eagerly and
    /// unconditionally as soon as the RPC socket answers, and the sidecar has
    /// exactly one. The daemon already treats this identity as load-bearing —
    /// `AppLivenessArbiter` decides on it whether the daemon may read a pty
    /// again — so nothing new is being trusted here, only read from one more
    /// place.
    ///
    /// Injected, and defaulting to "no recorded client", so a router built in a
    /// test authenticates nobody until a test says otherwise. That default is
    /// the fail-closed one.
    let recordedAppIdentity: @Sendable () async -> ProcessIdentity?
    /// The one process-fact reader, injected for the same reason `AgentReaper`
    /// and `AppLivenessArbiter` take one: the re-verification must be statable
    /// in a test without a process to inspect.
    let processSignaller: any ProcessSignaller

    /// Behavior seam for send-path settling after an image paste and the
    /// graceful interrupt before an in-place profile replacement. A
    /// `Duration` is behavior, so this is the `Clock` seam rather than the
    /// `now` date seam beside it, and it is existential (`any Clock<Duration>`)
    /// for the reason every other subsystem here holds one that way — a generic
    /// parameter would infect the `Sendable` conformances the router already
    /// carries.
    let clock: any Clock<Duration>

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
        profilePoolCandidateSource: ProfilePoolCandidateSource? = nil,
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
        transcriptFingerprinter: @escaping TranscriptFingerprinter = TranscriptFingerprinting.live,
        transcriptDeltaInspector: @escaping TranscriptDeltaInspector
            = TranscriptDeltaInspection.live,
        paneProcessInspector: any PaneProcessInspecting = ProductionPaneProcessInspector(),
        completionInventory: CompletionInventoryService = CompletionInventoryService(),
        recordedAppIdentity: @escaping @Sendable () async -> ProcessIdentity? = { nil },
        processSignaller: any ProcessSignaller = ProductionProcessSignaller(),
        actuationLog: ActuationLog,
        remoteTranscriptEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.recordedAppIdentity = recordedAppIdentity
        self.processSignaller = processSignaller
        self.clock = clock
        self.now = now
        self.transcriptFingerprinter = transcriptFingerprinter
        self.transcriptDeltaInspector = transcriptDeltaInspector
        self.paneProcessInspector = paneProcessInspector
        self.completionInventory = completionInventory
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
        let poller = PRPoller()
        self.prPoller = poller
        let ledger = WorktreeActivityLedger()
        self.activityLedger = ledger
        // Placeholder handlers: the real ones need the fully formed router and
        // are installed at the end of `init`, beside `prPoller.installPass`.
        let scheduler = PRPollScheduler(facts: { [] }, run: { _ in }, now: now, clock: clock)
        self.prPollScheduler = scheduler
        // The steps capture the three actors, not the router, so the switch
        // keeps no router alive. Off→on stops the poller, enables the ledger
        // (before the first wake reads it), then starts the scheduler; on→off
        // reverses that. Every step is idempotent, and each stop waits for a
        // pass in flight to finish so the next driver never overlaps it.
        self.prPollDriverSwitch = PRPollDriverSwitch(steps: .init(
            startLegacy: { await poller.start() },
            stopLegacy: { await poller.stopAndWait() },
            startSchedule: {
                await ledger.setEnabled(true)
                await scheduler.start()
            },
            stopSchedule: {
                await scheduler.stopAndWait()
                await ledger.setEnabled(false)
            }))
        // Default the candidate source from the router's own stores rather
        // than leaving it nil: the rate-limit handler's suggestion reads it,
        // and a caller that forgets to pass one would otherwise disable it
        // silently (the AI review caught exactly that gap in the daemon's
        // wiring). Callers that pass one — the
        // daemon, so the resolver and the handler share it, and tests that
        // inject fakes — still win.
        let resolvedCandidateSource = profilePoolCandidateSource ?? ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { [configDirManager] in configDirManager.loginIdentity(forProfileID: $0) }
        )
        self.profilePoolCandidateSource = resolvedCandidateSource
        let resolvedModelProfileResolver = modelProfileResolver ?? ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config,
            candidateSource: resolvedCandidateSource,
            reservations: ProfilePickReservations(),
            staleAlerts: StaleAccountAlerts(
                notify: StaleAccountAlerts.notifier(db: db, subscriptions: subscriptions)),
            fallbackAlerts: BalancingFallbackAlerts(
                notify: StaleAccountAlerts.notifier(db: db, subscriptions: subscriptions))
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
        // Resolved in `bindingRepoPath`, the directory the row's poll runs in:
        // a local row's own checkout, and a remote row's REPO checkout, since a
        // remote row has no directory on this machine and owner, name and host
        // are repo facts rather than worktree facts. Without the remote arm
        // every bind on a lane deferred, so a lane could hold no binding at all.
        let repoResolver = prBindingRepoResolver ?? { [db, prManager] worktreeID in
            guard let path = await RPCRouter.bindingRepoPath(worktreeID: worktreeID, db: db) else { return nil }
            return await prManager.repoIdentity(repoPath: path)
        }
        self.prBindingRepoResolver = repoResolver
        // The forge half of the same seam, resolved in the same directory:
        // `glab` reads its configuration from the checkout it runs in, and a
        // remote row's repo checkout carries the same configuration its lane's
        // repo does. Nil still means "nothing here to ask in" — an unknown row,
        // or a remote row whose repo is gone.
        let forgeResolver: @Sendable (UUID, String) async -> Bool? = { [db, prManager] worktreeID, host in
            guard let path = await RPCRouter.bindingRepoPath(worktreeID: worktreeID, db: db) else { return nil }
            return await prManager.isGitLabHost(host, repoPath: path)
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
        // `remoteTranscriptEnvironment` resolves the cache root through
        // `TBDConstants`, so `TBD_HOME` decides where caches live and a test
        // can point it at a temp home without touching the process env.
        let hints = RemoteTranscriptHints()
        self.remoteTranscriptHints = hints
        let transcriptSync = remoteManager.map { manager in
            RemoteTranscriptSync(
                environment: remoteTranscriptEnvironment,
                policy: { [db] provider, sessionID in
                    // Read at every decision, never cached (§ Gating), so a
                    // toggle takes effect on the next sync.
                    let enabled = (try? await db.config.get().remoteTranscriptLiveSyncEnabled)
                        ?? Config.remoteTranscriptLiveSyncEnabledDefault
                    let capabilities = await manager.declaredCapabilities(provider: provider)
                    return RemoteTranscriptSyncPolicy(
                        liveSyncEnabled: enabled,
                        tailDeclared: capabilities.contains(RemoteCapability.transcriptTail),
                        hint: await hints.latest(provider: provider, sessionID: sessionID))
                },
                invoke: { provider, verb in
                    try await manager.invoke(
                        providerName: provider, verb: verb, stdin: nil,
                        timeout: RPCRouter.transcriptReadTimeout)
                })
        }
        self.remoteTranscriptSync = transcriptSync
        if let manager = remoteManager, let transcriptSync {
            self.remoteTranscriptBackgroundSync = RemoteTranscriptBackgroundSync(
                environment: remoteTranscriptEnvironment,
                hints: hints,
                isEnabled: { [db] in
                    // Read at every admission and dequeue, never cached.
                    (try? await db.config.get().remoteTranscriptLiveSyncEnabled)
                        ?? Config.remoteTranscriptLiveSyncEnabledDefault
                },
                capabilities: { provider in
                    await manager.declaredCapabilities(provider: provider)
                },
                isDismissed: { [db] provider, sessionID in
                    let row = try? await db.remoteSessions.row(provider: provider, sessionID: sessionID)
                    return row?.dismissed == true
                },
                discard: { provider, sessionID in
                    await transcriptSync.discard(provider: provider, sessionID: sessionID)
                },
                sync: { provider, sessionID in
                    try await transcriptSync.sync(provider: provider, sessionID: sessionID)
                })
        } else {
            self.remoteTranscriptBackgroundSync = nil
        }
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
        // The schedule's facts and pass, on the same terms and for the same
        // reason: `weak`, so a discarded router is not kept alive by its own
        // scheduler, and a wake on a deallocated router sees no work.
        prPollScheduler.installHandlers(
            facts: { [weak self] in
                guard let self else { return [] }
                return await self.pollScheduleFacts()
            },
            run: { [weak self] due in await self?.runScheduledPass(due) })
    }

    /// Handle a raw JSON Data blob representing an RPCRequest.
    /// Returns an RPCResponse.
    ///
    /// `connection` is what the daemon knows about the socket the bytes arrived
    /// on, as opposed to what they say about themselves. Defaulted to nil —
    /// "not established" — because most callers are not sockets at all, and
    /// that is the fail-closed answer for every one of them.
    public func handleRaw(
        _ data: Data, connection: RPCConnectionContext? = nil
    ) async -> RPCResponse {
        do {
            let request = try decoder.decode(RPCRequest.self, from: data)
            return await handle(request, connection: connection)
        } catch {
            return RPCResponse(error: "Failed to decode request: \(error.localizedDescription)")
        }
    }

    /// Handle a decoded RPCRequest and return an RPCResponse.
    public func handle(
        _ request: RPCRequest, connection: RPCConnectionContext? = nil
    ) async -> RPCResponse {
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
            case RPCMethod.terminalContinueInClaude:
                return try await handleTerminalContinueInClaude(
                    request.paramsData, actor: request.actor)
            case RPCMethod.terminalList:
                return try await handleTerminalList(request.paramsData)
            case RPCMethod.terminalSend:
                // The ONE case that is handed the connection, because it is the
                // one that makes an authorization decision on it.
                return try await handleTerminalSend(
                    request.paramsData, actor: request.actor, connection: connection)
            case RPCMethod.terminalCompletions:
                return try await handleTerminalCompletions(request.paramsData)
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
                return try await handleDaemonStatus()
            case RPCMethod.daemonCheckForUpdate:
                return try await handleDaemonCheckForUpdate()
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
            case RPCMethod.modelProfileUpdateToken:
                return try await handleModelProfileUpdateToken(request.paramsData)
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
            case RPCMethod.modelProfileSetPoolOptOut:
                return try await handleModelProfileSetPoolOptOut(request.paramsData)
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
            case RPCMethod.configSetGCHangStacksEnabled:
                return try await handleConfigSetGCHangStacksEnabled(request.paramsData)
            case RPCMethod.configSetGCRetainedTranscriptsEnabled:
                return try await handleConfigSetGCRetainedTranscriptsEnabled(request.paramsData)
            case RPCMethod.configSetRemoteDeleteEnabled:
                return try await handleConfigSetRemoteDeleteEnabled(request.paramsData)
            case RPCMethod.configSetProfileBalancingEnabled:
                return try await handleConfigSetProfileBalancingEnabled(request.paramsData)
            case RPCMethod.configSetProfileBalancingUsageCeiling:
                return try await handleConfigSetProfileBalancingUsageCeiling(request.paramsData)
            case RPCMethod.configSetProfileBalancingMaxReadingAge:
                return try await handleConfigSetProfileBalancingMaxReadingAge(request.paramsData)
            case RPCMethod.configSetPRPollScheduleEnabled:
                return try await handleConfigSetPRPollScheduleEnabled(request.paramsData)
            case RPCMethod.configSetRemoteTranscriptLiveSyncEnabled:
                return try await handleConfigSetRemoteTranscriptLiveSyncEnabled(request.paramsData)
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
            case RPCMethod.remoteRetain:
                return try await handleRemoteRetain(request.paramsData)
            case RPCMethod.remoteImport:
                return try await handleRemoteImport(request.paramsData)
            case RPCMethod.remoteRecall:
                return try await handleRemoteRecall(request.paramsData)
            case RPCMethod.remoteTranscript:
                return try await handleRemoteTranscript(request.paramsData)
            case RPCMethod.remoteRetainedList:
                return try await handleRemoteRetainedList(request.paramsData)
            case RPCMethod.remoteDelete:
                return try await handleRemoteDelete(request.paramsData, actor: request.actor)
            case RPCMethod.remoteSetPin:
                return try await handleRemoteSetPin(request.paramsData)
            case RPCMethod.remoteReportAttachExit:
                return try await handleRemoteReportAttachExit(request.paramsData)
            case RPCMethod.remoteReconnect:
                return try await handleRemoteReconnect(request.paramsData)
            case RPCMethod.remoteTranscriptSync:
                return try await handleRemoteTranscriptSync(request.paramsData)
            case RPCMethod.remoteTranscriptLoadEarlier:
                return try await handleRemoteTranscriptLoadEarlier(request.paramsData)
            case RPCMethod.remoteSendMessage:
                return try await handleRemoteSendMessage(request.paramsData, actor: request.actor)
            case RPCMethod.configSetRemoteBackends:
                return try await handleConfigSetRemoteBackends(request.paramsData)
            case RPCMethod.configSetRemotePeerMessagingEnabled:
                return try await handleConfigSetRemotePeerMessagingEnabled(request.paramsData)
            case RPCMethod.configSetUpdateMode:
                return try await handleConfigSetUpdateMode(request.paramsData)
            case RPCMethod.configSetPtyHolderEnabled:
                return try await handleConfigSetPtyHolderEnabled(request.paramsData)
            case RPCMethod.configSetModelProxyEnabled:
                return try await handleConfigSetModelProxyEnabled(request.paramsData)
            case RPCMethod.configSetTranscriptStreamingEnabled:
                return try await handleConfigSetTranscriptStreamingEnabled(request.paramsData)
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
        var result = DaemonCapabilitiesResult(
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
            claudeCloudLive: claudeCloudLive,
            remoteDeleteEnabled: config.remoteDeleteEnabled,
            updateMode: config.updateMode,
            ptyHolderEnabled: config.ptyHolderEnabled,
            // The same second half the spawn gate asks
            // (`WorktreeLifecycle+Create`): a registry can exist and still be
            // unable to start a holder, and with the flag on that combination
            // falls back to tmux silently. Reported so Settings can say so
            // instead of offering a switch that would change nothing.
            ptyHolderSupported: holderRegistry?.canSpawn == true)
        // Assigned rather than passed: this initializer's argument list is at
        // the Swift type-checker's expression budget — adding to it produces
        // "unable to type-check this expression in reasonable time" — so the
        // model-proxy fields are set after construction instead.
        result.modelProxyEnabled = config.modelProxyEnabled
        // The conjunction, not the raw column: a hand-edited row holding
        // streaming on with the proxy off streams nothing, and the app should
        // not have to re-derive that.
        result.transcriptStreamingEnabled = config.transcriptStreamingEffective
        // One actor hop for all three, so a port and a version cannot come
        // from either side of a proxy replacement. With no supervisor wired
        // they keep their initializer defaults — false, nil, nil — which is the
        // honest answer for a daemon that cannot route a session, and what
        // Settings greys the toggle out on.
        let proxy = await modelProxySupervisor?.capabilitySnapshot()
            ?? ModelProxyCapabilitySnapshot.none
        result.modelProxySupported = proxy.supported
        result.modelProxyPort = proxy.port
        result.modelProxyVersion = proxy.version
        // Assigned rather than passed, for the same budget reason as the
        // model-proxy fields above: the load-balancing soak gate.
        result.profileBalancingEnabled = config.profileBalancingEnabled
        result.prPollScheduleEnabled = config.prPollScheduleEnabled
        result.profileBalancingUsageCeilingPercent = config.profileBalancingUsageCeilingPercent
        result.profileBalancingMaxReadingAgeSeconds = config.profileBalancingMaxReadingAgeSeconds
        result.remoteTranscriptLiveSyncEnabled = config.remoteTranscriptLiveSyncEnabled
        return try RPCResponse(result: result)
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
    /// The periodic driver owns the clock, and it owns it alone — `PRPoller`,
    /// or `PRPollScheduler` when `pr_poll_schedule_enabled` is set, never both
    /// (`PRPollDriver`). That is not tidiness:
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
        let discovery = try await runDiscoveryLeg(worktrees, forceBranchMatch: false)
        // A bindings-only row still counts as polled: its bound PRs refresh by
        // number. The `gh` directory falls back to a bindings-only row's so a
        // pass where no row was branch-matched never runs `gh` in the daemon's
        // own cwd.
        await refreshBindingStatuses(
            polled: discovery.infos, bindingsOnly: discovery.bindingsOnlyIDs,
            repoPath: discovery.infos.first?.worktreePath ?? discovery.bindingsOnlyFirstPath)
        await pruneAfterPass(infos: discovery.infos,
                             activeIDs: Set(discovery.infos.map(\.id)).union(discovery.bindingsOnlyIDs))
    }

    // MARK: - PR poll schedule

    /// How often a scheduled pass prunes the branch-facts cache against the
    /// whole fleet. See `lastFullPrune`.
    static let scheduledFullPruneInterval: TimeInterval = 3600

    /// The facts the PR schedule is rebuilt from on every wake: each pollable
    /// active row, whether it is active, whether it has a branch discovery can
    /// match on, and its live bindings with their stored states.
    ///
    /// Activity comes from the hook-fed session rows and the ledger's
    /// in-memory stamps only — never from terminal text. The ledger is pruned
    /// to the live terminals and rows here, so stamps for sessions and rows
    /// that left the fleet do not accumulate.
    ///
    /// A DB read failure answers nil, and the scheduler keeps the schedule it
    /// has: answering `[]` would drop every item, and the next good read would
    /// rebuild the whole fleet as due at once.
    func pollScheduleFacts() async -> [PRPollWorktreeFacts]? {
        do {
            let worktrees = Self.pollableWorktrees(try await db.worktrees.list(status: .active))
            let bindings = try await db.prBindings.listAll().filter { !$0.detached }
            let terminals = try await db.terminals.list()
            let repos = try await db.repos.list()
            let mirrorMeta = Self.mirrorMetaByOrigin((try? await db.remoteSessions.list()) ?? [])
            let repoPathByID = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0.path) })
            let defaultBranchByRepo = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0.defaultBranch) })
            let bindingsByWorktree = Dictionary(grouping: bindings, by: \.worktreeID)
            let terminalsByWorktree = Dictionary(grouping: terminals, by: \.worktreeID)
            await activityLedger.retain(terminalIDs: Set(terminals.map(\.id)),
                                        worktreeIDs: Set(worktrees.map(\.id)))
            let stamps = await activityLedger.snapshot()
            let current = now()
            return worktrees.map { wt in
                let active = WorktreeActivity.isActive(
                    sessions: WorktreeActivity.facts(from: terminalsByWorktree[wt.id] ?? []),
                    lastHookAt: stamps.hooks, lastSelectedAt: stamps.selections[wt.id], now: current)
                let discoverable = Self.hasPollableBranch(
                    wt, repoPathByID: repoPathByID, mirrorMeta: mirrorMeta,
                    defaultBranchByRepo: defaultBranchByRepo)
                let facts = (bindingsByWorktree[wt.id] ?? []).map {
                    PRPollBindingFact(key: PRPollKey($0), state: $0.status?.state)
                }
                return PRPollWorktreeFacts(worktreeID: wt.id, active: active,
                                           discoverable: discoverable, bindings: facts)
            }
        } catch {
            // `.private`, as in `PRPoller.tick`: a GRDB error carries its SQL.
            routerLogger.warning("PR schedule facts unreadable, schedule kept as it was: \(error, privacy: .private)")
            return nil
        }
    }

    /// One scheduled pass: discover the due branches, refresh the due PRs by
    /// number, and settle what that implies — the scheduler's counterpart to
    /// `runPollPass`, built from the same legs.
    ///
    /// Never throws: a DB enumeration failure costs this pass, logged as
    /// `PRPoller.tick` logs it, and the scheduler marks the items as run so a
    /// failing read does not turn into a tight retry loop.
    func runScheduledPass(_ due: PRPollDue) async {
        // Taken before anything is asked, so "observed by this pass" can be
        // told apart from a cached value left by an earlier one.
        let passStartedAt = now()
        do {
            try await runScheduledPassLegs(due, passStartedAt: passStartedAt)
        } catch {
            routerLogger.warning("scheduled PR pass skipped: \(error, privacy: .private)")
        }
    }

    private func runScheduledPassLegs(_ due: PRPollDue, passStartedAt: Date) async throws {
        // Open the pass before anything can observe a merge, as `runPollPass`
        // does and for the same reason.
        await mergeTrigger?.beginPollPass()
        let worktrees = Self.pollableWorktrees(try await db.worktrees.list(status: .active))
        var track = due.track

        if !due.discover.isEmpty {
            let discovered = worktrees.filter { due.discover.contains($0.id) }
            // Every branch goes through the branch query, even a row with a
            // stored PR number: a closed PR's branch is in discovery to learn
            // whether that PR reopened or a newer one replaced it, and only
            // the branch query answers with the newest PR for the branch.
            let discovery = try await runDiscoveryLeg(discovered, forceBranchMatch: true)
            // A PR this leg just bound is tracked in this same pass, inside the
            // `beginPollPass` window opened above. Discovery of an already-
            // merged PR with nothing bound fires the un-bound fallback from
            // `fetchAll`; judging the new binding here lets the trigger dedupe
            // that pass's two edges, as `runPollPass` does. Left to the next
            // wake, a new pass window would let `evaluate` fan out again.
            track.formUnion(discovery.newlyBound)
            track.formUnion(await reopenedClosedKeys(among: Set(discovered.map(\.id)),
                                                     observedSince: passStartedAt))
        }

        if !track.isEmpty {
            let live = try await db.prBindings.listAll()
            let owners = Set(live.filter { !$0.detached && track.contains(PRPollKey($0)) }.map(\.worktreeID))
            let mirrorMeta = Self.mirrorMetaByOrigin((try? await db.remoteSessions.list()) ?? [])
            let plan = await pollEntries(worktrees.filter { owners.contains($0.id) },
                                         repos: try await db.repos.list(), mirrorMeta: mirrorMeta)
            let trackStartedAt = now()
            let report = await refreshBindingStatuses(
                polled: plan.matched, bindingsOnly: Set(plan.bindingsOnly.map(\.id)),
                repoPath: plan.matched.first?.worktreePath ?? plan.bindingsOnly.first?.worktreePath,
                onlyKeys: track)
            // A tracked worktree never reaches `fetchAll`, which is where the
            // fixed poller keeps each worktree's observation and cached status
            // current. Record both here, so `pr.list` and the freshness label
            // stay as current as the bindings the pass just read. Stamped at
            // the start of this leg: a credential refusal `refreshBindings`
            // recorded during it is newer and stands.
            for (worktreeID, fresh) in report.dueFreshness {
                await prManager.recordBindingRefresh(
                    worktreeID: worktreeID,
                    status: fresh ? report.worstStatus[worktreeID] : nil,
                    outcome: fresh ? .observed : .undetermined(cause: PRUndeterminedCause.queryFailed),
                    at: trackStartedAt)
            }
        }

        // `activeIDs` is the whole pollable fleet, never the due subset: a row
        // that was not due this round still holds its PR facts.
        let activeIDs = Set(worktrees.map(\.id))
        let current = now()
        let pruneInterval = Self.scheduledFullPruneInterval
        let fullPruneDue = lastFullPrune.withLock { stamp in
            stamp.map { current.timeIntervalSince($0) >= pruneInterval } ?? true
        }
        if fullPruneDue {
            // The hourly full prune: compose every row's entry so the
            // branch-facts cache is retained against the whole fleet.
            let mirrorMeta = Self.mirrorMetaByOrigin((try? await db.remoteSessions.list()) ?? [])
            let plan = await pollEntries(worktrees, repos: try await db.repos.list(), mirrorMeta: mirrorMeta)
            await pruneAfterPass(infos: plan.matched, activeIDs: activeIDs)
            lastFullPrune.withLock { $0 = current }
        } else {
            // `pruneAfterPass` with this pass's partial entries would retain
            // the branch-facts cache against the due rows alone and evict
            // every row that was not due, so between full prunes only the PR
            // facts are pruned.
            await prManager.retain(active: activeIDs)
        }
    }

    /// The keys of closed bindings whose PR discovery just found open again.
    ///
    /// Only a status THIS pass observed counts: a cached entry stamped before
    /// `observedSince` is an earlier pass's answer — possibly days old — and
    /// acting on it would re-query the closed PR by number every closed-
    /// discovery round while its branch query keeps finding nothing.
    ///
    /// The branch query can answer with the same closed PR. `bind` then reports
    /// it already bound and leaves the binding's stored status at `.closed`, so
    /// on its own a reopened PR would stay on the closed-discovery tier
    /// forever. When the status discovery just cached for a row names one of
    /// that row's closed bindings and is not closed, that key is refreshed by
    /// number in this same pass; its binding row then holds the open status
    /// and the next reconcile tracks it on its proper tier. A different number
    /// is a new PR, which discovery's own `bind` handles; the same PR still
    /// closed changes nothing.
    private func reopenedClosedKeys(among worktreeIDs: Set<UUID>,
                                    observedSince: Date) async -> Set<PRPollKey> {
        guard let live = try? await db.prBindings.listAll() else { return [] }
        let statuses = await prManager.allStatuses()
        var keys: Set<PRPollKey> = []
        for binding in live where !binding.detached && worktreeIDs.contains(binding.worktreeID)
            && binding.status?.state == .closed {
            guard let cached = statuses[binding.worktreeID], cached.number == binding.number,
                  cached.state != .closed,
                  let observedAt = cached.observedAt, observedAt >= observedSince else { continue }
            keys.insert(PRPollKey(binding))
        }
        return keys
    }

    /// What one discovery leg composed and matched: the rows matched by branch
    /// (`infos`), and the rows polled for their bindings alone, with the first
    /// such row's working directory as a `gh` fallback.
    struct DiscoveryLegResult {
        let infos: [PRStatusManager.PollWorktree]
        let bindingsOnlyIDs: Set<UUID>
        let bindingsOnlyFirstPath: String?
        /// The keys of the bindings this leg created — branch matches and
        /// provenance seeds whose `bind` answered `.bound`. A key that was
        /// already bound is not here.
        var newlyBound: Set<PRPollKey> = []
    }

    /// The discovery half of a poll pass: compose each row's poll entry, ask
    /// the forge what PR each branch has, heal what that disproves, bind what
    /// it discovers, and seed each row's provenance binding.
    ///
    /// `forceBranchMatch` sends every entry to `fetchAll` without its stored
    /// PR number, so every branch goes through the branch query — which
    /// answers with the newest PR for the branch, the one a closed PR's
    /// successor would be. `runPollPass` passes false and behaves as it always
    /// has.
    func runDiscoveryLeg(_ worktrees: [Worktree], forceBranchMatch: Bool) async throws -> DiscoveryLegResult {
        // A remote row is matched on its session's LIVE branch (`meta.branch`
        // on the mirror's latest sighting), never on its stored branch. An
        // unreadable mirror is an empty map: every remote row is then
        // bindings-only for this pass, with no fallback to the stored branch.
        let mirrorMeta = Self.mirrorMetaByOrigin((try? await db.remoteSessions.list()) ?? [])
        let plan = await pollEntries(worktrees, repos: try await db.repos.list(), mirrorMeta: mirrorMeta)
        let infos = plan.matched
        let bindingsOnlyIDs = Set(plan.bindingsOnly.map(\.id))
        var fetchInput: [PRStatusManager.PollWorktree] = infos
        if forceBranchMatch {
            fetchInput = infos.map { entry -> PRStatusManager.PollWorktree in
                (id: entry.id, branch: entry.branch, upstreamBranch: entry.upstreamBranch,
                 defaultBranch: entry.defaultBranch, pushBranch: entry.pushBranch,
                 worktreePath: entry.worktreePath, prNumber: nil)
            }
        }
        let poll = await prManager.fetchAll(worktrees: fetchInput)
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
        var newlyBound: Set<PRPollKey> = []
        for match in poll.discovered {
            if case .bound(let binding) = await prBindingCoordinator.bind(
                worktreeID: match.worktreeID, parsed: match.parsed, source: .branch) {
                newlyBound.insert(PRPollKey(binding))
            }
        }
        newlyBound.formUnion(await seedProvenanceBindings(worktrees))
        return DiscoveryLegResult(infos: infos, bindingsOnlyIDs: bindingsOnlyIDs,
                                  bindingsOnlyFirstPath: plan.bindingsOnly.first?.worktreePath,
                                  newlyBound: newlyBound)
    }

    /// The end of a poll pass: drop what the fleet no longer holds.
    ///
    /// `activeIDs` is every row still in the fleet — a scheduler passes the
    /// full pollable set here, never the subset that was due, or a row merely
    /// not due this round would lose its facts.
    func pruneAfterPass(infos: [PRStatusManager.PollWorktree], activeIDs: Set<UUID>) async {
        // Prune at the END so we never drop an entry this pass just populated,
        // and **unconditionally** — including when the enumeration came back
        // empty, which is the pass that has the most to prune.
        await branchTrackingCache.retain(active: infos.map { (worktreePath: $0.worktreePath, branch: $0.branch) })
        // Same contract, same reason, for the PR facts themselves: the outcome
        // of an attempt on a worktree that has left the fleet is not a fact
        // anyone can act on, and every `pr.list` payload would carry it. A
        // bindings-only row is still in the fleet.
        await prManager.retain(active: activeIDs)
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
    ///
    /// Answers the keys of the bindings it created.
    private func seedProvenanceBindings(_ worktrees: [Worktree]) async -> Set<PRPollKey> {
        var seeded: Set<PRPollKey> = []
        for worktree in worktrees {
            guard let number = worktree.prNumber else { continue }
            guard let recorded = try? await db.prBindings.list(worktreeID: worktree.id,
                                                               includeDetached: true),
                  !recorded.contains(where: { $0.number == number }) else { continue }
            guard let parsed = await prRef(worktreeID: worktree.id, number: number) else {
                continue
            }
            if case .bound(let binding) = await prBindingCoordinator.seedProvenance(
                worktreeID: worktree.id, parsed: parsed) {
                seeded.insert(PRPollKey(binding))
            }
        }
        return seeded
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
    ///
    /// `bindingsOnly` names the polled rows that had no branch to match on this
    /// pass (a remote row without a valid live branch). Their bindings refresh
    /// like any other; with no poll entry, the merge rule judges them against
    /// no branch candidates, so its ownership arm fails closed for that pass.
    ///
    /// `onlyKeys` narrows what is *asked*, never what is *judged*. Nil asks
    /// about every binding, as a full poll pass does. A set asks about only
    /// the bindings whose `PRPollKey` it holds, and asks once per key: one
    /// representative binding goes to the forge and its fresh observation is
    /// fanned out to every binding sharing that key. Every other binding folds
    /// onto no observation and so keeps its stored status, but still takes
    /// part in the worst-status write and the merge rule, which need the whole
    /// worktree.
    ///
    /// The returned report is what the scheduled pass records at worktree
    /// level (`DueBindingRefreshReport`); a full pass ignores it.
    @discardableResult
    func refreshBindingStatuses(
        polled entries: [PRStatusManager.PollWorktree], bindingsOnly: Set<UUID>, repoPath: String?,
        onlyKeys: Set<PRPollKey>? = nil
    ) async -> DueBindingRefreshReport {
        var report = DueBindingRefreshReport()
        let polled = Set(entries.map(\.id)).union(bindingsOnly)
        guard let live = try? await db.prBindings.listAll() else { return report }
        let bindings = live.filter { polled.contains($0.worktreeID) }
        // Report the whole polled population before the early return, not just
        // the part with bindings. `evaluate` below only ever sees worktrees that
        // HAVE live bindings, so a worktree whose last binding was detached
        // could never re-arm itself — and a subsequent `tbd pr attach` would be
        // judged against a fired-guard that still held it.
        await mergeTrigger?.retainBound(
            polled: polled, bound: Set(bindings.map(\.worktreeID)))
        guard !bindings.isEmpty else { return report }

        let observations: [UUID: PRStatusManager.PRBindingObservation]
        if let onlyKeys {
            let due = await refreshDueBindings(bindings, onlyKeys: onlyKeys, repoPath: repoPath)
            observations = due.observations
            // A worktree's attempt resolved only if every due key it owns
            // came back fresh.
            for binding in bindings where onlyKeys.contains(PRPollKey(binding)) {
                let fresh = due.freshKeys.contains(PRPollKey(binding))
                report.dueFreshness[binding.worktreeID] =
                    (report.dueFreshness[binding.worktreeID] ?? true) && fresh
            }
        } else {
            observations = await prManager.refreshBindings(bindings, repoPath: repoPath)
        }
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
            report.worstStatus[update.worktreeID] = update.status
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
        //
        // The worktree's own repository travels too, but is resolved only for a
        // group holding a merged `.provider` binding — the one source the rule
        // checks it for (a provider may name a companion repository's PR, whose
        // branch name or number can coincide with the lane's). The resolver is
        // the same one the coordinator's own-repo check uses, behind the same
        // TTL cache, so a pass with no merged provider PR pays nothing for it.
        if let mergeTrigger {
            let entryByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            for (worktreeID, group) in Dictionary(grouping: refreshed, by: \.worktreeID) {
                let entry = entryByID[worktreeID]
                let needsOwnRepo = group.contains {
                    !$0.detached && $0.source == .provider && $0.status?.state == .merged
                }
                var ownRepo: (owner: String, name: String, host: String)?
                if needsOwnRepo { ownRepo = await prBindingRepoResolver(worktreeID) }
                await mergeTrigger.evaluate(
                    worktreeID: worktreeID, bindings: group,
                    branchCandidates: entry.map { PRStatusManager.candidatesFor($0) } ?? [],
                    provenancePRNumber: entry?.prNumber,
                    ownRepo: ownRepo)
            }
        }
        return report
    }

    /// What a narrowed binding refresh learned, per worktree, for the
    /// scheduled pass to record at worktree level.
    struct DueBindingRefreshReport {
        /// Every worktree owning at least one due key, and whether every due
        /// key it owns was freshly observed. Empty for an un-narrowed refresh.
        var dueFreshness: [UUID: Bool] = [:]
        /// The worst-of status per worktree, as written to its `prStatus`
        /// column. Never `.merged` (`worktreePRStatusUpdates`).
        var worstStatus: [UUID: PRStatus] = [:]
    }

    /// The due half of a narrowed refresh: query one representative binding per
    /// due key, and give its observation to every binding with that key. A
    /// binding whose key is not due is absent from the result. `freshKeys`
    /// names the due keys whose representative was freshly observed.
    ///
    /// Only a FRESH observation is fanned out. `refreshBindings` also answers
    /// with fallbacks meaning "keep what is stored" — no data from `gh`, a
    /// number that did not resolve, a failed check query — and each of those
    /// carries the representative's own stored status. Handed to a sibling it
    /// would overwrite the sibling's stored status with the representative's,
    /// so the sibling gets no entry instead and folds onto itself. The
    /// representative keeps its own entry either way, exactly as an un-narrowed
    /// refresh would give it.
    private func refreshDueBindings(
        _ bindings: [PRBinding], onlyKeys: Set<PRPollKey>, repoPath: String?
    ) async -> (observations: [UUID: PRStatusManager.PRBindingObservation], freshKeys: Set<PRPollKey>) {
        let due = bindings.filter { onlyKeys.contains(PRPollKey($0)) }
        var representatives: [PRBinding] = []
        var representative: [PRPollKey: PRBinding] = [:]
        for binding in due where representative[PRPollKey(binding)] == nil {
            representative[PRPollKey(binding)] = binding
            representatives.append(binding)
        }
        // Representatives go in bind order, not dictionary order, so the
        // query's alias sequence is deterministic.
        let raw = await prManager.refreshBindings(representatives, repoPath: repoPath)
        var freshKeys: Set<PRPollKey> = []
        for rep in representatives {
            if let observed = raw[rep.id], Self.isFreshObservation(observed, of: rep) {
                freshKeys.insert(PRPollKey(rep))
            }
        }
        var observations: [UUID: PRStatusManager.PRBindingObservation] = [:]
        for binding in due {
            guard let rep = representative[PRPollKey(binding)], let observed = raw[rep.id] else {
                continue
            }
            if binding.id == rep.id || freshKeys.contains(PRPollKey(rep)) {
                observations[binding.id] = observed
            }
        }
        return (observations, freshKeys)
    }

    /// Whether `refreshBindings` actually read this binding's PR this round,
    /// rather than carrying its stored status forward.
    ///
    /// Every fresh observation is stamped with a new `observedAt`, and every
    /// fallback path returns the binding's stored status untouched — never
    /// re-stamped (see `PRStatusManager.refreshBindingGroup` and its GitLab
    /// twin). So full `==` against the stored status, `observedAt` included,
    /// is the discriminator; `sameValue(as:)`, which ignores the stamp, would
    /// call an unchanged fresh reading a fallback. A binding never observed
    /// before has no stored status, so anything returned for it is fresh.
    static func isFreshObservation(
        _ observed: PRStatusManager.PRBindingObservation, of binding: PRBinding
    ) -> Bool {
        observed.status != binding.status
    }

    /// Test seam: one binding refresh over every pollable row, as a full pass
    /// composes it, narrowed by `onlyKeys`. Skips discovery and pruning, so a
    /// test sees exactly what the refresh leg asks and writes.
    func refreshBindingStatusesForTests(onlyKeys: Set<PRPollKey>?) async {
        guard let rows = try? await db.worktrees.list(status: .active),
              let repos = try? await db.repos.list() else { return }
        let mirrorMeta = Self.mirrorMetaByOrigin((try? await db.remoteSessions.list()) ?? [])
        let plan = await pollEntries(Self.pollableWorktrees(rows), repos: repos, mirrorMeta: mirrorMeta)
        await refreshBindingStatuses(
            polled: plan.matched, bindingsOnly: Set(plan.bindingsOnly.map(\.id)),
            repoPath: plan.matched.first?.worktreePath ?? plan.bindingsOnly.first?.worktreePath,
            onlyKeys: onlyKeys)
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
    ///
    /// The branch each entry is matched on comes from `pollBranch`: a local row's
    /// stored branch, and a remote row's LIVE branch from `mirrorMeta` (keyed by
    /// the row's provider and session). A remote row with no valid live branch,
    /// or whose live branch is its repo's default branch, is not matched by
    /// branch at all; it lands in `bindingsOnly`, so its bindings still refresh.
    func pollEntries(
        _ worktrees: [Worktree], repos: [Repo], mirrorMeta: [WorktreeOrigin: [String: String]]
    ) async -> PollPlan {
        let defaultBranchByRepo = Dictionary(
            uniqueKeysWithValues: repos.map { ($0.id, $0.defaultBranch) })
        let pathByRepo = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0.path) })
        var plan = PollPlan()
        plan.matched.reserveCapacity(worktrees.count)
        for wt in worktrees {
            // A remote row whose repo is gone resolves to nil and is simply not
            // polled — there is no directory to run `git` or `gh` in.
            guard let target = Self.pollTarget(
                for: wt, repoPathByID: pathByRepo, mirrorMeta: mirrorMeta,
                defaultBranchByRepo: defaultBranchByRepo) else {
                continue
            }
            let workingDirectory = target.workingDirectory
            switch target.choice {
            case .bindingsOnly:
                plan.bindingsOnly.append((id: wt.id, worktreePath: workingDirectory))
            case .match(let branch):
                let (upstreamBranch, pushBranch) = await branchFacts(
                    worktreePath: workingDirectory, branch: branch)
                plan.matched.append((
                    id: wt.id,
                    branch: branch,
                    upstreamBranch: upstreamBranch,
                    defaultBranch: wt.repoID.flatMap { defaultBranchByRepo[$0] },
                    pushBranch: pushBranch,
                    worktreePath: workingDirectory,
                    prNumber: wt.prNumber
                ))
            }
        }
        return plan
    }

    /// Where a row's poll runs and which branch it is matched on, or nil when
    /// the row has no working directory and is skipped. The one place a row's
    /// poll working directory is chosen, shared by `pollEntries` and
    /// `hasPollableBranch` so the two cannot drift.
    static func pollTarget(
        for wt: Worktree, repoPathByID: [UUID: String],
        mirrorMeta: [WorktreeOrigin: [String: String]], defaultBranchByRepo: [UUID: String]
    ) -> (workingDirectory: String, choice: PollBranchChoice)? {
        guard let workingDirectory = pollWorkingDirectory(wt, repoPathByID: repoPathByID) else {
            return nil
        }
        let choice = pollBranch(for: wt,
                                mirrorMeta: mirrorOrigin(of: wt).flatMap { mirrorMeta[$0] },
                                defaultBranch: wt.repoID.flatMap { defaultBranchByRepo[$0] })
        return (workingDirectory, choice)
    }

    /// Whether a row is matched by branch on a pass: it has a working
    /// directory AND a branch to match on. A row that fails either is never
    /// sent to discovery — it is skipped, or refreshed for its bindings only.
    static func hasPollableBranch(
        _ wt: Worktree, repoPathByID: [UUID: String],
        mirrorMeta: [WorktreeOrigin: [String: String]], defaultBranchByRepo: [UUID: String]
    ) -> Bool {
        guard let target = pollTarget(for: wt, repoPathByID: repoPathByID, mirrorMeta: mirrorMeta,
                                      defaultBranchByRepo: defaultBranchByRepo),
              case .match = target.choice else { return false }
        return true
    }

    /// Which branch a row is matched on this pass.
    enum PollBranchChoice: Equatable {
        case match(String)
        /// No branch to match on: refresh the row's bindings only.
        case bindingsOnly
    }

    /// One poll pass's composed input: the rows matched by branch, and the rows
    /// that are polled for their bindings alone.
    struct PollPlan {
        var matched: [PRStatusManager.PollWorktree] = []
        var bindingsOnly: [(id: UUID, worktreePath: String)] = []
    }

    /// Which branch a row is matched on. A remote row reads the LATEST
    /// sighting's `meta.branch`: its stored branch is identity, frozen at
    /// adoption and usually the creation branch, so it is never used for a
    /// lookup and there is no fallback to it. A landed lane is `.local` (its
    /// retained origin notwithstanding) and keeps its stored branch.
    ///
    /// A remote row whose live branch is the repo's default branch is not
    /// matched by branch either: a session that has not pushed a branch of its
    /// own yet reports `main`, and every PR whose head is `main` — a fork's,
    /// typically — is somebody else's work. `defaultBranch` is the repo
    /// record's stored value (`Repo.defaultBranch`), read with the rows rather
    /// than asked of the forge each poll; nil (repo unknown) compares equal to
    /// nothing. Local rows are unaffected.
    static func pollBranch(for worktree: Worktree, mirrorMeta: [String: String]?,
                           defaultBranch: String?) -> PollBranchChoice {
        switch worktree.location {
        case .local:
            return .match(worktree.branch)
        case .remote:
            guard let live = RemoteSessionPayload.metaLiveBranch(mirrorMeta) else { return .bindingsOnly }
            if let defaultBranch, live == defaultBranch { return .bindingsOnly }
            return .match(live)
        }
    }

    /// Each mirror row's `meta`, keyed by `(provider, sessionID)`. A `gone`
    /// row still counts: it is the last-known value, which the mirror keeps
    /// shown. A row whose payload does not decode, or carries no `meta`, is
    /// absent.
    static func mirrorMetaByOrigin(_ rows: [RemoteSessionRow]) -> [WorktreeOrigin: [String: String]] {
        var out: [WorktreeOrigin: [String: String]] = [:]
        for row in rows {
            guard let meta = row.decodedPayload?.meta else { continue }
            out[WorktreeOrigin(provider: row.provider, sessionID: row.sessionID)] = meta
        }
        return out
    }

    /// The mirror key a row's live branch is read under: its `.remote`
    /// location, never its retained `origin` (a landed lane is local).
    private static func mirrorOrigin(of worktree: Worktree) -> WorktreeOrigin? {
        guard case .remote(let provider, let sessionID) = worktree.location else { return nil }
        return WorktreeOrigin(provider: provider, sessionID: sessionID)
    }

    /// The directory a binding's repo identity (and forge) is resolved in —
    /// the same directory the row's poll runs in. A remote row has no checkout
    /// here, so it resolves in its repo's; that is sound for the same reason
    /// `pollWorkingDirectory` states: owner, name and host are repo facts,
    /// never worktree facts. Nil for an unknown row, or a remote row whose repo
    /// is gone.
    static func bindingRepoPath(worktreeID: UUID, db: TBDDatabase) async -> String? {
        guard let worktree = try? await db.worktrees.get(id: worktreeID) else { return nil }
        var repoPathByID: [UUID: String] = [:]
        if let repoID = worktree.repoID, let repo = try? await db.repos.get(id: repoID) {
            repoPathByID[repo.id] = repo.path
        }
        return pollWorkingDirectory(worktree, repoPathByID: repoPathByID)
    }

    private func handlePRRefresh(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PRRefreshParams.self, from: paramsData)

        // Run a targeted refresh for one row and try the tracked upstream branch
        // when needed. The working directory comes from `pollWorkingDirectory`,
        // exactly as the poll's does, so a remote row refreshes against its
        // repo's checkout and its live branch. A row with no working directory —
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
        // The app sends this on selection, so it is the PR schedule's
        // "the user is looking at this worktree" signal. Only a pollable row
        // is stamped: an unpolled one has no schedule item to make due.
        await activityLedger.recordSelection(worktreeID: wt.id, at: now())
        var repo: Repo?
        if let repoID = wt.repoID {
            repo = try await db.repos.get(id: repoID)
        }
        guard let workingDirectory = Self.pollWorkingDirectory(
            wt, repoPathByID: repo.map { [$0.id: $0.path] } ?? [:]) else {
            return try RPCResponse(result: PRRefreshResult(status: nil))
        }
        // The branch the poll matches this row on, chosen by the same rule: a
        // remote row's live branch from its mirror row, never its stored one.
        // A remote row with no valid live branch, or on its repo's default
        // branch, gets "no attempt", like a scratch row — its bindings still
        // refresh on the poll.
        var mirrorMeta: [String: String]?
        if case .remote(let provider, let sessionID) = wt.location {
            mirrorMeta = (try? await db.remoteSessions.row(provider: provider, sessionID: sessionID))?
                .decodedPayload?.meta
        }
        guard case .match(let branch) = Self.pollBranch(
            for: wt, mirrorMeta: mirrorMeta, defaultBranch: repo?.defaultBranch) else {
            return try RPCResponse(result: PRRefreshResult(status: nil, observation: nil))
        }
        // Read the branch facts through the SAME cache the poll uses. Reading
        // git directly here would let a user refresh attach a PR that the very
        // next poll — still inside the cache's TTL, still holding the older
        // facts — judges by a different candidate list and clears again.
        let (upstreamBranch, pushBranch) = await branchFacts(
            worktreePath: workingDirectory, branch: branch)

        let status = await prManager.refresh(
            worktreeID: wt.id,
            branch: branch,
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
        //
        // `.provider` reads as `manual` too: it is reachable only from a
        // provider snapshot, never from the wire, because it skips the
        // coordinator's repo validation — a socket client naming it would
        // bypass the wrong-repo guard.
        let source: PRBindingSource
        switch params.source.flatMap(PRBindingSource.init(rawValue:)) {
        case .some(.provider), .none:
            source = .manual
        case .some(let wireSource):
            source = wireSource
        }
        switch await prBindingCoordinator.bind(worktreeID: params.worktreeID,
                                               parsed: parsed, source: source) {
        case .bound(let binding):
            // Wake the PR schedule: its next reconcile sees the new binding,
            // never yet observed, and makes it due at once.
            await prPollScheduler.kick()
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
    ///
    /// **Attach also reads a whole URL exactly**, with the parser a provider's
    /// `meta.prs` goes through (`parsePRURL(exactly:)`), which accepts a GitHub
    /// pull request on any host. That is what lets `tbd pr attach <Enterprise
    /// URL>` revive a detached Enterprise PR, and bind one on an Enterprise
    /// checkout; the coordinator's own-repo and host check still decides every
    /// new binding. Detach reads a URL exactly only when this worktree already
    /// holds a row for that identity — an Enterprise chip's own binding — so
    /// every other detach keeps the scanner and its number fallthrough for
    /// synthetic chips exactly as before.
    private func resolvePRRef(_ params: PRBindingRefParams,
                              numberFallback: Bool = false) async -> PRRefResolution {
        if let url = params.url, !url.isEmpty {
            if let exact = PRBindingExtractor.parsePRURL(
                exactly: url.trimmingCharacters(in: .whitespacesAndNewlines)) {
                if !numberFallback { return .resolved(exact) }
                if await worktreeHoldsRow(worktreeID: params.worktreeID, for: exact) {
                    return .resolved(exact)
                }
            }
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

    /// Whether this worktree has a binding row, live or tombstoned, for the
    /// PR `parsed` names.
    private func worktreeHoldsRow(worktreeID: UUID, for parsed: ParsedPRURL) async -> Bool {
        let key = PRBinding(worktreeID: worktreeID, host: parsed.host, owner: parsed.owner,
                            repo: parsed.repo, number: parsed.number, url: parsed.url,
                            source: .manual).identityKey
        guard let rows = try? await db.prBindings.list(worktreeID: worktreeID, includeDetached: true)
        else { return false }
        return rows.contains { $0.identityKey == key }
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
    /// Nil is a third answer and not a soft "no". A worktree with no directory
    /// to ask in — an unknown or deleted row, or a remote row whose repo is
    /// gone (a remote row otherwise asks in its repo's checkout, see
    /// `bindingRepoPath`) — cannot supply one, so nothing has answered, and answering
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
