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

    // A Claude tab whose agent is still starting up, or whose session hook
    // never fired, names no conversation either — and that happens in the
    // field. Without its own skip it would reach the running-shell move and
    // have a live agent killed and replaced by a bare login shell in a tab
    // still reading Claude.
    @Test func aClaudeTabWithNoConversationYetIsSkippedWithItsOwnReason() {
        let t = makeTerminal(kind: .claude, claudeSessionID: nil)
        #expect(TransportMigrationEligibility.decide(t)
            == .skip(reason: TransportMigrationEligibility.claudeWithoutConversationSkip))
    }

    /// The same row WITH a conversation is eligible — which is what makes the
    /// skip above about the missing session rather than about the kind.
    @Test func aClaudeTabWithAConversationIsEligible() {
        let t = makeTerminal(kind: .claude, claudeSessionID: "session-1")
        #expect(TransportMigrationEligibility.decide(t) == .eligible)
    }

    /// A nil `kind` reads as a shell, the `(kind ?? .shell)` idiom the rest of
    /// the daemon uses for a row written before kinds existed. Such a row must
    /// still be movable, or it would be stranded on tmux forever.
    @Test func aKindlessRowWithNoSessionIDReadsAsAShellAndIsEligible() {
        let t = makeTerminal(kind: nil, claudeSessionID: nil)
        #expect(TransportMigrationEligibility.decide(t) == .eligible)
    }

    // A pre-session hook tab is a shell with no session id, so without its own
    // skip it is eligible — and a fleet run during a worktree creation would
    // kill the hook mid-run, which the creation flow reports as a hook failure
    // with the hook's work lost.
    @Test func aPreSessionHookTabIsSkippedWithItsOwnReason() {
        let t = makeTerminal(
            kind: .shell, label: TerminalLabel.preSession, claudeSessionID: nil)
        #expect(TransportMigrationEligibility.decide(t)
            == .skip(reason: TransportMigrationEligibility.preSessionSkip))
    }

    /// Unconditional, deliberately: the tab is transient, so skipping it costs
    /// nothing even once its hook has finished, and a row-only view cannot see
    /// whether the creation flow is still waiting on it. An idle one is
    /// therefore skipped too.
    @Test func anIdlePreSessionHookTabIsStillSkipped() {
        let t = makeTerminal(
            kind: .shell, label: TerminalLabel.preSession,
            claudeSessionID: nil, activityState: .idle)
        #expect(TransportMigrationEligibility.decide(t)
            == .skip(reason: TransportMigrationEligibility.preSessionSkip))
    }

    /// And `.alreadyHolder` still comes first for it, like every other row.
    @Test func aPreSessionHookTabOnTheHolderIsAlreadyWhereItBelongs() {
        let t = makeTerminal(
            transport: .holder, kind: .shell,
            label: TerminalLabel.preSession, claudeSessionID: nil)
        #expect(TransportMigrationEligibility.decide(t) == .alreadyHolder)
    }

    /// A `setup` hook tab is deliberately NOT skipped here: it is a parallel
    /// tab nothing waits on, so it moves like any other shell, and the
    /// coordinator's busy rail is what protects it while its hook is still
    /// running.
    @Test func aSetupHookTabIsEligible() {
        let t = makeTerminal(
            kind: .shell, label: TerminalLabel.setup, claudeSessionID: nil)
        #expect(TransportMigrationEligibility.decide(t) == .eligible)
    }
}
