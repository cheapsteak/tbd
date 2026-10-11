import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct TransportMigrationEligibilityTests {
    private func makeTerminal(
        transport: TerminalTransport = .tmux,
        kind: TerminalKind? = .claude,
        claudeSessionID: String? = "session-1",
        activityState: TerminalActivityState = .idle,
        hibernatedAt: Date? = nil
    ) -> Terminal {
        Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            claudeSessionID: claudeSessionID, kind: kind,
            activityState: activityState, hibernatedAt: hibernatedAt,
            transport: transport)
    }

    @Test func aHolderRowIsAlreadyWhereItBelongs() {
        let t = makeTerminal(transport: .holder)
        #expect(TransportMigrationEligibility.decide(t) == .alreadyHolder)
    }

    @Test func aWorkingSessionIsSkippedWithItsReason() {
        let t = makeTerminal(activityState: .working)
        #expect(TransportMigrationEligibility.decide(t)
            == .skip(reason: "Session is actively running"))
    }

    @Test func aSessionWaitingOnAPromptIsSkipped() {
        let t = makeTerminal(activityState: .waitingForUser)
        #expect(TransportMigrationEligibility.decide(t)
            == .skip(reason: "Session is waiting on a permission prompt"))
    }

    // The resumable-Claude guard that the profile swap and manual hibernate
    // apply is deliberately NOT applied here: a shell must be migratable.
    @Test func aShellWithNoSessionIDIsEligible() {
        let t = makeTerminal(kind: .shell, claudeSessionID: nil)
        #expect(TransportMigrationEligibility.decide(t) == .eligible)
    }

    @Test func aParkedRowIsEligible() {
        let t = makeTerminal(hibernatedAt: Date())
        #expect(TransportMigrationEligibility.decide(t) == .eligible)
    }
}
