import Foundation
import Testing
@testable import TBDShared

/// Tier 1. The state model's promise is that a fact never loses its
/// provenance and never repairs ignorance into confidence. These tests assert
/// exactly those two things, on the wire and on the composed output a reader
/// actually sees.
@Suite struct SessionStateModelTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    // MARK: - SessionStateValue

    @Test(arguments: [
        SessionStateValue.working,
        .idle,
        .awaitingInput(reason: nil),
        .awaitingInput(reason: AwaitingInputReason(
            message: "Claude needs your permission to use Bash",
            hookEventName: "Notification",
            raw: #"{"hook_event_name":"Notification"}"#)),
        .rateLimited(until: nil),
        .rateLimited(until: Date(timeIntervalSince1970: 1_770_003_600)),
        .parked(reason: "manual"),
        .gone,
        .unknown(why: "transcript unreadable")
    ])
    func everyStateRoundTrips(state: SessionStateValue) throws {
        #expect(try roundTrip(state) == state)
    }

    /// An unrecognized tag is ignorance, and stays ignorance: it must not throw
    /// (which would take the whole record with it) and must not become a
    /// confident value (which would have a supervisor act on a session nobody
    /// could read).
    @Test func unrecognizedStateTagDecodesToUnknown() throws {
        let json = #"{"state":"compacting","detail":"whatever"}"#
        let decoded = try JSONDecoder().decode(SessionStateValue.self, from: Data(json.utf8))

        #expect(decoded.isConfident == false)
        guard case .unknown(let why) = decoded else {
            Issue.record("expected .unknown, got \(decoded)")
            return
        }
        #expect(why == "unrecognized state tag 'compacting'")
        // And the raw tag survives into anything rendered from it.
        #expect(decoded.label.contains("compacting"))
    }

    @Test func onlyUnknownIsUnconfident() {
        #expect(SessionStateValue.working.isConfident)
        #expect(SessionStateValue.idle.isConfident)
        #expect(SessionStateValue.awaitingInput(reason: nil).isConfident)
        #expect(SessionStateValue.rateLimited(until: nil).isConfident)
        #expect(SessionStateValue.parked(reason: "manual").isConfident)
        #expect(SessionStateValue.gone.isConfident)
        #expect(SessionStateValue.unknown(why: "no source").isConfident == false)
    }

    /// The reason is carried, never interpreted — so it survives a round trip
    /// byte for byte, including the raw payload.
    @Test func awaitingInputReasonIsCarriedVerbatim() throws {
        let reason = AwaitingInputReason(
            message: "Claude needs your permission to use Bash",
            hookEventName: "Notification",
            raw: #"{"message":"Claude needs your permission to use Bash"}"#)
        let decoded = try roundTrip(reason)
        #expect(decoded == reason)
        #expect(decoded.message == "Claude needs your permission to use Bash")
        #expect(decoded.raw == #"{"message":"Claude needs your permission to use Bash"}"#)
    }

    // MARK: - Awaiting-input classification

    struct ClassCase: Sendable, CustomStringConvertible {
        let type: String?
        let expected: AwaitingInputClass
        var description: String { "\(type ?? "<absent>") → \(expected.rawValue)" }
    }

    /// One case per branch of the classifier, including the two that must
    /// land in `unrecognized`.
    @Test(arguments: [
        ClassCase(type: "permission_prompt", expected: .promptOnScreen),
        ClassCase(type: "elicitation_dialog", expected: .promptOnScreen),
        ClassCase(type: "agent_needs_input", expected: .promptOnScreen),
        ClassCase(type: "idle_prompt", expected: .doneWaiting),
        ClassCase(type: "auth_success", expected: .informational),
        ClassCase(type: "elicitation_complete", expected: .informational),
        ClassCase(type: "elicitation_response", expected: .informational),
        ClassCase(type: "agent_completed", expected: .informational),
        ClassCase(type: "a_type_from_a_later_release", expected: .unrecognized),
        ClassCase(type: nil, expected: .unrecognized)
    ])
    func notificationTypeIsFiledUnderItsClass(branch: ClassCase) throws {
        let reason = AwaitingInputReason(
            message: "m", hookEventName: "Notification", notificationType: branch.type)
        #expect(reason.classification == branch.expected)
        // Verbatim through a round trip, class and all.
        let decoded = try roundTrip(reason)
        #expect(decoded.notificationType == branch.type)
        #expect(decoded.classification == branch.expected)
    }

    /// The stored class is a convenience for outside readers, never an input:
    /// a record claiming `prompt_on_screen` for a type this build does not
    /// know is re-derived to `unrecognized` on the way in. Without that, a
    /// hand-edited row (or a newer daemon's vocabulary) could put a type in a
    /// class this build's own classifier would refuse it.
    @Test func decodingRederivesTheClassRatherThanTrustingIt() throws {
        let json = #"""
        {"message":"m","hookEventName":"Notification",\#
        "notificationType":"a_type_from_a_later_release","classification":"prompt_on_screen"}
        """#
        let decoded = try JSONDecoder().decode(AwaitingInputReason.self, from: Data(json.utf8))
        #expect(decoded.notificationType == "a_type_from_a_later_release")
        #expect(decoded.classification == .unrecognized)
    }

    /// An unrecognized class *tag* is also ignorance rather than a throw — the
    /// same promise `FactSource` and `SessionStateValue` make.
    @Test func unrecognizedClassTagDecodesToUnrecognized() throws {
        let decoded = try JSONDecoder().decode(
            AwaitingInputClass.self, from: Data(#""some_future_class""#.utf8))
        #expect(decoded == .unrecognized)
    }

    /// A row written before the type was modelled still decodes, with no type
    /// and no invented class.
    @Test func legacyReasonJSONDecodesAsUnrecognized() throws {
        let json = #"{"message":"Claude needs your permission","hookEventName":"Notification"}"#
        let decoded = try JSONDecoder().decode(AwaitingInputReason.self, from: Data(json.utf8))
        #expect(decoded.message == "Claude needs your permission")
        #expect(decoded.notificationType == nil)
        #expect(decoded.classification == .unrecognized)
    }

    /// The composed line a reader sees carries the message, the class, the
    /// verbatim type, the source and the age — none of them droppable.
    @Test func reasonFactSummaryComposesEverything() {
        let reason = AwaitingInputReason(
            message: "Claude needs your permission to use Bash",
            hookEventName: "Notification",
            notificationType: "permission_prompt")
        let fact = ObservedFact(
            value: reason, source: .hookEvent("Notification"), observedAt: epoch)
        let summary = fact.summary
        #expect(summary.contains("Claude needs your permission to use Bash"))
        #expect(summary.contains("prompt_on_screen"))
        #expect(summary.contains("type=permission_prompt"))
        #expect(summary.contains("source: hook:Notification"))
        #expect(summary.contains(FactTimestamp.string(from: epoch)))
    }

    /// Half a triple is not a fact here either. The wait reason's source is the
    /// hook event that delivered it, so a reason with no event name — like a
    /// reason with no observed-at — reports nothing rather than letting a bare
    /// message masquerade as an observation.
    @Test func awaitingInputFactNeedsBothItsHalves() {
        let reason = AwaitingInputReason(
            message: "Claude needs your permission",
            hookEventName: "Notification",
            notificationType: "permission_prompt")
        func terminal(
            reason: AwaitingInputReason?, observedAt: Date?
        ) -> Terminal {
            Terminal(
                worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
                awaitingInputReason: reason, awaitingInputObservedAt: observedAt)
        }

        let whole = terminal(reason: reason, observedAt: epoch).observedAwaitingInput
        #expect(whole?.value == reason)
        #expect(whole?.source == .hookEvent("Notification"))
        #expect(whole?.observedAt == epoch)

        #expect(terminal(reason: reason, observedAt: nil).observedAwaitingInput == nil)
        #expect(terminal(reason: nil, observedAt: epoch).observedAwaitingInput == nil)
        let nameless = AwaitingInputReason(message: "m", hookEventName: nil)
        #expect(terminal(reason: nameless, observedAt: epoch).observedAwaitingInput == nil)
        // An EMPTY name names a source exactly as poorly as no name at all: it
        // would render as the bare `hook:` and pass every "does this fact say
        // where it came from" check while saying nothing.
        let blank = AwaitingInputReason(message: "m", hookEventName: "")
        #expect(terminal(reason: blank, observedAt: epoch).observedAwaitingInput == nil)
    }

    // MARK: - FactSource

    @Test(arguments: [
        FactSource.hookEvent("Notification"),
        .transcriptTail,
        .statuslineTee,
        .database,
        .processLiveness,
        .forge,
        .gitSweep,
        .derived,
        .unavailable,
        .unrecognized("screen-scrape")
    ])
    func everySourceRoundTrips(source: FactSource) throws {
        #expect(try roundTrip(source) == source)
    }

    @Test func unrecognizedSourceKindDecodesWithoutThrowing() throws {
        let json = #"{"kind":"telepathy","detail":"ignored"}"#
        let decoded = try JSONDecoder().decode(FactSource.self, from: Data(json.utf8))
        #expect(decoded == .unrecognized("telepathy"))
        // The unknown name is reportable, not swallowed.
        #expect(decoded.summary == "telepathy")
    }

    /// `hook` with no `detail` is not a source. The qualifier IS the
    /// provenance — which hook fired — so an empty one produces a fact that
    /// renders as the bare `hook:` and satisfies every check for "does this
    /// name its source" while naming nothing.
    @Test func aHookSourceWithNoEventNameIsNotAHookSource() throws {
        for json in [#"{"kind":"hook"}"#, #"{"kind":"hook","detail":""}"#] {
            let decoded = try JSONDecoder().decode(FactSource.self, from: Data(json.utf8))
            #expect(decoded == .unrecognized("hook"), "decoded \(json) as \(decoded)")
            #expect(decoded.summary == "hook")
            // And it round-trips back to the same bytes rather than inventing
            // an empty detail on the way out.
            #expect(try roundTrip(decoded) == decoded)
        }
    }

    @Test func hookEventSourceCarriesItsEventName() throws {
        let decoded = try roundTrip(FactSource.hookEvent("Notification"))
        #expect(decoded == .hookEvent("Notification"))
        #expect(decoded.summary == "hook:Notification")
    }

    @Test func userActionSourceCarriesItsActionName() throws {
        let json = #"{"kind":"user-action","detail":"terminal-interrupt"}"#
        let decoded = try JSONDecoder().decode(FactSource.self, from: Data(json.utf8))

        #expect(decoded.kind == "user-action")
        #expect(decoded.detail == "terminal-interrupt")
        #expect(decoded.summary == "user-action:terminal-interrupt")
        #expect(try roundTrip(decoded) == decoded)
    }

    // MARK: - ObservedFact.summary

    /// Assert on the COMPOSED line, not on the presence of the three fields:
    /// the guarantee is that no rendering of a fact can omit where it came from
    /// or when it was seen, and only the composed output can show that.
    @Test func summaryComposesValueSourceAndObservedAt() {
        let fact = SessionState(
            value: .awaitingInput(reason: nil),
            source: .hookEvent("Notification"),
            observedAt: epoch)

        #expect(fact.summary ==
            "awaiting input (source: hook:Notification, observed 2026-02-02T02:40:00Z)")
    }

    @Test func summaryOfAnUnknownStateNamesWhyAndItsSource() {
        let fact = SessionState(
            value: .unknown(why: "no transcript"), source: .unavailable, observedAt: epoch)
        #expect(fact.summary ==
            "unknown (no transcript) (source: unavailable, observed 2026-02-02T02:40:00Z)")
    }

    @Test func summaryOfAPlainValueStillCarriesProvenance() {
        let fact = ObservedFact(value: 42, source: .transcriptTail, observedAt: epoch)
        #expect(fact.summary == "42 (source: transcript-tail, observed 2026-02-02T02:40:00Z)")
    }

    @Test func observedFactRoundTrips() throws {
        let fact = SessionState(
            value: .rateLimited(until: epoch), source: .transcriptTail, observedAt: epoch)
        #expect(try roundTrip(fact) == fact)
    }

    // MARK: - Context load

    @Test func unknownWindowFallsBackToTheLabeledAssumption() {
        let (tokens, assumed) = ContextWindow.unknown(why: "no statusline tee").effectiveTokens()
        #expect(tokens == 200_000)
        #expect(assumed)
        #expect(ContextWindow.assumedTokens == 200_000)
    }

    @Test func observedWindowIsNotAssumed() {
        let window = ContextWindow.observed(
            ObservedFact(value: 1_000_000, source: .statuslineTee, observedAt: epoch))
        let (tokens, assumed) = window.effectiveTokens()
        #expect(tokens == 1_000_000)
        #expect(assumed == false)
    }

    @Test func percentUsedIsNilWhenTheNumeratorIsUnknown() {
        let load = ContextLoad(used: nil, window: .observed(
            ObservedFact(value: 200_000, source: .statuslineTee, observedAt: epoch)))
        #expect(load.percentUsed() == nil)
    }

    @Test func percentUsedFlagsTheAssumedWindow() throws {
        let load = ContextLoad(
            used: ObservedFact(value: 50_000, source: .transcriptTail, observedAt: epoch),
            window: .unknown(why: "no statusline tee"))
        let result = try #require(load.percentUsed())
        #expect(result.percent == 25.0)
        #expect(result.assumedWindow)
    }

    @Test func percentUsedDoesNotFlagAnObservedWindow() throws {
        let load = ContextLoad(
            used: ObservedFact(value: 50_000, source: .transcriptTail, observedAt: epoch),
            window: .observed(
                ObservedFact(value: 1_000_000, source: .statuslineTee, observedAt: epoch)))
        let result = try #require(load.percentUsed())
        #expect(result.percent == 5.0)
        #expect(result.assumedWindow == false)
    }

    @Test func contextLoadRoundTrips() throws {
        let load = ContextLoad(
            used: ObservedFact(value: 50_000, source: .transcriptTail, observedAt: epoch),
            window: .unknown(why: "no statusline tee"))
        #expect(try roundTrip(load) == load)
    }

    /// An unfamiliar window tag becomes `unknown`, so the denominator falls back
    /// to the LABELED assumption rather than to a number nobody observed.
    @Test func unrecognizedWindowTagDecodesToUnknown() throws {
        let json = #"{"window":"estimated","fact":{}}"#
        let decoded = try JSONDecoder().decode(ContextWindow.self, from: Data(json.utf8))
        let (tokens, assumed) = decoded.effectiveTokens()
        #expect(tokens == 200_000)
        #expect(assumed)
        guard case .unknown(let why) = decoded else {
            Issue.record("expected .unknown, got \(decoded)")
            return
        }
        #expect(why == "unrecognized window tag 'estimated'")
    }

    // MARK: - PRObservation

    @Test(arguments: [
        PRObservation.Outcome.observed,
        .none,
        .undetermined(cause: "network unreachable")
    ])
    func everyPROutcomeRoundTrips(outcome: PRObservation.Outcome) throws {
        let observation = PRObservation(outcome: outcome, observedAt: epoch)
        #expect(try roundTrip(observation) == observation)
    }

    /// The bug this type exists to prevent: "the forge answered; no PR" and
    /// "we could not find out" are different facts, before AND after the wire.
    @Test func noneAndUndeterminedStayDistinguishable() throws {
        let answered = PRObservation(outcome: .none, observedAt: epoch)
        let failed = PRObservation(
            outcome: .undetermined(cause: "network unreachable"), observedAt: epoch)

        #expect(answered != failed)
        #expect(answered.outcome != failed.outcome)

        let answeredBack = try roundTrip(answered)
        let failedBack = try roundTrip(failed)
        #expect(answeredBack != failedBack)
        #expect(answeredBack.outcome == .none)
        #expect(failedBack.outcome == .undetermined(cause: "network unreachable"))
    }

    @Test func unrecognizedOutcomeTagDecodesToUndetermined() throws {
        let json = #"{"outcome":"rate_limited"}"#
        let decoded = try JSONDecoder().decode(PRObservation.Outcome.self, from: Data(json.utf8))
        guard case .undetermined(let cause) = decoded else {
            Issue.record("expected .undetermined, got \(decoded)")
            return
        }
        #expect(cause == "unrecognized outcome tag 'rate_limited'")
        // Emphatically NOT `.none`: that would assert the forge answered.
        #expect(decoded != PRObservation.Outcome.none)
    }

    // MARK: - Counters and report

    @Test func sessionCountersRoundTrip() throws {
        let counters = SessionCounters(
            turnsInWindow: 12,
            hookEventsInWindow: 40,
            windowStart: epoch,
            observedAt: epoch.addingTimeInterval(600),
            commitsUnchangedSince: epoch.addingTimeInterval(-3600))
        #expect(try roundTrip(counters) == counters)
    }

    @Test func reportRoundTripsWithItsOptionalsEmpty() throws {
        let report = SessionStateReport(
            terminalID: UUID(),
            worktreeID: UUID(),
            state: SessionState(value: .working, source: .hookEvent("UserPromptSubmit"),
                                observedAt: epoch))
        let decoded = try roundTrip(report)
        #expect(decoded == report)
        #expect(decoded.contextLoad == nil)
        #expect(decoded.counters == nil)
    }

    @Test func reportRoundTripsWithItsOptionalsFilled() throws {
        let report = SessionStateReport(
            terminalID: UUID(),
            worktreeID: UUID(),
            state: SessionState(value: .idle, source: .hookEvent("Stop"), observedAt: epoch),
            contextLoad: ContextLoad(
                used: ObservedFact(value: 90_000, source: .transcriptTail, observedAt: epoch),
                window: .observed(
                    ObservedFact(value: 200_000, source: .statuslineTee, observedAt: epoch))),
            counters: SessionCounters(
                turnsInWindow: 3, hookEventsInWindow: 9,
                windowStart: epoch, observedAt: epoch))
        #expect(try roundTrip(report) == report)
    }
}
