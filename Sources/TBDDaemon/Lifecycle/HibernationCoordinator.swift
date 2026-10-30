import Foundation
import TBDShared
import TBDKernel
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "Hibernation")

public enum HibernateResult: Equatable, Sendable {
    case ok
    case alreadyHibernated
    case notEligible(reason: String)
    case notFound
}

/// Which rails a park attempt is judged by, and the config facts those rails
/// need. Transport is not among them: the park mechanic exists on every
/// transport, so what differs between a holder row and a tmux row is how the
/// park is carried out, never whether it is allowed.
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
    /// (`hibernationRefusal`) refuses it, and the tmux arm of the same action
    /// has never honoured any of them.
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
    /// **What it reaches.** The transcript-tail rail both transports share
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
    /// tmux answered about a reachable server and the pane is not on it — it,
    /// or its window, is gone. A server that could not be REACHED is not this
    /// case and never becomes a disagreement; it is `WakeResult.paneUnreadable`.
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
    /// `classifyUnparkedWake` for why repair is a separate change.
    case sessionGone(paneID: String, detail: UnparkedPaneDisagreement)
    /// The row is NOT parked and its pane could not be READ: no tmux server
    /// answered on the socket the daemon resolved. Distinct from `.sessionGone`
    /// because nothing disagreed — the question was never answered — and
    /// distinct from `.notHibernated` because the caller must learn the check
    /// failed rather than be told "already awake, nothing to do". Nothing was
    /// woken and any `initialPrompt` was NOT delivered, so an autonomous caller
    /// has to know it should retry rather than assume delivery.
    case paneUnreadable(paneID: String, server: String)
    case notFound        // terminal/worktree DB row missing — NOT tmux failures
    case noSessionID
    /// The parked row names a session, but its tab is a shell or Codex tab
    /// (`Terminal.claudeResumeDecision`). Refused before anything is touched,
    /// exactly as a shell tab with no session id is: nothing is respawned and
    /// the row stays as it was.
    case notAClaudeTab(kind: TerminalKind)
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
    /// The row is exit-stamped (`.exited`) and a process other than the pane's
    /// own shell owns the pane's foreground process group. Wake is
    /// `respawn-window -k`, which would kill it. Nothing was respawned and the
    /// row stays exit-stamped, so a retry once the process finishes still
    /// wakes. Carries the foreground pid so the message can name it.
    case paneBusy(pid: Int32)
}

/// What moving a RUNNING session with nothing to resume onto the pty holder
/// came to — `HibernationCoordinator.moveRunningShellToHolder`.
///
/// Four cases, and the three that did not move mean different things. A lost
/// compare-and-set is a race whose other side already gave the person a
/// working session and a busy pane is a state they can change, so both are
/// reported as skips; a refusal names a fact that has to change first.
enum ShellTransportMoveOutcome: Sendable, Equatable {
    /// The row reads holder-backed and names the processes of a fresh login
    /// shell running in the same working directory.
    case moved
    /// The write found the row had changed under the move, so nothing was
    /// written and the holder that had been started was abandoned.
    case lostTheRace
    /// Something other than the pane's own shell is running in the session's
    /// terminal, and moving the session would stop it. Nothing was touched;
    /// the person finishes or stops that process and runs the migration again.
    ///
    /// Distinct from `refused` because of where it lands in a fleet run's
    /// report: this is the "change this and try again" column, and the whole
    /// point of telling someone is that they can.
    case busy(reason: String)
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
/// passes no oracle — the registry-cannot-spawn refusal — plus
/// `TerminalTransportMigratorTests`'
/// `aRunningShellWhoseHolderCannotBeStartedIsRefused`, which runs the
/// production operations and fails inside the real `registry.spawn`, and the
/// two `KillWindowSiblingSitesPaneOwnershipTests` shell-move cases, which reach
/// the pane consult and the kill with no oracle wired. There is no live-target
/// coverage of this move; the gap is the spawn itself succeeding.
struct HolderSpawnOracle: Sendable {
    let spawn: @Sendable (UUID, HolderLaunchRequest) async throws -> HolderHandle
    let abandon: @Sendable (UUID, HolderHandle) async -> Void
}

/// Owns session PARKING — the single unified "park a Claude session" feature
/// (the former Suspend and Hibernate features merged into one). It gracefully
/// terminates a Claude process while KEEPING its tmux window alive (the shell
/// stays), and wakes it later by respawning `claude --resume <id>` in that same
/// window.
///
/// The park sequence:
///   1. Ask the session mod whether the park may go ahead
///      (`ComposerDraftParkGate`): it is the only guard for text typed into
///      the composer and not sent.
///   2. Capture an ANSI pane snapshot so the app can show the frozen pane as
///      a backdrop while parked / waking. It is shown, never judged.
///   3. Enforce the live rail the DB row can't express: transcript-tail
///      validity.
///   4. End Claude by SIGTERM to its process (`TmuxSignalEnding`), so Claude
///      flushes its transcript, shuts down MCP children, fires Stop hooks and
///      lets the session mod make its final save; poll up to ~3s for it to
///      leave. Nothing is typed into the pane.
///   5. Either way, `respawn-window` the pane to a bare shell (the window/pane
///      and its scrollback survive, freeing the claude process + its RSS).
///      We do NOT kill the window.
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
    /// spawn two `claude --resume` processes into the same window.
    // Not private: `HibernationCoordinator+Holder` claims both.
    var wakesInFlight: Set<UUID> = []

    /// Invoked after EVERY `ensureServer` on the wake-recreate path (whether or
    /// not a server was actually created — the downstream control-mode
    /// `enableIfGated` is idempotent, so firing on an existing server is a
    /// no-op). Daemon.swift wires this to the control-mode bridge so a freshly
    /// recreated server gets the same gated `tmux -CC` connection as every
    /// other `ensureServer()` call site.
    private var onServerCreated: (@Sendable (String) async -> Void)?

    /// Terminal ids with an in-flight hibernate, so a manual "Hibernate now"
    /// racing the idle sweep (or two sweeps) can't respawn-to-shell twice.
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

