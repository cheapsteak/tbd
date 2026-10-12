import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct TransportMigrationEligibilityTests {
    private func makeTerminal(
        transport: TerminalTransport = .tmux,
        kind: TerminalKind? = .claude,
        label: String? = nil,
        claudeSessionID: String? = "session-1",
        activityState: TerminalActivityState = .idle,
        hibernatedAt: Date? = nil
    ) -> Terminal {
        Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: label,
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

    // A Codex tab names no resumable session either, so without its own skip
    // it would fall into the running-shell move and be silently replaced by a
    // bare shell.
    @Test func aCodexKindIsSkippedWithItsOwnReason() {
        let t = makeTerminal(kind: .codex, claudeSessionID: nil)
        #expect(TransportMigrationEligibility.decide(t)
            == .skip(reason: TransportMigrationEligibility.codexSkip))
    }

    /// The other half of the recreate path's predicate: a Codex tab is
    /// recognised by its label too, so a row whose kind never got written
    /// still gets the Codex answer.
    @Test func aCodexLabelIsSkippedWithItsOwnReason() {
        let t = makeTerminal(
            kind: .shell, label: TerminalLabel.codex, claudeSessionID: nil)
        #expect(TransportMigrationEligibility.decide(t)
            == .skip(reason: TransportMigrationEligibility.codexSkip))
    }

    /// The Codex skip comes before the activity rails, so one Codex tab gets
    /// one answer however busy it looks.
    @Test func aBusyCodexTabIsStillSkippedAsCodex() {
        let t = makeTerminal(kind: .codex, claudeSessionID: nil, activityState: .working)
        #expect(TransportMigrationEligibility.decide(t)
            == .skip(reason: TransportMigrationEligibility.codexSkip))
    }

    /// `.alreadyHolder` is the one answer that comes first: a Codex tab that
    /// is already holder-backed has nothing to be told about moving.
    @Test func aCodexTabOnTheHolderIsAlreadyWhereItBelongs() {
        let t = makeTerminal(transport: .holder, kind: .codex, claudeSessionID: nil)
        #expect(TransportMigrationEligibility.decide(t) == .alreadyHolder)
    }
}
