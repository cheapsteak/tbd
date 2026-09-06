import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "Hibernation")

public enum HibernateResult: Equatable, Sendable {
    case ok
    case alreadyHibernated
    case notEligible(reason: String)
    case notFound
}

/// Which rails a park attempt is judged by, and the config facts those rails
/// need. Every case carries `holderHibernationEnabled` because the park
/// mechanic for the pty-holder transport is behind a soak gate whatever
/// triggered it — the property the soak validates (a row never claims parked
/// while its child runs) does not depend on who asked.
enum HibernateEligibilityPolicy: Sendable {
    case manual(holderHibernationEnabled: Bool)
    case merge(inputVetoEnabled: Bool, holderHibernationEnabled: Bool)
    case automatic(
        enabled: Bool,
        inputVetoEnabled: Bool,
        holderHibernationEnabled: Bool,
        idleTimeout: TimeInterval,
        idleSince: Date?)
}

/// How an unparked terminal's pane disagreed with the row that claims it is
/// awake. Only states tmux gave a positive answer for appear here; "the probe
/// failed" is deliberately not a case, because it is not a disagreement.
public enum UnparkedPaneDisagreement: Equatable, Sendable {
    /// tmux cannot find the pane — it, its window, or the whole server is gone.
    case paneMissing
    /// The pane object survives (`remain-on-exit`) but its process has exited,
    /// so the row's "awake" refers to a shell, not a session.
    case processExited
    /// The pane is alive but answers with a DIFFERENT terminal's id: this row's
    /// coordinate went stale and now points at a stranger's pane after tmux
    /// reused the id (#384). Someone else's live pane is not evidence that this
    /// session is healthy.
    case paneBelongsToAnotherTerminal(actualTerminalID: String)
}

public enum WakeResult: Equatable, Sendable {
    case ok
    case notHibernated   // idempotent no-op: nothing to wake
    /// The row is NOT parked — TBD believes this terminal is awake — but its
    /// pane says otherwise, so there is no live session for an "already awake"
    /// answer to refer to. `detail` names which way it disagreed. Distinct from
    /// `.notHibernated` so a caller can tell a benign idempotent no-op from a
    /// terminal that needs recovery, and so a dropped `prompt` is reported
    /// rather than silently discarded. Nothing is respawned — see
    /// `classifyUnparkedWake` for why repair is a separate change.
    case sessionGone(paneID: String, detail: UnparkedPaneDisagreement)
    case notFound        // terminal/worktree DB row missing — NOT tmux failures
    case noSessionID
    case inFlight        // a wake for this terminal is already respawning
    /// The respawn (or window recreate) failed in tmux. The row stays parked
    /// so a later retry can wake it; `reason` names the real failure instead
    /// of the misleading "Terminal not found".
    case respawnFailed(reason: String)
    /// The worktree row exists but its directory is gone from disk — respawn
    /// would silently land in $HOME. Carries the missing path so callers can
    /// surface an actionable message instead of a generic "not found".
    case worktreeMissing(path: String)
    /// The terminal was pinned to a model profile whose row (or, for an
    /// .apiKey profile, its keychain secret) no longer resolves. Waking would
    /// silently fall back to the ambient keychain login and resume on the WRONG
    /// account. Refuse and surface this so the app can offer an explicit
    /// default-profile fallback; the row stays parked and resumable. Carries
    /// the missing profile id for the message.
    case profileMissing(profileID: UUID)
    /// The row runs on the pty-holder transport and
    /// `holder_hibernation_enabled` is off. The transport has a wake mechanic —
    /// spawn a fresh holder running `claude --resume` — and this soak gate says
    /// it may not run here yet, so wake refuses before touching anything and
    /// leaves the row exactly as it found it.
    case holderTransport
    /// The row is exit-stamped (`.exited`) and a process other than the pane's
    /// own shell owns the pane's foreground process group. Wake is
    /// `respawn-window -k`, which would kill it. Nothing was respawned and the
    /// row stays exit-stamped, so a retry once the process finishes still
    /// wakes. Carries the foreground pid so the message can name it.
    case paneBusy(pid: Int32)
}

