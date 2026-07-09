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
    private func claudeTerminal(
        activityState: TerminalActivityState = .idle,
        keepWarm: Bool = false,
        hibernatedAt: Date? = nil,
        suspendedAt: Date? = nil,
        sessionID: String? = "sess-1",
        kind: TerminalKind? = .claude
    ) -> Terminal {
        Terminal(
            worktreeID: UUID(), tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", claudeSessionID: sessionID,
            suspendedAt: suspendedAt, kind: kind,
            activityState: activityState, hibernatedAt: hibernatedAt, keepWarm: keepWarm
        )
    }

    // MARK: - The go path: no idle window at all

    @Test func eligibleForIdleResumableWithNoIdleMarker() {
        // No idleSince is even passed — proving the idle window is absent from
        // merge-park. An idle resumable Claude terminal is a valid park target
        // the instant its PR merges.
        let t = claudeTerminal(activityState: .idle)
        #expect(HibernationGate.decideForMerge(terminal: t) == .eligible)
    }

    @Test func eligibleForUnknownActivity() {
        // `.unknown` (hook hasn't fired) is treated as at-rest, same as the sweep.
        let t = claudeTerminal(activityState: .unknown)
        #expect(HibernationGate.decideForMerge(terminal: t) == .eligible)
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
        #expect(HibernationGate.decideForMerge(terminal: t) == .eligible)
    }

    // MARK: - Hard safety rails (each blocks)

    @Test func keepWarmBlocks() {
        // Merge-park HONORS keep-warm (unlike manualHibernate).
        let t = claudeTerminal(keepWarm: true)
        #expect(HibernationGate.decideForMerge(terminal: t) == .keepWarm)
    }

    @Test func runningTurnBlocks() {
        let t = claudeTerminal(activityState: .working)
        #expect(HibernationGate.decideForMerge(terminal: t) == .running)
    }

    @Test func waitingForUserBlocks() {
        let t = claudeTerminal(activityState: .waitingForUser)
        #expect(HibernationGate.decideForMerge(terminal: t) == .waitingForUser)
    }

    @Test func alreadyHibernatedBlocks() {
        let t = claudeTerminal(hibernatedAt: Date(timeIntervalSince1970: 1))
        #expect(HibernationGate.decideForMerge(terminal: t) == .alreadyHibernated)
    }

    @Test func suspendedBlocks() {
        let t = claudeTerminal(suspendedAt: Date(timeIntervalSince1970: 1))
        #expect(HibernationGate.decideForMerge(terminal: t) == .suspended)
    }

    @Test func nonClaudeBlocks() {
        let t = claudeTerminal(sessionID: nil, kind: .shell)
        #expect(HibernationGate.decideForMerge(terminal: t) == .notClaudeResumable)
    }
}
