import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

/// Every branch of the MERGE-triggered park decision (`decideForMerge`). Proves
/// it (a) has NO idle window and NO master switch, and (b) still enforces every
/// hard safety rail. Pure: no DB, no tmux, no actor. One test per rail per
/// CLAUDE.md's "test every gated branch" rule.
@Suite("HibernationGateMerge")
struct HibernationGateMergeTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func claudeTerminal(
        activityState: TerminalActivityState = .idle,
        keepWarm: Bool = false,
        hibernatedAt: Date? = nil,
        suspendedAt: Date? = nil,
        sessionID: String? = "sess-1",
        kind: TerminalKind? = .claude,
        activityStateObservedAt: Date? = nil
    ) -> Terminal {
        Terminal(
            worktreeID: UUID(), tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", claudeSessionID: sessionID,
            suspendedAt: suspendedAt, kind: kind,
            activityState: activityState, hibernatedAt: hibernatedAt, keepWarm: keepWarm,
            activityStateObservedAt: activityStateObservedAt
        )
    }

    /// Default-carrying wrapper so the rail tests read as they did before the
    /// veto arguments existed: veto OFF, no recorded input — i.e. exactly
    /// today's merge-park behavior.
    private func decideForMerge(
        _ terminal: Terminal,
        inputVetoEnabled: Bool = false,
        lastInputAt: Date? = nil
    ) -> HibernationGate.Decision {
        HibernationGate.decideForMerge(
            terminal: terminal, inputVetoEnabled: inputVetoEnabled, lastInputAt: lastInputAt)
    }

    // MARK: - The go path: no idle window at all

    @Test func eligibleForIdleResumableWithNoIdleMarker() {
        // No idleSince is even passed — proving the idle window is absent from
        // merge-park. An idle resumable Claude terminal is a valid park target
        // the instant its PR merges.
        let t = claudeTerminal(activityState: .idle)
        #expect(decideForMerge(t) == .eligible)
    }

    @Test func eligibleForUnknownActivity() {
        // `.unknown` (hook hasn't fired) is treated as at-rest, same as the sweep.
        let t = claudeTerminal(activityState: .unknown)
        #expect(decideForMerge(t) == .eligible)
    }

    // MARK: - Independence from the idle-sweep master switch

    @Test func eligibleEvenThoughMasterSwitchWouldBeOff() {
        // `decideForMerge` takes NO `autoHibernateEnabled` argument, so there is
        // structurally no way for the idle sweep's master switch to gate it.
        // Cross-check against `decide(...)` with the switch OFF: that would return
        // `.featureDisabled`, but merge-park stays `.eligible`.
        let t = claudeTerminal(activityState: .idle)
        let sweepWithSwitchOff = HibernationGate.decide(
            terminal: t, autoHibernateEnabled: false,
            idleTimeout: 30 * 60,
            idleSince: Date(timeIntervalSince1970: 0), now: Date()
        )
        #expect(sweepWithSwitchOff == .featureDisabled)
        #expect(decideForMerge(t) == .eligible)
    }

    // MARK: - Hard safety rails (each blocks)

    @Test func keepWarmBlocks() {
        // Merge-park HONORS keep-warm (unlike manualHibernate).
        let t = claudeTerminal(keepWarm: true)
        #expect(decideForMerge(t) == .keepWarm)
    }

    @Test func runningTurnBlocks() {
        let t = claudeTerminal(activityState: .working)
        #expect(decideForMerge(t) == .running)
    }

    @Test func waitingForUserBlocks() {
        let t = claudeTerminal(activityState: .waitingForUser)
        #expect(decideForMerge(t) == .waitingForUser)
    }

    @Test func alreadyHibernatedBlocks() {
        let t = claudeTerminal(hibernatedAt: Date(timeIntervalSince1970: 1))
        #expect(decideForMerge(t) == .alreadyHibernated)
    }

    @Test func suspendedBlocks() {
        let t = claudeTerminal(suspendedAt: Date(timeIntervalSince1970: 1))
        #expect(decideForMerge(t) == .suspended)
    }

    @Test func nonClaudeBlocks() {
        let t = claudeTerminal(sessionID: nil, kind: .shell)
        #expect(decideForMerge(t) == .notClaudeResumable)
    }

    // MARK: - Rail: pending typed input (input veto)
    //
    // Merge-park has no idle marker, so it compares `lastInputAt` against
    // `activityStateObservedAt` — the moment the session was observed to enter
    // the at-rest state it is in now.

    @Test func typedInputAfterGoingIdleBlocksWhenVetoEnabled() {
        // The headline guarantee, on the MERGE path: a session that was typed
        // into after it came to rest is not parked when its PR merges. Nobody
        // is watching — merge-park now runs on the daemon's clock.
        let atRest = now.addingTimeInterval(-10 * 60)
        let t = claudeTerminal(activityStateObservedAt: atRest)
        #expect(decideForMerge(
            t, inputVetoEnabled: true,
            lastInputAt: now.addingTimeInterval(-30)) == .pendingTypedInput)
    }

    @Test func typedInputAfterGoingIdleIsEligibleWhenVetoDisabled() {
        // Flag OFF + identical inputs → `.eligible`. Proves the rail is truly
        // gated and pins today's behavior for installs that have not opted in.
        let atRest = now.addingTimeInterval(-10 * 60)
        let t = claudeTerminal(activityStateObservedAt: atRest)
        #expect(decideForMerge(
            t, inputVetoEnabled: false,
            lastInputAt: now.addingTimeInterval(-30)) == .eligible)
    }

    @Test func inputConsumedBeforeGoingIdleIsEligible() {
        // Input recorded BEFORE the at-rest observation was submitted: the turn
        // it started is what put the session back at rest. Nothing pending, so
        // merge-park proceeds exactly as it does today.
        let atRest = now.addingTimeInterval(-60)
        let t = claudeTerminal(activityStateObservedAt: atRest)
        #expect(decideForMerge(
            t, inputVetoEnabled: true,
            lastInputAt: now.addingTimeInterval(-10 * 60)) == .eligible)
    }

    @Test func noRecordedInputIsEligibleWithVetoOn() {
        // Veto ON but nothing was ever typed into this pane (post-restart, or a
        // pane only ever driven by TBD). The gate has no reason to refuse.
        let t = claudeTerminal(activityStateObservedAt: now.addingTimeInterval(-60))
        #expect(decideForMerge(t, inputVetoEnabled: true, lastInputAt: nil) == .eligible)
    }

    @Test func inputAtExactlyTheAtRestInstantBlocks() {
        // `>=`, matching the sweep: input at the same instant as the at-rest
        // observation counts as arriving after it.
        let atRest = now.addingTimeInterval(-5 * 60)
        let t = claudeTerminal(activityStateObservedAt: atRest)
        #expect(decideForMerge(
            t, inputVetoEnabled: true, lastInputAt: atRest) == .pendingTypedInput)
    }

    @Test func recordedInputWithNoObservationFailsClosed() {
        // A row with no `activityStateObservedAt` (written before the
        // provenance columns, or by a writer that never stamped one) offers no
        // evidence the recorded input was ever consumed. Refuse: a session that
        // survives a merge-park is recoverable, eaten input is not.
        let t = claudeTerminal(activityStateObservedAt: nil)
        #expect(decideForMerge(
            t, inputVetoEnabled: true,
            lastInputAt: now.addingTimeInterval(-60)) == .pendingTypedInput)
    }

    @Test func noObservationAndNoInputIsStillEligible() {
        // The fail-closed arm above is scoped to rows that HAVE recorded input.
        // A row with neither is the ordinary pre-provenance case and still parks.
        let t = claudeTerminal(activityStateObservedAt: nil)
        #expect(decideForMerge(t, inputVetoEnabled: true, lastInputAt: nil) == .eligible)
    }

    // MARK: - Precedence: hard rails still win

    @Test func inputVetoLosesToRunning() {
        let t = claudeTerminal(
            activityState: .working, activityStateObservedAt: now.addingTimeInterval(-10 * 60))
        #expect(decideForMerge(
            t, inputVetoEnabled: true, lastInputAt: now) == .running)
    }

    @Test func inputVetoLosesToKeepWarm() {
        let t = claudeTerminal(
            keepWarm: true, activityStateObservedAt: now.addingTimeInterval(-10 * 60))
        #expect(decideForMerge(t, inputVetoEnabled: true, lastInputAt: now) == .keepWarm)
    }

    @Test func inputVetoLosesToAlreadyHibernated() {
        let t = claudeTerminal(
            hibernatedAt: now.addingTimeInterval(-60),
            activityStateObservedAt: now.addingTimeInterval(-10 * 60))
        #expect(decideForMerge(t, inputVetoEnabled: true, lastInputAt: now) == .alreadyHibernated)
    }
}
