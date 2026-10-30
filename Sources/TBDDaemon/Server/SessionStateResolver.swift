import Foundation
import TBDShared

// MARK: - The facts one resolve pass composes

/// Everything `SessionStateResolver` is allowed to look at for one terminal.
///
/// A value type rather than "the router plus the world", for the same reason
/// `TerminalDeliveryFacts` is one: with the inputs enumerated, the resolver
/// cannot quietly start consulting a source this design did not license — a
/// rendered pane, a model, a subprocess. Everything here is either a column the
/// daemon already holds or a bounded read something else already paid for.
struct SessionStateFacts: Sendable, Equatable {
    /// A hard usage limit classified off the session's transcript tail, and the
    /// moment that tail was read.
    ///
    /// `DetectedRateLimit` is not `Codable`, so it cannot ride in an
    /// `ObservedFact`; the pair carries the same triple by hand and the
    /// resolver stamps `.transcriptTail` when it uses it.
    struct TranscriptRateLimit: Sendable, Equatable {
        let limit: DetectedRateLimit
        let observedAt: Date

        init(limit: DetectedRateLimit, observedAt: Date) {
            self.limit = limit
            self.observedAt = observedAt
        }
    }

    /// The terminal row: `hibernatedAt`/`hibernateReason`, `pendingResumeAt`,
    /// the transport, the provenance-bearing `observedActivity`, and the wait
    /// reason stored beside it.
    let terminal: Terminal
    /// The transcript tail's rate-limit classification, when it found one.
    let transcriptRateLimit: TranscriptRateLimit?
    /// Pane/process liveness — **supplied only by a caller that already
    /// established it for another reason**, never probed by this path. See the
    /// resolver's note on `.gone`.
    let liveness: ObservedFact<Bool>?
    /// The terminal's Program Status Protocol (OSC 7501) snapshot from
    /// `ProgramStatusStore` — memory, not a column. nil when the store holds
    /// nothing for the terminal. See the resolver's rung 4.
    let programStatus: ProgramStatusSnapshot?

    init(
        terminal: Terminal,
        transcriptRateLimit: TranscriptRateLimit? = nil,
        liveness: ObservedFact<Bool>? = nil,
        programStatus: ProgramStatusSnapshot? = nil
    ) {
        self.terminal = terminal
        self.transcriptRateLimit = transcriptRateLimit
        self.liveness = liveness
        self.programStatus = programStatus
    }
}

// MARK: - The resolver

