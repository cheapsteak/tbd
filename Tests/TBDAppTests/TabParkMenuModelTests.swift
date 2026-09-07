import Foundation
import Testing
import TBDShared
@testable import TBDApp

/// The per-tab Hibernate/Wake context-menu affordance (the park control that
/// returned to the tab after PR #362 retired the play/pause Suspend button).
/// Tests the pure decision
/// `TabParkMenuModel.action(for:panelHoldsPTY:)`
/// across every branch without SwiftUI: hibernate for a live
/// manually-hibernatable Claude session, wake for a parked one (authoritative
/// `hibernatedAt` AND legacy `suspendedAt`), and neither for
/// busy/nil/non-Claude terminals or a holder tab whose panel owns the pty.
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
        #expect(terminal.isManuallyHibernatable())
        #expect(TabParkMenuModel.action(for: terminal, panelHoldsPTY: false) == .hibernate)
    }

    /// Branch 2: a parked session (authoritative `hibernatedAt`) → offer Wake.
    @Test func parkedTerminalOffersWake() {
        let terminal = claudeTerminal(hibernatedAt: Date())
        #expect(TabParkMenuModel.action(for: terminal, panelHoldsPTY: false) == .wake)
    }

    /// Branch 2 (legacy): a row parked by the pre-merge Suspend feature has
    /// ONLY `suspendedAt` set — it must still read as parked and offer Wake.
    @Test func legacySuspendedOnlyTerminalOffersWake() {
        let terminal = claudeTerminal(suspendedAt: Date())
        #expect(terminal.hibernatedAt == nil)
        #expect(TabParkMenuModel.action(for: terminal, panelHoldsPTY: false) == .wake)
    }

    /// Branch 3: a Claude session mid-turn (`.working`) is neither parked nor
    /// manually hibernatable → no item.
    @Test func workingTerminalOffersNothing() {
        let terminal = claudeTerminal(activityState: .working)
        #expect(TabParkMenuModel.action(for: terminal, panelHoldsPTY: false) == nil)
    }

    /// Branch 3: a Claude session waiting on a permission prompt — hibernating
    /// would eat the raised hand → no item.
    @Test func waitingForUserTerminalOffersNothing() {
        let terminal = claudeTerminal(activityState: .waitingForUser)
        #expect(TabParkMenuModel.action(for: terminal, panelHoldsPTY: false) == nil)
    }

    /// Branch 3: no terminal backing the tab → no item.
    @Test func nilTerminalOffersNothing() {
        #expect(TabParkMenuModel.action(for: nil, panelHoldsPTY: false) == nil)
    }

    /// Branch 3: non-Claude terminals (plain shell, Codex) are never
    /// hibernatable → no item.
    @Test func nonClaudeTerminalOffersNothing() {
        let shell = Terminal(id: UUID(), worktreeID: UUID(), tmuxWindowID: "@1",
                             tmuxPaneID: "%1", kind: .shell, activityState: .idle)
        let codex = Terminal(id: UUID(), worktreeID: UUID(), tmuxWindowID: "@2",
                             tmuxPaneID: "%2", kind: .codex, activityState: .idle)
        #expect(TabParkMenuModel.action(for: shell, panelHoldsPTY: false) == nil)
        #expect(TabParkMenuModel.action(for: codex, panelHoldsPTY: false) == nil)
    }

    /// A live holder tab offers Hibernate exactly as a tmux tab does: manual
    /// park is unflagged on every transport, so the menu offers what the daemon
    /// will actually do.
    @Test func holderTabOffersHibernate() {
        let holder = Terminal(
            id: UUID(), worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            claudeSessionID: "session-1", kind: .claude, activityState: .idle,
            transport: .holder)
        #expect(TabParkMenuModel.action(for: holder, panelHoldsPTY: false) == .hibernate)
        #expect(
            TabParkMenuModel.action(for: claudeTerminal(), panelHoldsPTY: false) == .hibernate)
    }

    /// A PARKED holder tab offers Wake, exactly as a parked tmux tab does.
    @Test func parkedHolderTabOffersWake() {
        let parked = Terminal(
            id: UUID(), worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            claudeSessionID: "session-1", kind: .claude, activityState: .idle,
            hibernatedAt: Date(), transport: .holder)
        #expect(TabParkMenuModel.action(for: parked, panelHoldsPTY: false) == .wake)
    }

    /// Both branches of the viewer suppression, on a holder tab — so the only
    /// thing moving is whether this app's panel owns the pty.
    ///
    /// The daemon fail-closes a park while a viewer holds the pty: its
    /// pending-input rail judges its own emulator, which is frozen for the
    /// duration of the attach. A Hibernate item offered there errors every
    /// single time, which is worse than no item at all.
    @Test func holderTabWithAnAttachedPanelOffersNothing() {
        let holder = Terminal(
            id: UUID(), worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            claudeSessionID: "session-1", kind: .claude, activityState: .idle,
            transport: .holder)
        #expect(
            TabParkMenuModel.action(
                for: holder, panelHoldsPTY: true) == nil)
        #expect(
            TabParkMenuModel.action(
                for: holder, panelHoldsPTY: false)
                == .hibernate)
    }

    /// A tmux tab is unaffected by the same input, which is what makes the test
    /// above about the transport rather than about an attached panel alone: the
    /// daemon reads a tmux pane's screen with `capture-pane` whoever is looking
    /// at it.
    @Test func tmuxTabIsUnaffectedByAnAttachedPanel() {
        let terminal = claudeTerminal()
        for held in [false, true] {
            #expect(
                TabParkMenuModel.action(
                    for: terminal, panelHoldsPTY: held)
                    == .hibernate)
        }
    }

    /// A PARKED holder tab still offers Wake with a panel attached: a parked
    /// row has no pty for anything to hold, and the wake path reads no screen.
    @Test func parkedHolderTabOffersWakeEvenWithAnAttachedPanel() {
        let parked = Terminal(
            id: UUID(), worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            claudeSessionID: "session-1", kind: .claude, activityState: .idle,
            hibernatedAt: Date(), transport: .holder)
        #expect(
            TabParkMenuModel.action(
                for: parked, panelHoldsPTY: true) == .wake)
    }
}
