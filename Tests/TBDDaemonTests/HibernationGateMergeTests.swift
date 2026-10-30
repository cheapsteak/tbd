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

    private func decideForMerge(_ terminal: Terminal) -> HibernationGate.Decision {
        HibernationGate.decideForMerge(terminal: terminal)
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

    // MARK: - Merge-park rides the same rails on every transport

    /// A holder-backed row that passes every other merge rail, so the only
    /// thing the tests below vary is the transport.
    private func holderTerminal() -> Terminal {
        Terminal(
            worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            label: "claude", claudeSessionID: "sess-1", kind: .claude,
            activityState: .idle,
            activityStateObservedAt: now.addingTimeInterval(-10 * 60),
            transport: .holder)
    }

    /// Merge-park elects a holder row on the same terms it elects a tmux one —
    /// the per-worktree tri-state and `auto_hibernate_on_merge_default` decide
    /// the fan-out, and transport decides nothing.
    @Test func mergeParkElectsAHolderRow() {
        #expect(HibernationGate.decideForMerge(terminal: holderTerminal()) == .eligible)
    }

    /// The two transports get the same answer from the same facts, which is
    /// what makes the assertions above about the rails rather than about a
    /// transport special case.
    @Test func bothTransportsGetTheSameAnswerFromTheSameFacts() {
        #expect(HibernationGate.decideForMerge(terminal: claudeTerminal()) == .eligible)
        #expect(HibernationGate.decideForMerge(
            terminal: claudeTerminal(keepWarm: true)) == .keepWarm)
        var warmHolder = holderTerminal()
        warmHolder.keepWarm = true
        #expect(HibernationGate.decideForMerge(terminal: warmHolder) == .keepWarm)
    }
}