/// Composes one terminal's `SessionState` — the phase-1 triple — out of the
/// machine facts the daemon already holds.
///
/// Cheap enough to ask about every agent on a cadence, and that bound is a
/// design constraint rather than an aspiration: **no model call, no rendered
/// screen, no subprocess.** Every input is a database column, the program
/// status store's memory, or a byte-bounded file read a caller already made.
///
/// ## Precedence, and why it is this order
///
/// The facts are not ranked by how much anyone likes them. Each rung outranks
/// the ones below it because a fact on the lower rung would be a statement
/// about a session that the higher rung has already shown is not the session
/// in front of us.
///
/// 1. **`.gone`** — the pane or process is not there. Every other value asserts
///    something about a live session, so reporting one about a torn-down pane
///    would be a claim about nothing. It goes first for that reason alone.
/// 2. **`.parked`** — `hibernatedAt` says TBD tore the agent process down
///    itself. Above the agent's own facts because those describe the
///    *previous* process: a state recorded before a park is true about a
///    process that no longer runs, and repeating it would present a parked
///    session as one sitting quietly at a prompt. Below `.gone` because parking
///    deliberately keeps the window alive, so a park is only meaningful while
///    the pane is.
/// 3. **`.rateLimited`** — a scheduled resume TBD recorded (`pendingResumeAt`,
///    source `.database`), else the transcript tail's own classification
///    (source `.transcriptTail`). Above the agent's report because a
///    rate-limited session reports its turn as ended — it did end — and
///    reporting `idle` invites a caller to send work the session cannot do
///    until the limit resets.
/// 4. **The program status snapshot (OSC 7501)** — the agent's own report,
///    Claude Code's or Codex's, for the terminal's current incarnation, rolled
///    up with its task entries by `ProgramStatusRollup` (source
///    `.programStatus`). This is where `.done`, `.error` and `.needsAuth` come
///    from, and where a wait carries the agent's `title` or `msg`. A snapshot
///    for another incarnation, one with no main entry, or one whose main state
///    this build does not recognize says nothing here. Below the three states
///    TBD owns. Design: docs/specs/2026-10-10-program-status-protocol-design.md.
/// 5. **The activity columns** — `observedActivity` and the wait reason
///    stored beside it. Only `ProgramStatusStore` (from the same reports,
///    mapped onto the column vocabulary) and a park write them, so this is
///    what speaks after a daemon restart, before the agent's next report:
///    `.working` and `.idle` as recorded, `.waitingForUser` as
///    `.awaitingInput` carrying the stored reason — the block the agent
///    reported, with no message text. The store writes state and reason
///    together from one report, so the two never disagree and neither needs
///    ranking against the other. A recorded `.unknown` says nothing and falls
///    through.
/// 6. **`.unknown(why:)`** — nothing could speak. A real answer, not an error,
///    and its `why` names the cause from the transport: a tmux session's
///    agent cannot report at all, and a holder session's has not reported
///    from this incarnation.
///
/// ## `.gone`, and the probe this resolver refuses to add
///
/// There is **no cheap per-terminal liveness fact in the daemon today.** Pane
/// and window liveness live in the tmux server, and every way to ask costs a
/// subprocess; nothing durable records it (a terminal whose window dies is
/// *parked* by the reconcile sweep with `.recovery`, and a deleted terminal has
/// no row left to report on). Adding a probe here would put one subprocess per
/// agent on a path built to be asked about every agent at once, which is the
/// cost this resolver exists to avoid.
///
/// So `liveness` is an input, not something this type goes and gets. A caller
/// that already established it — the send path consults the pane
/// synchronously at act time, which is where staleness actually bites — may
/// pass it in. When nobody did, the resolver does not guess: it falls through.
struct SessionStateResolver: Sendable {
    /// Date seam. Read for the two stamps that are genuinely "when TBD looked":
    /// the database read behind `.rateLimited(from pendingResumeAt)` and the
    /// `.unavailable` stamp on an `.unknown` nobody could speak to.
    var now: @Sendable () -> Date = { Date() }

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func resolve(_ facts: SessionStateFacts) -> SessionState {
        let terminal = facts.terminal

        // 1. Gone.
        if let liveness = facts.liveness, liveness.value == false {
            return SessionState(
                value: .gone, source: liveness.source, observedAt: liveness.observedAt)
        }

        // 2. Parked. Observed-at is the park instant, not the read: the fact
        //    became true then, and aging it by the read would make a
        //    three-day-old park look like it happened at this read.
        if let hibernatedAt = terminal.hibernatedAt {
            return SessionState(
                value: .parked(reason: terminal.hibernateReason?.rawValue ?? "unspecified"),
                source: .database,
                observedAt: hibernatedAt)
        }

        // 3. Rate-limited. TBD's own scheduled-resume mirror first: it is the
        //    record of a limit TBD already classified AND scheduled, and an
        //    agent report of a new turn cancels it, so it cannot outlive the
        //    wait it describes.
        if let pendingResumeAt = terminal.pendingResumeAt {
            return SessionState(
                value: .rateLimited(until: pendingResumeAt),
                source: .database,
                observedAt: now())
        }
        // Else the transcript tail's classification — the same
        // `RateLimitDetection` the CLI and the actuator use, never a second
        // classifier. Reported only while the announced reset is still ahead:
        // the detector classifies a *record*, not whether the limit still
        // holds, and a reset that has passed is stopping nothing.
        if let transcriptRateLimit = facts.transcriptRateLimit,
           transcriptRateLimit.limit.resetsAt > transcriptRateLimit.observedAt {
            return SessionState(
                value: .rateLimited(until: transcriptRateLimit.limit.resetsAt),
                source: .transcriptTail,
                observedAt: transcriptRateLimit.observedAt)
        }

        // 4. The program status snapshot. While this incarnation's main entry
        //    carries a recognized state, or stands over task entries that
        //    decide the state, the agent's own report is the session's state.
        if let snapshot = facts.programStatus,
           snapshot.incarnationID == terminal.sessionIncarnationID,
           let resolution = ProgramStatusRollup.resolve(snapshot) {
            return SessionState(
                value: resolution.value, source: .programStatus,
                observedAt: resolution.observedAt)
        }

        // 5. The activity columns, with the wait reason stored beside them.
        if let activityFact = terminal.observedActivity {
            switch activityFact.value {
            case .working:
                return SessionState(
                    value: .working, source: activityFact.source,
                    observedAt: activityFact.observedAt)
            case .idle:
                return SessionState(
                    value: .idle, source: activityFact.source,
                    observedAt: activityFact.observedAt)
            case .waitingForUser:
                return SessionState(
                    value: .awaitingInput(reason: terminal.awaitingInputReason),
                    source: activityFact.source,
                    observedAt: activityFact.observedAt)
            case .unknown:
                break
            }
        }

        // 6. Nothing could speak. Say why.
        return SessionState(
            value: .unknown(why: Self.unknownWhy(terminal)),
            source: .unavailable,
            observedAt: now())
    }

    /// The cause, in the reader's own terms, from the terminal's transport.
    /// Never a generic "could not determine": a `why` that does not name the
    /// gap is a shrug with provenance attached.
    static func unknownWhy(_ terminal: Terminal) -> String {
        switch terminal.transport {
        case .tmux:
            return "this session runs on the tmux transport, which does not carry agent status"
        case .holder:
            return "the agent has not reported its status from this session's current incarnation"
        }
    }
}
