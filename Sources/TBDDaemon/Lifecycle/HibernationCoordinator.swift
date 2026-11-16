import Foundation
import TBDShared
import TBDKernel
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "Hibernation")

public enum HibernateResult: Equatable, Sendable {
    case ok
    case alreadyHibernated
    case notEligible(reason: String)
    /// The row is live on the tmux transport, which TBD no longer reaches or
    /// stops (`liveTmuxParkRefusal`). Nothing was touched; `reason` says the
    /// session may still be running in tmux and how to end it. Kept apart
    /// from `notEligible` so the park RPCs can answer it with
    /// `RPCErrorCode.terminalOnTmux`, as every other request such a row
    /// refuses does. The actuation record calls it `not-eligible`.
    case onTmux(reason: String)
    case notFound
}

/// Which rails a park attempt is judged by, and the config facts those rails
/// need. Transport is not among them: TBD parks only holder rows, and a row
/// still on tmux is refused before any policy is read.
enum HibernateEligibilityPolicy: Sendable {
    case manual
    case merge
    case automatic(
        enabled: Bool,
        idleTimeout: TimeInterval,
        idleSince: Date?)
    /// The park half of an in-place profile swap.
    ///
    /// A fourth policy rather than a switch on the others, because it is the
    /// only one that deliberately bypasses the live rails: the user asked for
    /// this session to move accounts, so neither a mid-write transcript tail
    /// (`honoursLiveRails`) nor a turn in flight or a raised permission hand
    /// (`hibernationRefusal`) refuses it.
    /// See `docs/specs/2026-09-22-holder-in-place-profile-swap-design.md`,
    /// "The swap interrupts regardless, matching tmux", and
    /// `docs/specs/2026-10-24-mod-only-park-guard-design.md`, "Which parks go
    /// ahead".
    ///
    /// Like every park, it ends by SIGTERM and types nothing into the session.
    case profileSwap
}

extension HibernateEligibilityPolicy {
    /// Whether this park is judged by the rail that reads live state — the
    /// transcript tail — as opposed to the row alone.
    ///
    /// One predicate, named once, so a rail that comes to answer to it cannot
    /// disagree with this one about which policies it answers to.
    ///
    /// **What it reaches.** The transcript-tail rail
    /// (`transcriptTailRefusal`). No park judges the screen: each reads it
    /// once for the display snapshot alone, kept as the row's
    /// `suspendedSnapshot`, and nothing the screen shows — nor whether it can
    /// be read at all — refuses a park.
    var honoursLiveRails: Bool {
        if case .profileSwap = self { return false }
        return true
    }
}

/// How an unparked terminal's pane disagreed with the row that claims it is
/// awake. Only states tmux gave a positive answer for appear here; "the probe
/// failed" is deliberately not a case, because it is not a disagreement.
public enum UnparkedPaneDisagreement: Equatable, Sendable {
    /// The pane the row names is gone, or its window is. A read that failed
    /// is never this case: a failed read is not a disagreement.
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
    /// The wake respawned the agent. Carries the incarnation
    /// `prepareHibernatedAgentRespawn` minted for that spawn, which is what
    /// scopes a caller's wait to the session THIS call started.
    case ok(sessionIncarnationID: UUID?)
    case notHibernated   // idempotent no-op: nothing to wake
    /// The row is NOT parked — TBD believes this terminal is awake — but its
    /// pane says otherwise, so there is no live session for an "already awake"
    /// answer to refer to. `detail` names which way it disagreed. Distinct from
    /// `.notHibernated` so a caller can tell a benign idempotent no-op from a
    /// terminal that needs recovery, and so a dropped `prompt` is reported
    /// rather than silently discarded. Nothing is respawned — see
    /// `classifyUnparkedHolderWake`.
    case sessionGone(paneID: String, detail: UnparkedPaneDisagreement)
    case notFound        // terminal/worktree DB row missing — NOT tmux failures
    case noSessionID
    /// The parked row has no provider-qualified recovery plan, such as a
    /// shell tab carrying an incidental session ID. Nothing is respawned and
    /// the row stays as it was. Kept for compatibility with Claude-only callers.
    case notAClaudeTab(kind: TerminalKind)
    case inFlight        // a wake for this terminal is already respawning
    /// The wake stopped without leaving the session running under an
    /// un-parked row, for a cause that has no case of its own. Several causes
    /// share it, and not all of them start anything:
    ///
    /// - a Codex wake that carries an initial prompt, refused once the row is
    ///   known to be a parked holder row with a resume plan, and before the
    ///   worktree, condition, directory and profile checks;
    /// - a Codex resume that could not be prepared;
    /// - a row that changed while the wake prepared or launched;
    /// - a holder spawn that failed or could not be attempted;
    /// - a running session, a replacement just started or a holder already
    ///   there, whose pids or un-parked marker could not be written;
    /// - an answer that keeps the row parked over a live holder: the daemon is
    ///   shutting down, a teardown let the session go, or it was released
    ///   while the wake adopted it.
    ///
    /// The wake does not un-park the row, so a later wake can try again, and
    /// `reason` names the real cause instead of the misleading "Terminal not
    /// found".
    case respawnFailed(reason: String)
    /// The row is on the tmux transport, which TBD no longer starts, reaches
    /// or stops sessions on (`tmuxWakeRefusal`). Nothing was touched and an
    /// `initialPrompt` was not delivered. `reason` says what to do: a parked
    /// row's names `tbd terminal migrate`, and a live row's says the session
    /// is still running in tmux and how to end it.
    ///
    /// A refusal rather than a failed start, so no retry helps: the wake RPCs
    /// answer it with `RPCErrorCode.terminalOnTmux`, as every other request a
    /// tmux row refuses does, and the actuation record calls it
    /// `not-eligible`.
    case onTmux(reason: String)
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
    /// The caller named a `SessionRestoreCondition` and this parked row no
    /// longer meets it. Nothing was started and the row stays exactly as it was,
    /// because the row is no longer the one the caller chose. Only a wake that
    /// names a condition gets this answer.
    case conditionNotMet
}

/// What moving a live session with nothing to resume onto the pty holder came
/// to — `HibernationCoordinator.moveRunningShellToHolder`.
///
/// Three cases, and the two that did not move mean different things. A lost
/// compare-and-set is a race whose other side already gave the person a
/// working session, so it is reported as a skip; a refusal names a fact that
/// has to change first.
enum ShellTransportMoveOutcome: Sendable, Equatable {
    /// The row reads holder-backed and names the processes of a fresh login
    /// shell running in the same working directory.
    case moved
    /// The write found the row had changed under the move, so nothing was
    /// written and the holder that had been started was abandoned.
    case lostTheRace
    /// The move was not attempted, or could not be finished. Nothing was
    /// written either way.
    case refused(reason: String)
}

/// How the running-shell move starts a holder, and undoes one whose move could
/// not be recorded.
///
/// A **test seam only**: production leaves
/// `HibernationCoordinator.holderSpawnOracle` nil and the move goes through
/// `HolderRegistry`, which is the only thing that can actually start a holder.
/// It exists for the same reason `holderScreenOracle` does — reaching the
/// move's own decisions (the launch it composes, a write that lost its
/// compare-and-set, the abandon that undoes the spawn) through a real registry
/// would mean a real `TBDHolder`, a real pty and a real handshake for
/// questions this coordinator answers either side of the spawn.
///
/// **What still reaches the real registry**, so the seam cannot hide a broken
/// production wiring: every case in `RunningShellTransportMoveTests` that
/// passes no oracle — the registry-cannot-spawn refusal and the daemon with no
/// registry at all. There is no live-target coverage of this move; the gap is
/// the spawn itself succeeding.
struct HolderSpawnOracle: Sendable {
    let spawn: @Sendable (UUID, HolderLaunchRequest) async throws -> HolderHandle
    let abandon: @Sendable (UUID, HolderHandle) async -> Void
}