    /// Verify-exit poll after the tmux park's SIGTERM: how many times we
    /// re-check the pane's current command, and how long we wait between checks.
    /// 15 × 200ms ≈ 3s. If claude is still the pane's program after the whole
    /// window, `respawn-window -k` ends it. The interval also paces every poll
    /// of the holder park's ladder.
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
    /// children, let the session mod make its final save, and flush the
    /// transcript it is mid-write on. Every holder park starts at this rung,
    /// so a session that is shutting down cleanly and slowly gets five seconds
    /// before anything is killed. Injectable on the same terms as the pair
    /// above.
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

    /// Called by the tmux park with the terminal's id once it has read the row
    /// and passed every rail it checks before the worktree's server lock, just
    /// before it waits for that lock. A **test seam only** — production leaves
    /// it nil — so a test can learn that a park is queued behind a lock the
    /// test holds, or hold a park at that point while another replacement takes
    /// the lock first. Synchronous, so a test may block the park's thread here.
    var tmuxParkWillAwaitServerLock: (@Sendable (UUID) -> Void)?

    /// Whether a recorded holder pid is still a live `TBDHolder` — the
    /// holder half of `HolderChildDisposition.sessionHasEnded`. Production uses the shared
    /// `HolderSpawner.isLiveHolder`; tests replace it through
    /// `setHolderProcessIsLive`, because a fixture's holder pid is a number
    /// the real kernel answers for.
    var holderProcessIsLive: @Sendable (Int32) -> Bool = { HolderSpawner.isLiveHolder(pid: $0) }

    /// How the holder park observes and ends a child process, and how the
    /// tmux park signals the Claude process. Injected so a test can state "the
    /// job ignored SIGTERM" in one line instead of arranging a real one, and
    /// can see which pid a park signalled.
    let signaller: any ProcessSignaller

    /// Reads a tmux pane's foreground process group from the process table.
    /// Used by the exit-stamped wake guard, and by the tmux park to find the
    /// Claude process it signals. Injected so a test can state "the pane's
    /// shell is idle", "something is running in it" or "Claude is this pid"
    /// without arranging a real process.
    private let paneProcessInspector: any PaneProcessInspecting

    /// The daemon's actuation record. The idle sweep and the merge-park rail
    /// are daemon-internal actuation sites — they bypass the router, so each
    /// logs its own row. Deliberately NOT logged inside `performHibernate`: the
    /// RPC handlers call that same method after writing their own row, and a
    /// row there would double-count every manual park.
    private let actuationLog: ActuationLog

    /// The Program Status Protocol (OSC 7501) store. A park or a wake drops the
    /// terminal's entries (spec "Liveness"): a parked session's program is
    /// gone, and a SIGKILLed one never sent `state=clear`. Nil in tests that
    /// do not exercise it.
    private let programStatus: ProgramStatusStore?

