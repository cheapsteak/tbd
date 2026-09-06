import Foundation
import Testing
import TBDShared
@testable import TBDApp

/// The per-tab Hibernate/Wake context-menu affordance (the park control that
/// returned to the tab after PR #362 retired the play/pause Suspend button).
/// Tests the pure decision `TabParkMenuModel.action(for:holderHibernationEnabled:)` across every
/// branch without SwiftUI: hibernate for a live manually-hibernatable Claude
/// session, wake for a parked one (authoritative `hibernatedAt` AND legacy
/// `suspendedAt`), and neither for busy/nil/non-Claude terminals.
@Suite("Tab park menu decision (per-tab Hibernate/Wake)")
struct TabParkMenuModelTests {
    /// A live, resumable Claude terminal — the shape `isManuallyHibernatable`
    /// requires (session id present, Claude kind, not parked, not busy).
    private func claudeTerminal(
        activityState: TerminalActivityState = .idle,
        suspendedAt: Date? = nil,
        hibernatedAt: Date? = nil
    ) -> Terminal {
        Terminal(id: UUID(), worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
                 claudeSessionID: "session-1", suspendedAt: suspendedAt,
                 kind: .claude, activityState: activityState,
                 hibernatedAt: hibernatedAt)
    }

    /// Branch 1: a live, idle, resumable Claude session is manually
    /// hibernatable → offer Hibernate.
    @Test func manuallyHibernatableTerminalOffersHibernate() {
        let terminal = claudeTerminal()
        #expect(terminal.isManuallyHibernatable(holderHibernationEnabled: false))
        #expect(TabParkMenuModel.action(for: terminal, holderHibernationEnabled: false) == .hibernate)
    }

    /// Branch 2: a parked session (authoritative `hibernatedAt`) → offer Wake.
    @Test func parkedTerminalOffersWake() {
        let terminal = claudeTerminal(hibernatedAt: Date())
        #expect(TabParkMenuModel.action(for: terminal, holderHibernationEnabled: false) == .wake)
    }

    /// Branch 2 (legacy): a row parked by the pre-merge Suspend feature has
    /// ONLY `suspendedAt` set — it must still read as parked and offer Wake.
    @Test func legacySuspendedOnlyTerminalOffersWake() {
        let terminal = claudeTerminal(suspendedAt: Date())
        #expect(terminal.hibernatedAt == nil)
        #expect(TabParkMenuModel.action(for: terminal, holderHibernationEnabled: false) == .wake)
    }

    /// Branch 3: a Claude session mid-turn (`.working`) is neither parked nor
    /// manually hibernatable → no item.
    @Test func workingTerminalOffersNothing() {
        let terminal = claudeTerminal(activityState: .working)
        #expect(TabParkMenuModel.action(for: terminal, holderHibernationEnabled: false) == nil)
    }

    /// Branch 3: a Claude session waiting on a permission prompt — hibernating
    /// would eat the raised hand → no item.
    @Test func waitingForUserTerminalOffersNothing() {
        let terminal = claudeTerminal(activityState: .waitingForUser)
        #expect(TabParkMenuModel.action(for: terminal, holderHibernationEnabled: false) == nil)
    }

    /// Branch 3: no terminal backing the tab → no item.
    @Test func nilTerminalOffersNothing() {
        #expect(TabParkMenuModel.action(for: nil, holderHibernationEnabled: false) == nil)
    }

    /// Branch 3: non-Claude terminals (plain shell, Codex) are never
    /// hibernatable → no item.
    @Test func nonClaudeTerminalOffersNothing() {
        let shell = Terminal(id: UUID(), worktreeID: UUID(), tmuxWindowID: "@1",
                             tmuxPaneID: "%1", kind: .shell, activityState: .idle)
        let codex = Terminal(id: UUID(), worktreeID: UUID(), tmuxWindowID: "@2",
                             tmuxPaneID: "%2", kind: .codex, activityState: .idle)
        #expect(TabParkMenuModel.action(for: shell, holderHibernationEnabled: false) == nil)
        #expect(TabParkMenuModel.action(for: codex, holderHibernationEnabled: false) == nil)
    }

    /// Both branches of the holder soak gate. The menu must agree with the rail
    /// the daemon will apply: with the gate off a holder tab offers nothing,
    /// because a Hibernate item there could only ever produce a refusal the
    /// user cannot act on; with it on the same tab offers Hibernate.
    @Test func holderTabFollowsTheSoakGate() {
        let holder = Terminal(
            id: UUID(), worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            claudeSessionID: "session-1", kind: .claude, activityState: .idle,
            transport: .holder)
        #expect(TabParkMenuModel.action(for: holder, holderHibernationEnabled: false) == nil)
        #expect(
            TabParkMenuModel.action(for: holder, holderHibernationEnabled: true) == .hibernate)
    }

    /// A PARKED holder tab offers Wake under both values: the gate decides
    /// whether a park may happen, and a row that is already parked has to be
    /// wakeable however it got there — an older daemon, or the reconcile rail.
    @Test func parkedHolderTabAlwaysOffersWake() {
        let parked = Terminal(
            id: UUID(), worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            claudeSessionID: "session-1", kind: .claude, activityState: .idle,
            hibernatedAt: Date(), transport: .holder)
        #expect(TabParkMenuModel.action(for: parked, holderHibernationEnabled: false) == .wake)
        #expect(TabParkMenuModel.action(for: parked, holderHibernationEnabled: true) == .wake)
    }

    /// A tmux tab is unaffected by either value, which is what makes the two
    /// tests above about the transport rather than about the flag alone.
    @Test func tmuxTabIsUnaffectedByTheSoakGate() {
        let terminal = claudeTerminal()
        for enabled in [false, true] {
            #expect(
                TabParkMenuModel.action(for: terminal, holderHibernationEnabled: enabled)
                    == .hibernate)
        }
    }
}
