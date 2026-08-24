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
    /// and the two provenance-bearing facts `observedActivity` and
    /// `observedAwaitingInput`.
    let terminal: Terminal
    /// The transcript tail's rate-limit classification, when it found one.
    let transcriptRateLimit: TranscriptRateLimit?
    /// When the session's transcript last grew, or nil when TBD could not read
    /// the file at all.
    ///
    /// **Byte-level evidence, not content.** The value is the transcript file's
    /// own append stamp, taken from the same descriptor the tail was read
    /// through; nothing anywhere on this path parses, matches or interprets a
    /// record. It exists for one comparison — see the resolver's staleness rule
    /// — and nil is "no observation", never "it did not grow".
    let transcriptLastAppendedAt: ObservedFact<Date>?
    /// Pane/process liveness — **supplied only by a caller that already
    /// established it for another reason**, never probed by this path. See the
    /// resolver's note on `.gone`.
    let liveness: ObservedFact<Bool>?

    init(
        terminal: Terminal,
        transcriptRateLimit: TranscriptRateLimit? = nil,
        transcriptLastAppendedAt: ObservedFact<Date>? = nil,
        liveness: ObservedFact<Bool>? = nil
    ) {
        self.terminal = terminal
        self.transcriptRateLimit = transcriptRateLimit
        self.transcriptLastAppendedAt = transcriptLastAppendedAt
        self.liveness = liveness
    }
}

// MARK: - The resolver

