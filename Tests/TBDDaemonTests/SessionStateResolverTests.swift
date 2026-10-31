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
        pendingResumeAt: Date? = nil,
        transport: TerminalTransport = .tmux
    ) -> Terminal {
        Terminal(
            worktreeID: UUID(),
            tmuxWindowID: transport == .holder ? "" : "@0",
            tmuxPaneID: transport == .holder ? "" : "%0",
            activityState: activityState,
            hibernatedAt: hibernatedAt,
            hibernateReason: hibernateReason,
            pendingResumeAt: pendingResumeAt,
            activityStateSource: activityStateSource,
            activityStateObservedAt: activityStateObservedAt,
            awaitingInputReason: awaitingInputReason,
            awaitingInputObservedAt: awaitingInputObservedAt,
            transport: transport)
    }

    /// The wait reason the program status store writes: the block alone, no
    /// message text and no hook event.
    private func storedReason(
        _ kind: ProgramStatusBlockKind? = .permission, taskID: String? = nil
    ) -> AwaitingInputReason {
        AwaitingInputReason(
            message: "", programStatusBlock: ProgramStatusBlock(kind: kind, taskID: taskID))
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
        let reportAt = t0.addingTimeInterval(50)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .idle,
                activityStateSource: .programStatus,
                activityStateObservedAt: reportAt),
            transcriptRateLimit: .init(
                limit: DetectedRateLimit(
                    resetsAt: readAt.addingTimeInterval(-60),
                    limitType: "session",
                    rawMessage: "hit your session limit"),
                observedAt: readAt)))

        // The detector classifies a record, not whether the limit still holds.
        #expect(state.value == .idle)
        #expect(state.source == .programStatus)
    }

    @Test func goneComesOnlyFromASuppliedLivenessFact() {
        let observedAt = t0.addingTimeInterval(42)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .working,
                activityStateSource: .programStatus,
                activityStateObservedAt: t0),
            liveness: ObservedFact(value: false, source: .processLiveness, observedAt: observedAt)))

        #expect(state.value == .gone)
        #expect(state.source == .processLiveness)
        #expect(state.observedAt == observedAt)
    }

    @Test func aLivenessFactSayingAliveDoesNotItselfDecideTheState() {
        let reportAt = t0.addingTimeInterval(7)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .working,
                activityStateSource: .programStatus,
                activityStateObservedAt: reportAt),
            liveness: ObservedFact(value: true, source: .processLiveness, observedAt: t0)))

        #expect(state.value == .working)
        #expect(state.source == .programStatus)
        #expect(state.observedAt == reportAt)
    }

    // MARK: - The column rung

    @Test func awaitingInputCarriesTheColumnsSourceAndStamp() {
        let reportAt = t0.addingTimeInterval(300)
        let reason = storedReason(.question)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .waitingForUser,
                activityStateSource: .programStatus,
                activityStateObservedAt: reportAt,
                awaitingInputReason: reason,
                awaitingInputObservedAt: reportAt)))

        #expect(state.value == .awaitingInput(reason: reason))
        #expect(state.source == .programStatus)
        #expect(state.observedAt == reportAt)
    }

    /// The store writes the block it was told about and no hook event, so the
    /// reason carries no event name; it still rides on the wait.
    @Test func aWaitingColumnCarriesItsStoredBlock() throws {
        let reportAt = t0.addingTimeInterval(20)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .waitingForUser,
                activityStateSource: .programStatus,
                activityStateObservedAt: reportAt,
                awaitingInputReason: storedReason(.permission, taskID: "t1"),
                awaitingInputObservedAt: reportAt)))

        guard case .awaitingInput(let reason) = state.value else {
            Issue.record("expected awaitingInput, got \(state.value)")
            return
        }
        let carried = try #require(reason)
        #expect(carried.programStatusBlock == ProgramStatusBlock(kind: .permission, taskID: "t1"))
        #expect(carried.message == "")
        #expect(carried.classification == .promptOnScreen)
    }

    @Test func aWaitingColumnWithNoStoredReasonCarriesNone() {
        let reportAt = t0.addingTimeInterval(400)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .waitingForUser,
                activityStateSource: .programStatus,
                activityStateObservedAt: reportAt)))

        #expect(state.value == .awaitingInput(reason: nil))
        #expect(state.source == .programStatus)
        #expect(state.observedAt == reportAt)
    }

    @Test func workingAndIdleCarryTheColumnsProvenance() {
        let at = t0.addingTimeInterval(11)
        let working = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .working,
                activityStateSource: .programStatus,
                activityStateObservedAt: at)))
        #expect(working.value == .working)
        #expect(working.source == .programStatus)
        #expect(working.observedAt == at)

        let idle = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .idle,
                activityStateSource: .programStatus,
                activityStateObservedAt: at)))
        #expect(idle.value == .idle)
        #expect(idle.source == .programStatus)
        #expect(idle.observedAt == at)
    }

    // MARK: - The ordering itself

    @Test func aParkedTerminalWithAStaleAwaitingInputReasonResolvesAsParked() {
        let parkedAt = t0.addingTimeInterval(900)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .waitingForUser,
                activityStateSource: .programStatus,
                activityStateObservedAt: t0.addingTimeInterval(800),
                awaitingInputReason: storedReason(),
                awaitingInputObservedAt: t0.addingTimeInterval(800),
                hibernatedAt: parkedAt,
                hibernateReason: .auto)))

        // The park tore down the process the prompt was on.
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

    @Test func rateLimitedOutranksAnIdleColumn() {
        let until = t0.addingTimeInterval(2_400)
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .idle,
                activityStateSource: .programStatus,
                activityStateObservedAt: t0.addingTimeInterval(1_000),
                pendingResumeAt: until)))

        // A rate-limited session's turn genuinely did end, so the agent
        // reports idle. Reporting idle would invite a send it cannot act on.
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

    // MARK: - `.unknown` is a distinct outcome

    @Test func nothingToSayResolvesToAnUnknownFromNoSource() {
        let state = resolver().resolve(SessionStateFacts(terminal: terminal()))

        #expect(state.value.isConfident == false)
        #expect(state.source == .unavailable)
        #expect(state.observedAt == resolveNow)
    }

    /// A recorded `.unknown` — the reset an incarnation change writes — says
    /// nothing, so it falls to the unknown rung like no record at all.
    @Test func unknownNamesTheTmuxTransport() {
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(
                activityState: .unknown,
                activityStateSource: .derived,
                activityStateObservedAt: t0.addingTimeInterval(60))))

        #expect(state.value == .unknown(
            why: "this session runs on the tmux transport, which does not carry agent status"))
        #expect(state.source == .unavailable)
        #expect(state.observedAt == resolveNow)
    }

    @Test func unknownNamesAMissingReportOnHolder() {
        let state = resolver().resolve(SessionStateFacts(
            terminal: terminal(transport: .holder)))

        #expect(state.value == .unknown(
            why: "the agent has not reported its status from this session's current incarnation"))
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
                activityStateSource: .programStatus,
                activityStateObservedAt: nil)))

        #expect(state.value.isConfident == false)
        #expect(state.source == .unavailable)
    }
}
