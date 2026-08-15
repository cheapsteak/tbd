import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 1. `SessionStateResolver` is a pure function of an enumerated fact
/// bundle — no database, no filesystem, no daemon — so every branch and the
/// ordering between branches is a plain value assertion.
///
/// Every test asserts on the **composed output** (value, source, observed-at),
/// not on the presence of fields. A state whose provenance is right by accident
/// and wrong by construction would pass a field-presence check.
@Suite("SessionStateResolver")
struct SessionStateResolverTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let resolveNow = Date(timeIntervalSince1970: 1_700_010_000)

    private func resolver() -> SessionStateResolver {
        let pinned = resolveNow
        return SessionStateResolver(now: { pinned })
    }

    private func terminal(
        activityState: TerminalActivityState = .unknown,
        activityStateSource: FactSource? = nil,
        activityStateObservedAt: Date? = nil,
        awaitingInputReason: AwaitingInputReason? = nil,
        awaitingInputObservedAt: Date? = nil,
        hibernatedAt: Date? = nil,
        hibernateReason: HibernateReason? = nil,
        pendingResumeAt: Date? = nil
    ) -> Terminal {
        Terminal(
            worktreeID: UUID(),
            tmuxWindowID: "@0",
            tmuxPaneID: "%0",
            activityState: activityState,
            hibernatedAt: hibernatedAt,
            hibernateReason: hibernateReason,
            pendingResumeAt: pendingResumeAt,
            activityStateSource: activityStateSource,
            activityStateObservedAt: activityStateObservedAt,
            awaitingInputReason: awaitingInputReason,
            awaitingInputObservedAt: awaitingInputObservedAt)
    }

    private func promptReason(_ message: String = "Claude needs your permission") -> AwaitingInputReason {
        AwaitingInputReason(
            message: message,
            hookEventName: "Notification",
            notificationType: "permission_prompt")
    }

    // MARK: - One test per precedence branch

    @Test func parkedCarriesTheParkInstantAndTheDatabaseSource() {
        let parkedAt = t0.addingTimeInterval(500)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(hibernatedAt: parkedAt, hibernateReason: .manual)))

        #expect(state.value == .parked(reason: "manual"))
        #expect(state.source == .database)
        #expect(state.observedAt == parkedAt)
        #expect(state.value.isConfident)
    }

    @Test func scheduledResumeMirrorReportsRateLimitedFromTheDatabase() {
        let until = t0.addingTimeInterval(3_600)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(pendingResumeAt: until)))

        #expect(state.value == .rateLimited(until: until))
        #expect(state.source == .database)
        // The database read IS the observation, so it is stamped at resolve
        // time rather than at whenever the row was written.
        #expect(state.observedAt == resolveNow)
    }

    @Test func transcriptClassificationReportsRateLimitedFromTheTail() {
        let readAt = t0.addingTimeInterval(100)
        let resetsAt = readAt.addingTimeInterval(1_800)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(),
            transcriptRateLimit: .init(
                limit: DetectedRateLimit(
                    resetsAt: resetsAt, limitType: "session", rawMessage: "hit your session limit"),
                observedAt: readAt)))

        #expect(state.value == .rateLimited(until: resetsAt))
        #expect(state.source == .transcriptTail)
        #expect(state.observedAt == readAt)
    }

    @Test func aTranscriptLimitWhoseResetHasPassedIsNotReported() {
        let readAt = t0.addingTimeInterval(100)
        let hookAt = t0.addingTimeInterval(50)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .idle,
                activityStateSource: .hookEvent("Stop"),
                activityStateObservedAt: hookAt),
            transcriptRateLimit: .init(
                limit: DetectedRateLimit(
                    resetsAt: readAt.addingTimeInterval(-60),
                    limitType: "session",
                    rawMessage: "hit your session limit"),
                observedAt: readAt)))

        // The detector classifies a record, not whether the limit still holds.
        #expect(state.value == .idle)
        #expect(state.source == .hookEvent("Stop"))
    }

    @Test func goneComesOnlyFromASuppliedLivenessFact() {
        let observedAt = t0.addingTimeInterval(42)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .working,
                activityStateSource: .hookEvent("UserPromptSubmit"),
                activityStateObservedAt: t0),
            liveness: ObservedFact(value: false, source: .processLiveness, observedAt: observedAt)))

        #expect(state.value == .gone)
        #expect(state.source == .processLiveness)
        #expect(state.observedAt == observedAt)
    }

    @Test func aLivenessFactSayingAliveDoesNotItselfDecideTheState() {
        let hookAt = t0.addingTimeInterval(7)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .working,
                activityStateSource: .hookEvent("UserPromptSubmit"),
                activityStateObservedAt: hookAt),
            liveness: ObservedFact(value: true, source: .processLiveness, observedAt: t0)))

        #expect(state.value == .working)
        #expect(state.source == .hookEvent("UserPromptSubmit"))
        #expect(state.observedAt == hookAt)
    }

    @Test func awaitingInputCarriesTheHookSourceAndTheReasonVerbatim() {
        let reasonAt = t0.addingTimeInterval(300)
        let reason = promptReason("Claude needs your permission to use Bash")
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .idle,
                activityStateSource: .hookEvent("Stop"),
                activityStateObservedAt: t0.addingTimeInterval(100),
                awaitingInputReason: reason,
                awaitingInputObservedAt: reasonAt)))

        #expect(state.value == .awaitingInput(reason: reason))
        #expect(state.source == .hookEvent("Notification"))
        #expect(state.observedAt == reasonAt)
    }

    @Test func workingAndIdleCarryTheActivityRailsProvenance() {
        let at = t0.addingTimeInterval(11)
        let working = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .working,
                activityStateSource: .hookEvent(RPCMethod.terminalActivityEvent),
                activityStateObservedAt: at)))
        #expect(working.value == .working)
        #expect(working.source == .hookEvent(RPCMethod.terminalActivityEvent))
        #expect(working.observedAt == at)

        let idle = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .idle,
                activityStateSource: .hookEvent("Stop"),
                activityStateObservedAt: at)))
        #expect(idle.value == .idle)
        #expect(idle.source == .hookEvent("Stop"))
        #expect(idle.observedAt == at)
    }

    @Test func aFreshWaitingForUserActivityStateDoesNotBorrowAnOlderPromptsText() {
        let reasonAt = t0.addingTimeInterval(100)
        let activityAt = t0.addingTimeInterval(400)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .waitingForUser,
                activityStateSource: .hookEvent(RPCMethod.terminalActivityEvent),
                activityStateObservedAt: activityAt,
                awaitingInputReason: promptReason("an older prompt"),
                awaitingInputObservedAt: reasonAt)))

        #expect(state.value == .awaitingInput(reason: nil))
        #expect(state.source == .hookEvent(RPCMethod.terminalActivityEvent))
        #expect(state.observedAt == activityAt)
    }

    // MARK: - The ordering itself

    @Test func aParkedTerminalWithAStaleAwaitingInputReasonResolvesAsParked() {
        let parkedAt = t0.addingTimeInterval(900)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .idle,
                activityStateSource: .hookEvent("Stop"),
                activityStateObservedAt: t0.addingTimeInterval(200),
                awaitingInputReason: promptReason(),
                // Newer than the activity fact, and still outranked: the park
                // tore down the process the prompt was on.
                awaitingInputObservedAt: t0.addingTimeInterval(800),
                hibernatedAt: parkedAt,
                hibernateReason: .auto)))

        #expect(state.value == .parked(reason: "auto"))
        #expect(state.source == .database)
        #expect(state.observedAt == parkedAt)
    }

    @Test func goneOutranksParked() {
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(hibernatedAt: t0, hibernateReason: .auto),
            liveness: ObservedFact(value: false, source: .processLiveness, observedAt: t0)))
        #expect(state.value == .gone)
    }

    @Test func rateLimitedOutranksAnIdleHookObservation() {
        let until = t0.addingTimeInterval(2_400)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .idle,
                activityStateSource: .hookEvent("Stop"),
                activityStateObservedAt: t0.addingTimeInterval(1_000),
                pendingResumeAt: until)))

        // A rate-limited session's turn genuinely did end, so the hook rail
        // says idle. Reporting idle would invite a send it cannot act on.
        #expect(state.value == .rateLimited(until: until))
        #expect(state.source == .database)
    }

    @Test func parkedOutranksRateLimited() {
        let parkedAt = t0.addingTimeInterval(1_500)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                hibernatedAt: parkedAt,
                hibernateReason: .merged,
                pendingResumeAt: t0.addingTimeInterval(9_000))))
        #expect(state.value == .parked(reason: "merged"))
        #expect(state.observedAt == parkedAt)
    }

    // MARK: - The staleness rule, both directions

    @Test func aReasonNewerThanTheLastActivityObservationWins() {
        let activityAt = t0.addingTimeInterval(100)
        let reasonAt = t0.addingTimeInterval(200)
        let reason = promptReason()
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .idle,
                activityStateSource: .hookEvent("Stop"),
                activityStateObservedAt: activityAt,
                awaitingInputReason: reason,
                awaitingInputObservedAt: reasonAt)))

        #expect(state.value == .awaitingInput(reason: reason))
        #expect(state.observedAt == reasonAt)
    }

    @Test func aReasonOlderThanTheLastActivityObservationIsNotReportedAsALivePrompt() {
        let reasonAt = t0.addingTimeInterval(100)
        let activityAt = t0.addingTimeInterval(200)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .working,
                activityStateSource: .hookEvent(RPCMethod.terminalActivityEvent),
                activityStateObservedAt: activityAt,
                awaitingInputReason: promptReason("stale permission request"),
                awaitingInputObservedAt: reasonAt)))

        #expect(state.value == .working)
        #expect(state.source == .hookEvent(RPCMethod.terminalActivityEvent))
        #expect(state.observedAt == activityAt)
        // Nothing anywhere in the composed answer repeats the stale prompt.
        #expect(!state.summary.contains("stale permission request"))
    }

    // MARK: - The staleness rule the observed-at comparison cannot express

    /// The mirror of `aReasonOlderThanTheLastActivityObservationIsNotReportedAsALivePrompt`,
    /// and the case that one cannot catch.
    ///
    /// A prompt recorded a second AFTER the turn's `working` stamp wins on
    /// observed-at forever: the activity rail only stamps at turn boundaries and
    /// its handler returns early on an unchanged value, so nothing on that rail
    /// ever retracts the reason. The transcript is the only other interface that
    /// speaks mid-turn — and it cannot settle it either, because a parallel
    /// subagent, a backgrounded task's completion record and a queued user
    /// message all append while the prompt is still up. So growth makes the two
    /// situations indistinguishable, and the answer is `unknown`.
    ///
    /// **The direction this test pins is the dangerous one.** Falling through to
    /// the activity rail here would report `.working` — from a `working` stamp
    /// left by `UserPromptSubmit` at the top of the turn — for a session blocked
    /// on a human, indefinitely.
    @Test func aPromptTheTranscriptHasGrownPastResolvesUnknownRatherThanWorking() {
        let activityAt = t0.addingTimeInterval(100)
        let reasonAt = t0.addingTimeInterval(200)
        let appendedAt = t0.addingTimeInterval(260)
        let readAt = t0.addingTimeInterval(300)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .working,
                activityStateSource: .hookEvent(RPCMethod.terminalActivityEvent),
                activityStateObservedAt: activityAt,
                awaitingInputReason: promptReason("possibly answered permission request"),
                awaitingInputObservedAt: reasonAt),
            transcriptLastAppendedAt: ObservedFact(
                value: appendedAt, source: .transcriptTail, observedAt: readAt)))

        guard case .unknown(let why) = state.value else {
            Issue.record("expected .unknown, got \(state.value)")
            return
        }
        // Both possibilities named, and the two stamps that put them in tension.
        #expect(why.contains("a prompt was reported"))
        #expect(why.contains("the transcript has grown since"))
        #expect(why.contains("cannot be told from machine facts"))
        #expect(why.contains("permission_prompt"))
        #expect(why.contains("prompt_on_screen"))
        // The evidence that made it unknown is the transcript read, so that is
        // the provenance the answer carries.
        #expect(state.source == .transcriptTail)
        #expect(state.observedAt == readAt)
        // The prompt's own text is never composed into a `why` — it may quote
        // repo content, and it rides on `.awaitingInput` for readers entitled
        // to it.
        #expect(!state.summary.contains("possibly answered permission request"))
    }

    /// The symptom that would reveal the unmeasured assumption under the
    /// comparison, made visible on purpose.
    ///
    /// The rule assumes Claude Code flushes the assistant record carrying the
    /// `tool_use` BEFORE it fires the `Notification` hook. If it flushes after,
    /// an unanswered prompt's newest append lands a hair past the reason's
    /// observed-at and **every** prompt resolves unknown — which is what this
    /// asserts, so the day that assumption breaks the failure is a fleet of
    /// unknowns rather than a silent wrong answer. The fix that would then apply
    /// is a tolerance sized to a measured flush lag, deliberately not written
    /// yet.
    @Test func aFlushLandingAfterTheHookWouldMakeEveryPromptResolveUnknown() {
        let reasonAt = t0.addingTimeInterval(200)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .working,
                activityStateSource: .hookEvent(RPCMethod.terminalActivityEvent),
                activityStateObservedAt: t0.addingTimeInterval(100),
                awaitingInputReason: promptReason(),
                awaitingInputObservedAt: reasonAt),
            transcriptLastAppendedAt: ObservedFact(
                value: reasonAt.addingTimeInterval(0.001), source: .transcriptTail,
                observedAt: reasonAt.addingTimeInterval(0.001))))

        guard case .unknown = state.value else {
            Issue.record("expected .unknown, got \(state.value)")
            return
        }
    }

    @Test func aPromptStandsWhileTheTranscriptHasNotGrownPastIt() {
        let reasonAt = t0.addingTimeInterval(200)
        // The last append predates the prompt: the assistant's tool-use record
        // was written, then the prompt appeared, and nothing has been appended
        // since — which is what an unanswered prompt looks like in bytes.
        let appendedAt = t0.addingTimeInterval(199)
        let reason = promptReason()
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .working,
                activityStateSource: .hookEvent(RPCMethod.terminalActivityEvent),
                activityStateObservedAt: t0.addingTimeInterval(100),
                awaitingInputReason: reason,
                awaitingInputObservedAt: reasonAt),
            transcriptLastAppendedAt: ObservedFact(
                value: appendedAt, source: .transcriptTail, observedAt: appendedAt)))

        #expect(state.value == .awaitingInput(reason: reason))
        #expect(state.observedAt == reasonAt)
    }

    @Test func withNoGrowthFactAtAllTheRecordedPromptStillStands() {
        // "We could not read the transcript" is not evidence that the prompt
        // went away, and must never be spent as though it were.
        let reasonAt = t0.addingTimeInterval(200)
        let reason = promptReason()
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .working,
                activityStateSource: .hookEvent(RPCMethod.terminalActivityEvent),
                activityStateObservedAt: t0.addingTimeInterval(100),
                awaitingInputReason: reason,
                awaitingInputObservedAt: reasonAt),
            transcriptLastAppendedAt: nil))

        #expect(state.value == .awaitingInput(reason: reason))
        #expect(state.observedAt == reasonAt)
    }

    @Test func aTranscriptThatGrewBeforeThePromptDecidesNothing() {
        // Ordering, not presence: an append stamp that predates the reason is
        // the ordinary case (the tool-use record itself) and must not read as
        // evidence of an answer.
        let reasonAt = t0.addingTimeInterval(200)
        let reason = promptReason()
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .idle,
                activityStateSource: .hookEvent("Stop"),
                activityStateObservedAt: t0.addingTimeInterval(100),
                awaitingInputReason: reason,
                awaitingInputObservedAt: reasonAt),
            transcriptLastAppendedAt: ObservedFact(
                value: reasonAt, source: .transcriptTail, observedAt: reasonAt)))

        #expect(state.value == .awaitingInput(reason: reason))
    }

    /// Growth puts the *identity* of the live prompt in doubt, not whether one
    /// is live — so when a second rail already says the session is blocked on a
    /// human, the answer stays the confident one.
    ///
    /// Reachable exactly as written: `PreToolUse:AskUserQuestion` sets
    /// `waiting_for_user` on the activity rail (and clears any carried reason),
    /// a `Notification` records a `permission_prompt` after it, and the
    /// transcript then grows. Spending `.unknown` here would discard an
    /// independent, confident observation and — because consumers gate on
    /// `isConfident` — turn a correct actionable answer into a non-answer.
    @Test func aPromptTheTranscriptGrewPastStaysAwaitingInputWhenTheActivityRailCorroboratesIt() {
        let activityAt = t0.addingTimeInterval(100)
        let reasonAt = t0.addingTimeInterval(200)
        let appendedAt = t0.addingTimeInterval(260)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .waitingForUser,
                activityStateSource: .hookEvent(RPCMethod.terminalActivityEvent),
                activityStateObservedAt: activityAt,
                awaitingInputReason: promptReason("possibly answered permission request"),
                awaitingInputObservedAt: reasonAt),
            transcriptLastAppendedAt: ObservedFact(
                value: appendedAt, source: .transcriptTail,
                observedAt: t0.addingTimeInterval(300))))

        // The corroborating fact is the activity observation, so it is that
        // fact's provenance the answer carries — not the transcript read's.
        #expect(state.value == .awaitingInput(reason: nil))
        #expect(state.source == .hookEvent(RPCMethod.terminalActivityEvent))
        #expect(state.observedAt == activityAt)
        #expect(state.value.isConfident)
        // No reason is attached: which prompt is on screen is exactly what the
        // growth put in doubt, and the text may quote repo content besides.
        #expect(!state.summary.contains("possibly answered permission request"))
    }

    /// The same growth with the activity rail saying anything else is still
    /// ambiguous — the corroboration branch must not swallow the `unknown` case
    /// it sits in front of.
    @Test func growthPastAPromptIsStillUnknownWhenTheActivityRailSaysWorking() {
        let reasonAt = t0.addingTimeInterval(200)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .working,
                activityStateSource: .hookEvent(RPCMethod.terminalActivityEvent),
                activityStateObservedAt: t0.addingTimeInterval(100),
                awaitingInputReason: promptReason(),
                awaitingInputObservedAt: reasonAt),
            transcriptLastAppendedAt: ObservedFact(
                value: t0.addingTimeInterval(260), source: .transcriptTail,
                observedAt: t0.addingTimeInterval(300))))

        #expect(state.value.isConfident == false)
        #expect(state.source == .transcriptTail)
    }

    // MARK: - `doneWaiting` outranks a stale activity stamp

    /// `idle_prompt` is Claude Code saying its turn is over and it is sitting at
    /// its own prompt. When `Stop`/`StopFailure` never reached the daemon — a
    /// hook failure, or a stale `tbd` on the pane's PATH, a known failure class
    /// here — `activityState` is stuck at `working` from `UserPromptSubmit`, and
    /// falling through to it would report `.working` for a session whose turn
    /// demonstrably ended: the one answer this resolver may never give for a
    /// session that may be blocked on a human.
    ///
    /// It resolves `.idle`, not `.awaitingInput`: nothing is on screen to
    /// answer, and reporting a prompt that does not exist would send a
    /// supervisor looking for one.
    @Test func aDoneWaitingReasonNewerThanAStaleWorkingStampResolvesIdleNotWorking() {
        let reasonAt = t0.addingTimeInterval(400)
        let idlePrompt = AwaitingInputReason(
            message: "Claude is waiting for your input",
            hookEventName: "Notification",
            notificationType: "idle_prompt")
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .working,
                activityStateSource: .hookEvent(RPCMethod.terminalActivityEvent),
                activityStateObservedAt: t0.addingTimeInterval(100),
                awaitingInputReason: idlePrompt,
                awaitingInputObservedAt: reasonAt)))

        #expect(state.value == .idle)
        #expect(state.source == .hookEvent("Notification"))
        #expect(state.observedAt == reasonAt)
        #expect(state.value.isConfident)
    }

    /// The ordering still decides: a `doneWaiting` reason OLDER than the newest
    /// activity observation is a turn that has since restarted, and the rail
    /// wins. Without this the fix above would be a standing rank rather than an
    /// observed-at comparison.
    @Test func aDoneWaitingReasonOlderThanTheActivityStampDoesNotOutrankIt() {
        let activityAt = t0.addingTimeInterval(500)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .working,
                activityStateSource: .hookEvent(RPCMethod.terminalActivityEvent),
                activityStateObservedAt: activityAt,
                awaitingInputReason: AwaitingInputReason(
                    message: "Claude is waiting for your input",
                    hookEventName: "Notification",
                    notificationType: "idle_prompt"),
                awaitingInputObservedAt: t0.addingTimeInterval(400))))

        #expect(state.value == .working)
        #expect(state.observedAt == activityAt)
    }

    @Test func onlyThePromptOnScreenClassProducesAwaitingInput() {
        // `agent_completed` is `informational`: something happened, nobody is
        // being waited on. It is newer than the activity fact and still does
        // not become `awaitingInput`.
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .idle,
                activityStateSource: .hookEvent("Stop"),
                activityStateObservedAt: t0.addingTimeInterval(100),
                awaitingInputReason: AwaitingInputReason(
                    message: "Agent finished",
                    hookEventName: "Notification",
                    notificationType: "agent_completed"),
                awaitingInputObservedAt: t0.addingTimeInterval(500))))

        #expect(state.value == .idle)
        #expect(state.source == .hookEvent("Stop"))
    }

    @Test func anUnrecognizedNotificationTypeIsNeverGuessedIntoAwaitingInput() {
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .working,
                activityStateSource: .hookEvent(RPCMethod.terminalActivityEvent),
                activityStateObservedAt: t0.addingTimeInterval(100),
                awaitingInputReason: AwaitingInputReason(
                    message: "Claude needs your permission to do a new thing",
                    hookEventName: "Notification",
                    // Spelled exactly like a prompt; this build has never heard
                    // of it, so it stays unrecognized and establishes nothing.
                    notificationType: "permission_prompt_v2"),
                awaitingInputObservedAt: t0.addingTimeInterval(900))))

        #expect(state.value == .working)
    }

    // MARK: - `.unknown` is a distinct outcome

    @Test func nothingToSayResolvesToAnUnknownThatNamesTheMissingFacts() {
        let state = resolver().resolve(SessionStateFacts(terminal: terminal()))

        #expect(state.value.isConfident == false)
        guard case .unknown(let why) = state.value else {
            Issue.record("expected .unknown, got \(state.value)")
            return
        }
        #expect(why.contains("activityStateSource"))
        #expect(why.contains("Notification"))
        #expect(why.contains("liveness"))
        #expect(state.source == .unavailable)
        #expect(state.observedAt == resolveNow)
    }

    @Test func aHalfTripleActivityRowCannotMasqueradeAsAnObservation() {
        // A value with a source but no observed-at: `Terminal.observedActivity`
        // refuses to build a fact out of it, so the resolver must not report
        // `working`.
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .working,
                activityStateSource: .hookEvent(RPCMethod.terminalActivityEvent),
                activityStateObservedAt: nil)))

        #expect(state.value.isConfident == false)
        #expect(state.source == .unavailable)
    }

    @Test func aRecordedUnknownActivityStateKeepsItsHookProvenance() {
        let at = t0.addingTimeInterval(60)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .unknown,
                activityStateSource: .hookEvent(RPCMethod.terminalActivityEvent),
                activityStateObservedAt: at)))

        #expect(state.value.isConfident == false)
        guard case .unknown(let why) = state.value else {
            Issue.record("expected .unknown, got \(state.value)")
            return
        }
        #expect(why.contains("activity rail recorded state 'unknown'"))
        // An unknown that *was* observed keeps the observation's provenance —
        // it is not folded into the `.unavailable` shrug.
        #expect(state.source == .hookEvent(RPCMethod.terminalActivityEvent))
        #expect(state.observedAt == at)
    }

    // MARK: - The delegation trap, pinned

    /// A session waiting on a **background subagent** resolves as `idle`, with
    /// its source and observed-at, and the resolver claims nothing more.
    ///
    /// This shape is deliberate, not an oversight, and the test is named so
    /// that survives. Measured on a live session: a worktree that delegated to
    /// a background agent read idle for twenty minutes while its subagent
    /// churned, because `Stop` fires when the parent's turn ends and the
    /// parent's turn really does end at delegation. The plausible detector —
    /// "an `Agent` tool-use with no matching `tool_result` means a delegation is
    /// outstanding" — fails on exactly this case: a backgrounded agent's
    /// `tool_result` lands immediately (measured: 27 tool-uses, 27 results,
    /// zero pending, subagent running throughout), so the transcript shows a
    /// completed tool call while the work runs out of band.
    ///
    /// Separating the two shapes would mean reading result prose — content
    /// interpretation at a layer that may not interpret content. The design
    /// sends the case to a desk instead, which is the tier allowed to read the
    /// transcript. What compiled TBD owes is carrying the ambiguity honestly:
    /// `idle` **with provenance**, never `idle` presented as "not working".
    @Test func aSessionWaitingOnABackgroundSubagentResolvesAsIdleWithProvenanceNotAsNotWorking() {
        let stopAt = t0.addingTimeInterval(60)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .idle,
                activityStateSource: .hookEvent("Stop"),
                activityStateObservedAt: stopAt)))

        #expect(state.value == .idle)
        #expect(state.source == .hookEvent("Stop"))
        #expect(state.observedAt == stopAt)
        // The composed answer always carries how and when, so a consumer can
        // never receive a bare "idle" it might read as "not working".
        #expect(state.summary.contains("hook:Stop"))
        #expect(state.summary.contains(FactTimestamp.string(from: stopAt)))
    }
}