/// Composes one terminal's `SessionState` — the phase-1 triple — out of the
/// machine facts the daemon already holds.
///
/// Cheap enough to ask about every agent every cycle, and that bound is a
/// design constraint rather than an aspiration: **no model call, no rendered
/// screen, no subprocess.** Every input is a database column or a byte-bounded
/// file read a caller already made.
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
///    itself. Above the activity facts because those describe the *previous*
///    process: an `idle` recorded before a park is true about a process that no
///    longer runs, and repeating it would present a parked session as one
///    sitting quietly at a prompt. Below `.gone` because parking deliberately
///    keeps the window alive, so a park is only meaningful while the pane is.
/// 3. **`.rateLimited`** — a scheduled resume TBD recorded (`pendingResumeAt`,
///    source `.database`), else the transcript tail's own classification
///    (source `.transcriptTail`). Above the activity facts because a
///    rate-limited session reads as `idle` on the hook rail — its turn *did*
///    end — and reporting `idle` invites a supervisor to send work the session
///    cannot do until the limit resets.
/// 4. **`.awaitingInput` vs `.working`/`.idle`** — decided by **observed-at**,
///    not by a fixed rank, and a recorded prompt the transcript has grown past
///    resolves `.unknown(why:)` rather than either — unless a second rail
///    corroborates it. See the staleness rule below.
/// 5. **`.unknown(why:)`** — nothing could speak. A real answer, not an error,
///    and its `why` names the fact that was missing.
///
/// ## The staleness rule between the wait reason and the activity state
///
/// `Terminal.observedAwaitingInput` and `Terminal.observedActivity` are
/// **independent** facts written by different handlers.
/// `handleTerminalNotificationEvent` records a reason without touching
/// `activityState` (deliberately — `activityState` gates hibernation), and
/// `handleTerminalActivityEvent` returns early when the state is unchanged, so
/// a repeated same-state event does **not** rewrite the activity stamp. It does
/// retract a not-newer reason, on the same ordering rule a changed state
/// follows — but the retraction and the activity stamp move independently, and
/// only the reason column is touched.
///
/// So neither fact may be given a standing rank, and observed-at decides
/// between them. A reason older than the newest activity observation is a
/// prompt the session has already moved past, and it must never be reported as
/// a live one. Symmetrically, when the activity fact wins and its value is
/// `waiting_for_user`, the state is `.awaitingInput(reason: nil)` — the older
/// recorded message is not attached, because presenting stale prompt text
/// beside a fresh observation is the same lie in a smaller font.
///
/// **The two mechanisms do not compose safely on their own, and this is the
/// direction they fail in.** The activity stamp does not advance during a turn:
/// the overlay emits `tbd terminal-activity` only at turn boundaries
/// (`UserPromptSubmit`, `Stop`/`StopFailure`, and the `AskUserQuestion` pair),
/// and the handler returns early on an unchanged value without rewriting
/// provenance. So a `permission_prompt` recorded a second *after* the turn's
/// `working` stamp keeps outranking it for the rest of the turn — ten minutes
/// of reporting `.awaitingInput` for a prompt answered seconds after it
/// appeared.
///
/// A same-state event does now retract a not-newer reason, which is what the
/// rail could not do before. It does not close this window, and it is worth
/// being exact about how narrow it is. An `AskUserQuestion` prompt was never in
/// the window: its pre-hook writes `waiting_for_user` and its post-hook writes
/// `working`, a *changed* state that has always retracted. And **no hook fires
/// at all when a human approves a Bash or an Edit** — the overlay's only
/// `PostToolUse` entries are matched to `AskUserQuestion` and to
/// `Bash`-for-PR-binding — so between that approval and the turn's `Stop` there
/// is nothing to retract on. What the same-state retraction reaches is a
/// repeated value: a queued `UserPromptSubmit` mid-turn, a second `Stop`, or a
/// post-hook whose paired pre-hook was lost to a stale `tbd` on `PATH`.
///
/// So the transcript check below is still the only thing that speaks during a
/// turn, and it is still what this doctrine rests on.
///
/// The transcript is the only other interface that speaks during a turn, and it
/// **cannot settle this either — so growth is evidence of ambiguity, not of an
/// answer.** Answering a prompt does append (the tool runs and its result is
/// written), but so do several things that happen while the prompt is still on
/// screen: a parallel `Task` subagent appends sidechain records to the same
/// JSONL, a backgrounded task's completion record lands, a queued user message
/// is written. Reading growth as proof of an answer therefore fails in the one
/// direction that costs a night — Claude issues a `Task` and a `Bash` in one
/// turn, the `Bash` raises a permission prompt, the subagent appends two seconds
/// later, and a resolver that discarded the reason would fall through to an
/// `activityState` still reading `working` from `UserPromptSubmit` and report
/// `.working` for a session blocked on a human, indefinitely.
///
/// **The resolver must never report `.working` for a session that may be
/// blocked on a human.** So the three cases are:
///
/// - A recorded `promptOnScreen` reason with **no** growth since its
///   observed-at → `.awaitingInput(reason:)`.
/// - A recorded `promptOnScreen` reason **with** growth since → `.unknown(why:)`,
///   whose `why` names both possibilities: a prompt was reported at that moment,
///   the transcript has grown since, and whether it was answered cannot be told
///   from machine facts.
/// - The same growth, but with an activity fact whose value is
///   `waiting_for_user` → `.awaitingInput(reason: nil)`, on the activity fact's
///   provenance. The `AskUserQuestion` pre-hook writes that value, so this is
///   the shape where a second, independent rail is already saying the session
///   is blocked on a human. Growth casts doubt on *which* prompt is up, not on
///   whether one is — so no reason is attached, and the answer stays the
///   confident one. `unknown` is for genuine ambiguity, never for discarding
///   corroboration: consumers gate on `isConfident`, so reporting `unknown`
///   here would downgrade a correct actionable answer to a non-answer.
/// - No recorded prompt → the activity rail.
///
/// This is the same doctrine the delegation trap below already follows: when
/// compiled facts cannot separate two situations, do not guess — report
/// `unknown` and let the tier that may read text decide. Its converse is the
/// case above: when a fact *can* separate them, spending `unknown` anyway is
/// not caution, it is throwing away an observation TBD already paid for.
///
/// The evidence is **byte-level only**: the fact consulted is
/// `SessionStateFacts.transcriptLastAppendedAt`, the transcript file's own
/// append stamp, read from the same descriptor the tail was read through. No
/// record is parsed, matched or interpreted anywhere on this path — a rule this
/// file shares with `SessionCountersTracker`, whose turn count is likewise a
/// count of appends and never a reading of them. And an *absent* growth fact (no
/// transcript path, or a file TBD could not read) establishes nothing: the
/// prompt stands, because "we could not look" is not evidence that it went away.
///
/// **One assumption rides on the comparison, and it is unmeasured.** It holds
/// that Claude Code flushes the assistant record carrying the `tool_use` to the
/// JSONL *before* it fires the `Notification` hook, so an unanswered prompt's
/// newest append predates the reason's observed-at. If the flush happens after
/// the hook instead, every prompt shows growth immediately and **every prompt
/// resolves `unknown`** — that is the symptom to look for, and it is visible in
/// the composed output rather than hidden. The fix that would then apply is a
/// small tolerance on this comparison, sized to a measured flush lag. It is
/// deliberately not written yet: an unmeasured tolerance constant would paper
/// over the assumption instead of exposing it, and honest-and-detectable beats a
/// magic number.
///
/// Only the `.promptOnScreen` class produces `.awaitingInput`.
/// `.informational` and `.unrecognized` say nothing about whether a human is
/// being waited on, so they establish no state and the resolver falls through
/// to the activity fact. `.unrecognized` in particular is **never** guessed
/// into `.awaitingInput` — that is phase 2's refusal to file an unknown type by
/// the sound of its spelling, kept intact one layer up. The branch is on
/// `classification`, which is TBD's own closed vocabulary derived mechanically
/// from a machine field; nothing here branches on `message`.
///
/// `.doneWaiting` is the one other class that decides something, and it
/// resolves `.idle`. Its only member is `idle_prompt` — Claude Code reporting
/// that it has finished and is sitting at its own prompt, which is precisely
/// what `.idle` denotes here ("the rail last told us a turn ended, at this
/// time"). It is deliberately not `.awaitingInput`: nothing is on screen for a
/// human to answer, and reporting a prompt that does not exist would send a
/// supervisor looking for one. **What it must never resolve to is `.working`**,
/// and that is why it is decided here rather than left to fall through. When
/// `Stop`/`StopFailure` never reaches the daemon — a hook failure, or a stale
/// `tbd` on the pane's `PATH` — `activityState` is stuck at `working` from
/// `UserPromptSubmit`, and falling through would discard a newer, more specific
/// observation in favour of a stale one, reporting `.working` for a session
/// whose turn demonstrably ended. That is the same rule the growth branch above
/// serves: never `.working` for a session that may be blocked on a human, least
/// of all in the case where the activity rail has failed.
///
/// ## `.gone`, and the probe this resolver refuses to add
///
/// There is **no cheap per-terminal liveness fact in the daemon today.** Pane
/// and window liveness live in the tmux server, and every way to ask costs a
/// subprocess; nothing durable records it (a terminal whose window dies is
/// *parked* by the reconcile sweep with `.recovery`, and a deleted terminal has
/// no row left to report on). Adding a probe here would put one subprocess per
/// agent on a path built to run every cycle for the whole fleet, which is the
/// cost this whole slice exists to avoid.
///
/// So `liveness` is an input, not something this type goes and gets. A caller
/// that already established it — the send path consults the pane
/// synchronously at act time, which is where staleness actually bites — may
/// pass it in. When nobody did, the resolver does not guess: it falls through,
/// and if nothing else can speak the answer is `.unknown(why:)` naming the
/// missing liveness fact.
///
/// ## The ambiguity this resolver carries rather than resolves
///
/// **A session waiting on a background subagent reads as `idle`, and no machine
/// signal fixes that.** Measured on a live session: a worktree that delegated to
/// a background agent showed idle for twenty minutes while its subagent
/// churned, because `Stop` fires when the *parent's* turn ends and the parent's
/// turn genuinely does end at delegation.
///
/// The obvious detector does not work. "An `Agent` tool-use with no matching
/// `tool_result` means a delegation is outstanding" fails on exactly this case:
/// a backgrounded agent's `tool_result` lands immediately, so the transcript
/// shows a completed tool call while the work runs out of band — measured at 27
/// tool-uses, 27 results, zero pending, subagent running throughout.
///
/// **Do not build a delegation detector here.** Telling the two shapes apart
/// would mean matching launches against later completion notices by reading
/// result prose: content interpretation at a layer that is not allowed to
/// interpret content, and brittle against a wording change nobody would think
/// to look for. The design already answers this — when compiled facts cannot
/// separate two situations, the case goes to a desk, and the desk reads the
/// transcript, which is the tier licensed to interpret text.
///
/// What this type owes instead is **carrying the ambiguity honestly**. `idle`
/// with a source and an observed-at is a fine answer; `idle` presented as "not
/// working" is not, and nothing here presents it that way — the triple is all a
/// consumer ever receives, so it can always see that `idle` means "the hook
/// rail last told us a turn ended, at this time", which is exactly what it
/// means.
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
        //    three-day-old park look like it happened on this cycle.
        if let hibernatedAt = terminal.hibernatedAt {
            return SessionState(
                value: .parked(reason: terminal.hibernateReason?.rawValue ?? "unspecified"),
                source: .database,
                observedAt: hibernatedAt)
        }

        // 3. Rate-limited. TBD's own scheduled-resume mirror first: it is the
        //    record of a limit TBD already classified AND scheduled, and the
        //    activity rail cancels it the moment the user continues manually,
        //    so it cannot outlive the wait it describes.
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

        // 4. The wait reason and the activity state, newest first.
        let reasonFact = terminal.observedAwaitingInput
        let activityFact = terminal.observedActivity

        if let reasonFact, reasonIsNewer(reasonFact, than: activityFact) {
            switch reasonFact.value.classification {
            case .promptOnScreen:
                // Growth since the prompt does not retract it — it makes the two
                // situations indistinguishable from machine facts. Say so, rather
                // than falling through to an activity rail that would report
                // `.working` for a session possibly blocked on a human.
                if let growth = facts.transcriptLastAppendedAt,
                   growth.value > reasonFact.observedAt {
                    // Unless the activity rail is independently saying the
                    // session is blocked on a human. Then the two facts do not
                    // conflict — only the prompt's identity is in doubt — and
                    // an `unknown` here would discard a confident observation
                    // rather than report an ambiguity. No reason is attached:
                    // which prompt is up is exactly what growth put in doubt.
                    if let activityFact, activityFact.value == .waitingForUser {
                        return SessionState(
                            value: .awaitingInput(reason: nil), source: activityFact.source,
                            observedAt: activityFact.observedAt)
                    }
                    return SessionState(
                        value: .unknown(why: ambiguousPromptWhy(reason: reasonFact, growth: growth)),
                        source: growth.source,
                        observedAt: growth.observedAt)
                }
                return SessionState(
                    value: .awaitingInput(reason: reasonFact.value),
                    source: reasonFact.source,
                    observedAt: reasonFact.observedAt)
            case .doneWaiting:
                // The agent's own report that its turn is over, newer than
                // anything the activity rail managed to record. `.idle` is what
                // that means here — see the doc comment's rule; the one answer
                // it must never become is `.working`.
                return SessionState(
                    value: .idle, source: reasonFact.source,
                    observedAt: reasonFact.observedAt)
            case .informational, .unrecognized:
                // Establishes no state. Fall through to the activity rail.
                break
            }
        }

        if let activityFact {
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
                // No reason is attached even when one is on record: this branch
                // is reached only when the activity observation is the newer of
                // the two, so any stored message describes an earlier prompt.
                return SessionState(
                    value: .awaitingInput(reason: nil), source: activityFact.source,
                    observedAt: activityFact.observedAt)
            case .unknown:
                // A recorded fact whose value is "we do not know" — an
                // observation, so it keeps the hook's source and stamp.
                return SessionState(
                    value: .unknown(why: "the activity rail recorded state 'unknown' for this session"),
                    source: activityFact.source,
                    observedAt: activityFact.observedAt)
            }
        }

        // 5. Nothing could speak. Say which fact was missing.
        return SessionState(
            value: .unknown(why: unknownWhy(facts: facts, reasonFact: reasonFact)),
            source: .unavailable,
            observedAt: now())
    }

    /// True when the recorded wait reason is at least as new as the newest
    /// activity observation.
    ///
    /// Ties go to the reason. Two facts stamped at the same instant cannot be
    /// ordered, and the reason is the more specific of the two — it names what
    /// is being waited on, where the activity value only says a turn boundary
    /// was crossed.
    private func reasonIsNewer(
        _ reason: ObservedFact<AwaitingInputReason>,
        than activity: ObservedFact<TerminalActivityState>?
    ) -> Bool {
        guard let activity else { return true }
        return reason.observedAt >= activity.observedAt
    }

    /// The `why` for a prompt the transcript has grown past: both possibilities,
    /// named, with the two stamps that put them in tension.
    ///
    /// **Never the prompt's `message`.** That text may quote repo content, and
    /// it is carried on the `.awaitingInput` value for readers entitled to it;
    /// a `why` string is composed into briefings and logs. The classification
    /// and the verbatim `notification_type` are TBD's own closed vocabulary and
    /// Claude Code's, so both are safe to name.
    private func ambiguousPromptWhy(
        reason: ObservedFact<AwaitingInputReason>, growth: ObservedFact<Date>
    ) -> String {
        let type = reason.value.notificationType ?? "none"
        return "a prompt was reported for this session at \(Self.stamp(reason.observedAt)) "
            + "(notification_type '\(type)', classified "
            + "'\(reason.value.classification.rawValue)') and the transcript has grown since "
            + "(last append \(Self.stamp(growth.value))); whether it was answered cannot be told "
            + "from machine facts — answering a prompt appends, and so do a parallel subagent's "
            + "records, a backgrounded task's completion record and a queued user message"
    }

    /// One stable textual form for the stamps a `why` names, so two readers of
    /// the same string never disagree about which instant it means.
    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// Which fact was missing, in the reader's own terms. Never a generic
    /// "could not determine": a `why` that does not name the gap is a shrug
    /// with provenance attached.
    private func unknownWhy(
        facts: SessionStateFacts, reasonFact: ObservedFact<AwaitingInputReason>?
    ) -> String {
        var missing: [String] = [
            "no activity observation is recorded (activityStateSource / "
                + "activityStateObservedAt are absent)"
        ]
        if let reasonFact {
            missing.append(
                "the newest recorded Notification is classified "
                    + "'\(reasonFact.value.classification.rawValue)', which establishes no session state")
        } else {
            missing.append("no Notification wait reason is on record")
        }
        if facts.liveness == nil {
            missing.append(
                "and no pane/process liveness fact was supplied — this path never probes for one")
        }
        return missing.joined(separator: "; ")
    }
}