/// Owns session PARKING — the single unified "park a Claude session" feature
/// (the former Suspend and Hibernate features merged into one). A park ends a
/// holder-backed session's agent process and keeps its identity on the row; a
/// wake starts a fresh pty holder running `claude --resume` (or the Codex
/// resume) for the same row.
///
/// The park sequence (`performHibernate`, then `performHolderHibernate`):
///   1. Ask the session mod whether the park may go ahead
///      (`ComposerDraftParkGate`): it is the only guard for text typed into
///      the composer and not sent.
///   2. Read the screen once for a display snapshot, which the app shows as
///      the frozen backdrop while parked or waking. It is shown, never judged.
///   3. Enforce the live rail the DB row can't express: transcript-tail
///      validity.
///   4. Record the park intent, then end the holder's job by SIGTERM, so
///      Claude flushes its transcript, shuts down MCP children, fires Stop
///      hooks and lets the session mod make its final save; abandon the
///      holder if the job outlives the poll. Nothing is typed into the
///      session.
///   5. Finalize the row parked via `hibernatedAt` (the authoritative
///      timestamp), with no pids on it, and persist the snapshot.
///
/// **Only holder rows park and wake.** TBD no longer drives tmux: every park
/// refuses a live row still on the tmux transport (`liveTmuxParkRefusal`), and
/// every wake refuses a tmux row (`tmuxWakeRefusal`) — a parked one names
/// `tbd terminal migrate`, a live one says it is still running in tmux. A tmux
/// row is parked only once its tmux server is positively gone, and not here:
/// reconcile, the app's Check Again and the transport migration park it
/// (`WorktreeLifecycle.parkLeftoverTmuxRow`, `LeftoverTmuxServerProbe`). Wake
/// is the ONE resume path for auto-parked, manually-parked, and (via
/// reconcile) died sessions; it clears BOTH `hibernatedAt` and any legacy
/// `suspendedAt`.
///
/// The prompt cache expires after ~5 min idle, so a session past the TTL pays
/// full uncached input on its next message whether or not the process stayed
/// alive — parking an idle session is therefore nearly free.
public actor HibernationCoordinator {
    let db: TBDDatabase
    private let modelProfileResolver: ModelProfileResolver?
    private let codexExecutableResolver: @Sendable () throws -> String
    private let codexHomeEnsurer: @Sendable () throws -> URL
    private let subscriptions: StateSubscriptionManager?
    /// Routes ambient claude-projects-root resolution for the wake transcript
    /// sync — injectable (mirroring `RPCRouter.configDirManager`) so tests
    /// point it at a temp dir instead of falling back to the real `~/.claude`.
    private let configDirManager: ClaudeProfileConfigDirManager
    /// The title each Claude session was last given — shared with the
    /// lifecycle and router, so a wake's `--name` is what the next prompt's
    /// title is compared against. See `ClaudeSessionTitle`. Not private: the
    /// holder wake in `HibernationCoordinator+Holder` settles its reservation.
    let sessionTitles: ClaudeSessionTitleStore
    let now: @Sendable () -> Date

    /// Per-terminal "first time we observed it idle-at-rest" marker, maintained
    /// by `sweep`. In-memory only: a daemon restart clears it, so a freshly
    /// started daemon won't instantly hibernate long-idle sessions — it waits a
    /// full idle window first, which is the safe behavior.
    var idleSince: [UUID: Date] = [:]

    /// Terminal ids with an in-flight wake respawn, so a double-focus can't
    /// spawn two `claude --resume` processes for the same session.
    // Not private: `HibernationCoordinator+Holder` claims both.
    var wakesInFlight: Set<UUID> = []

    /// Terminal ids with an in-flight hibernate, so a manual "Hibernate now"
    /// racing the idle sweep (or two sweeps) can't end the same session twice.
    // Not private: `HibernationCoordinator+Holder` claims both.
    var hibernatesInFlight: Set<UUID> = []

    /// Terminal ids with an in-flight in-place profile swap, held across the
    /// WHOLE of that swap rather than across either half of it.
    ///
    /// The swap is a composition — park, re-home, wake — and the two
    /// singleflight sets above release between them: the park's claim is gone
    /// the instant the park returns, and the wake's is not taken until several
    /// suspension points later. The row is parked in that gap and nothing owns
    /// it, so the app's wake-on-focus (which wakes exactly the active tab's
    /// parked terminal, and the tab a user just pressed "Switch account" on is
    /// the active tab) could un-park it and start a fresh session under the
    /// OLD account before the re-home landed. The re-home's compare-and-set
    /// then refused the write, which is safe but leaves the user told their
    /// session is parked on its old account when it is in fact awake there.
    ///
    /// So the swap claims the row before it parks and releases it after the
    /// wake, and the public `wake` answers a claimed row `.inFlight`. The
    /// swap's OWN halves are exempt by construction, not by a flag a caller
    /// could forget to pass: `performHibernate` consults only
    /// `hibernatesInFlight`, and the swap wakes through
    /// `wakeHolderAfterInPlaceChange`, which consults only the two sets above.
    private var swapsInFlight: Set<UUID> = []

    /// Debounce after a terminal first crosses the idle threshold: the sweep
    /// marks it `pendingKillSince`, and only actually hibernates on a LATER
    /// sweep once this settle window has also elapsed AND every rail still
    /// holds. State can flip in the final instant (a turn starts, a permission
    /// prompt appears), so the kill decision is re-verified here, not at
    /// arm-time. (Knative/KEDA poll-cheaply / decide-against-window pattern.)
    var pendingKillSince: [UUID: Date] = [:]

    /// Settle window between crossing the idle threshold and the actual kill.
    static let killDebounce: TimeInterval = 20

    /// How long the holder park waits between checks of its child, at every
    /// rung of its ladder: 200 ms in production.
    ///
    /// Injectable (a defaulted init parameter) rather than `static let`, so a
    /// test can cross an exhaustion threshold in a handful of `TestClock`
    /// advances instead of paying real wall time to prove one branch.
    /// Deliberately not `private`: the production default is pinned by a test.
    /// `nonisolated` because it is immutable and `Sendable`, so reading it
    /// needs no actor hop — without it a test's synchronous `#expect` against
    /// it fails to compile. Safe only while it stays `let`; a `var` here would
    /// have to drop `nonisolated` and every reader would need `await`.
    nonisolated let exitPollInterval: Duration

    /// How many times the holder park re-checks its child after sending it
    /// `SIGTERM`, before escalating to the forced teardown.
    ///
    /// 25 at the production `exitPollInterval` of 200 ms is five seconds, and
    /// the number is sized against what a Claude session actually does with a
    /// `SIGTERM` it means to honour: run its Stop hooks, tear down its MCP
    /// children, let the session mod make its final save, and flush the
    /// transcript it is mid-write on. Every holder park starts at this rung,
    /// so a session that is shutting down cleanly and slowly gets five seconds
    /// before anything is killed. Injectable on the same terms as
    /// `exitPollInterval`.
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

    /// Root of the per-session directories a wake writes `spawn.json` under
    /// when a session-mod feature is on. Defaults to `TBDConstants.sessionsDir()`
    /// (which follows `TBD_HOME`); tests inject a scratch directory.
    let sessionsDir: URL

    /// The pty-holder registry, wired post-construction by Daemon.swift — the
    /// registry is built before the RPC router that owns this coordinator, and
    /// both must reach the SAME actor: the park path reads a session's screen
    /// through the reader the spawn path registered.
    ///
    /// Nil in mock mode and in any composition with no holder transport, where
    /// the park path refuses by name: with no registry there is no way to
    /// abandon the holder, so nothing in this daemon could end the job.
    var holderRegistry: HolderRegistry?

    /// Answers a holder-backed session's screen, for the park's display
    /// snapshot. A **test seam only** — production leaves it nil and
    /// `holderScreen` falls through to the registry's own reader, which
    /// is the single source the design names.
    ///
    /// It exists for the same reason the send path's `holderModeOracle` does:
    /// reaching each screen answer (`daemon`, `staleDaemon`, a screen that will
    /// not project, and no screen at all) through a real registry means a real
    /// holder, a real pty and a real attach. The registry-backed path is
    /// exercised live; this is how the snapshot's branches are pinned.
    ///
    /// `nil` from the seam means the same thing as no reader: nothing answered.
    /// A throw means the same thing as a refused projection.
    var holderScreenOracle: (@Sendable (UUID) async throws -> TerminalScreen?)?

    /// Starts and undoes the holder the running-shell transport move needs. A
    /// **test seam only** — production leaves it nil and the move goes through
    /// `holderRegistry`. See `HolderSpawnOracle`.
    var holderSpawnOracle: HolderSpawnOracle?

    /// Whether a recorded holder pid is still a live `TBDHolder` — the
    /// holder half of `HolderChildDisposition.sessionHasEnded`. Production uses the shared
    /// `HolderSpawner.isLiveHolder`; tests replace it through
    /// `setHolderProcessIsLive`, because a fixture's holder pid is a number
    /// the real kernel answers for.
    var holderProcessIsLive: @Sendable (Int32) -> Bool = { HolderSpawner.isLiveHolder(pid: $0) }

    /// How the holder park observes and ends a child process. Injected so a
    /// test can state "the job ignored SIGTERM" in one line instead of
    /// arranging a real one, and can see which pid a park signalled.
    let signaller: any ProcessSignaller

    /// The daemon's actuation record. The idle sweep and the merge-park rail
    /// are daemon-internal actuation sites — they bypass the router, so each
    /// logs its own row. Deliberately NOT logged inside `performHibernate`: the
    /// RPC handlers call that same method after writing their own row, and a
    /// row there would double-count every manual park.
    private let actuationLog: ActuationLog

    /// The Program Status Protocol (OSC 7501) store. A park or a wake drops the
    /// terminal's entries (spec "Liveness"): a parked session's program is
    /// gone, and a SIGKILLed one never sent `state=clear`. A holder park that
    /// rolls back discards what the store kept for a wake. Nil in tests that
    /// do not exercise it.
    let programStatus: ProgramStatusStore?

    /// What a person is told when a session parked on the tmux transport is
    /// asked to wake. TBD opens sessions only on the pty holder, so such a row
    /// never wakes where it is, whether or not tmux is installed. Names the
    /// gesture that moves the session, **and the session**: this string is the
    /// entire product of the backstop — it exists to hand a stranded person a
    /// command they can run — so the id is interpolated rather than left as a
    /// placeholder to be looked up.
    static func tmuxWakeUnavailableReason(terminalID: UUID) -> String {
        "This session was parked on the tmux transport, which TBD no longer runs sessions on. "
        + "Run `tbd terminal migrate \(terminalID.uuidString)` (or `tbd terminal migrate --all`) "
        + "to move it to the pty holder, then wake it again."
    }

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
        exitPollInterval: Duration = .milliseconds(200),
        holderTerminateAttempts: Int = 25,
        holderEscalationAttempts: Int = 5,
        clock: any Clock<Duration> = ContinuousClock(),
        signaller: any ProcessSignaller = ProductionProcessSignaller(),
        sessionsDir: URL = TBDConstants.sessionsDir(),
        sessionTitles: ClaudeSessionTitleStore,
        actuationLog: ActuationLog,
        programStatus: ProgramStatusStore? = nil,
        codexExecutableResolver: (@Sendable () throws -> String)? = nil,
        codexHomeEnsurer: (@Sendable () throws -> URL)? = nil
    ) {
        self.db = db
        self.modelProfileResolver = modelProfileResolver
        self.subscriptions = subscriptions
        self.configDirManager = configDirManager
        self.now = now
        self.exitPollInterval = exitPollInterval
        self.holderTerminateAttempts = holderTerminateAttempts
        self.holderEscalationAttempts = holderEscalationAttempts
        self.clock = clock
        self.signaller = signaller
        self.sessionsDir = sessionsDir
        self.sessionTitles = sessionTitles
        self.actuationLog = actuationLog
        self.programStatus = programStatus
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

    /// Wire the pty-holder registry. Set once by Daemon.swift after
    /// construction: the registry exists before the router that owns this
    /// coordinator, and every consumer must share the one actor that holds the
    /// daemon's readers.
    func setHolderRegistry(_ registry: HolderRegistry?) {
        holderRegistry = registry
    }

    /// Replace the holder liveness check. Tests only — see `holderProcessIsLive`.
    func setHolderProcessIsLive(_ isLive: @escaping @Sendable (Int32) -> Bool) {
        holderProcessIsLive = isLive
    }

    /// Wire the park snapshot's screen seam. Tests only — see
    /// `holderScreenOracle`.
    func setHolderScreenOracle(
        _ oracle: (@Sendable (UUID) async throws -> TerminalScreen?)?
    ) {
        holderScreenOracle = oracle
    }

    /// Wire the running-shell move's holder seam. Tests only — see
    /// `HolderSpawnOracle`.
    func setHolderSpawnOracle(_ oracle: HolderSpawnOracle?) {
        holderSpawnOracle = oracle
    }

    // MARK: - Keep-warm

    public func setKeepWarm(terminalID: UUID, keepWarm: Bool) async -> Bool {
        guard let terminal = try? await db.terminals.get(id: terminalID) else { return false }
        try? await db.terminals.setKeepWarm(id: terminalID, keepWarm: keepWarm)
        // Carry the row's persisted snapshot/reason: on a parked row this
        // re-broadcast has hibernated == true, and the app's in-place apply
        // would otherwise wipe both from its cached row.
        await broadcastHibernation(
            terminal: terminal, hibernated: terminal.isHibernated, keepWarm: keepWarm,
            suspendedSnapshot: terminal.isHibernated ? terminal.suspendedSnapshot : nil,
            hibernateReason: terminal.isHibernated ? terminal.hibernateReason : nil,
            isParkOrWake: false)
        return true
    }

    // MARK: - Hibernate

    /// Manual "Hibernate now". Honors the running / permission-prompt rails but
    /// not keep-warm or idle-time (the user asked explicitly). It parks a
    /// session whose session mod cannot vouch for its draft without asking,
    /// so an unsent draft TBD could not confirm saved may be lost.
    public func manualHibernate(terminalID: UUID) async -> HibernateResult {
        guard let terminal = try? await db.terminals.get(id: terminalID) else {
            return .notFound
        }
        guard terminal.hibernatedAt == nil else { return .alreadyHibernated }
        if let refusal = await liveTmuxParkRefusal(terminal) { return refusal }
        guard terminal.isManuallyHibernatable() else {
            return .notEligible(reason: manualBlockReason(terminal))
        }
        return await performHibernate(
            terminal: terminal, reason: .manual, policy: .manual)
    }

    /// Claim this row for the whole of an in-place profile swap, refusing if
    /// any park, wake or other swap of it is already in flight.
    ///
    /// Paired with `releaseSwap(terminalID:)`, which the caller must reach on
    /// every exit including a thrown one — a claim that leaks makes the row
    /// unwakeable until the daemon restarts.
    ///
    /// - Returns: true when the claim was taken, false when it was refused and
    ///   the caller must change nothing.
    func claimSwap(terminalID: UUID) -> Bool {
        guard !transitionInFlight(terminalID: terminalID) else { return false }
        swapsInFlight.insert(terminalID)
        return true
    }

    /// Release the claim `claimSwap(terminalID:)` took. Idempotent, so the
    /// caller may release on a path it is not certain claimed.
    func releaseSwap(terminalID: UUID) {
        swapsInFlight.remove(terminalID)
    }

    /// Whether an in-place profile swap currently holds this row. For tests
    /// and for the assertions that pin the claim's lifetime.
    func isSwapInFlight(terminalID: UUID) -> Bool {
        swapsInFlight.contains(terminalID)
    }

    /// Whether a park, a wake or an in-place profile swap of this row is in
    /// flight — the three claims that each own a row while they run.
    ///
    /// The one statement of that question: a wake and a swap claim refuse a
    /// row any of the three holds, and an attach asks it before adopting a
    /// holder session on demand (`RPCRouter.mayAdoptForAttach`).
    func transitionInFlight(terminalID: UUID) -> Bool {
        hibernatesInFlight.contains(terminalID)
            || wakesInFlight.contains(terminalID)
            || swapsInFlight.contains(terminalID)
    }

    /// Park a session because an in-place profile swap is about to re-home it
    /// onto another account and resume it there.
    ///
    /// The park half of `terminal.swapProfile`'s holder arm, and the only
    /// caller of `.profileSwap`. `.auto` rather than `.manual` as the reason,
    /// deliberately: a daemon that dies between this park and the wake that
    /// follows it leaves a row the next focus-wake heals, where a manual park
    /// is excluded from wake-on-focus and would sit there until somebody woke
    /// it by hand.
    ///
    /// It does not check the transport: `performHibernate` refuses a row still
    /// on tmux as it does for every park. The swap handler calls this for
    /// **holder rows only**, because `handleTerminalSwapProfile` branches on
    /// `transport == .holder` before reaching the arm that calls here. See
    /// `honoursLiveRails`.
    func parkForProfileSwap(terminalID: UUID) async -> HibernateResult {
        guard let terminal = try? await db.terminals.get(id: terminalID) else {
            return .notFound
        }
        return await performHibernate(
            terminal: terminal, reason: .auto, policy: .profileSwap)
    }

    // MARK: - Moving a live session that has nothing to resume

    /// The refusal when this session's worktree cannot give the move a local
    /// working directory.
    ///
    /// Two readings, and the wording has to carry both, because `getLocal`
    /// answers nil for each: a row that could not be read at all, and a row
    /// that is perfectly readable and REMOTE — a remote worktree has no
    /// filesystem path, so there is nowhere on this machine to start a
    /// replacement shell. Saying only "could not be read" would report the
    /// ordinary second case as a database fault.
    static let shellMoveWorktreeUnreadableRefusal =
        "This session's worktree gives TBD no local directory to start a replacement shell in — "
        + "it is a remote worktree, or its row could not be read; nothing was changed."

    /// The refusal when the replacement shell could not be started. Says what
    /// state the session is in and what moves it: the row was not rewritten,
    /// so running the move again starts the shell on the holder. Names the
    /// session, because the command takes it.
    static func shellMoveSpawnFailedRefusal(terminalID: UUID, detail: String) -> String {
        "This session was not moved: starting a holder for its replacement shell failed "
        + "(\(detail)). The session still reads as live on tmux, whose server is gone. Run "
        + "`tbd terminal migrate \(terminalID.uuidString)` again to start it on the pty holder."
    }

    /// The refusal the loser of two concurrent moves of one row meets: a holder
    /// is already registered for this session, so the winner has started its
    /// replacement shell.
    ///
    /// Its own reason rather than the spawn-failure one, whose advice — the
    /// session still reads as live on tmux, and running the move again starts
    /// it on the holder — describes a row that was not moved. The winner has
    /// already moved this one, so that advice would be false in every
    /// particular.
    static let shellMoveAlreadyMovingRefusal =
        "Another move of this session is already running and has started its replacement shell "
        + "on the pty holder, so this one changed nothing further."

    /// The refusal when the one guarded write threw. The holder started for
    /// the move has been abandoned, so no process outlives the row, and the
    /// row was not rewritten, so running the move again starts the shell on the
    /// holder.
    static func shellMoveWriteFailedRefusal(terminalID: UUID, detail: String) -> String {
        "A replacement shell was started for this session, but the move could not be recorded "
        + "(\(detail)), so that shell was stopped again. The session still reads as live on "
        + "tmux, whose server is gone. Run `tbd terminal migrate \(terminalID.uuidString)` "
        + "again to start it on the pty holder."
    }

    /// Move a live tmux session that has no conversation to resume onto the
    /// pty holder, once its tmux server is gone: start a fresh login shell on a
    /// holder in the same working directory, and record the move in one
    /// guarded write.
    ///
    /// **Reached only by shells whose tmux server is gone.**
    /// `TerminalTransportMigrator` probes the server first and refuses while it
    /// may still be running, so there is nothing left here to stop: the server
    /// took the shell with it. And `TransportMigrationEligibility` turns away
    /// every other row that names no conversation — a Codex tab, a Claude tab
    /// whose session has not begun, a hook tab of either kind — each with its
    /// own reason, so nothing here has to guess what a tab was for.
    ///
    /// **Three steps, and the order is the contract.** Refuse early what cannot
    /// be done; spawn the holder carrying a freshly minted incarnation; write
    /// once. The write is a compare-and-set against the row as this move read
    /// it, so any writer that changes the row in between — closing the tab,
    /// say — leaves this write a stale snapshot: it writes nothing and the
    /// holder it started is abandoned. Nothing can leave a row naming a
    /// transport its live process is not on.
    ///
    /// **There is nothing to park.** A park exists to preserve a conversation
    /// across a respawn, and this row names none — which is exactly why
    /// `performHibernate` refuses it ("No session id to resume later") and why
    /// this path exists at all.
    ///
    /// Every failure leaves the row untouched, so a later migration sees
    /// exactly what this one saw.
    /// See `docs/specs/2026-10-11-holder-transport-migration-design.md`.
    func moveRunningShellToHolder(terminal: Terminal) async -> ShellTransportMoveOutcome {
        // Before anything is touched. A session whose holder cannot be started
        // must be left as it is rather than half-moved.
        //
        // The registry is required even when the oracle answers the spawn,
        // because its `environment` is what the job inherits: the same daemon
        // environment every other holder spawn reads, scrubbed by
        // `SpawnBaseEnvironment` inside `holderLaunch`. The INHERITED
        // environment deliberately has no fallback to
        // `ProcessInfo.processInfo.environment` — under the test fence that is
        // the ambient `TBD_HOME` and rendezvous root the fence exists to keep
        // out of a composed launch. The program the job runs is a separate
        // question and does read the ambient `SHELL`: `defaultShell` is
        // `ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"`, which is
        // the daemon's own login shell and the same one every other replacement
        // shell in this file is launched with.
        guard let registry = holderRegistry else {
            logger.warning("shell transport move: refusing \(terminal.id, privacy: .public) — this daemon has no holder registry")
            return .refused(reason: TerminalTransportMigrator.holderUnspawnableRefusal)
        }
        let spawnEnvironment = registry.environment
        let spawnHolder: @Sendable (UUID, HolderLaunchRequest) async throws -> HolderHandle
        let abandonHolder: @Sendable (UUID, HolderHandle) async -> Void
        if let oracle = holderSpawnOracle {
            spawnHolder = oracle.spawn
            abandonHolder = oracle.abandon
        } else {
            guard registry.canSpawn else {
                logger.warning("shell transport move: refusing \(terminal.id, privacy: .public) — no holder can be started")
                return .refused(reason: TerminalTransportMigrator.holderUnspawnableRefusal)
            }
            spawnHolder = { try await registry.spawn(terminalID: $0, launch: $1) }
            abandonHolder = { await registry.abandon(terminalID: $0, handle: $1) }
        }
        guard let worktree = try? await db.worktrees.getLocal(id: terminal.worktreeID) else {
            logger.warning("shell transport move: refusing \(terminal.id, privacy: .public) — its worktree row could not be read")
            return .refused(reason: Self.shellMoveWorktreeUnreadableRefusal)
        }

        // Taken BEFORE the spawn, so the write below compares against the row
        // as it was when this move decided to act.
        let expectedState = TerminalReplacementSnapshot(terminal: terminal)

        // Minted here rather than inside the write, which is what collapses a
        // prepare-then-record pair into one statement: the replacement shell
        // is launched already carrying the incarnation the row will name.
        let incarnationID = UUID()
        // `TBD_WORKTREE_ID` so `tbd` commands and a hand-launched agent in this
        // shell resolve the right worktree instead of whatever the daemon's own
        // environment carries, and `TBD_TERMINAL_ID` so they resolve the right
        // tab — the same two the recreate-as-shell branch plants, for the same
        // reasons.
        let launchEnv = AgentProcessEnvironment.replacement(
            base: [
                "TBD_WORKTREE_ID": worktree.id.uuidString,
                "TBD_TERMINAL_ID": terminal.id.uuidString,
            ],
            incarnationID: incarnationID)
        let handle: HolderHandle
        do {
            handle = try await spawnHolder(
                terminal.id,
                WorktreeLifecycle.holderLaunch(
                    shellCommand: defaultShell,
                    env: launchEnv,
                    // Nothing sensitive to carry: a shell has no profile and
                    // no resume argv.
                    sensitiveEnv: [:],
                    workingDirectory: worktree.path,
                    cols: TmuxManager.defaultCols,
                    rows: TmuxManager.defaultRows,
                    environment: spawnEnvironment))
        } catch {
            // Not a spawn that failed: a spawn the registry DECLINED because
            // this session already has a holder, which is what the loser of two
            // concurrent moves of one row meets. The winner has moved the row,
            // so the spawn-failure reason's recovery advice would be false in
            // every particular.
            if let registryError = error as? HolderRegistry.Error,
               case .sessionAlreadyRegistered = registryError {
                logger.warning("shell transport move: \(terminal.id, privacy: .public) already has a registered holder — another move won; nothing further was changed")
                return .refused(reason: Self.shellMoveAlreadyMovingRefusal)
            }
            let detail = "\(error)"
            logger.warning("shell transport move: could not start a holder for \(terminal.id, privacy: .public): \(detail, privacy: .public)")
            return .refused(reason: Self.shellMoveSpawnFailedRefusal(
                terminalID: terminal.id, detail: detail))
        }

        do {
            guard try await db.terminals.moveRunningShellToHolder(
                id: terminal.id,
                expectedState: expectedState,
                incarnationID: incarnationID,
                holderPID: handle.holderPID,
                childPID: handle.childPID,
                startedAt: now()) != nil else {
                // A holder and a job no row names would be reclaimable by
                // nothing, so the abandon is not optional. The person keeps
                // whatever the race gave them.
                await abandonHolder(terminal.id, handle)
                logger.warning("shell transport move: the write was refused for \(terminal.id, privacy: .public) — the row changed under the move; the holder was abandoned")
                return .lostTheRace
            }
        } catch {
            await abandonHolder(terminal.id, handle)
            let detail = "\(error)"
            logger.error("shell transport move: started a holder for \(terminal.id, privacy: .public) but could not record the move, so it was abandoned: \(detail, privacy: .public)")
            return .refused(reason: Self.shellMoveWriteFailedRefusal(
                terminalID: terminal.id, detail: detail))
        }
        logger.info("shell transport move: terminal \(terminal.id, privacy: .public) now runs a fresh login shell on the pty holder (holder \(handle.holderPID, privacy: .public), child \(handle.childPID, privacy: .public))")
        return .moved
    }

    /// The refusal a park owes a row no wake may resume, or nil when a wake
    /// may resume it. Every park asks this before it touches a process — and
    /// asks again after re-reading the row under its lock — so all of them
    /// give a shell tab carrying a session id the same answer the wake does.
    static func parkRefusal(for terminal: Terminal) -> HibernateResult? {
        switch terminal.claudeResumeDecision {
        case .resume:
            return nil
        case .noSession:
            return .notEligible(reason: noSessionToParkReason)
        case .notAClaudeTab(let kind):
            return .notEligible(reason: ClaudeResumeDecision.notAClaudeTabReason(kind))
        }
    }

    static let noSessionToParkReason = "No session id to resume later"

    /// The reason a manual hibernate was refused, for the RPC error string.
    private func manualBlockReason(_ terminal: Terminal) -> String {
        if case .notAClaudeTab(let kind) = terminal.claudeResumeDecision {
            return ClaudeResumeDecision.notAClaudeTabReason(kind)
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
    /// (including keep-warm, unlike `manualHibernate`, exactly as the sweep
    /// does) but NOT the idle window or the idle-sweep master switch — see
    /// `HibernationGate.decideForMerge`. A session whose session mod cannot
    /// vouch for its draft is skipped, as the sweep skips it
    /// (`ComposerDraftParkGate`).
    ///
    /// A daemon-internal rail: no RPC carried this, so it writes its own row
    /// with no `method` and the rail-named actor. `AutoHibernateOnMergeCoordinator`
    /// fans out over every terminal in the worktree and most are refused by the
    /// rails above, so — like the idle sweep — the row goes after the gate, at
    /// the moment this rail is actually about to act on a session.
    ///
    public func hibernateForMerge(terminalID: UUID) async -> HibernateResult {
        guard let terminal = try? await db.terminals.get(id: terminalID) else {
            return .notFound
        }
        guard terminal.hibernatedAt == nil else { return .alreadyHibernated }
        // Before the record: a park this rail can never make writes no row.
        if let refusal = await liveTmuxParkRefusal(terminal) { return refusal }
        let decision = HibernationGate.decideForMerge(terminal: terminal)
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
            policy: .merge)
        await actuationLog.appendOutcome(
            confirms: actuationID,
            result: ActuationOutcome.classify(result),
            error: ActuationOutcome.detail(result))
        return result
    }

    /// The reason a merge-park or an idle-sweep park was refused, for
    /// logging/telemetry. Mirrors `manualBlockReason` but maps every
    /// `blockingRail` case — including keep-warm, which merge-park honors but
    /// manual bypasses.
    private static func mergeBlockReason(_ decision: HibernationGate.Decision) -> String {
        switch decision {
        case .notClaudeResumable: return "Not a resumable Claude session"
        case .alreadyHibernated: return "Terminal is already hibernated"
        case .suspended: return "Terminal is suspended"
        case .keepWarm: return "Terminal is pinned keep-warm"
        case .running: return "Session is actively running"
        case .waitingForUser: return "Session is waiting on a permission prompt"
        case .unknownActivity: return "Session state is unknown — the agent is not reporting status"
        case .eligible, .featureDisabled, .notIdleLongEnough: return "Not hibernatable"
        }
    }

    /// Park a session: end its agent process and record the row as parked,
    /// keeping its identity for a wake. The mechanic is the holder park's
    /// (`performHolderHibernate`); this is the part every park shares.
    ///
    /// Singleflighted per-terminal. Refuses a row still on the tmux transport
    /// before anything else, then asks the session mod whether the park may go
    /// ahead; the holder arm re-reads the row under its claim and enforces the
    /// live rail the DB row can't express (transcript-tail validity).
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

        // Before anything else is asked of the row: TBD can neither reach nor
        // stop a session still running in tmux.
        if let refusal = await liveTmuxParkRefusal(terminal) { return refusal }

        // A park exists to be resumed, so it takes only what a wake may
        // resume. The policies that read live rails ask `isClaudeResumable`
        // through their own gates; `.profileSwap` reads none, so this line is
        // what keeps every policy to the same answer.
        if let refusal = Self.parkRefusal(for: terminal) { return refusal }

        // The composer-draft gate, read once and ahead of any process work:
        // the session mod is the park's only guard for an unsent draft, and a
        // skip must leave the session untouched. Every park that gets past it
        // ends Claude by signal.
        let composerDraftStatus = ComposerDraftStatus.read(
            sessionsDir: sessionsDir,
            claudeSessionID: terminal.claudeResumeDecision.resumableSessionID,
            liveIncarnationID: terminal.sessionIncarnationID,
            now: now())
        switch ComposerDraftParkGate.decide(status: composerDraftStatus, policy: policy) {
        case .proceed:
            break
        case .skip(let unconfirmed):
            // The condition outlives this attempt — a session spawned with the
            // feature reads unknown until its mod confirms it, which on a
            // machine where the mod never loads is never — so the idle markers
            // are cleared like every other lasting refusal's, and the next
            // attempt waits out a fresh idle window instead of re-firing every
            // sweep.
            ComposerDraftParkGate.logSkip(terminalID: terminal.id, reason: unconfirmed)
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return .notEligible(reason: ComposerDraftParkGate.skipReason(unconfirmed))
        }

        guard let worktree = try? await db.worktrees.getLocal(id: terminal.worktreeID) else {
            return .notFound
        }
        return await performHolderHibernate(
            terminal: terminal, worktree: worktree, reason: reason, policy: policy)
    }

    /// The answer every park gives a row still on the tmux transport, or nil
    /// for a holder row.
    ///
    /// TBD no longer drives tmux, so it can neither stop such a session nor
    /// keep its identity across a stop. A live row is refused (`.onTmux`)
    /// with the still-running advice, which names the command that ends it; a
    /// row already parked there answers `.alreadyHibernated`. The idle markers
    /// are cleared either way, because the condition outlasts every later
    /// sweep. A tmux row is parked only once its server is positively gone,
    /// and not by this coordinator: see `WorktreeLifecycle.parkLeftoverTmuxRow`.
    private func liveTmuxParkRefusal(_ terminal: Terminal) async -> HibernateResult? {
        guard terminal.transport != .holder else { return nil }
        idleSince[terminal.id] = nil
        pendingKillSince[terminal.id] = nil
        if terminal.isParked { return .alreadyHibernated }
        guard let worktree = try? await db.worktrees.getLocal(id: terminal.worktreeID) else {
            return .notFound
        }
        logger.info("hibernate: refusing \(terminal.id, privacy: .public) — it is live on the tmux transport, which TBD no longer parks")
        return .onTmux(reason: LeftoverTmuxSession.stillRunningRefusal(
            terminalID: terminal.id, server: worktree.tmuxServer))
    }

    func hibernationRefusal(
        terminal: Terminal,
        policy: HibernateEligibilityPolicy
    ) -> HibernateResult? {
        switch policy {
        case .manual:
            guard terminal.hibernatedAt == nil else { return .alreadyHibernated }
            guard terminal.isManuallyHibernatable() else {
                return .notEligible(reason: manualBlockReason(terminal))
            }
            return nil

        case .merge:
            let decision = HibernationGate.decideForMerge(terminal: terminal)
            guard decision == .eligible else {
                return .notEligible(reason: Self.mergeBlockReason(decision))
            }
            return nil

        case let .automatic(enabled, idleTimeout, idleSince):
            let decision = HibernationGate.decide(
                terminal: terminal,
                autoHibernateEnabled: enabled,
                idleTimeout: idleTimeout,
                idleSince: idleSince,
                now: now())
            guard decision == .eligible else {
                return .notEligible(reason: Self.mergeBlockReason(decision))
            }
            return nil

        case .profileSwap:
            // The one refusal this policy keeps. The swap handler routes an
            // already-parked row down the cold path before it ever asks for a
            // park, so reaching here means the row parked between that read
            // and this call — a focus-wake, or the idle sweep, either mid-ladder
            // or freshly complete. This is a refusal to the swap, not a signal
            // to proceed: `holderInPlaceSwapUnderClaim` treats `.alreadyHibernated`
            // as a hard error, records nothing, and never calls
            // `reHomeParkedRow` — it tells the caller to retry, and a retry
            // against a row whose park has by then completed takes the cold
            // path instead. Every other rail is deliberately absent: the
            // handler has already established that this is a resumable Claude
            // session, and refusing a *working* session is precisely what this
            // policy exists not to do.
            guard terminal.hibernatedAt == nil else { return .alreadyHibernated }
            return nil
        }
    }

    /// The park's transcript-tail rail: the refusal a mid-write transcript
    /// earns, or nil when the tail is complete, absent, or the policy does not
    /// honour the rail.
    ///
    /// Killing claude mid-write can leave an unresumable jsonl, so the park
    /// asks this before it touches the process. Named so the holder park and
    /// the test assert one decision rather than two copies of it — and so the
    /// `.profileSwap` bypass is stated once. An unreadable or missing file is
    /// not a refusal: there is nothing there to corrupt.
    static func transcriptTailRefusal(
        transcriptPath: String?,
        policy: HibernateEligibilityPolicy
    ) -> HibernateResult? {
        guard policy.honoursLiveRails else { return nil }
        guard let transcriptPath,
              let body = try? String(contentsOfFile: transcriptPath, encoding: .utf8),
              !HibernationSafetyChecks.isTranscriptTailValid(jsonlBody: body) else {
            return nil
        }
        return .notEligible(reason: "Transcript is mid-write; try again shortly")
    }

    // MARK: - Wake

    /// What a wake of a row still on the tmux transport answers. Nothing is
    /// touched either way, and an `initialPrompt` is not delivered.
    ///
    /// A parked row refuses with `tmuxWakeUnavailableReason`, which names
    /// `tbd terminal migrate`. A live row is running in tmux as far as this
    /// daemon knows — reconcile parks a row once its tmux server is gone — and
    /// this daemon can neither reach nor stop it, so the refusal says so and
    /// how to end it. Both are `.onTmux`, a refusal rather than a failed
    /// start. No probe runs here: reconcile, Check Again and the migration are
    /// where a row's server is looked at.
    private func tmuxWakeRefusal(_ terminal: Terminal) async -> WakeResult {
        if terminal.isParked {
            // `.notice`, not `.error`: a retrying focus-wake reaches this on
            // every attempt, and a state the person can act on is not a daemon
            // fault.
            logger.notice("wake: terminal \(terminal.id, privacy: .public) is parked on the tmux transport; refusing and leaving it parked")
            return .onTmux(
                reason: Self.tmuxWakeUnavailableReason(terminalID: terminal.id))
        }
        guard let worktree = try? await db.worktrees.getLocal(id: terminal.worktreeID) else {
            return .notFound
        }
        logger.notice("wake: terminal \(terminal.id, privacy: .public) is live on the tmux transport; refusing — TBD can no longer reach it")
        return .onTmux(reason: LeftoverTmuxSession.stillRunningRefusal(
            terminalID: terminal.id, server: worktree.tmuxServer))
    }

    /// Resume a parked session: spawn a fresh pty holder running
    /// `claude --resume <sessionID>` (or the Codex resume) for the row, which
    /// keeps its identity. Idempotent: a non-hibernated terminal is a no-op,
    /// and concurrent wakes for the same terminal collapse to one respawn.
    ///
    /// **Only a holder row wakes.** A row on the tmux transport is refused
    /// before anything else about it is asked (`tmuxWakeRefusal`): a parked
    /// one names `tbd terminal migrate` and stays parked, and a live one says
    /// it is still running in tmux. TBD no longer starts sessions on tmux.
    ///
    /// An UNPARKED holder row whose job died is reported (`.sessionGone`) but
    /// not repaired — see `classifyUnparkedHolderWake`, which asks the process
    /// table.
    ///
    /// `condition` limits a wake to the rows its caller chose. A parked row that
    /// no longer meets it answers `.conditionNotMet`. A row that changes after
    /// the check loses the compare-and-set each mechanic makes before it starts
    /// anything.
    public func wake(terminalID: UUID, cols: Int? = nil, rows: Int? = nil, allowDefaultProfileFallback: Bool = false, initialPrompt: String? = nil, condition: SessionRestoreCondition? = nil) async -> WakeResult {
        // Claim synchronously, before the first suspension. Otherwise two wake
        // calls can both read the parked row, then each pass the in-flight check
        // after actor reentrancy lets them interleave. Keep the claim across all
        // early exits so the defer releases lookup failures and successful wakes
        // alike.
        // `performHibernate` is actor-reentrant while it waits for the SIGTERM
        // poll. Once its durable begin transition marks this row parked, a
        // wake must not rotate/clear the row and let hibernation resume against
        // the replacement process. A second wake is refused for the reason
        // above, and an in-place profile swap owns this row from before its
        // park until after its wake: a focus-wake landing in the gap between
        // those halves would un-park the row under the account the swap is
        // moving it off.
        guard !transitionInFlight(terminalID: terminalID) else { return .inFlight }
        wakesInFlight.insert(terminalID)
        defer { wakesInFlight.remove(terminalID) }

        guard let terminal = try? await db.terminals.get(id: terminalID) else {
            return .notFound
        }
        // The backstop for a row still on tmux, asked before anything else
        // about it — its resume plan, its prompt — because none of those can
        // change the answer: TBD starts sessions only on the pty holder, so a
        // tmux row never wakes where it is. Refusing here, before anything is
        // touched, leaves a parked row parked with its session id, so a wake
        // after `tbd terminal migrate` succeeds on the holder.
        if terminal.transport != .holder {
            return await tmuxWakeRefusal(terminal)
        }
        // Wake ANY parked row, not just `hibernatedAt`-marked ones: legacy rows
        // and the reconcile / recreate-window paths may carry only `suspendedAt`.
        // `clearHibernated` nils both columns, so this fully un-parks either.
        guard terminal.isParked else {
            return await classifyUnparkedHolderWake(terminal)
        }
        // Recovery and wake share provider identity; parking a live process
        // continues to use the stricter Claude-only eligibility policy.
        guard let resumePlan = terminal.recoveryResumePlan else {
            if case .notAClaudeTab(let kind) = terminal.claudeResumeDecision {
                return .notAClaudeTab(kind: kind)
            }
            return .noSessionID
        }
        let sessionID = resumePlan.identity.sessionID
        if resumePlan.identity.agentKind == .codex, let initialPrompt, !initialPrompt.isEmpty {
            return .respawnFailed(reason: "Codex wake cannot deliver an initial prompt; resume without a prompt, then send it to the session.")
        }
        let expectedReplacementState = TerminalReplacementSnapshot(terminal: terminal)
        guard let worktree = try? await db.worktrees.getLocal(id: terminal.worktreeID) else {
            return .notFound
        }
        // Asked of the row this call read, after its claim, because anything the
        // caller checked before calling can be stale by now: start admission
        // alone runs between the two. Ahead of the directory check, so a worktree
        // whose archive has already removed its directory answers this and not
        // `.worktreeMissing`.
        if let condition, !condition.isMet(by: terminal, worktreeStatus: worktree.status) {
            logger.info("wake: terminal \(terminal.id, privacy: .public) no longer meets this wake's condition; leaving it as it is")
            return .conditionNotMet
        }
        // Never respawn into a missing directory: the resumed claude would
        // neither find its session (resume is cwd-scoped) nor belong to this
        // worktree. Leave the row parked so a retry after the path is restored
        // can still wake it.
        guard FileManager.default.fileExists(atPath: worktree.path) else {
            logger.error("wake: worktree path missing on disk for terminal \(terminal.id, privacy: .public): \(worktree.path, privacy: .public) — refusing respawn (would fall back to $HOME)")
            return .worktreeMissing(path: worktree.path)
        }
        let config = try? await db.config.get()
        let repo: Repo?
        if let rid = worktree.repoID {
            repo = try? await db.repos.get(id: rid)
        } else {
            repo = nil
        }
        // Inject TBD_WORKTREE_ID + TBD_TERMINAL_ID so notifications and the
        // SessionStart hook attribute to this terminal after the resume rollover.
        var preparedEnv: [String: String] = [
            "TBD_WORKTREE_ID": worktree.id.uuidString,
            "TBD_TERMINAL_ID": terminal.id.uuidString,
        ]
        let spawnCommand: String
        let sensitiveEnv: [String: String]
        let spawnTitle: ClaudeSpawnTitle?
        let overlay: ReplacementSpawnOverlay?
        switch resumePlan {
        case .claude:
            // Honor the exact profile persisted on the terminal (loadByID, not
            // re-resolve) so wake lands on the same account the session used.
            //
            // Pre-wake profile check: if the pinned profile no longer resolves (row
            // deleted, or an .apiKey profile whose keychain secret is gone), the OLD
            // behavior silently fell back to the ambient keychain login — resuming on
            // the WRONG account, which reads to the user as "the session won't wake".
            // Refuse and surface `.profileMissing` so the app can offer an explicit
            // default-profile fallback (mirrors how `.worktreeMissing` fails loudly
            // just above rather than resuming into $HOME). This is BEFORE any
            // spawn, so a refusal changes nothing. Pass
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

            let mergedEnvOverrides = EnvOverrideResolver.merge(
                global: config?.envOverrides,
                repo: repo?.envOverrides,
                profile: resolvedProfile?.envOverrides
            )
            let profileConfigDir = await configDirManager.resolveConfigDir(for: resolvedProfile)
            // The terminal's own plugin folders and settings overlay, kept on its
            // row so every start of its session reapplies them — a wake included.
            // A folder that has gone since is skipped by the builder, with a
            // warning, and the wake goes on: a wake can run with nobody watching.
            let spawnExtras = terminal.claudeSpawnExtras
            // Planned, not written: a wake that adopts a holder still running
            // launches nothing at all, and must leave the running process's overlay
            // alone. Each launch writes the overlay just before it starts
            // (`ReplacementSpawnOverlay.settle`).
            let claudeOverlay = ReplacementSpawnOverlay.plan(
                fallbackModels: resolvedProfile?.fallbackModels,
                sessionKey: terminal.id.uuidString,
                // Repo fragment is file-backed config, read fresh — reapplied on wake.
                repoSettingsJSON: ClaudeHookOverlay.repoSettingsFragment(repoID: repo?.id),
                extraSettingsJSON: spawnExtras?.claudeSettingsOverlay
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
            // Reserved here; confirmed only once the wake has launched a session
            // under it — even when a later step fails, since that session carries
            // the name — and released on every other outcome.
            let claudeTitle = await ClaudeSessionTitle.forSpawn(
                db: db, store: sessionTitles,
                worktreeID: worktree.id, displayName: worktree.displayName,
                terminalID: terminal.id)
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
                profileModel: spawnExtras?.model ?? resolvedProfile?.model,
                profileAwsRegion: resolvedProfile?.awsRegion,
                profileAwsProfile: resolvedProfile?.awsProfile,
                profileConfigDir: profileConfigDir,
                cmd: nil,
                shellFallback: defaultShell,
                settingsOverlayPath: claudeOverlay.path,
                pluginDirPath: PluginDirWriter.pluginDirPath,
                extraPluginDirs: spawnExtras?.pluginDirs ?? [],
                envSettingOverrides: config?.envSettingOverrides ?? [:],
                sessionName: claudeTitle.name,
                // The overlay is written at launch, so its path counts as present.
                fileExists: claudeOverlay.commandFileExists
            )
            // The free-form overrides, with the builder's auth env layered on top
            // so auth wins — the same merge the create path makes.
            sensitiveEnv = mergedEnvOverrides.merging(spawn.sensitiveEnv) { _, builder in builder }
            spawnCommand = spawn.command
            spawnTitle = claudeTitle
            overlay = claudeOverlay

        case .codex:
            do {
                // The row model is lenient on corrupt JSON. Relaunch must read
                // strictly, or a damaged dedicated-home record could silently
                // launch this thread on the shared home.
                let options = try await db.terminals.codexLaunchOptionsForRelaunch(id: terminal.id)
                let executableResolver = codexExecutableResolver
                let homeEnsurer = codexHomeEnsurer
                let preparation: CodexLaunchPreparation = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(with: Result {
                            try CodexLaunchPreparation.prepare(
                                guardedHome: options?.codexHome,
                                executableResolver: executableResolver,
                                sharedHomeEnsurer: homeEnsurer)
                        })
                    }
                }
                spawnCommand = CodexSpawnCommandBuilder.build(
                    initialPrompt: nil, resumeThreadID: sessionID,
                    executablePath: preparation.executablePath,
                    model: options?.model, disabledFeatures: options?.disabledFeatures ?? [])
                preparedEnv["CODEX_HOME"] = preparation.codexHome.path
                sensitiveEnv = GuardedCodexHome.forcingHome(
                    EnvOverrideResolver.merge(global: config?.envOverrides,
                        repo: repo?.envOverrides, profile: nil)
                        .merging(["DISABLE_AUTO_UPDATE": "true"]) { _, forced in forced },
                    preparation, guarded: options?.codexHome != nil)
                spawnTitle = nil
                overlay = nil
            } catch {
                return .respawnFailed(reason: "preparing Codex resume failed: \(error.localizedDescription)")
            }
        }

        let env = preparedEnv
        // Both providers consume the same prepared command. Only Claude
        // carries a title, overlay, and session-mod preparation.
        return await wakeHolderSection(
            terminal: terminal,
            worktree: worktree,
            sessionID: sessionID,
            expectedReplacementState: expectedReplacementState,
            spawnCommand: spawnCommand,
            env: env,
            sensitiveEnv: sensitiveEnv,
            cols: cols,
            rows: rows,
            spawnTitle: spawnTitle,
            overlay: overlay)
    }

    // MARK: - Idle sweep (auto-hibernate)

    /// One pass of the auto-hibernate idle timer, run cheaply on a short cadence
    /// (poll) while the actual kill decision is made against the 30-min idle
    /// window (decide) — the Knative/KEDA poll/decide split.
    ///
    /// For every holder-backed Claude terminal:
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
    ///    instant). `performHibernate` adds the session mod's draft gate and
    ///    the live transcript rail on top.
    public func sweep() async {
        guard let config = try? await db.config.get() else { return }
        guard let terminals = try? await db.terminals.list() else { return }
        let timeout = TimeInterval(max(1, config.hibernateIdleMinutes)) * 60
        let reference = now()

        // Prune markers for terminals that vanished.
        let liveIDs = Set(terminals.map { $0.id })
        idleSince = idleSince.filter { liveIDs.contains($0.key) }
        pendingKillSince = pendingKillSince.filter { liveIDs.contains($0.key) }

        for terminal in terminals {
            // A row still on tmux is never a candidate: every park refuses it
            // (`liveTmuxParkRefusal`), and asking would write a request row and
            // its refusal on every sweep. Its markers are dropped, so nothing
            // is armed for it.
            guard terminal.transport == .holder else {
                idleSince[terminal.id] = nil
                pendingKillSince[terminal.id] = nil
                continue
            }
            let decision = HibernationGate.decide(
                terminal: terminal,
                autoHibernateEnabled: config.autoHibernateEnabled,
                idleTimeout: timeout,
                idleSince: idleSince[terminal.id],
                now: reference
            )

            // A holder row whose session this daemon holds no reader for is
            // not a candidate, however idle it is. `performHolderHibernate`
            // refuses exactly this — the session was never adopted, or its
            // reader is gone — but it only reaches that refusal after the sweep
            // has written a request row and its refused outcome. The condition
            // holds until the daemon adopts the session again, so without this
            // check it costs one request+refusal pair per sweep, forever, for a
            // park that could never have happened.
            //
            // The gate cannot make this call: it is pure, and the registry is
            // only available here. So the sweep asks, and treats the answer the
            // way it treats the `.running` family — reset the idle clock and
            // any armed debounce, write nothing — which restarts the full idle
            // window from the moment a reader is back.
            if decision == .eligible || decision == .notIdleLongEnough,
               await holderHasNoReader(terminalID: terminal.id) {
                logger.debug("hibernate: not arming \(terminal.id, privacy: .public) — the daemon holds no reader for this holder session")
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

            case .featureDisabled, .notClaudeResumable,
                 .alreadyHibernated, .suspended, .keepWarm, .running,
                 .waitingForUser, .unknownActivity:
                // Not at rest (or ineligible): the idle clock and any armed
                // debounce reset so a later settle starts a fresh full window.
                idleSince[terminal.id] = nil
                pendingKillSince[terminal.id] = nil
            }
        }
    }

    // MARK: - Startup Reconciliation

    /// Settle every parked row against what is actually running, once on
    /// daemon startup. It checks BOTH the authoritative `hibernatedAt` and the
    /// legacy `suspendedAt`, so a row parked by either path is reconciled.
    ///
    /// A parked holder row is checked against its holder and child
    /// (`reconcileParkedHolderRow`): a park the last daemon left half-done
    /// over a child that is still running is undone.
    ///
    /// A parked row on the tmux transport is left parked. TBD no longer reads
    /// tmux, so it has no evidence to un-park one with, and such a row wakes
    /// only after `tbd terminal migrate` moves it to the holder. The one
    /// exception is an earlier build's exit stamp on a tab that is not
    /// Claude's, which is lifted (`liftEarlierBuildsExitStamp`).
    public func reconcileOnStartup() async {
        guard let allTerminals = try? await db.terminals.list() else { return }

        for terminal in allTerminals where terminal.isParked {
            if terminal.transport == .holder {
                await reconcileParkedHolderRow(terminal)
            } else if terminal.isExitStamped, !terminal.isClaudeTab {
                await liftEarlierBuildsExitStamp(terminal)
            }
        }
    }

    /// Lift an exit stamp an earlier build left on a tab that is not Claude's.
    ///
    /// Builds before `stampSessionExited` asked the tab's kind stamped a shell
    /// tab whose hand-started Claude exited: that Claude carries TBD's hook, so
    /// its `SessionEnd` reaches the row. This build's wake refuses such a tab
    /// (`Terminal.claudeResumeDecision`) and the app never auto-wakes
    /// `.exited`, so nothing else would lift the stamp, and the tab would sit
    /// behind its frozen snapshot until it was closed. The stamp stopped
    /// nothing — the pane's shell stays alive under it — so lifting it leaves
    /// the row as this build would have: unstamped, the live shell it is. No
    /// process is touched. The row is then a live shell row on tmux, which
    /// reconcile treats like any other: once its tmux server is gone the tab
    /// goes, rather than staying parked behind a snapshot nothing can wake.
    ///
    /// tmux rows only. `stampSessionExited` has never stamped a holder row,
    /// and a parked holder row's arm (`reconcileParkedHolderRow`) is the one
    /// that verifies its child process, so it keeps answering for those.
    ///
    /// It runs on every pass, like `reconcileParkedHolderRow`, and after the
    /// first one it finds nothing: this build never writes the stamp it lifts.
    private func liftEarlierBuildsExitStamp(_ terminal: Terminal) async {
        let kind = terminal.kind?.rawValue ?? "unrecorded"
        do {
            if try await db.terminals.clearSessionExitStamp(id: terminal.id, at: now()) {
                logger.info("startup: lifted an earlier build's exit stamp from \(kind, privacy: .public) terminal \(terminal.id, privacy: .public) — no wake resumes Claude in it, and its shell was never stopped")
            }
        } catch {
            logger.warning("startup: failed to lift the exit stamp from \(kind, privacy: .public) terminal \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    /// Announce the activity columns `terminalID`'s row holds, read back after
    /// a commit that changed them with no park or wake broadcast to carry
    /// them: a park that rolled back before its broadcast, whose un-park reset
    /// the intent's `.idle` to `.unknown`.
    func broadcastActivityColumns(terminalID: UUID) async {
        guard let row = try? await db.terminals.get(id: terminalID) else { return }
        subscriptions?.broadcast(delta: .terminalActivityUpdated(TerminalActivityDelta(columnsOf: row)))
    }

    /// `suspendedSnapshot`/`hibernateReason` ride hibernate broadcasts (and
    /// keep-warm re-broadcasts on a parked row) because the app applies this
    /// delta to its cached row IN PLACE: the parked view materializes on the
    /// `hibernated` flip and reads the row's snapshot once, and wake-on-focus
    /// reads the row's reason — a later refetch is too late. Wake broadcasts
    /// leave them nil.
    ///
    /// `isParkOrWake` is false only for a re-broadcast that changes neither
    /// (`setKeepWarm`); every other caller parks or wakes the row, which drops
    /// a holder row's Program Status entries (`dropProgramStatus`).
    ///
    /// A park or a wake also carries the row's session incarnation and its
    /// activity columns, read back after the commit: both mint an incarnation,
    /// and the app forwards Program Status reports under its cached row's; a
    /// park writes `.idle` and a wake resets the column to `.unknown`, which
    /// nothing else announces.
    func broadcastHibernation(
        terminal: Terminal, hibernated: Bool, keepWarm: Bool,
        tmuxWindowID: String? = nil, tmuxPaneID: String? = nil,
        suspendedSnapshot: String? = nil, hibernateReason: HibernateReason? = nil,
        isParkOrWake: Bool = true
    ) async {
        // Only holder sessions carry Program Status entries; a park or wake of
        // any other row has nothing to drop and does not hop to the store.
        if isParkOrWake, terminal.transport == .holder {
            await dropProgramStatus(terminalID: terminal.id, hibernated: hibernated)
        }
        let committed = isParkOrWake ? (try? await db.terminals.get(id: terminal.id)) : nil
        subscriptions?.broadcast(delta: .terminalHibernationChanged(TerminalHibernationDelta(
            terminalID: terminal.id,
            worktreeID: terminal.worktreeID,
            hibernated: hibernated,
            keepWarm: keepWarm,
            tmuxWindowID: tmuxWindowID,
            tmuxPaneID: tmuxPaneID,
            suspendedSnapshot: suspendedSnapshot,
            hibernateReason: hibernateReason,
            sessionIncarnationID: committed?.sessionIncarnationID,
            activity: committed.map(TerminalActivityDelta.init(columnsOf:))
        )))
    }

    /// Drops the terminal's Program Status entries on a park or a wake (spec
    /// "Liveness"). Every park and wake broadcast funnels through
    /// `broadcastHibernation`, so this is the one place both are seen.
    ///
    /// A park drops unconditionally and refuses every report observed before
    /// it, so a report already on its way cannot land after the drop. A wake
    /// drops only entries whose incarnation differs from the row's current
    /// one: by the time a wake broadcasts, the replacement session is live and
    /// what it has already reported is its current state.
    ///
    /// Awaited, not launched as a task: a park's drop sets the store's
    /// watermark at the instant it runs, so a drop that ran after a later wake
    /// would refuse the woken session's first reports. Every park reaches here
    /// with `hibernatesInFlight` still claimed, and wake refuses a row with a
    /// park in flight, so awaiting the drop orders it before any wake.
    ///
    /// A keep-warm toggle (`setKeepWarm`) re-broadcasts the row's current
    /// state without parking or waking it, so it passes `isParkOrWake: false`
    /// and drops nothing.
    private func dropProgramStatus(terminalID: UUID, hibernated: Bool) async {
        guard let programStatus else { return }
        if hibernated {
            await programStatus.drop(terminalID: terminalID, reason: .parked)
        } else {
            await programStatus.dropIfIncarnationChanged(terminalID: terminalID, reason: .woke)
        }
    }
}