/// Owns session PARKING — the single unified "park a Claude session" feature
/// (the former Suspend and Hibernate features merged into one). It gracefully
/// terminates a Claude process while KEEPING its tmux window alive (the shell
/// stays), and wakes it later by respawning `claude --resume <id>` in that same
/// window.
///
/// The park sequence combines the strengths of both predecessors:
///   1. Capture an ANSI pane snapshot FIRST (from the old Suspend feature) so
///      the app can show the frozen pane as a backdrop while parked / waking.
///   2. Enforce the live rails the DB row can't express (typed-but-unsent
///      input, transcript-tail validity) — from Hibernate.
///   3. Try a polite in-band `/exit` (from Suspend) so Claude flushes its
///      transcript, shuts down MCP children, and fires Stop hooks; poll up to
///      ~3s for the process to actually leave.
///   4. If `/exit` didn't take, fall back to a graceful interrupt
///      (Escape → C-c C-c → SIGTERM) — from Hibernate.
///   5. Either way, `respawn-window` the pane to a bare shell (Hibernate's
///      mechanic: the window/pane and its scrollback survive, freeing the
///      claude process + its RSS). We do NOT kill the window (Suspend's old
///      mechanic).
///   6. Verify the shell survived + log orphaned claude children.
///   7. Mark parked via `hibernatedAt` (the authoritative timestamp) and
///      persist the snapshot.
///
/// Wake `respawn-window`s the same pane back to `claude --resume`. It is the ONE
/// resume path for auto-parked, manually-parked, and (via reconcile) died
/// sessions; it clears BOTH `hibernatedAt` and any legacy `suspendedAt`.
///
/// The prompt cache expires after ~5 min idle, so a session past the TTL pays
/// full uncached input on its next message whether or not the process stayed
/// alive — parking an idle session is therefore nearly free.
public actor HibernationCoordinator {
    let db: TBDDatabase
    private let tmux: TmuxManager
    private let modelProfileResolver: ModelProfileResolver?
    private let subscriptions: StateSubscriptionManager?
    /// Routes ambient claude-projects-root resolution for the wake transcript
    /// sync — injectable (mirroring `RPCRouter.configDirManager`) so tests
    /// point it at a temp dir instead of falling back to the real `~/.claude`.
    private let configDirManager: ClaudeProfileConfigDirManager
    /// Default input activity tracker. Wired post-construction by Daemon.swift
    /// to the shared instance from the input router so both use the same tracker.
    var inputActivity: InputActivityTracker
    let now: @Sendable () -> Date

    /// Per-terminal "first time we observed it idle-at-rest" marker, maintained
    /// by `sweep`. In-memory only: a daemon restart clears it, so a freshly
    /// started daemon won't instantly hibernate long-idle sessions — it waits a
    /// full idle window first, which is the safe behavior.
    var idleSince: [UUID: Date] = [:]

    /// Terminal ids with an in-flight wake respawn, so a double-focus can't
    /// spawn two `claude --resume` processes into the same window.
    private var wakesInFlight: Set<UUID> = []

    /// Invoked after EVERY `ensureServer` on the wake-recreate path (whether or
    /// not a server was actually created — the downstream control-mode
    /// `enableIfGated` is idempotent, so firing on an existing server is a
    /// no-op). Daemon.swift wires this to the control-mode bridge so a freshly
    /// recreated server gets the same gated `tmux -CC` connection as every
    /// other `ensureServer()` call site.
    private var onServerCreated: (@Sendable (String) async -> Void)?

    /// Terminal ids with an in-flight hibernate, so a manual "Hibernate now"
    /// racing the idle sweep (or two sweeps) can't respawn-to-shell twice.
    private var hibernatesInFlight: Set<UUID> = []

    /// Debounce after a terminal first crosses the idle threshold: the sweep
    /// marks it `pendingKillSince`, and only actually hibernates on a LATER
    /// sweep once this settle window has also elapsed AND every rail still
    /// holds. State can flip in the final instant (a turn starts, a permission
    /// prompt appears), so the kill decision is re-verified here, not at
    /// arm-time. (Knative/KEDA poll-cheaply / decide-against-window pattern.)
    var pendingKillSince: [UUID: Date] = [:]

    /// Settle window between crossing the idle threshold and the actual kill.
    static let killDebounce: TimeInterval = 20

    /// Verify-exit poll after the polite in-band `/exit`: how many times we
    /// re-check the pane's current command, and how long we wait between checks.
    /// 15 × 200ms ≈ 3s — ported from the old Suspend feature. If claude is still
    /// the pane's program after the whole window, we fall back to SIGTERM.
    ///
    /// Injectable (defaulted init parameters) rather than `static let`, so a
    /// test can cross the exhaustion threshold in a handful of `TestClock`
    /// advances instead of paying ~3s of real wall time to prove one branch.
    /// Deliberately not `private`: the production defaults are pinned by a test.
    /// `nonisolated` because both are immutable and `Sendable`, so reading them
    /// needs no actor hop — without it a test's synchronous `#expect` against
    /// them fails to compile. Safe only while they stay `let`; a `var` here
    /// would have to drop `nonisolated` and every reader would need `await`.
    nonisolated let exitPollAttempts: Int
    nonisolated let exitPollInterval: Duration

    /// How many times the holder park re-checks its child after sending it
    /// `SIGTERM`, before escalating to the forced teardown.
    ///
    /// 25 at the production `exitPollInterval` of 200 ms is five seconds, and
    /// the number is sized against what a Claude session actually does with a
    /// `SIGTERM` it means to honour: run its Stop hooks, tear down its MCP
    /// children, and flush the transcript it is mid-write on. Three seconds of
    /// polite `/exit` has already passed by the time this rung is reached, so a
    /// session that is shutting down cleanly and slowly gets eight seconds in
    /// total before anything is killed — which is the whole reason this rung
    /// exists, since the alternative it replaced was a `SIGKILL` of the process
    /// group at three seconds. Injectable on the same terms as the pair above.
    nonisolated let holderTerminateAttempts: Int

    /// How many times the holder park re-checks its child AFTER escalating to
    /// `HolderRegistry.abandon` — which forgets the holder, kills the job by
    /// process group and reaps the corpse.
    ///
    /// Five at the production `exitPollInterval` of 200 ms is one second, and
    /// it is a different budget from the poll before it: that one waits for a
    /// session to shut itself down politely, this one waits for a `SIGKILL`ed
    /// process to leave the process table. Injectable on the same terms as the
    /// pair above, and for the same reason — a test proving the "the child
    /// survived everything" branch must not pay a real second to do it.
    nonisolated let holderEscalationAttempts: Int

    /// Delay seam for the verify-exit poll (`Duration` is behavior). Tests
    /// inject a `TestClock` so the poll's pacing is virtual and the
    /// "escalate after exactly N attempts" boundary is exact.
    let clock: any Clock<Duration>

    /// The pty-holder registry, wired post-construction by Daemon.swift the way
    /// `inputActivity` is — the registry is built before the RPC router that
    /// owns this coordinator, and both must reach the SAME actor: the park path
    /// reads a session's screen through the reader the spawn path registered.
    ///
    /// Nil in mock mode and in any composition with no holder transport, where
    /// the park path refuses by name rather than pretending it could have read
    /// a screen.
    var holderRegistry: HolderRegistry?

    /// Answers a holder-backed session's screen, for the park's pending-input
    /// rail to judge. A **test seam only** — production leaves it nil and
    /// `holderScreenReading` falls through to the registry's own reader, which
    /// is the single source the design names.
    ///
    /// It exists for the same reason the send path's `holderModeOracle` does:
    /// reaching the rail's answers (`daemon`, `staleDaemon`, a screen that will
    /// not project, and no screen at all) through a real registry means a real
    /// holder, a real pty and a real attach for what is a pure question about
    /// whether a park may proceed. The registry-backed path is exercised live;
    /// this is how the rail's own branches are pinned.
    ///
    /// `nil` from the seam means the same thing as no reader: nothing answered.
    /// A throw means the same thing as a refused projection.
    var holderScreenOracle: (@Sendable (UUID) async throws -> TerminalScreen?)?

    /// How the holder park observes and ends a child process. Injected so a
    /// test can state "the job declined `/exit`" in one line instead of
    /// arranging a real one.
    let signaller: any ProcessSignaller

    /// Reads a tmux pane's foreground process group from the process table.
    /// Used by exactly one rail — the exit-stamped wake guard — and injected
    /// so a test can state "the pane's shell is idle" or "something is running
    /// in it" without arranging a real process.
    private let paneProcessInspector: any PaneProcessInspecting

    /// The daemon's actuation record. The idle sweep and the merge-park rail
    /// are daemon-internal actuation sites — they bypass the router, so each
    /// logs its own row. Deliberately NOT logged inside `performHibernate`: the
    /// RPC handlers call that same method after writing their own row, and a
    /// row there would double-count every manual park.
    private let actuationLog: ActuationLog

    private var defaultShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    public init(
        db: TBDDatabase,
        tmux: TmuxManager,
        modelProfileResolver: ModelProfileResolver? = nil,
        subscriptions: StateSubscriptionManager? = nil,
        configDirManager: ClaudeProfileConfigDirManager = ClaudeProfileConfigDirManager(),
        now: @escaping @Sendable () -> Date = { Date() },
        exitPollAttempts: Int = 15,
        exitPollInterval: Duration = .milliseconds(200),
        holderTerminateAttempts: Int = 25,
        holderEscalationAttempts: Int = 5,
        clock: any Clock<Duration> = ContinuousClock(),
        signaller: any ProcessSignaller = ProductionProcessSignaller(),
        paneProcessInspector: any PaneProcessInspecting = ProductionPaneProcessInspector(),
        actuationLog: ActuationLog
    ) {
        self.db = db
        self.tmux = tmux
        self.modelProfileResolver = modelProfileResolver
        self.subscriptions = subscriptions
        self.configDirManager = configDirManager
        self.inputActivity = InputActivityTracker()
        self.now = now
        self.exitPollAttempts = exitPollAttempts
        self.exitPollInterval = exitPollInterval
        self.holderTerminateAttempts = holderTerminateAttempts
        self.holderEscalationAttempts = holderEscalationAttempts
        self.clock = clock
        self.signaller = signaller
        self.paneProcessInspector = paneProcessInspector
        self.actuationLog = actuationLog
    }

    /// Projects root for a wake spawn's resolved profile config dir path,
    /// falling back to the coordinator's (injectable) ambient claude dir.
    /// Mirrors `RPCRouter.claudeProjectsRoot(profileConfigDirPath:)`: unlike
    /// `TranscriptProjectDirSync.projectsRoot`, whose nil-profile fallback
    /// constructs a default manager (real `~/.claude`), this routes through
    /// `configDirManager` so tests isolate via the injection seam.
    private func claudeProjectsRoot(profileConfigDirPath: String?) -> URL {
        if let path = profileConfigDirPath, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
        }
        return configDirManager.ambientConfigDirectory
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// Wire the post-`ensureServer` hook (see `onServerCreated`). Set once by
    /// Daemon.swift right after construction, mirroring how the RPC router's
    /// `controlMode` is wired post-construction.
    public func setOnServerCreated(_ hook: (@Sendable (String) async -> Void)?) {
        onServerCreated = hook
    }

    /// Wire the input activity tracker so the sweep can veto parks based on
    /// pending typed input. Set once by Daemon.swift after construction so the
    /// shared tracker is used across the input router and coordinator.
    /// Wire the pty-holder registry. Set once by Daemon.swift after
    /// construction, for the same reason `setInputActivity` is: the registry
    /// exists before the router that owns this coordinator, and every consumer
    /// must share the one actor that holds the daemon's readers.
    func setHolderRegistry(_ registry: HolderRegistry?) {
        holderRegistry = registry
    }

    /// Wire the park rail's screen seam. Tests only — see `holderScreenOracle`.
    func setHolderScreenOracle(
        _ oracle: (@Sendable (UUID) async throws -> TerminalScreen?)?
    ) {
        holderScreenOracle = oracle
    }

    func setInputActivity(_ tracker: InputActivityTracker) {
        // Replace the default tracker with the shared one from the input router.
        // This is safe because nothing has accessed inputActivity yet at wiring time.
        self.inputActivity = tracker
    }

    // MARK: - Keep-warm

    public func setKeepWarm(terminalID: UUID, keepWarm: Bool) async -> Bool {
        guard let terminal = try? await db.terminals.get(id: terminalID) else { return false }
        try? await db.terminals.setKeepWarm(id: terminalID, keepWarm: keepWarm)
        // Carry the row's persisted snapshot/reason: on a parked row this
        // re-broadcast has hibernated == true, and the app's in-place apply
        // would otherwise wipe both from its cached row.
        broadcastHibernation(
            terminal: terminal, hibernated: terminal.isHibernated, keepWarm: keepWarm,
            suspendedSnapshot: terminal.isHibernated ? terminal.suspendedSnapshot : nil,
            hibernateReason: terminal.isHibernated ? terminal.hibernateReason : nil)
        return true
    }

    // MARK: - Hibernate

    /// Manual "Hibernate now". Honors the running / permission-prompt rails but
    /// not keep-warm or idle-time (the user asked explicitly).
    public func manualHibernate(terminalID: UUID) async -> HibernateResult {
        guard let terminal = try? await db.terminals.get(id: terminalID) else {
            return .notFound
        }
        guard terminal.hibernatedAt == nil else { return .alreadyHibernated }
        // One read, carried into the policy so the rail re-checked under the
        // lock cannot disagree with the one checked here. A config read that
        // fails takes the shipped default, which refuses a holder row.
        let holderHibernationEnabled = await resolvedHolderHibernationEnabled()
        guard terminal.isManuallyHibernatable(
            holderHibernationEnabled: holderHibernationEnabled) else {
            return .notEligible(reason: manualBlockReason(
                terminal, holderHibernationEnabled: holderHibernationEnabled))
        }
        return await performHibernate(
            terminal: terminal,
            reason: .manual,
            policy: .manual(holderHibernationEnabled: holderHibernationEnabled))
    }

    /// `config.holderHibernationEnabled`, resolved through the shipped default
    /// when the config row cannot be read. Failing toward the default is
    /// failing toward refusal, which is the safe direction for a mechanic that
    /// kills a live process.
    private func resolvedHolderHibernationEnabled() async -> Bool {
        (try? await db.config.get())?.holderHibernationEnabled
            ?? Config.holderHibernationEnabledDefault
    }

    /// The reason a manual hibernate was refused, for the RPC error string.
    private func manualBlockReason(
        _ terminal: Terminal, holderHibernationEnabled: Bool
    ) -> String {
        if terminal.transport == .holder, !holderHibernationEnabled {
            return Self.holderTransportRefusal
        }
        if !terminal.isClaudeResumable { return "Not a resumable Claude session" }
        if terminal.suspendedAt != nil { return "Terminal is suspended" }
        switch terminal.activityState {
        case .working: return "Session is actively running"
        case .waitingForUser: return "Session is waiting on a permission prompt"
        default: return "Not hibernatable"
        }
    }

    /// Park a session because its worktree's PR merged. Honors every safety rail
    /// (including keep-warm, unlike `manualHibernate`, and the pending-input
    /// veto, exactly as the sweep does) but NOT the idle window or the
    /// idle-sweep master switch — see `HibernationGate.decideForMerge`.
    ///
    /// `inputVetoEnabled` is `config.hibernateInputVetoEnabled`, passed in by
    /// the caller rather than re-read here: `AutoHibernateOnMergeCoordinator`
    /// already loaded the config snapshot that armed the fan-out, and arming
    /// the veto from that same snapshot keeps the two decisions consistent and
    /// adds no config read that could fail open per terminal.
    ///
    /// A daemon-internal rail: no RPC carried this, so it writes its own row
    /// with no `method` and the rail-named actor. `AutoHibernateOnMergeCoordinator`
    /// fans out over every terminal in the worktree and most are refused by the
    /// rails above, so — like the idle sweep — the row goes after the gate, at
    /// the moment this rail is actually about to act on a session.
    ///
    /// `holderHibernationEnabled` is not defaulted, for the reason
    /// `Terminal.isManuallyHibernatable(holderHibernationEnabled:)` gives: the
    /// flag reaches several call sites across the daemon and the app, and a
    /// missing argument should be a compile error rather than a rail that
    /// quietly disagrees with the menu the user is looking at. A default that
    /// leaned on "forgetting refuses, which is safe" would invert the day the
    /// shipped constant flips, which is this flag's whole graduation plan.
    public func hibernateForMerge(
        terminalID: UUID,
        inputVetoEnabled: Bool,
        holderHibernationEnabled: Bool
    ) async -> HibernateResult {
        guard let terminal = try? await db.terminals.get(id: terminalID) else {
            return .notFound
        }
        guard terminal.hibernatedAt == nil else { return .alreadyHibernated }
        let decision = HibernationGate.decideForMerge(
            terminal: terminal,
            inputVetoEnabled: inputVetoEnabled,
            holderHibernationEnabled: holderHibernationEnabled,
            lastInputAt: inputActivity.lastInput(
                paneID: InputActivityTracker.key(for: terminal)))
        guard decision == .eligible else {
            return .notEligible(reason: Self.mergeBlockReason(decision))
        }

        // Fail-closed, as everywhere else: an unrecordable park does not
        // happen. The writer already logged the failure at `.fault`; carrying
        // its self-explaining text out as the refusal reason puts it in the
        // caller's log too.
        var row = ActuationRow(
            actor: .daemon(rail: ActuationRail.autoHibernateOnMerge), kind: .hibernate)
        row.target = .local(worktree: terminal.worktreeID, terminal: terminal.id)
        let actuationID: String
        do {
            actuationID = try await actuationLog.appendRequest(row)
        } catch {
            return .notEligible(reason: "\(error)")
        }

        let result = await performHibernate(
            terminal: terminal,
            reason: .merged,
            policy: .merge(
                inputVetoEnabled: inputVetoEnabled,
                holderHibernationEnabled: holderHibernationEnabled))
        await actuationLog.appendOutcome(
            confirms: actuationID,
            result: ActuationOutcome.classify(result),
            error: ActuationOutcome.detail(result))
        return result
    }

    /// The reason a merge-park was refused, for logging/telemetry. Mirrors
    /// `manualBlockReason` but maps every `blockingRail` case — including
    /// keep-warm, which merge-park honors but manual bypasses — plus the
    /// pending-input veto, whose wording matches the backup TUI scrape's so a
    /// reader cannot tell which of the two rails fired and does not need to.
    /// The one refusal text every gated path uses for a holder-backed row, so
    /// the CLI, the app and the actuation record all name the same reason. What
    /// the flag gates is a new park and the classification of an UNPARKED
    /// holder row; a row that is already parked wakes without consulting it.
    static let holderTransportRefusal =
        "Session runs on the pty-holder transport and holder hibernation is off "
        + "(Settings → Hibernate pty-holder sessions, or `tbd config "
        + "holder-hibernation on`)"

    /// The one refusal text for an exit-stamped row whose pane is busy, so the
    /// CLI, the app and the actuation record all name the same fact and the
    /// same two ways out. Named here rather than at each call site for the same
    /// reason `holderTransportRefusal` is.
    static func paneBusyRefusal(pid: Int32) -> String {
        "This session's agent process exited, but something is still running in its terminal "
        + "(pid \(pid)), and waking would replace that shell and kill it. Finish or stop that "
        + "process and retry, or wake the session from the terminal itself."
    }

    private static func mergeBlockReason(_ decision: HibernationGate.Decision) -> String {
        switch decision {
        case .holderTransport: return holderTransportRefusal
        case .notClaudeResumable: return "Not a resumable Claude session"
        case .alreadyHibernated: return "Terminal is already hibernated"
        case .suspended: return "Terminal is suspended"
        case .keepWarm: return "Terminal is pinned keep-warm"
        case .running: return "Session is actively running"
        case .waitingForUser: return "Session is waiting on a permission prompt"
        case .pendingTypedInput: return "Terminal has unsent typed input"
        case .eligible, .featureDisabled, .notIdleLongEnough: return "Not hibernatable"
        }
    }

    /// Gracefully terminate the pane's Claude and swap the pane to a bare shell
    /// via `respawn-window` (window + tab survive). Marks the row hibernated.
    ///
    /// Singleflighted per-terminal, and re-verifies the live pane/disk rails
    /// (typed-but-unsent input, transcript-tail validity) that the DB row can't
    /// express. After the kill it verifies the claude process is gone and the
    /// pane's shell survived, and logs any orphaned claude children.
    ///
    /// `reason` records WHO parked the session (`.manual` from the explicit
    /// "Hibernate now" entry points, `.auto` from the idle sweep) — persisted
    /// so the app's wake-on-focus can skip manual parks.
    private func performHibernate(
        terminal: Terminal,
        reason: HibernateReason,
        policy: HibernateEligibilityPolicy
    ) async -> HibernateResult {
        guard !hibernatesInFlight.contains(terminal.id) else {
            return .alreadyHibernated
        }
        hibernatesInFlight.insert(terminal.id)
        defer { hibernatesInFlight.remove(terminal.id) }

        guard terminal.claudeSessionID != nil else {
            return .notEligible(reason: "No session id to resume later")
        }
        guard let worktree = try? await db.worktrees.getLocal(id: terminal.worktreeID) else {
            return .notFound
        }
        // The two transports diverge here, ahead of the first tmux call. A
        // holder-backed row has no tmux server to lock and no pane to capture:
        // its park writes to the holder's pty, confirms the child is gone, and
        // clears the row's pids. Everything above this line — the singleflight
        // claim, the session-id and worktree lookups — is shared, and
        // everything below it is the tmux mechanic, unchanged.
        if terminal.transport == .holder {
            return await performHolderHibernate(
                terminal: terminal, worktree: worktree, reason: reason, policy: policy)
        }

        let server = worktree.tmuxServer
        let paneID = terminal.tmuxPaneID

        // Fast pre-lock rail: refuse obvious typed input before queueing for a
        // server replacement. The authoritative capture and the snapshot that
        // is persisted happen after the lock is acquired, because this pane
        // can change while the operation waits.
        if let capture = try? await tmux.capturePaneWithAnsi(server: server, paneID: paneID) {
            // Rail: typed-but-unsent input. Chrome's single biggest tab-discard
            // backlash was lost typed text — never park a pane with a
            // half-composed prompt.
            if HibernationSafetyChecks.hasPendingInput(paneCapture: capture) {
                logger.debug("hibernate: skipping \(terminal.id, privacy: .public) — pending typed input in prompt")
                return .notEligible(reason: "Terminal has unsent typed input")
            }
        }

        // Rail: transcript-tail validity. Killing mid-write can leave an
        // unresumable jsonl (#18880). Only park when the last line is
        // complete JSON. Missing/empty transcript is allowed (nothing to
        // corrupt); the resume will just find no prior turns.
        if let transcriptPath = terminal.transcriptPath,
           let body = try? String(contentsOfFile: transcriptPath, encoding: .utf8),
           !HibernationSafetyChecks.isTranscriptTailValid(jsonlBody: body) {
            logger.warning("hibernate: skipping \(terminal.id, privacy: .public) — transcript tail not parseable, would be unresumable")
            return .notEligible(reason: "Transcript is mid-write; try again shortly")
        }

        do {
            return try await tmux.withWorktreeServerLock(
                db: db,
                worktreeID: worktree.id,
                allowedStatuses: [worktree.status]
            ) { currentWorktree in
                await self.performHibernateReplacementLocked(
                    terminal: terminal,
                    worktree: currentWorktree,
                    reason: reason,
                    policy: policy)
            }
        } catch {
            logger.warning("hibernate: failed to lock the current tmux server for \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return .notFound
        }
    }

    /// Runs only while the worktree tmux server resource lock is held. Every
    /// in-place process replacement on that server participates in the same
    /// lock, while the two database transitions additionally CAS the captured
    /// process incarnation so a request that waited cannot act on stale state.
    private func performHibernateReplacementLocked(
        terminal: Terminal,
        worktree: LocalWorktree,
        reason: HibernateReason,
        policy: HibernateEligibilityPolicy
    ) async -> HibernateResult {
        guard let currentTerminal = try? await db.terminals.get(id: terminal.id) else {
            return .notFound
        }
        guard TerminalReplacementSnapshot(terminal: terminal).matches(currentTerminal) else {
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return .notEligible(reason: "Terminal process changed before hibernation")
        }
        if case .automatic = policy,
           !TerminalHibernationSnapshot(terminal: terminal).matchesActivity(currentTerminal) {
            // A full turn may start and finish while an automatic park waits
            // for this server lock. The fresh row can be idle again, but its
            // old idle timer no longer proves a full quiet window. Refuse this
            // attempt and let the next sweep seed a new idle generation.
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return .notEligible(reason: "Session activity changed before hibernation")
        }
        guard let sessionID = currentTerminal.claudeSessionID else {
            return .notEligible(reason: "No session id to resume later")
        }
        if let refusal = hibernationRefusal(terminal: currentTerminal, policy: policy) {
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return refusal
        }

        let server = worktree.tmuxServer
        let paneID = currentTerminal.tmuxPaneID
        let windowID = currentTerminal.tmuxWindowID

        guard await tmux.windowExists(server: server, windowID: windowID) else {
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return .notEligible(reason: "Terminal window is no longer live")
        }
        if tmux.verifiesPaneCurrentCommand {
            guard let command = try? await tmux.paneCurrentCommand(server: server, paneID: paneID),
                  ClaudeStateDetector.isClaudeProcess(command) else {
                idleSince[terminal.id] = nil
                pendingKillSince[terminal.id] = nil
                return .notEligible(reason: "Terminal session is no longer live")
            }
        }

        // The checks above the server lock are only a fast refusal. This fresh
        // capture and transcript read are authoritative: a queued hibernation
        // must not act on input or transcript state observed before another
        // replacement or hook had its turn under the same server lock.
        let capturedSnapshot: String?
        if let capture = try? await tmux.capturePaneWithAnsi(server: server, paneID: paneID) {
            if HibernationSafetyChecks.hasPendingInput(paneCapture: capture) {
                logger.debug("hibernate: skipping \(terminal.id, privacy: .public) — pending typed input in prompt")
                return .notEligible(reason: "Terminal has unsent typed input")
            }
            capturedSnapshot = capture.isEmpty ? nil : capture
        } else {
            capturedSnapshot = nil
        }

        if let transcriptPath = currentTerminal.transcriptPath,
           let body = try? String(contentsOfFile: transcriptPath, encoding: .utf8),
           !HibernationSafetyChecks.isTranscriptTailValid(jsonlBody: body) {
            logger.warning("hibernate: skipping \(terminal.id, privacy: .public) — transcript tail not parseable, would be unresumable")
            return .notEligible(reason: "Transcript is mid-write; try again shortly")
        }

        // Persist the park intent before touching the live process, without
        // rotating its token. A crash or failure before tmux replaces Claude
        // can therefore be reconciled by unparking the surviving process, whose
        // hooks still match the row.
        let expectedState = TerminalHibernationSnapshot(terminal: currentTerminal)
        let inertIncarnation: TerminalSessionIncarnation
        do {
            guard let prepared = try await db.terminals.beginHibernatedShellRespawn(
                id: terminal.id,
                expectedState: expectedState,
                snapshot: capturedSnapshot,
                reason: reason,
                at: now()) else {
                idleSince[terminal.id] = nil
                pendingKillSince[terminal.id] = nil
                return .notEligible(reason: "Terminal process changed before hibernation")
            }
            inertIncarnation = prepared
        } catch {
            logger.warning("hibernate: failed to prepare parked state for \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return .notEligible(reason: "Failed to persist hibernation")
        }

        // Polite park: try an in-band `/exit` first (ported from Suspend) so
        // Claude flushes its transcript, shuts down MCP children, and fires Stop
        // hooks, then poll up to ~3s for the process to actually leave. Only if
        // it's still a claude process after the poll window do we escalate to
        // the graceful-interrupt SIGTERM fallback. Either way, `respawn-window
        // -k` below guarantees termination.
        let exited = await politeExitThenPoll(
            server: server, paneID: paneID, terminalID: terminal.id)
        if !exited {
            logger.debug("hibernate: /exit did not terminate \(terminal.id, privacy: .public) within poll window — falling back to graceful interrupt")
            await gracefullyInterruptPane(server: server, paneID: paneID)
        }

        let baseEnvironment = [
            "TBD_WORKTREE_ID": worktree.id.uuidString,
            "TBD_TERMINAL_ID": terminal.id.uuidString,
        ]

        // First replace Claude with a controlled process that cannot emit agent
        // hooks. Only after this succeeds is it safe to rotate the durable
        // token and clear process-local lifecycle evidence.
        do {
            try await tmux.respawnWindow(
                server: server,
                windowID: windowID,
                cwd: worktree.path,
                shellCommand: "exec /usr/bin/tail -f /dev/null",
                env: baseEnvironment
            )
        } catch {
            logger.warning("hibernate: respawn-to-inert failed for terminal \(terminal.id, privacy: .public) window \(windowID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .notEligible(reason: "Failed to replace agent")
        }

        let shellIncarnationID: UUID
        do {
            guard let finalized = try await db.terminals.finalizeHibernatedShellRespawn(
                id: terminal.id,
                expectedIncarnation: inertIncarnation,
                at: now()) else {
                idleSince[terminal.id] = nil
                pendingKillSince[terminal.id] = nil
                return .notEligible(reason: "Terminal process changed during hibernation")
            }
            shellIncarnationID = finalized
        } catch {
            logger.warning("hibernate: failed to fence replaced agent for \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return .notEligible(reason: "Failed to finalize hibernation")
        }
        let shellEnvironment = AgentProcessEnvironment.replacement(
            base: baseEnvironment,
            incarnationID: shellIncarnationID)

        // Replace the inert process with the user-facing login shell carrying
        // the exact token persisted by the finalization transaction. A failure
        // leaves the inert pane parked and rejects hooks from the old agent.
        do {
            try await tmux.respawnWindow(
                server: server,
                windowID: windowID,
                cwd: worktree.path,
                shellCommand: defaultShell,
                env: shellEnvironment
            )
        } catch {
            logger.warning("hibernate: respawn-to-shell failed for terminal \(terminal.id, privacy: .public) window \(windowID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .notEligible(reason: "Failed to respawn shell")
        }

        // Post-kill verification: the pane must now be running a shell, not
        // claude. Any leftover orphaned descendants are logged but not killed.
        await verifyHibernationTookEffect(
            server: server, paneID: paneID, terminalID: terminal.id)
        // The pane id may be reused later; do not carry an old input veto into
        // the replacement process.
        inputActivity.forget(paneID: paneID)

        guard let persisted = try? await db.terminals.get(id: terminal.id),
              persisted.sessionIncarnationID == shellIncarnationID else {
            logger.warning("hibernate: prepared row disappeared or changed during shell launch for \(terminal.id, privacy: .public)")
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return .notEligible(reason: "Failed to verify hibernation")
        }
        idleSince[terminal.id] = nil
        pendingKillSince[terminal.id] = nil
        // The app materializes its parked view on this flip, so carry the
        // snapshot and reason rather than waiting for a later row refresh.
        broadcastHibernation(
            terminal: currentTerminal, hibernated: true, keepWarm: currentTerminal.keepWarm,
            suspendedSnapshot: capturedSnapshot, hibernateReason: reason)
        logger.info("hibernated terminal \(terminal.id, privacy: .public) (session \(sessionID, privacy: .public))")
        return .ok
    }

    func hibernationRefusal(
        terminal: Terminal,
        policy: HibernateEligibilityPolicy
    ) -> HibernateResult? {
        switch policy {
        case let .manual(holderHibernationEnabled):
            guard terminal.hibernatedAt == nil else { return .alreadyHibernated }
            guard terminal.isManuallyHibernatable(
                holderHibernationEnabled: holderHibernationEnabled) else {
                return .notEligible(reason: manualBlockReason(
                    terminal, holderHibernationEnabled: holderHibernationEnabled))
            }
            return nil

        case let .merge(inputVetoEnabled, holderHibernationEnabled):
            let decision = HibernationGate.decideForMerge(
                terminal: terminal,
                inputVetoEnabled: inputVetoEnabled,
                holderHibernationEnabled: holderHibernationEnabled,
                lastInputAt: inputActivity.lastInput(
                    paneID: InputActivityTracker.key(for: terminal)))
            guard decision == .eligible else {
                return .notEligible(reason: Self.mergeBlockReason(decision))
            }
            return nil

        case let .automatic(
            enabled, inputVetoEnabled, holderHibernationEnabled, idleTimeout, idleSince):
            let decision = HibernationGate.decide(
                terminal: terminal,
                autoHibernateEnabled: enabled,
                inputVetoEnabled: inputVetoEnabled,
                holderHibernationEnabled: holderHibernationEnabled,
                idleTimeout: idleTimeout,
                idleSince: idleSince,
                lastInputAt: inputActivity.lastInput(
                    paneID: InputActivityTracker.key(for: terminal)),
                now: now())
            guard decision == .eligible else {
                return .notEligible(reason: Self.mergeBlockReason(decision))
            }
            return nil
        }
    }

    /// Confirm the respawn-to-shell actually replaced claude, and log any
    /// orphaned claude children left behind. Best-effort, log-only.
    private func verifyHibernationTookEffect(server: String, paneID: String, terminalID: UUID) async {
        if let cmd = try? await tmux.paneCurrentCommand(server: server, paneID: paneID),
           ClaudeStateDetector.isClaudeProcess(cmd) {
            logger.warning("hibernate: pane for terminal \(terminalID, privacy: .public) still shows claude after respawn (\(cmd, privacy: .public))")
        }
        // Detect orphaned claude descendants (children reparented to launchd
        // after the parent died) so they're observable via `log stream`.
        if let orphans = await Self.detectOrphanedClaudeProcesses(), !orphans.isEmpty {
            logger.warning("hibernate: \(orphans.count, privacy: .public) orphaned claude-descendant process(es) survived hibernation of terminal \(terminalID, privacy: .public): PIDs \(orphans.map(String.init).joined(separator: ","), privacy: .public)")
        }
    }

    /// Enumerate claude processes now parented to PID 1 (launchd) — a rough
    /// signal of orphaned children left by a killed claude. Log-only in v1.
    ///
    /// Runs through the shared bounded runner (`TmuxManager.runExternalCommand`)
    /// which drains stdout concurrently with the child. The naive
    /// `waitUntilExit()`-then-read shape deadlocked forever once `ps -Ao`
    /// output exceeded the 64KB kernel pipe buffer (~900+ processes), hanging
    /// every hibernation. This is a best-effort diagnostic: any failure —
    /// including timeout — returns nil and must never block hibernation.
    ///
    /// Package-internal + parameterized so tests can substitute a fake `ps`
    /// that deterministically emits more than 64KB.
    static func detectOrphanedClaudeProcesses(
        psExecutable: String = "/bin/ps",
        arguments: [String] = ["-Ao", "pid=,ppid=,comm="],
        timeout: Duration = .seconds(5)
    ) async -> [Int]? {
        guard let out = try? await TmuxManager.runExternalCommand(
            executable: psExecutable,
            arguments: arguments,
            label: "ps",
            timeout: timeout
        ) else { return nil }
        var orphans: [Int] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int(parts[0]), let ppid = Int(parts[1]) else { continue }
            let comm = parts[2...].joined(separator: " ")
            if ppid == 1 && comm.contains("claude") { orphans.append(pid) }
        }
        return orphans
    }

    // MARK: - Wake

    /// Answer a wake aimed at a row TBD believes is already awake.
    ///
    /// The previous answer was an unconditional `.notHibernated` — "already
    /// awake, nothing to do" — read straight off the DB parked flags. That is
    /// a claim about a live tmux session made without ever looking at tmux,
    /// and on a fleet it is often false: a window dies (server restart,
    /// `kill-window`, a crash) without anything clearing the row. Measured on
    /// a live fleet, 34 of 49 rows the DB called awake had no pane. The caller
    /// then got neither a wake nor an error, and any `initialPrompt` was
    /// silently dropped.
    ///
    /// So ask — using the SAME probe `terminal.send` asks with
    /// (`TmuxManager.paneSendTarget`), rather than adding a second liveness
    /// primitive that would drift from it. That probe already answers both
    /// halves of the question: is a process there, and is the pane still ours.
    ///
    /// Only a POSITIVE disagreement downgrades the answer, exactly as on the
    /// send path. A probe that merely threw keeps the benign historical no-op:
    /// a failed tmux call proves nothing, and tmux calls fail spuriously
    /// precisely when the machine is loaded enough for the session to be alive.
    /// A pane carrying no identity at all is likewise left alone.
    ///
    /// This reports; it deliberately does NOT repair. Respawning an unparked
    /// row would make tmux authoritative over the parked flag, and then one
    /// false-negative probe destroys a live session's in-flight work.
    /// Auto-recovery needs a human design decision and is tracked in #586, not
    /// decided here. Recovery today stays the parked-row path below and the
    /// explicit `terminal.recreateWindow` RPC.
    private func classifyUnparkedWake(_ terminal: Terminal) async -> WakeResult {
        // No worktree row means no server name to probe with, so nothing can be
        // proven and the benign historical answer stands.
        //
        // The parked path returns `.notFound` for this same condition, and the
        // asymmetry is deliberate rather than an oversight. There, the missing
        // worktree blocks an action the caller asked for, so it has to be
        // reported. Here it blocks only a *diagnosis*: the caller asked to wake
        // something the row already calls awake, and failing to look it up is
        // not evidence that the session is dead. Reporting `.notFound` would
        // turn "I couldn't check" into "your terminal is gone" — the same
        // conflation this whole change exists to remove. Practically
        // unreachable either way: `terminal.worktreeID` is a cascading foreign
        // key, so a terminal row outliving its worktree does not happen.
        guard let worktree = try? await db.worktrees.getLocal(id: terminal.worktreeID) else {
            return .notHibernated
        }
        let target: PaneSendTarget
        do {
            target = try await tmux.paneSendTarget(
                server: worktree.tmuxServer, paneID: terminal.tmuxPaneID)
        } catch {
            // Couldn't ask. Fail closed to the benign answer.
            return .notHibernated
        }

        let disagreement: UnparkedPaneDisagreement
        switch target {
        case .live(let paneTerminalID):
            // No identity to compare, or it agrees — the historical no-op.
            guard let paneTerminalID,
                  paneTerminalID.caseInsensitiveCompare(terminal.id.uuidString) != .orderedSame
            else { return .notHibernated }
            disagreement = .paneBelongsToAnotherTerminal(actualTerminalID: paneTerminalID)
        case .missing:
            disagreement = .paneMissing
        case .dead:
            disagreement = .processExited
        }

        logger.warning("""
            wake: terminal \(terminal.id, privacy: .public) is unparked but its pane \
            \(terminal.tmuxPaneID, privacy: .public) on server \
            \(worktree.tmuxServer, privacy: .public) disagrees \
            (\(String(describing: disagreement), privacy: .public)) — reporting sessionGone \
            instead of "already awake"
            """)
        return .sessionGone(paneID: terminal.tmuxPaneID, detail: disagreement)
    }

    /// Respawn `claude --resume <sessionID>` in the hibernated terminal's
    /// kept-alive window. Idempotent: a non-hibernated terminal is a no-op, and
    /// concurrent wakes for the same terminal collapse to one respawn.
    ///
    /// For a PARKED row whose window is GONE (killed, or the whole tmux server
    /// died — e.g. a machine reboot), the window is recreated (ensureServer +
    /// createWindow) and the same resume command spawned there; the terminal
    /// row keeps its identity and gets the new window/pane ids persisted.
    ///
    /// That recovery covers parked rows ONLY, because it lives downstream of
    /// the parked check below. An UNPARKED row whose session died is reported
    /// (`.sessionGone`) but not repaired — see `classifyUnparkedWake`.
    ///
    /// **An already-parked holder row wakes whatever `holder_hibernation_enabled`
    /// says.** The flag gates new parks and the classification of an UNPARKED
    /// holder row; it does not gate the wake of a row the feature has already
    /// parked. Turning the flag off is the soak's abort gesture, and an abort
    /// that stranded everything the soak parked would be no abort at all — the
    /// app's focus-wake would fire a failing RPC on every focus, forever, with
    /// no way back to a live session.
    public func wake(terminalID: UUID, cols: Int? = nil, rows: Int? = nil, allowDefaultProfileFallback: Bool = false, initialPrompt: String? = nil) async -> WakeResult {
        // Claim synchronously, before the first suspension. Otherwise two wake
        // calls can both read the parked row, then each pass the in-flight check
        // after actor reentrancy lets them interleave. Keep the claim across all
        // early exits so the defer releases lookup failures and successful wakes
        // alike.
        // `performHibernate` is actor-reentrant while it waits for polite exit
        // and tmux. Once its durable begin transition marks this row parked, a
        // wake must not rotate/clear the row and let hibernation resume against
        // the replacement process.
        guard !hibernatesInFlight.contains(terminalID) else { return .inFlight }
        guard !wakesInFlight.contains(terminalID) else { return .inFlight }
        wakesInFlight.insert(terminalID)
        defer { wakesInFlight.remove(terminalID) }

        guard let terminal = try? await db.terminals.get(id: terminalID) else {
            return .notFound
        }
        // Wake ANY parked row, not just `hibernatedAt`-marked ones: legacy rows
        // and the reconcile / recreate-window paths may carry only `suspendedAt`.
        // `clearHibernated` nils both columns, so this fully un-parks either.
        //
        // The unparked answer is per-transport: `classifyUnparkedWake` probes a
        // tmux pane, and a holder row's pane id is the empty string, which tmux
        // answers for by reporting the pane gone — a live session reported as
        // `.sessionGone`. The holder classification asks the process table
        // instead.
        guard terminal.isParked else {
            guard terminal.transport == .holder else {
                return await classifyUnparkedWake(terminal)
            }
            // The soak gate belongs HERE and not above the parked check: it
            // decides whether this install classifies an unparked holder row
            // at all, and an install that has not armed the feature is told so
            // rather than being handed a process-table verdict it never asked
            // for. Nothing is mutated on the way out.
            guard await resolvedHolderHibernationEnabled() else { return .holderTransport }
            return await classifyUnparkedHolderWake(terminal)
        }
        guard let sessionID = terminal.claudeSessionID else { return .noSessionID }
        let expectedReplacementState = TerminalReplacementSnapshot(terminal: terminal)
        guard let worktree = try? await db.worktrees.getLocal(id: terminal.worktreeID) else {
            return .notFound
        }
        // Never respawn into a missing directory: tmux's `-c` silently falls
        // back to $HOME, and the resumed claude would neither find its session
        // (resume is cwd-scoped) nor belong to this worktree. Leave the row
        // parked so a retry after the path is restored can still wake it.
        guard FileManager.default.fileExists(atPath: worktree.path) else {
            logger.error("wake: worktree path missing on disk for terminal \(terminal.id, privacy: .public): \(worktree.path, privacy: .public) — refusing respawn (would fall back to $HOME)")
            return .worktreeMissing(path: worktree.path)
        }
        let server = worktree.tmuxServer
        let paneID = terminal.tmuxPaneID

        // ─── An exit-stamped row whose pane is busy is not ours to replace ───
        //
        // `.exited` parks the row while the pane's SHELL stays alive and usable
        // — that is the whole point of the stamp — and wake is
        // `respawn-window -k`, which kills whatever occupies the pane. For every
        // other park reason that costs nothing: hibernate put an inert shell
        // there itself. For an exit stamp the pane is the one the person was
        // sitting in when the agent left, and they may have started something in
        // it since.
        //
        // The app-side exclusion — `.exited` is not auto-woken on focus or tab
        // activation — is the first line and stays the first line. It is not the
        // only line, because it lives in the app: `docs/updating.md`'s
        // `--no-app` makes "daemon newer than app" a supported skew, and an app
        // binary older than this change reads `.exited` through the lenient
        // `HibernateReason` decoder as `.auto` and auto-wakes it. So the daemon
        // defends the respawn itself, and it does so for every caller — an old
        // app, the CLI, the composer — rather than trusting who asked.
        //
        // Asked of the process table, never the rendered screen. The pane's own
        // pid answering means an idle interactive shell and the wake proceeds
        // exactly as before; a different pid means something is running under
        // it. An unreadable pid proceeds too: a pane tmux cannot answer for is
        // not evidence that a process is there, and refusing on it would strand
        // an exit-stamped row behind a probe failure with no way back.
        //
        // tmux-only, for the same reason the cwd assertion below is: a holder
        // row's pane id is the empty string and names no tmux coordinate.
        if terminal.isExitStamped, terminal.transport != .holder,
           let panePIDString = try? await tmux.panePID(server: server, paneID: paneID),
           let panePID = Int32(panePIDString), panePID > 0,
           let foregroundPID = paneProcessInspector.paneForegroundPID(panePID: panePID),
           foregroundPID != panePID {
            logger.info("wake: exit-stamped terminal \(terminal.id, privacy: .public) has foreground pid \(foregroundPID, privacy: .public) in pane \(paneID, privacy: .public) (pane pid \(panePID, privacy: .public)) — refusing the respawn rather than killing it")
            return .paneBusy(pid: foregroundPID)
        }

        // Assert that the process about to be resumed will run in THIS
        // worktree. Not a lookup concern: `claude --resume <id>` is not
        // cwd-scoped — measured on claude 2.1.261, a resume from another
        // directory succeeds and appends to the original project directory's
        // JSONL. What the check is for is belonging: a session resumed outside
        // its worktree would edit the wrong tree while writing to the right
        // transcript, which is the harder failure to notice. The respawn `-c`s
        // into the worktree path regardless, so this only reports.
        //
        // tmux-only, and the guard is not decoration: a holder row's pane id is
        // the empty string, so this would ask a tmux server — starting one, on
        // a worktree whose sessions deliberately have none — about a
        // coordinate that names nothing.
        if terminal.transport != .holder,
           let paneCwd = try? await tmux.paneCurrentPath(server: server, paneID: paneID),
           paneCwd != worktree.path {
            logger.warning("wake: pane cwd \(paneCwd, privacy: .public) != worktree path \(worktree.path, privacy: .public) for terminal \(terminal.id, privacy: .public); respawn will -c into the worktree path")
        }

        // Honor the exact profile persisted on the terminal (loadByID, not
        // re-resolve) so wake lands on the same account the session used.
        //
        // Pre-wake profile check: if the pinned profile no longer resolves (row
        // deleted, or an .apiKey profile whose keychain secret is gone), the OLD
        // behavior silently fell back to the ambient keychain login — resuming on
        // the WRONG account, which reads to the user as "the session won't wake".
        // Refuse and surface `.profileMissing` so the app can offer an explicit
        // default-profile fallback (mirrors how `.worktreeMissing` fails loudly
        // just above rather than resuming into $HOME). This is BEFORE the tmux
        // mutation section, so a refusal never disturbs the pane. Pass
        // `allowDefaultProfileFallback` to opt back into the ambient-login resume.
        var resolvedProfile: ResolvedModelProfile? = nil
        if let profileID = terminal.profileID, let resolver = modelProfileResolver {
            resolvedProfile = try? await resolver.loadByID(profileID)
            if resolvedProfile == nil {
                if allowDefaultProfileFallback {
                    logger.warning("wake: profile \(profileID, privacy: .public) missing for terminal \(terminal.id, privacy: .public); explicit default-profile fallback → ambient keychain login")
                } else {
                    logger.error("wake: profile \(profileID, privacy: .public) no longer resolves for terminal \(terminal.id, privacy: .public); refusing wake — retry with the default-profile fallback to resume on the default account")
                    return .profileMissing(profileID: profileID)
                }
            }
        }

        let config = try? await db.config.get()
        let claudeEnvOverrides = config?.envSettingOverrides ?? [:]
        let repo: Repo?
        if let rid = worktree.repoID {
            repo = try? await db.repos.get(id: rid)
        } else {
            repo = nil
        }
        let mergedEnvOverrides = EnvOverrideResolver.merge(
            global: config?.envOverrides,
            repo: repo?.envOverrides,
            profile: resolvedProfile?.envOverrides
        )
        let profileConfigDir = configDirManager.resolveConfigDir(for: resolvedProfile)
        let overlayPath = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: resolvedProfile?.fallbackModels,
            sessionKey: terminal.id.uuidString,
            // Repo fragment is file-backed config, read fresh — reapplied on wake.
            repoSettingsJSON: ClaudeHookOverlay.repoSettingsFragment(repoID: repo?.id),
            // A wake reuses the SAME terminal row and therefore the same
            // statusline capture path, so a desk woken without the tee would
            // otherwise keep reading a capture whose mtime predates the resume.
            //
            // The row's own `watch_desk_role` is what this site reads, and it
            // is durable in the direction that matters: the desk spawn path
            // stamps it at create, so a desk is recognizable here from its first
            // instant and without a lease ever having existed. It is **not**
            // durable in every direction — `WatchDeskLeaseStore.release` and
            // `.revoke` NULL the column for the whole worktree, and a
            // hibernated desk is exactly the state that makes
            // `DeskSessionManager` revoke (its pane no longer runs an agent, so
            // the lease owner reads as gone). Such a desk wakes without a tee
            // and reports its window as unknown until a lease is reacquired.
            //
            // Demoting instead of NULLing would not fix that: `setRoles` brands
            // every terminal in the worktree, so a surviving role would install
            // the tee — which outranks the operator's own statusline in every
            // scope they can write — in ordinary sessions that merely happen to
            // sit in a desk's worktree. Reporting no denominator is the right
            // side to be wrong on, and it is only safe because the staleness is
            // closed independently: `ClaudeHookOverlay.resolveOverlayPath`
            // deletes the session's capture whenever it resolves an overlay
            // WITHOUT a tee, so a session that is not (re)installing one cannot
            // read a capture from a previous life. An ordinary terminal has nil
            // here and gets a byte-identical overlay.
            watchDeskRole: terminal.watchDeskRole,
            worktreePath: worktree.path,
            // The same config dir the resume below runs with, so the tee
            // delegates to the user-scope statusline THIS session reads.
            profileConfigDir: profileConfigDir
        )
        // Pre-accept Claude's folder-trust dialog so a wake onto a fresh
        // isolated profile dir (never seeded before) doesn't re-prompt — the
        // dialog blocks before SessionStart, so the stalled wake would be
        // machine-invisible. Cheap no-op once already trusted. `config` is a
        // `try?` read; fall back to the shipped default.
        await ClaudeTrustSeeder.ensureTrusted(
            worktree: worktree.worktree,
            autoTrustNonScratch: config?.autoTrustWorktrees ?? true,
            profileConfigDir: profileConfigDir)
        // Pre-resume freshness: if the worktree was moved/promoted while this
        // session was parked, its transcript still lives under the OLD munged
        // project dir; the cwd-scoped `claude --resume` below only checks the
        // dir derived from the CURRENT path. Mirror the jsonl (+ subagents)
        // there first — copy-if-newer, best-effort, never rewrites the row's
        // transcriptPath. Detached variant: the recursive copy must not run on
        // this actor's serial executor; the await still completes before the
        // respawn below.
        await TranscriptProjectDirSync.ensureSessionResumableDetached(
            sessionID: sessionID,
            worktreePath: worktree.path,
            projectsRoot: claudeProjectsRoot(profileConfigDirPath: profileConfigDir),
            storedTranscriptPath: terminal.transcriptPath
        )
        let spawn = ClaudeSpawnCommandBuilder.build(
            resumeID: sessionID,
            freshSessionID: nil,
            appendSystemPrompt: nil,
            // Delivered as a trailing argv to `claude --resume` — atomic with
            // the respawn, so it reaches ONLY a session this call actually
            // woke (an already-awake terminal returns .notHibernated above
            // and the prompt is never delivered anywhere).
            initialPrompt: initialPrompt,
            profileSecret: resolvedProfile?.secret,
            profileKind: resolvedProfile?.kind,
            profileBaseURL: resolvedProfile?.baseURL,
            profileModel: resolvedProfile?.model,
            profileAwsRegion: resolvedProfile?.awsRegion,
            profileAwsProfile: resolvedProfile?.awsProfile,
            profileConfigDir: profileConfigDir,
            cmd: nil,
            shellFallback: defaultShell,
            settingsOverlayPath: overlayPath,
            pluginDirPath: PluginDirWriter.pluginDirPath,
            envSettingOverrides: claudeEnvOverrides,
            sessionName: worktree.displayName
        )
        // Inject TBD_WORKTREE_ID + TBD_TERMINAL_ID so notifications and the
        // SessionStart hook attribute to this terminal after the resume rollover.
        let env: [String: String] = [
            "TBD_WORKTREE_ID": worktree.id.uuidString,
            "TBD_TERMINAL_ID": terminal.id.uuidString,
        ]
        let sensitiveEnv = mergedEnvOverrides.merging(spawn.sensitiveEnv) { _, builder in builder }

        // The transports diverge again, and for the last time. Everything above
        // — profile, env, overlay, trust seed, transcript sync, the resume
        // argv with its queued prompt — is shared verbatim, because it decides
        // WHAT to resume and that is transport-independent. Below is the tmux
        // mechanic.
        if terminal.transport == .holder {
            return await wakeHolderSection(
                terminal: terminal,
                worktree: worktree,
                sessionID: sessionID,
                expectedReplacementState: expectedReplacementState,
                spawnCommand: spawn.command,
                env: env,
                sensitiveEnv: sensitiveEnv,
                cols: cols,
                rows: rows)
        }

        // The window/pane the rest of wake must reference: the original ones
        // when the window survived, or the recreated window's fresh ones.
        let livePaneID: String
        let liveWindowID: String
        let liveServer: String
        let liveIncarnationID: UUID

        // The whole decide-then-mutate tmux section (ownership check +
        // windowExists + respawn/create/kill/persist) runs under the
        // per-server lock: `wakesInFlight` above only dedupes wakes for the
        // SAME terminal, while this closes the cross-terminal TOCTOU on a
        // shared server (see `TmuxManager.withWorktreeServerLock`). The lock
        // is NOT held around the delayed session-recapture Task below.
        let outcome: WakeTmuxOutcome
        do {
            outcome = try await tmux.withWorktreeServerLock(
                db: db, worktreeID: worktree.id, allowedStatuses: [worktree.status]
            ) { currentWorktree in
                guard let currentTerminal = try await self.db.terminals.get(
                    id: terminal.id),
                      expectedReplacementState.matches(currentTerminal) else {
                    return .failed(.respawnFailed(
                        reason: "terminal changed while wake was preparing; retry"))
                }
                return await self.wakeTmuxSection(
                    terminal: currentTerminal,
                    worktree: currentWorktree.worktree,
                    server: currentWorktree.tmuxServer,
                    windowID: currentTerminal.tmuxWindowID,
                    paneID: currentTerminal.tmuxPaneID,
                    spawnCommand: spawn.command,
                    env: env,
                    sensitiveEnv: sensitiveEnv,
                    cols: cols,
                    rows: rows
                )
            }
        } catch {
            return .notFound
        }
        switch outcome {
        case .failed(let result):
            return result
        case .respawned(
            let newPaneID,
            let newWindowID,
            let currentServer,
            let incarnationID
        ):
            livePaneID = newPaneID
            liveWindowID = newWindowID
            liveServer = currentServer
            liveIncarnationID = incarnationID
        }
        idleSince[terminal.id] = nil
        // Carry the LIVE window/pane ids on the un-park broadcast so the app
        // updates its cached row before (together with) the hibernated flip —
        // otherwise the terminal view rebuilds keyed on the dead window and
        // its failed attach re-parks the row (wake flap).
        broadcastHibernation(
            terminal: terminal, hibernated: false, keepWarm: terminal.keepWarm,
            tmuxWindowID: liveWindowID, tmuxPaneID: livePaneID
        )

        // `claude --resume <id>` forks into a NEW session file; re-capture the
        // fresh id so subsequent hibernate/wake reference the live session.
        SessionRecaptureScheduler(db: db, tmux: tmux, clock: clock).schedule(
            terminalID: terminal.id,
            paneID: livePaneID,
            server: liveServer,
            expectedIncarnationID: liveIncarnationID)
        logger.info("woke terminal \(terminal.id, privacy: .public) (resume \(sessionID, privacy: .public))")
        return .ok
    }

    /// Outcome of `wakeTmuxSection`: the live pane/window ids the rest of
    /// `wake()` should reference, or the `WakeResult` to return verbatim.
    private enum WakeTmuxOutcome {
        case respawned(
            paneID: String,
            windowID: String,
            server: String,
            incarnationID: UUID
        )
        case failed(WakeResult)
    }

    /// The decide-then-mutate tmux section of `wake()` — ownership check,
    /// `windowExists`, and the in-place respawn OR recreate mutations. Must
    /// only be entered under `TmuxManager.withWorktreeServerLock` (see the call
    /// site in `wake()`), otherwise two concurrent wakes on the same server can
    /// interleave across the awaits below and hijack each other's windows.
    private func wakeTmuxSection(
        terminal: Terminal,
        worktree: Worktree,
        server: String,
        windowID: String,
        paneID: String,
        spawnCommand: String,
        env: [String: String],
        sensitiveEnv: [String: String],
        cols: Int?,
        rows: Int?
    ) async -> WakeTmuxOutcome {
        // Post-reboot a fresh tmux server reissues window ids from @1 again,
        // so a stale parked row's window id can equal a window that ANOTHER
        // terminal's wake just created on the same server. `windowExists`
        // alone is therefore not ownership: if any other terminal currently
        // claims this id, ours is necessarily the stale claim (it predates
        // the reboot) and respawning in place would hijack that terminal's
        // live session. Treat the window as gone and recreate instead.
        let claimedByOther = await windowClaimedByAnotherTerminal(
            server: server, windowID: windowID, excluding: terminal.id
        )
        if claimedByOther {
            logger.info("wake: window \(windowID, privacy: .public) on \(server, privacy: .public) is claimed by another terminal — recreating instead of respawning in place for terminal \(terminal.id, privacy: .public)")
        }

        // Tri-state, because the `else` arm below `killWindow`s the old window
        // once its replacement exists — its own comment calls that out as "a
        // transient windowExists misclassification must not leak a live
        // window", and a timed-out probe is exactly such a misclassification.
        // Acting on it destroys a window on ignorance. A server that is
        // genuinely gone (the reboot case this recreate path exists for) still
        // answers `.absent`, so only the unanswerable case changes: the wake
        // fails and the row stays parked for the next focus or menu retry,
        // which is what every other tmux failure on this path already does.
        let windowPresence = claimedByOther
            ? TmuxPresence.absent
            : await tmux.probeWindow(server: server, windowID: windowID)
        if windowPresence == .unknown {
            logger.warning("wake: tmux gave no usable answer about window \(windowID, privacy: .public) on \(server, privacy: .public) for terminal \(terminal.id, privacy: .public) — leaving the row parked rather than recreating and killing on ignorance")
            return .failed(.respawnFailed(
                reason: "tmux did not answer whether window \(windowID) is still there; the row is unchanged — retry"))
        }
        if !claimedByOther, windowPresence == .alive {
            do {
                guard let incarnationID = try await db.terminals.prepareHibernatedAgentRespawn(
                    id: terminal.id,
                    expectedState: TerminalReplacementSnapshot(terminal: terminal),
                    at: now()) else {
                    return .failed(.respawnFailed(
                        reason: "terminal changed before wake could launch; retry"))
                }
                let replacementEnv = AgentProcessEnvironment.replacement(
                    base: env, incarnationID: incarnationID)
                try await tmux.respawnWindow(
                    server: server,
                    windowID: windowID,
                    cwd: worktree.localPath,
                    shellCommand: spawnCommand,
                    env: replacementEnv,
                    sensitiveEnv: sensitiveEnv,
                    cols: cols,
                    rows: rows
                )
                do {
                    try await db.terminals.clearHibernated(id: terminal.id)
                } catch {
                    // Keep the live replacement parked. Startup reconciliation
                    // detects parked+live-agent and clears this marker without
                    // erasing a SessionStart that arrived during launch.
                    logger.warning("wake: launched the replacement agent for terminal \(terminal.id, privacy: .public), but failed to clear its parked marker: \(error.localizedDescription, privacy: .public)")
                    return .failed(.respawnFailed(
                        reason: "replacement agent launched, but clearing the parked marker failed: \(error.localizedDescription)"))
                }
                return .respawned(
                    paneID: paneID,
                    windowID: windowID,
                    server: server,
                    incarnationID: incarnationID)
            } catch {
                // Leave the row hibernated so the next focus/menu retry can wake it.
                logger.warning("wake: respawn-to-claude failed for terminal \(terminal.id, privacy: .public) window \(windowID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return .failed(.respawnFailed(reason: "failed to respawn claude in window \(windowID): \(error.localizedDescription)"))
            }
        } else {
            // The window is GONE — killed, the whole tmux server died (a
            // machine reboot destroys every server; `windowExists` returns
            // false on any tmux error, covering both), or its id is owned by
            // another terminal (see above). Recreate the window and spawn the
            // same `claude --resume` there: transcripts live on disk, so
            // resume works fine in a fresh window. Mirrors
            // `handleTerminalRecreateWindow`. Tabs are keyed by terminal id,
            // so keeping the same terminal row preserves the tab.
            do {
                let resolvedCols = cols ?? TmuxManager.defaultCols
                let resolvedRows = rows ?? TmuxManager.defaultRows
                let bootstrapWindowID = try await tmux.ensureServer(
                    server: server,
                    session: "main",
                    cwd: worktree.localPath,
                    cols: resolvedCols,
                    rows: resolvedRows
                )
                await onServerCreated?(server)
                let window = try await tmux.createWindow(
                    server: server,
                    session: "main",
                    cwd: worktree.localPath,
                    // Stage an inert pane first. Launching Claude here would
                    // let its SessionStart arrive before the replacement tmux
                    // IDs and lifecycle fence commit below.
                    shellCommand: "exec /usr/bin/tail -f /dev/null",
                    env: env,
                    sensitiveEnv: sensitiveEnv,
                    cols: resolvedCols,
                    rows: resolvedRows
                )
                // Clean up the old window if it somehow still exists (a
                // transient windowExists misclassification must not leak a
                // live window; usually it's already dead so this no-ops).
                // Skip when another terminal owns the id — killing it would
                // tear down THEIR live window. This must happen AFTER
                // createWindow: if the row ever held the session's only
                // remaining window (e.g. the bootstrap window id), killing
                // it first would destroy the session and make createWindow
                // fail on every retry; killing after the new window exists
                // can never leave the session windowless.
                if !claimedByOther {
                    try? await tmux.killWindow(server: server, windowID: windowID)
                }
                // ensureServer returns the untracked bootstrap window id when
                // it just created the server; kill it now that the real
                // window exists (mirrors WorktreeLifecycle+PreSession).
                if let bootstrapWindowID, !bootstrapWindowID.isEmpty {
                    try? await tmux.killWindow(server: server, windowID: bootstrapWindowID)
                }
                let preparedIncarnationID: UUID?
                do {
                    preparedIncarnationID = try await db.terminals
                        .prepareHibernatedAgentRespawn(
                        id: terminal.id,
                        expectedState: TerminalReplacementSnapshot(terminal: terminal),
                        windowID: window.windowID,
                        paneID: window.paneID,
                        at: now())
                } catch {
                    // Don't leave an orphaned claude the DB doesn't know
                    // about: best-effort kill of the just-created window,
                    // and a reason that names the REAL failure (the window
                    // was created fine; persisting the ids failed).
                    try? await tmux.killWindow(server: server, windowID: window.windowID)
                    logger.warning("wake: created window \(window.windowID, privacy: .public) but failed to persist tmux ids for terminal \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return .failed(.respawnFailed(reason: "recreated tmux window \(window.windowID), but persisting the new tmux ids failed: \(error.localizedDescription)"))
                }
                guard let incarnationID = preparedIncarnationID else {
                    try? await tmux.killWindow(
                        server: server, windowID: window.windowID)
                    return .failed(.respawnFailed(
                        reason: "terminal changed before wake could launch; retry"))
                }
                let replacementEnv = AgentProcessEnvironment.replacement(
                    base: env, incarnationID: incarnationID)
                do {
                    try await tmux.respawnWindow(
                        server: server,
                        windowID: window.windowID,
                        cwd: worktree.localPath,
                        shellCommand: spawnCommand,
                        env: replacementEnv,
                        sensitiveEnv: sensitiveEnv,
                        cols: resolvedCols,
                        rows: resolvedRows)
                } catch {
                    // The row already owns this inert replacement window and
                    // remains parked, so startup reconciliation or a later wake
                    // can safely recover it.
                    logger.warning("wake: staged window \(window.windowID, privacy: .public) but failed to launch its agent for terminal \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return .failed(.respawnFailed(
                        reason: "recreated tmux window \(window.windowID), but launching the agent failed: \(error.localizedDescription)"))
                }
                do {
                    try await db.terminals.clearHibernated(id: terminal.id)
                } catch {
                    // Keep the live replacement parked for startup
                    // reconciliation; identity and process token stay intact.
                    logger.warning("wake: launched a replacement agent in \(window.windowID, privacy: .public), but failed to clear the parked marker for terminal \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return .failed(.respawnFailed(
                        reason: "replacement agent launched in \(window.windowID), but clearing the parked marker failed: \(error.localizedDescription)"))
                }
                logger.info("wake: window \(windowID, privacy: .public) was gone for terminal \(terminal.id, privacy: .public); recreated as \(window.windowID, privacy: .public) (pane \(window.paneID, privacy: .public))")
                return .respawned(
                    paneID: window.paneID,
                    windowID: window.windowID,
                    server: server,
                    incarnationID: incarnationID)
            } catch {
                // Leave the row hibernated so the next focus/menu retry can wake it.
                logger.warning("wake: recreate-window failed for terminal \(terminal.id, privacy: .public) (old window \(windowID, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                return .failed(.respawnFailed(reason: "tmux window \(windowID) is gone and could not be recreated: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Idle sweep (auto-hibernate)

    /// One pass of the auto-hibernate idle timer, run cheaply on a short cadence
    /// (poll) while the actual kill decision is made against the 30-min idle
    /// window (decide) — the Knative/KEDA poll/decide split.
    ///
    /// For every Claude terminal:
    ///  - track when it first went idle-at-rest (`idleSince`). Terminals that
    ///    leave the idle state (start working, raise a permission hand, get
    ///    suspended/hibernated) have their marker cleared so the clock restarts
    ///    next time they settle. The daemon's own pane status-polling does NOT
    ///    reset this — the marker keys off the DB activity state, not output
    ///    silence, so a busy-but-silent long tool call correctly stays BUSY and
    ///    an idle session isn't kept awake by our health checks (the bug that
    ///    silently disables Jupyter's idle-culler).
    ///  - once past the idle timeout, arm a short debounce (`pendingKillSince`)
    ///    and only hibernate on a LATER sweep after the debounce also elapses,
    ///    RE-VERIFYING every rail at that moment (state can flip in the final
    ///    instant). `performHibernate` adds the live typed-input / transcript
    ///    rails on top.
    public func sweep() async {
        guard let config = try? await db.config.get() else { return }
        guard let terminals = try? await db.terminals.list() else { return }
        let timeout = TimeInterval(max(1, config.hibernateIdleMinutes)) * 60
        let reference = now()

        // Prune markers for terminals that vanished.
        let liveIDs = Set(terminals.map { $0.id })
        // The tracker's own keys, so a holder row's entry (keyed by its
        // terminal id) survives a prune that a pane-id-only set would drop on
        // the very first sweep.
        let liveKeys = Set(terminals.map { InputActivityTracker.key(for: $0) })
        idleSince = idleSince.filter { liveIDs.contains($0.key) }
        pendingKillSince = pendingKillSince.filter { liveIDs.contains($0.key) }
        inputActivity.prune(keeping: liveKeys)

        for terminal in terminals {
            let lastInputAt = inputActivity.lastInput(
                paneID: InputActivityTracker.key(for: terminal))
            let decision = HibernationGate.decide(
                terminal: terminal,
                autoHibernateEnabled: config.autoHibernateEnabled,
                inputVetoEnabled: config.hibernateInputVetoEnabled,
                holderHibernationEnabled: config.holderHibernationEnabled,
                idleTimeout: timeout,
                idleSince: idleSince[terminal.id],
                lastInputAt: lastInputAt,
                now: reference
            )

            // A holder row whose screen this daemon cannot read is not a
            // candidate, however idle it is. `performHolderHibernate` fails
            // closed on exactly this — a viewer owns the pty, or no reader was
            // ever adopted — but it only reaches that refusal after the sweep
            // has written a request row and its refused outcome. On a tab the
            // user is looking at the condition holds for as long as the tab is
            // open, so without this check an open tab costs one
            // request+refusal pair per sweep, forever, for a park that could
            // never have happened.
            //
            // The gate cannot make this call: it is pure, and the registry is
            // only available here. So the sweep asks, and treats the answer the
            // way it treats the `.running` family — reset the idle clock and
            // any armed debounce, write nothing — which restarts the full idle
            // window from the moment the viewer leaves.
            if terminal.transport == .holder,
               decision == .eligible || decision == .notIdleLongEnough,
               await holderScreenIsUnreadable(terminalID: terminal.id) {
                logger.debug("hibernate: not arming \(terminal.id, privacy: .public) — the daemon cannot read this holder session's screen")
                idleSince[terminal.id] = nil
                pendingKillSince[terminal.id] = nil
                continue
            }

            switch decision {
            case .eligible:
                // Crossed the idle threshold. Arm the debounce on first
                // sighting; only kill once the settle window has ALSO passed
                // and the rails still hold (re-checked inside performHibernate,
                // and the gate itself is re-run on the next sweep before we get
                // here). A fresh at-rest terminal seeds idleSince here too.
                if idleSince[terminal.id] == nil {
                    // Should be non-nil to reach .eligible, but guard anyway.
                    idleSince[terminal.id] = reference
                }
                if let pending = pendingKillSince[terminal.id] {
                    if reference.timeIntervalSince(pending) >= Self.killDebounce {
                        // The rail's own row, written at its act moment. A
                        // request row that cannot be persisted refuses the act
                        // (fail-closed) — an unrecorded auto-park is exactly the
                        // silent gap the record exists to forbid.
                        var row = ActuationRow(
                            actor: .daemon(rail: ActuationRail.autoHibernate), kind: .hibernate)
                        row.target = .local(worktree: terminal.worktreeID, terminal: terminal.id)
                        guard let actuationID = try? await actuationLog.appendRequest(row) else {
                            continue
                        }
                        let result = await performHibernate(
                            terminal: terminal,
                            reason: .auto,
                            policy: .automatic(
                                enabled: config.autoHibernateEnabled,
                                inputVetoEnabled: config.hibernateInputVetoEnabled,
                                holderHibernationEnabled: config.holderHibernationEnabled,
                                idleTimeout: timeout,
                                idleSince: idleSince[terminal.id]))
                        await actuationLog.appendOutcome(
                            confirms: actuationID,
                            result: ActuationOutcome.classify(result),
                            error: ActuationOutcome.detail(result))
                    }
                } else {
                    pendingKillSince[terminal.id] = reference
                }

            case .notIdleLongEnough:
                // At rest but not past the timeout yet: keep/seed the idle
                // marker, clear any stale pending-kill (shouldn't exist).
                if idleSince[terminal.id] == nil {
                    idleSince[terminal.id] = reference
                }
                pendingKillSince[terminal.id] = nil

            case .pendingTypedInput:
                // Idle long enough but input arrived after it went idle: keep the
                // idle marker (session IS at rest) but clear the armed debounce so
                // the veto persists across sweeps until input is consumed (sending
                // advances idleSince past lastInputAt).
                logger.debug("hibernate: skipping \(terminal.id, privacy: .public) — pending typed input")
                pendingKillSince[terminal.id] = nil

            case .featureDisabled, .holderTransport, .notClaudeResumable,
                 .alreadyHibernated, .suspended, .keepWarm, .running,
                 .waitingForUser:
                // Not at rest (or ineligible): the idle clock and any armed
                // debounce reset so a later settle starts a fresh full window.
                idleSince[terminal.id] = nil
                pendingKillSince[terminal.id] = nil
            }
        }
    }

    // MARK: - Startup Reconciliation

    /// Clear a stale parked timestamp for any terminal whose Claude process is
    /// actually still alive (e.g. the daemon crashed mid-park before `/exit`
    /// landed, or before `respawn-window` ran). Ported from the old Suspend
    /// feature's `reconcileOnStartup`, generalized to the unified state: it
    /// checks BOTH the authoritative `hibernatedAt` and the legacy `suspendedAt`
    /// so a row parked by either path is reconciled, and `clearHibernated` nils
    /// both. Called once on daemon startup.
    public func reconcileOnStartup() async {
        guard let allTerminals = try? await db.terminals.list() else { return }

        for terminal in allTerminals where terminal.isParked {
            if terminal.transport == .holder {
                await reconcileParkedHolderRow(terminal)
                continue
            }
            guard let worktree = try? await db.worktrees.getLocal(id: terminal.worktreeID) else { continue }
            let server = worktree.tmuxServer

            // Check if the window still exists AND is running claude
            let serverAlive = await tmux.serverExists(server: server)
            guard serverAlive else { continue }

            let windowAlive = await tmux.windowExists(server: server, windowID: terminal.tmuxWindowID)
            guard windowAlive else { continue }

            // Verify the pane is still running a Claude process
            guard let cmd = try? await tmux.paneCurrentCommand(server: server, paneID: terminal.tmuxPaneID),
                  ClaudeStateDetector.isClaudeProcess(cmd) else {
                continue
            }

            // Window and process are alive — clear the parked state
            do {
                try await db.terminals.clearHibernated(id: terminal.id)
                logger.info("startup: cleared stale parked state for still-running terminal \(terminal.id, privacy: .public) — window \(terminal.tmuxWindowID, privacy: .public), process alive")
            } catch {
                logger.warning("startup: failed to clear parked state for terminal \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Helpers

    /// Send an in-band `/exit` (ported from the old Suspend feature) and poll
    /// the pane's current command up to `exitPollAttempts` × `exitPollInterval`
    /// (~3s) for the claude process to leave. Returns `true` if the pane is no
    /// longer running a claude process by the end of the window (polite exit
    /// succeeded), `false` if it's still claude (caller escalates to SIGTERM).
    ///
    /// If we can't even send `/exit`, we return `false` so the caller falls back
    /// — `respawn-window -k` still guarantees the process dies either way.
    private func politeExitThenPoll(server: String, paneID: String, terminalID: UUID) async -> Bool {
        do {
            try await tmux.sendCommand(server: server, paneID: paneID, command: "/exit")
        } catch {
            logger.debug("hibernate: /exit send failed for \(terminalID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
        // Invariant, preserved verbatim from the pre-clock version: `try?` is
        // NOT a cancellation check. On a cancelled task every `sleep` throws
        // immediately, so this loop burns all `exitPollAttempts` iterations at
        // zero delay, returns false, and the caller escalates straight to
        // SIGTERM. That is a real defect, filed separately; it is deliberately
        // NOT fixed here — an untested cancellation guard on a kill path is
        // exactly the accretion this migration refuses. Anything added to this
        // loop must keep that behaviour or change it with its own test.
        for _ in 0..<exitPollAttempts {
            try? await clock.sleep(for: exitPollInterval)
            if let cmd = try? await tmux.paneCurrentCommand(server: server, paneID: paneID),
               !ClaudeStateDetector.isClaudeProcess(cmd) {
                return true
            }
        }
        return false
    }

    /// Escape → settle → C-c C-c → settle → SIGTERM. Best-effort; the
    /// subsequent `respawn-window -k` guarantees termination. Copied from the
    /// swap path so hibernate and account-switch interrupt identically.
    ///
    /// **Acts on an unverified coordinate (issue #384)** — `paneID` comes from
    /// the terminal row and tmux reuses pane ids, so a stale row points this
    /// SIGTERM and the respawn that follows at a live stranger. See the swap
    /// path's copy in `RPCRouter+TerminalHandlers` for why the fix is a spec
    /// about refusal semantics rather than a consultation added here.
    private func gracefullyInterruptPane(server: String, paneID: String) async {
        try? await tmux.sendKey(server: server, paneID: paneID, key: "Escape")
        // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
        try? await Task.sleep(for: .milliseconds(150))
        try? await tmux.sendKey(server: server, paneID: paneID, key: "C-c")
        try? await tmux.sendKey(server: server, paneID: paneID, key: "C-c")
        // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
        try? await Task.sleep(for: .milliseconds(150))
        if let pidStr = try? await tmux.panePID(server: server, paneID: paneID),
           let pid = Int32(pidStr), pid > 0 {
            kill(pid, SIGTERM)
        }
    }

    /// True when any OTHER terminal row whose worktree lives on the same tmux
    /// server currently claims `windowID`. A fresh (post-reboot) server
    /// reissues window ids from @1, so a stale parked row can collide with a
    /// window a different terminal's wake just created — and the other row's
    /// claim is necessarily the fresher one. Worktrees can share a per-repo
    /// server, so ownership is resolved across every worktree on that server.
    private func windowClaimedByAnotherTerminal(
        server: String, windowID: String, excluding terminalID: UUID
    ) async -> Bool {
        guard let terminals = try? await db.terminals.list(),
              let worktrees = try? await db.worktrees.listLocal() else { return false }
        let serverWorktreeIDs = Set(worktrees.filter { $0.tmuxServer == server }.map(\.id))
        return terminals.contains {
            $0.id != terminalID
                && $0.tmuxWindowID == windowID
                && serverWorktreeIDs.contains($0.worktreeID)
        }
    }

    /// `suspendedSnapshot`/`hibernateReason` ride hibernate broadcasts (and
    /// keep-warm re-broadcasts on a parked row) because the app applies this
    /// delta to its cached row IN PLACE: the parked view materializes on the
    /// `hibernated` flip and reads the row's snapshot once, and wake-on-focus
    /// reads the row's reason — a later refetch is too late. Wake broadcasts
    /// leave them nil.
    func broadcastHibernation(
        terminal: Terminal, hibernated: Bool, keepWarm: Bool,
        tmuxWindowID: String? = nil, tmuxPaneID: String? = nil,
        suspendedSnapshot: String? = nil, hibernateReason: HibernateReason? = nil
    ) {
        subscriptions?.broadcast(delta: .terminalHibernationChanged(TerminalHibernationDelta(
            terminalID: terminal.id,
            worktreeID: terminal.worktreeID,
            hibernated: hibernated,
            keepWarm: keepWarm,
            tmuxWindowID: tmuxWindowID,
            tmuxPaneID: tmuxPaneID,
            suspendedSnapshot: suspendedSnapshot,
            hibernateReason: hibernateReason
        )))
    }
}