    /// What a person is told when a tmux-backed session cannot be woken because
    /// tmux cannot serve. Names the gesture that moves the session, **and the
    /// session**: this string is the entire product of the backstop — it exists
    /// to hand a stranded person a command they can run — so the id is
    /// interpolated rather than left as a placeholder to be looked up.
    static func tmuxWakeUnavailableReason(terminalID: UUID) -> String {
        "This session still runs on the tmux transport, and tmux is not available here. "
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
        exitPollAttempts: Int = 15,
        exitPollInterval: Duration = .milliseconds(200),
        holderTerminateAttempts: Int = 25,
        holderEscalationAttempts: Int = 5,
        clock: any Clock<Duration> = ContinuousClock(),
        signaller: any ProcessSignaller = ProductionProcessSignaller(),
        paneProcessInspector: any PaneProcessInspecting = ProductionPaneProcessInspector(),
        sessionsDir: URL = TBDConstants.sessionsDir(),
        sessionTitles: ClaudeSessionTitleStore,
        actuationLog: ActuationLog,
        programStatus: ProgramStatusStore? = nil
    ) {
        self.db = db
        self.tmux = tmux
        self.modelProfileResolver = modelProfileResolver
        self.subscriptions = subscriptions
        self.configDirManager = configDirManager
        self.now = now
        self.exitPollAttempts = exitPollAttempts
        self.exitPollInterval = exitPollInterval
        self.holderTerminateAttempts = holderTerminateAttempts
        self.holderEscalationAttempts = holderEscalationAttempts
        self.clock = clock
        self.signaller = signaller
        self.paneProcessInspector = paneProcessInspector
        self.sessionsDir = sessionsDir
        self.sessionTitles = sessionTitles
        self.actuationLog = actuationLog
        self.programStatus = programStatus
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

    /// Wire the tmux park's pre-lock seam. Tests only — see
    /// `tmuxParkWillAwaitServerLock`.
    func setTmuxParkWillAwaitServerLock(_ hook: (@Sendable (UUID) -> Void)?) {
        tmuxParkWillAwaitServerLock = hook
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
    /// It does not check the transport. The park mechanic exists on both, and
    /// `performHibernate` already routes a holder row to the holder arm; what
    /// the swap handler decides is which rows it calls this for — and today it
    /// calls this for **holder rows only**, because `handleTerminalSwapProfile`
    /// branches on `transport == .holder` before reaching the arm that calls
    /// here. See `honoursLiveRails`.
    func parkForProfileSwap(terminalID: UUID) async -> HibernateResult {
        guard let terminal = try? await db.terminals.get(id: terminalID) else {
            return .notFound
        }
        return await performHibernate(
            terminal: terminal, reason: .auto, policy: .profileSwap)
    }

    /// Park a session because it is being moved from the tmux transport to the
    /// pty holder in place, same row and same session id.
    ///
    /// The park half of `TerminalTransportMigrator.migrate`. `.auto` as the
    /// reason, for the same purpose as the profile swap's: a daemon that dies
    /// between this park and the wake that follows leaves a row the next
    /// focus-wake heals, where a manual park is excluded from wake-on-focus
    /// and would sit there until somebody woke it by hand.
    ///
    /// **`.manual` as the policy, which is the opposite of the swap's choice
    /// and is the point.** `.profileSwap` stops honouring the rails that read
    /// live state because switching accounts should interrupt regardless; a
    /// migration honours every one, so a session mid-turn, at a permission
    /// prompt or mid-write on its transcript is skipped with the rail's reason
    /// and a person runs the migration again. Like any manual park it does not
    /// wait for the session mod to vouch for an unsent draft
    /// (`ComposerDraftParkGate`). No new policy case is added.
    /// See `docs/specs/2026-10-11-holder-transport-migration-design.md`,
    /// "The park honours every live rail", and
    /// `docs/specs/2026-10-24-mod-only-park-guard-design.md`, "Which parks go
    /// ahead", for how a manual park treats an unsent draft.
    func parkForTransportMigration(terminalID: UUID) async -> HibernateResult {
        guard let terminal = try? await db.terminals.get(id: terminalID) else {
            return .notFound
        }
        return await performHibernate(
            terminal: terminal, reason: .auto, policy: .manual)
    }

    /// The pid of whatever is running in a tmux pane that is **not** the
    /// pane's own shell, or nil when nothing is and nil when the question
    /// could not be asked.
    ///
    /// Asked of the process table, never the rendered screen. The pane's own
    /// pid answering means an idle interactive shell; a different pid means
    /// something is running under it. An unreadable pid answers nil: a pane
    /// tmux cannot answer for is not evidence that a process is there, and
    /// refusing on it would strand the row behind a probe failure with no way
    /// back.
    ///
    /// The one place this question is composed, for the two rails that ask it —
    /// the exit-stamped guard below and the running-shell move's own. Copying
    /// the body beside a second caller is how the unreadable-pid stance and the
    /// `> 0` guard get quietly dropped from one of them.
    ///
    /// tmux-only by construction: a holder row's pane id is the empty string
    /// and names no tmux coordinate, so each caller establishes that first.
    func paneForegroundPIDOtherThanItsShell(
        server: String, paneID: String
    ) async -> Int32? {
        guard let panePIDString = try? await tmux.panePID(server: server, paneID: paneID),
              let panePID = Int32(panePIDString), panePID > 0,
              let foregroundPID = paneProcessInspector.paneForegroundPID(panePID: panePID),
              foregroundPID != panePID else { return nil }
        return foregroundPID
    }

    /// The pid of whatever is running in an **exit-stamped** row's pane, or
    /// nil when nothing is, when the row is not exit-stamped, or when the
    /// question could not be asked.
    ///
    /// `.exited` parks the row while the pane's SHELL stays alive and usable —
    /// that is the whole point of the stamp — so the pane is the one the person
    /// was sitting in when the agent left, and they may have started something
    /// in it since. Any action that would destroy that pane has to ask first.
    func exitStampedPaneBusyPID(
        terminal: Terminal, server: String, paneID: String
    ) async -> Int32? {
        guard terminal.isExitStamped, terminal.transport != .holder else { return nil }
        return await paneForegroundPIDOtherThanItsShell(server: server, paneID: paneID)
    }

    /// The refusal a transport migration owes a parked row whose pane still
    /// has something running in it, or nil when the rewrite may proceed.
    ///
    /// The migration blanks the row's tmux coordinates, after which nothing
    /// names that window and the reconcile pass kills it as untracked — so for
    /// an exit-stamped row the migration would destroy whatever the person
    /// started in the pane their agent left behind. This is the same question
    /// `wake` asks before its `respawn-window -k`, with the same refusal text,
    /// and it resolves the server itself because the migrator holds the row
    /// rather than the worktree.
    func transportMigrationPaneBusyRefusal(terminal: Terminal) async -> String? {
        guard terminal.isExitStamped, terminal.transport != .holder else { return nil }
        guard let worktree = try? await db.worktrees.getLocal(id: terminal.worktreeID) else {
            return nil
        }
        guard let busyPID = await exitStampedPaneBusyPID(
            terminal: terminal,
            server: worktree.tmuxServer,
            paneID: terminal.tmuxPaneID) else { return nil }
        logger.info("transport migration: exit-stamped terminal \(terminal.id, privacy: .public) has foreground pid \(busyPID, privacy: .public) in its pane — refusing to move it rather than orphaning that window")
        return Self.paneBusyRefusal(pid: busyPID)
    }

    /// Retire the tmux window a parked row leaves behind when its transport is
    /// rewritten to the holder.
    ///
    /// The tmux park keeps the window and respawns it to a bare login shell,
    /// which is what makes a parked tab wakeable in place. Once the row is
    /// holder-backed that window belongs to nobody: the row no longer names it,
    /// and one dangling window and shell per migrated session is a fleet run's
    /// worth of residue. So the migration retires it, and the reconcile pass's
    /// untracked-window sweep is the backstop rather than the mechanism.
    ///
    /// Must be called with a `terminal` that still carries the PRE-rewrite
    /// coordinates, and only once the rewrite has landed — a window killed for
    /// a row still recorded on tmux would be a tab the person loses for
    /// nothing.
    ///
    /// Best-effort and never reported upward: the session is already on the
    /// holder, and `paneOwnership` refuses outright if the coordinate has been
    /// recycled, so the one failure this can have is leaving the window for the
    /// sweep.
    func retireTmuxWindowAfterTransportMigration(terminal: Terminal) async {
        guard !terminal.tmuxWindowID.isEmpty,
              let worktree = try? await db.worktrees.getLocal(id: terminal.worktreeID) else {
            return
        }
        let server = worktree.tmuxServer
        let ownership = await tmux.paneOwnership(
            terminalID: terminal.id, server: server, paneID: terminal.tmuxPaneID)
        guard ownership.permitsTeardown else {
            logger.warning("transport migration: leaving window \(terminal.tmuxWindowID, privacy: .public) untouched for terminal \(terminal.id, privacy: .public) — \(ownership.refusalDetail ?? "", privacy: .public)")
            return
        }
        do {
            try await tmux.killWindow(server: server, windowID: terminal.tmuxWindowID)
            logger.info("transport migration: retired tmux window \(terminal.tmuxWindowID, privacy: .public) for terminal \(terminal.id, privacy: .public)")
        } catch {
            logger.warning("transport migration: could not retire tmux window \(terminal.tmuxWindowID, privacy: .public) for terminal \(terminal.id, privacy: .public); the reconcile pass will: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Moving a running session that has nothing to resume

    /// The refusal when this session's worktree cannot give the move a local
    /// working directory.
    ///
    /// Two readings, and the wording has to carry both, because `getLocal`
    /// answers nil for each: a row that could not be read at all, and a row
    /// that is perfectly readable and REMOTE — a remote worktree has no
    /// filesystem path and no tmux server, so there is nowhere on this machine
    /// to start a replacement shell. Saying only "could not be read" would
    /// report the ordinary second case as a database fault.
    static let shellMoveWorktreeUnreadableRefusal =
        "This session's worktree gives TBD no local directory to start a replacement shell in — "
        + "it is a remote worktree, or its row could not be read; nothing was changed."

    /// The skip when something other than the pane's own shell is running in
    /// the session's terminal.
    ///
    /// Worded like `paneBusyRefusal`: it names the state, and it names the
    /// two moves the person has. Not a refusal — this is the column of a
    /// fleet run's report a person can act on.
    static func shellMovePaneBusyRefusal(pid: Int32) -> String {
        "Something other than this session's own shell is running in its terminal (pid \(pid)), "
        + "and moving the session would stop it. Finish or stop that process and run the "
        + "migration again."
    }

    /// The refusal when the pane the row names cannot be proven to still be
    /// this terminal's. Carries `PaneOwnership.refusalDetail`, so the person
    /// reads the same fact every other teardown-by-coordinate site reports.
    static func shellMovePaneUnverifiedRefusal(detail: String) -> String {
        "This session was not moved because \(detail). Stopping its program would have risked "
        + "destroying another terminal's window, so nothing was changed."
    }

    /// The refusal when tmux would not kill the window. The program is
    /// presumed still running, so nothing was started beside it.
    static func shellMoveKillFailedRefusal(detail: String) -> String {
        "This session's tmux window could not be stopped (\(detail)), so it was not moved and "
        + "nothing was changed."
    }

    /// The refusal when the replacement shell could not be started. Says what
    /// state the session is in, because its program is already gone.
    static func shellMoveSpawnFailedRefusal(detail: String) -> String {
        "This session's program was stopped, but starting a holder for its replacement shell "
        + "failed (\(detail)). The session still reads as running on tmux with its window gone, "
        + "which the tab's window-died recovery repairs; retry the move after that."
    }

    /// The refusal the loser of two concurrent moves of one row meets: a holder
    /// is already registered for this session, so the winner has started its
    /// replacement shell.
    ///
    /// Its own reason rather than the spawn-failure one, whose recovery advice
    /// — the session reads as running on tmux with its window gone, and the
    /// tab's window-died recovery repairs it — describes a row that was not
    /// moved. The winner has already moved this one, so that advice would be
    /// false in every particular.
    static let shellMoveAlreadyMovingRefusal =
        "Another move of this session is already running and has started its replacement shell "
        + "on the pty holder, so this one changed nothing further."

    /// The refusal when the one guarded write threw. The holder started for
    /// the move has been abandoned, so no process outlives the row.
    static func shellMoveWriteFailedRefusal(detail: String) -> String {
        "This session's program was stopped and a replacement shell was started, but the move "
        + "could not be recorded (\(detail)), so that shell was stopped again. The session still "
        + "reads as running on tmux with its window gone, which the tab's window-died recovery "
        + "repairs."
    }

    /// Move a RUNNING session that has no conversation to resume onto the pty
    /// holder: stop its program, start a fresh login shell on a holder in the
    /// same working directory, and record the move in one guarded write.
    ///
    /// **Reached only by shells.** `TransportMigrationEligibility` turns away
    /// every other row that names no conversation — a Codex tab, a Claude tab
    /// whose session has not begun, a hook tab of either kind — each with its
    /// own reason, so nothing here has to guess what a tab was for.
    ///
    /// **Four steps, and the order is the contract.** Refuse early what cannot
    /// be done; kill the tmux window under the pane-ownership guard and the
    /// busy rail; spawn the holder carrying a freshly minted incarnation; write
    /// once. Killing before
    /// the write is the opposite of the parked path's order and is safe for a
    /// different reason: the write is a compare-and-set, so a recreate that
    /// notices the dead window first rotates the row's incarnation and this
    /// write finds its snapshot stale. Both outcomes are consistent, and
    /// nothing can leave a row naming a transport its live process is not on.
    ///
    /// **There is nothing to park.** A park exists to preserve a conversation
    /// across a respawn, and this row names none — which is exactly why
    /// `performHibernate` refuses it ("No session id to resume later") and why
    /// this path exists at all. The kill IS the stop.
    ///
    /// **And the stop is why there is a busy rail here.** A shell fires no
    /// hooks, so its activity state is never written and the eligibility rails
    /// that skip a busy session cannot fire for one. The process table answers
    /// instead, and a pane running something other than its own shell is left
    /// alone and named.
    ///
    /// Every failure lands the session in one of two states and no third: the
    /// row untouched with its program still running, or the row untouched with
    /// its window dead — the ordinary window-died state the app's recovery
    /// banner already owns, and which `handleTerminalRecreateWindow` can still
    /// repair precisely because the row has not been rewritten.
    /// See `docs/specs/2026-10-11-holder-transport-migration-design.md`.
    func moveRunningShellToHolder(terminal: Terminal) async -> ShellTransportMoveOutcome {
        // Before anything is touched. A session whose holder cannot be started
        // must keep the program it has rather than lose it to a move that
        // could never finish.
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

        // Taken BEFORE the kill, so the write below compares against the row
        // as it was when this move decided to act.
        let expectedState = TerminalReplacementSnapshot(terminal: terminal)

        // The pane-ownership guard every teardown by DB-recorded coordinate
        // goes through. A tmux server restart resets window and pane
        // numbering, and several worktrees of one repo share a server, so this
        // row's coordinate can collide with an unrelated live terminal's. A
        // pane that names a different terminal — or a consultation that could
        // not be run at all, which is "we do not know" rather than "gone" —
        // refuses, and nothing is written.
        let server = worktree.tmuxServer
        let ownership = await tmux.paneOwnership(
            terminalID: terminal.id, server: server, paneID: terminal.tmuxPaneID)
        guard ownership.permitsTeardown else {
            let detail = ownership.refusalDetail ?? "its pane could not be verified"
            logger.warning("shell transport move: refusing \(terminal.id, privacy: .public) — \(detail, privacy: .public)")
            return .refused(reason: Self.shellMovePaneUnverifiedRefusal(detail: detail))
        }

        // The busy rail, and the only one a shell can have. A shell fires no
        // hooks, so nothing ever writes its activity state and the row reads
        // `.unknown` for life — which means the eligibility rails that skip a
        // *busy* session can never fire for one. Ask the process table the same
        // question the exit-stamped guard asks: is the pane's foreground
        // process its own shell? A different pid is something the person
        // started, and a fleet-wide run is precisely the case where they did
        // not choose this tab. An unreadable pid proceeds, exactly as it does
        // for the wake: a pane tmux cannot answer for is not evidence that a
        // process is there.
        if let busyPID = await paneForegroundPIDOtherThanItsShell(
            server: server, paneID: terminal.tmuxPaneID) {
            logger.info("shell transport move: terminal \(terminal.id, privacy: .public) has foreground pid \(busyPID, privacy: .public) in its pane — leaving it alone rather than stopping it")
            return .busy(reason: Self.shellMovePaneBusyRefusal(pid: busyPID))
        }

        // The parity guard its sibling retire has
        // (`retireTmuxWindowAfterTransportMigration`). No reachable row shape
        // has `transport == .tmux` with blank coordinates today, but
        // `kill-window -t ''` on a server several worktrees share is not a
        // no-op, and a row that names no window has nothing to stop.
        if terminal.tmuxWindowID.isEmpty {
            logger.info("shell transport move: terminal \(terminal.id, privacy: .public) names no tmux window, so there is nothing to stop; continuing to the replacement shell")
        } else {
            do {
                try await tmux.killWindow(server: server, windowID: terminal.tmuxWindowID)
            } catch {
                // A window that is already gone is not a failure to stop anything:
                // `PaneOwnership.owned` covers "pane gone, server positively
                // absent" on purpose, so a row whose window died before the person
                // reached for this gesture arrives here and must not be refused
                // with a tmux error about a program that no longer exists. Only
                // tmux's own positive "no such window" counts; `.alive` is a
                // program still running, and `.unknown` is "we do not know", which
                // is a refusal at every site in this family.
                let detail = "\(error)"
                switch await tmux.probeWindow(server: server, windowID: terminal.tmuxWindowID) {
                case .absent:
                    logger.info("shell transport move: the window of \(terminal.id, privacy: .public) was already gone (\(detail, privacy: .public)); continuing to the replacement shell")
                case .alive, .unknown:
                    // The program is presumed still running, so nothing is started
                    // beside it: two live programs for one row is the one state
                    // this path must never produce.
                    logger.warning("shell transport move: could not stop the window of \(terminal.id, privacy: .public): \(detail, privacy: .public)")
                    return .refused(reason: Self.shellMoveKillFailedRefusal(detail: detail))
                }
            }
        }

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
            return .refused(reason: Self.shellMoveSpawnFailedRefusal(detail: detail))
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
            return .refused(reason: Self.shellMoveWriteFailedRefusal(detail: detail))
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

    /// The one refusal text for an exit-stamped row whose pane is busy, so the
    /// CLI, the app and the actuation record all name the same fact and the
    /// same two ways out. Named here rather than at each call site so every
    /// surface reports one wording.
    static func paneBusyRefusal(pid: Int32) -> String {
        "This session's agent process exited, but something is still running in its terminal "
        + "(pid \(pid)), and waking would replace that shell and kill it. Finish or stop that "
        + "process and retry, or wake the session from the terminal itself."
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

    /// Gracefully terminate the pane's Claude and swap the pane to a bare shell
    /// via `respawn-window` (window + tab survive). Marks the row hibernated.
    ///
    /// Singleflighted per-terminal, asks the session mod whether the park may
    /// go ahead, and re-verifies the live disk rail (transcript-tail validity)
    /// that the DB row can't express. After the kill it verifies the claude
    /// process is gone and the pane's shell survived, and logs any orphaned
    /// claude children.
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

        // A park exists to be resumed, so it takes only what a wake may
        // resume. The policies that read live rails ask `isClaudeResumable`
        // through their own gates; `.profileSwap` reads none, so this line is
        // what keeps every policy to the same answer.
        if let refusal = Self.parkRefusal(for: terminal) { return refusal }

        // The composer-draft gate, read once and ahead of any transport work:
        // the session mod is the park's only guard for an unsent draft, and a
        // skip must leave the session untouched. Every park that gets past it
        // ends Claude by signal, on either transport.
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
        // The two transports diverge here, ahead of the first tmux call. A
        // holder-backed row has no tmux server to lock and no pane to capture:
        // its park signals the holder's job, confirms the child is gone, and
        // clears the row's pids. Everything above this line — the singleflight
        // claim, the session-id and worktree lookups — is shared, and
        // everything below it is the tmux mechanic, unchanged.
        if terminal.transport == .holder {
            return await performHolderHibernate(
                terminal: terminal, worktree: worktree, reason: reason, policy: policy)
        }

        // Rail: transcript-tail validity. Killing mid-write can leave an
        // unresumable jsonl (#18880). Only park when the last line is
        // complete JSON. Missing/empty transcript is allowed (nothing to
        // corrupt); the resume will just find no prior turns.
        if let refusal = Self.transcriptTailRefusal(
            transcriptPath: terminal.transcriptPath, policy: policy) {
            logger.warning("hibernate: skipping \(terminal.id, privacy: .public) — transcript tail not parseable, would be unresumable")
            return refusal
        }

        tmuxParkWillAwaitServerLock?(terminal.id)
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
        // Re-asked of the row read under the lock: the decision is what the
        // park will hand a later wake.
        guard let sessionID = currentTerminal.claudeResumeDecision.resumableSessionID else {
            return Self.parkRefusal(for: currentTerminal)
                ?? .notEligible(reason: Self.noSessionToParkReason)
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

        // The display snapshot: the frame the app shows while the session is
        // parked or waking. Captured verbatim and never judged — nothing it
        // shows refuses the park. Taken under the lock so it is the frame of
        // the process this park ends.
        let capturedSnapshot: String?
        if let capture = try? await tmux.capturePaneWithAnsi(server: server, paneID: paneID),
           !capture.isEmpty {
            capturedSnapshot = capture
        } else {
            capturedSnapshot = nil
        }

        // The transcript rail above the server lock is only a fast refusal.
        // This fresh read is authoritative: a queued hibernation must not act
        // on transcript state observed before another replacement or hook had
        // its turn under the same server lock.
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

        // The ending: SIGTERM to the Claude process, and nothing typed into
        // the pane — no `/exit`, no Escape, no Ctrl+C — so a draft in the box
        // is never submitted or cleared. SIGTERM runs Claude's graceful
        // shutdown, and the session mod makes its final save in `session.end`.
        // No pid found, or a Claude that outlives the poll window, goes
        // straight to the respawn below, whose `-k` guarantees termination.
        await TmuxSignalEnding.end(
            tmux: tmux, server: server, paneID: paneID, terminalID: terminal.id,
            inspector: paneProcessInspector, signaller: signaller, clock: clock,
            attempts: exitPollAttempts, interval: exitPollInterval)

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
        await broadcastHibernation(
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
    /// Killing claude mid-write can leave an unresumable jsonl, so both
    /// transports ask this before they touch the process. Named and shared so
    /// the tmux park, the holder park and the test assert one decision rather
    /// than three copies of it — and so the `.profileSwap` bypass is stated
    /// once. An unreadable or missing file is not a refusal: there is nothing
    /// there to corrupt.
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
    /// Only a POSITIVE disagreement downgrades the answer to `.sessionGone`,
    /// exactly as on the send path. A probe that merely threw keeps the benign
    /// historical no-op: a failed tmux call proves nothing, and tmux calls fail
    /// spuriously precisely when the machine is loaded enough for the session
    /// to be alive. A pane carrying no identity at all is likewise left alone.
    ///
    /// A probe that ran and reached no server is the third answer,
    /// `.paneUnreadable`: like a throw it is not a disagreement, but unlike a
    /// throw it is a fact the caller can act on — it names the server and pane
    /// that could not be consulted, so an autonomous caller learns its prompt
    /// was not delivered instead of reading "already awake" off a check that
    /// never happened.
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
        case .absent:
            disagreement = .paneMissing
        case .dead:
            disagreement = .processExited
        case .unreachable:
            // The probe ran and reached no server. That is not a
            // disagreement — nothing answered to disagree — so it must not
            // become `.sessionGone`, which asserts the session is gone. Report
            // the failed read as itself so the caller knows its prompt was not
            // delivered and a retry is the right move.
            logger.warning("""
                wake: could not reach tmux server \(worktree.tmuxServer, privacy: .public) to \
                consult pane \(terminal.tmuxPaneID, privacy: .public) for unparked terminal \
                \(terminal.id, privacy: .public) — reporting the failed read, not sessionGone
                """)
            return .paneUnreadable(
                paneID: terminal.tmuxPaneID, server: worktree.tmuxServer)
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
    /// **Transport decides which mechanic runs, never whether one may.** A
    /// parked holder row wakes by spawning a fresh holder running
    /// `claude --resume`; a parked tmux row respawns its window. An UNPARKED
    /// holder row is classified against the process table rather than against a
    /// pane, because a holder row's pane id is the empty string by construction
    /// and tmux answers for it by reporting the pane gone.
    public func wake(terminalID: UUID, cols: Int? = nil, rows: Int? = nil, allowDefaultProfileFallback: Bool = false, initialPrompt: String? = nil) async -> WakeResult {
        // Claim synchronously, before the first suspension. Otherwise two wake
        // calls can both read the parked row, then each pass the in-flight check
        // after actor reentrancy lets them interleave. Keep the claim across all
        // early exits so the defer releases lookup failures and successful wakes
        // alike.
        // `performHibernate` is actor-reentrant while it waits for the SIGTERM
        // poll and tmux. Once its durable begin transition marks this row parked, a
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
            return await classifyUnparkedHolderWake(terminal)
        }
        // The tab's kind decides whether a Claude session may be resumed in
        // it, not the session id on its row — see
        // `Terminal.claudeResumeDecision`. Asked before the transport branch,
        // so neither mechanic can be reached for a tab that is not Claude's.
        let sessionID: String
        switch terminal.claudeResumeDecision {
        case .resume(let resumable):
            sessionID = resumable
        case .noSession:
            return .noSessionID
        case .notAClaudeTab(let kind):
            logger.notice("wake: terminal \(terminal.id, privacy: .public) is a \(kind.rawValue, privacy: .public) tab carrying a session id; refusing to resume a Claude session in it")
            return .notAClaudeTab(kind: kind)
        }
        // The backstop for a tmux row whose leg cannot serve the wake. Refusing
        // here, before anything is touched, leaves the row parked with its
        // session id, so a wake after `tbd terminal migrate` succeeds on the
        // holder. Today the leg cannot serve when tmux is not installed; once
        // the tmux path is deleted it can never serve and this is the answer.
        if terminal.transport != .holder, !tmux.canServeTmux {
            // `.notice`, not `.error`: a retrying focus-wake reaches this on
            // every attempt, and a state the person can act on is not a daemon
            // fault.
            logger.notice("wake: terminal \(terminal.id, privacy: .public) is on the tmux transport and tmux is unavailable; refusing and leaving it parked")
            return .respawnFailed(
                reason: Self.tmuxWakeUnavailableReason(terminalID: terminal.id))
        }
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
        if let busyPID = await exitStampedPaneBusyPID(
            terminal: terminal, server: server, paneID: paneID) {
            logger.info("wake: exit-stamped terminal \(terminal.id, privacy: .public) has foreground pid \(busyPID, privacy: .public) in pane \(paneID, privacy: .public) — refusing the respawn rather than killing it")
            return .paneBusy(pid: busyPID)
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
        let overlay = ReplacementSpawnOverlay.plan(
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
        let spawnTitle = await ClaudeSessionTitle.forSpawn(
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
            profileModel: resolvedProfile?.model,
            profileAwsRegion: resolvedProfile?.awsRegion,
            profileAwsProfile: resolvedProfile?.awsProfile,
            profileConfigDir: profileConfigDir,
            cmd: nil,
            shellFallback: defaultShell,
            settingsOverlayPath: overlay.path,
            pluginDirPath: PluginDirWriter.pluginDirPath,
            extraPluginDirs: spawnExtras?.pluginDirs ?? [],
            envSettingOverrides: claudeEnvOverrides,
            sessionName: spawnTitle.name,
            // The overlay is written at launch, so its path counts as present.
            fileExists: overlay.commandFileExists
        )
        // Inject TBD_WORKTREE_ID + TBD_TERMINAL_ID so notifications and the
        // SessionStart hook attribute to this terminal after the resume rollover.
        let env: [String: String] = [
            "TBD_WORKTREE_ID": worktree.id.uuidString,
            "TBD_TERMINAL_ID": terminal.id.uuidString,
        ]
        // The free-form overrides, with the builder's auth env layered on top
        // so auth wins — the same merge the create path makes.
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
                rows: rows,
                spawnTitle: spawnTitle,
                overlay: overlay)
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
                    claudeSessionID: sessionID,
                    worktree: currentWorktree.worktree,
                    server: currentWorktree.tmuxServer,
                    windowID: currentTerminal.tmuxWindowID,
                    paneID: currentTerminal.tmuxPaneID,
                    spawnCommand: spawn.command,
                    env: env,
                    sensitiveEnv: sensitiveEnv,
                    cols: cols,
                    rows: rows,
                    overlay: overlay
                )
            }
        } catch {
            await sessionTitles.release(spawnTitle)
            return .notFound
        }
        switch outcome {
        case .failed(let result):
            await sessionTitles.release(spawnTitle)
            return result
        case .launchedUnrecorded(let result):
            // The replacement is running under the reserved name; only the
            // row's un-park failed. The session carries the name, so confirm.
            await sessionTitles.confirm(spawnTitle)
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
        await sessionTitles.confirm(spawnTitle)
        // Carry the LIVE window/pane ids on the un-park broadcast so the app
        // updates its cached row before (together with) the hibernated flip —
        // otherwise the terminal view rebuilds keyed on the dead window and
        // its failed attach re-parks the row (wake flap).
        await broadcastHibernation(
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
        return .ok(sessionIncarnationID: liveIncarnationID)
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
        /// The replacement agent launched, but clearing the parked marker
        /// failed afterwards. Returned to the caller verbatim like `.failed`,
        /// but the session is running under this wake's `--name`.
        case launchedUnrecorded(WakeResult)
    }

    /// The decide-then-mutate tmux section of `wake()` — ownership check,
    /// `windowExists`, and the in-place respawn OR recreate mutations. Must
    /// only be entered under `TmuxManager.withWorktreeServerLock` (see the call
    /// site in `wake()`), otherwise two concurrent wakes on the same server can
    /// interleave across the awaits below and hijack each other's windows.
    private func wakeTmuxSection(
        terminal: Terminal,
        claudeSessionID: String,
        worktree: Worktree,
        server: String,
        windowID: String,
        paneID: String,
        spawnCommand: String,
        env: [String: String],
        sensitiveEnv: [String: String],
        cols: Int?,
        rows: Int?,
        // The overlay `spawnCommand` was composed with, written by each launch
        // below from the session mod that launch is actually given.
        overlay: ReplacementSpawnOverlay
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
                let sessionMod = SessionModSpawn.prepare(
                    config: try? await db.config.get(),
                    claudeSessionID: claudeSessionID, incarnationID: incarnationID,
                    sessionsDir: sessionsDir, now: now())
                let launchCommand = overlay.settle(command: spawnCommand)
                try await tmux.respawnWindow(
                    server: server,
                    windowID: windowID,
                    cwd: worktree.localPath,
                    shellCommand: launchCommand,
                    env: replacementEnv,
                    sensitiveEnv: sensitiveEnv.addingSessionMod(sessionMod),
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
                    return .launchedUnrecorded(.respawnFailed(
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
                // A restarted tmux server can reuse the parked row's stale id
                // for the replacement we just created. In that ABA shape the
                // old and replacement ids are textually identical, so cleanup
                // must not kill the fresh inert pane before it is respawned.
                if !claimedByOther, windowID != window.windowID {
                    try? await tmux.killWindow(server: server, windowID: windowID)
                }
                // ensureServer returns the untracked bootstrap window id when
                // it just created the server; kill it now that the real
                // window exists (mirrors WorktreeLifecycle+PreSession).
                if let bootstrapWindowID, !bootstrapWindowID.isEmpty,
                   bootstrapWindowID != window.windowID {
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
                // Only the agent launch carries the mod; the inert staging
                // pane above is not a Claude spawn.
                let sessionMod = SessionModSpawn.prepare(
                    config: try? await db.config.get(),
                    claudeSessionID: claudeSessionID, incarnationID: incarnationID,
                    sessionsDir: sessionsDir, now: now())
                let launchCommand = overlay.settle(command: spawnCommand)
                do {
                    try await tmux.respawnWindow(
                        server: server,
                        windowID: window.windowID,
                        cwd: worktree.localPath,
                        shellCommand: launchCommand,
                        env: replacementEnv,
                        sensitiveEnv: sensitiveEnv.addingSessionMod(sessionMod),
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
                    return .launchedUnrecorded(.respawnFailed(
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
            if terminal.transport == .holder,
               decision == .eligible || decision == .notIdleLongEnough,
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

    /// Clear a stale parked timestamp for any terminal whose Claude process is
    /// actually still alive (e.g. the daemon crashed mid-park before its
    /// SIGTERM landed, or before `respawn-window` ran). Ported from the old Suspend
    /// feature's `reconcileOnStartup`, generalized to the unified state: it
    /// checks BOTH the authoritative `hibernatedAt` and the legacy `suspendedAt`
    /// so a row parked by either path is reconciled, and `clearHibernated` nils
    /// both. Called once on daemon startup.
    ///
    /// The window and process checks are joined by one more: if the pane's own
    /// `@tbd_terminal_id` names a DIFFERENT terminal, the row stays parked even
    /// though the liveness checks passed — see the guard below for why that is
    /// the only identity signal strong enough to override them.
    public func reconcileOnStartup() async {
        guard let allTerminals = try? await db.terminals.list() else { return }

        for terminal in allTerminals where terminal.isParked {
            // Asked before the tmux arm below, which would judge this row as a
            // park to recover although no wake will ever resume it.
            if terminal.transport != .holder, terminal.isExitStamped, !terminal.isClaudeTab {
                await liftEarlierBuildsExitStamp(terminal)
                continue
            }
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

            // Refuse ONLY on a positive identity mismatch: the pane carries
            // `@tbd_terminal_id` (every spawn stamps it — `createWindow` and
            // `respawnWindow`) and it names a DIFFERENT terminal. A tmux
            // server restart can reuse pane ids, and the window/process
            // checks above alone cannot tell this terminal's own pane from a
            // stranger's that happens to sit at the same coordinate and also
            // runs `claude`. A false park is recoverable by `wake`; a false
            // un-park is not.
            //
            // Matched jointly against `.live` AND `.dead` — mirroring the
            // sibling reconciler's identical check in
            // `WorktreeLifecycle+Reconcile.swift` — because `.dead`'s own doc
            // comment exists precisely so a stranger pane whose process exited
            // in the gap between this probe and the `paneCurrentCommand` check
            // above still reads as a mismatch instead of silently slipping
            // through unmatched.
            //
            // When the option is ABSENT — a pane spawned before this stamp
            // existed — fall back to today's behavior (the window/process
            // checks above) rather than refusing: the stamp is deliberately
            // not backfilled onto existing panes (`stampTerminalID`'s doc
            // comment), so treating "no answer" the same as "wrong answer"
            // would leave every pre-existing session parked after every
            // daemon restart — reproducing the "sessions keep falling asleep"
            // symptom this reconcile pass exists to prevent. `.absent` (the
            // pane vanished between the liveness checks above and this probe),
            // `.unreachable` (the server could not be consulted) and a thrown
            // probe error are each their own kind of
            // inconclusive and, unlike an absent id, are not evidence the row
            // is safe to un-park — mirroring the sibling reconciler's "an
            // unreadable identity is not evidence of staleness," they leave
            // the row parked for a later sweep to retry rather than guessing.
            do {
                switch try await tmux.paneSendTarget(server: server, paneID: terminal.tmuxPaneID) {
                case .live(let paneTerminalID), .dead(let paneTerminalID):
                    if let paneTerminalID,
                       paneTerminalID.caseInsensitiveCompare(terminal.id.uuidString) != .orderedSame {
                        continue
                    }
                case .absent, .unreachable:
                    continue
                }
            } catch {
                logger.warning("startup: failed to inspect pane ownership for terminal \(terminal.id, privacy: .public): \(error, privacy: .public) — leaving it parked")
                continue
            }

            // Window and process are alive, and the pane raised no identity
            // objection — clear the parked state
            do {
                try await db.terminals.clearHibernated(id: terminal.id)
                logger.info("startup: cleared stale parked state for still-running terminal \(terminal.id, privacy: .public) — window \(terminal.tmuxWindowID, privacy: .public), process alive")
            } catch {
                logger.warning("startup: failed to clear parked state for terminal \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
    /// process is touched. A row whose window is already gone is then an
    /// unparked shell row over a dead window, which startup reconciliation
    /// reclaims like any other — the tab goes, rather than staying parked
    /// behind a snapshot nothing can wake.
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
            if try await db.terminals.clearSessionExitStamp(id: terminal.id) {
                logger.info("startup: lifted an earlier build's exit stamp from \(kind, privacy: .public) terminal \(terminal.id, privacy: .public) — no wake resumes Claude in it, and its shell was never stopped")
            }
        } catch {
            logger.warning("startup: failed to lift the exit stamp from \(kind, privacy: .public) terminal \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

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
    ///
    /// `isParkOrWake` is false only for a re-broadcast that changes neither
    /// (`setKeepWarm`); every other caller parks or wakes the row, which drops
    /// a holder row's Program Status entries (`dropProgramStatus`).
    ///
    /// A park or a wake also carries the row's session incarnation, read back
    /// after the commit: both mint one, and the app forwards Program Status
    /// reports under its cached row's incarnation.
    func broadcastHibernation(
        terminal: Terminal, hibernated: Bool, keepWarm: Bool,
        tmuxWindowID: String? = nil, tmuxPaneID: String? = nil,
        suspendedSnapshot: String? = nil, hibernateReason: HibernateReason? = nil,
        isParkOrWake: Bool = true
    ) async {
        // Only holder sessions carry Program Status entries; a tmux park or
        // wake has nothing to drop and does not hop to the store.
        if isParkOrWake, terminal.transport == .holder {
            await dropProgramStatus(terminalID: terminal.id, hibernated: hibernated)
        }
        let committedIncarnationID = isParkOrWake
            ? (try? await db.terminals.get(id: terminal.id))?.sessionIncarnationID
            : nil
        subscriptions?.broadcast(delta: .terminalHibernationChanged(TerminalHibernationDelta(
            terminalID: terminal.id,
            worktreeID: terminal.worktreeID,
            hibernated: hibernated,
            keepWarm: keepWarm,
            tmuxWindowID: tmuxWindowID,
            tmuxPaneID: tmuxPaneID,
            suspendedSnapshot: suspendedSnapshot,
            hibernateReason: hibernateReason,
            sessionIncarnationID: committedIncarnationID
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
