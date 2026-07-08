import Foundation
import Testing
import TBDShared
@testable import TBDApp

/// The per-tab Hibernate/Wake context-menu affordance (the park control that
/// returned to the tab after PR #362 retired the play/pause Suspend button).
/// Tests the pure decision `TabParkMenuModel.action(for:)` across every
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
        #expect(terminal.isManuallyHibernatable)
        #expect(TabParkMenuModel.action(for: terminal) == .hibernate)
    }

    /// Branch 2: a parked session (authoritative `hibernatedAt`) → offer Wake.
    @Test func parkedTerminalOffersWake() {
        let terminal = claudeTerminal(hibernatedAt: Date())
        #expect(TabParkMenuModel.action(for: terminal) == .wake)
    }

    /// Branch 2 (legacy): a row parked by the pre-merge Suspend feature has
    /// ONLY `suspendedAt` set — it must still read as parked and offer Wake.
    @Test func legacySuspendedOnlyTerminalOffersWake() {
        let terminal = claudeTerminal(suspendedAt: Date())
        #expect(terminal.hibernatedAt == nil)
        #expect(TabParkMenuModel.action(for: terminal) == .wake)
    }

    /// Branch 3: a Claude session mid-turn (`.working`) is neither parked nor
    /// manually hibernatable → no item.
    @Test func workingTerminalOffersNothing() {
        let terminal = claudeTerminal(activityState: .working)
        #expect(TabParkMenuModel.action(for: terminal) == nil)
    }

    /// Branch 3: a Claude session waiting on a permission prompt — hibernating
    /// would eat the raised hand → no item.
    @Test func waitingForUserTerminalOffersNothing() {
        let terminal = claudeTerminal(activityState: .waitingForUser)
        #expect(TabParkMenuModel.action(for: terminal) == nil)
    }

    /// Branch 3: no terminal backing the tab → no item.
    @Test func nilTerminalOffersNothing() {
        #expect(TabParkMenuModel.action(for: nil) == nil)
    }

    /// Branch 3: non-Claude terminals (plain shell, Codex) are never
    /// hibernatable → no item.
    @Test func nonClaudeTerminalOffersNothing() {
        let shell = Terminal(id: UUID(), worktreeID: UUID(), tmuxWindowID: "@1",
                             tmuxPaneID: "%1", kind: .shell, activityState: .idle)
        let codex = Terminal(id: UUID(), worktreeID: UUID(), tmuxWindowID: "@2",
                             tmuxPaneID: "%2", kind: .codex, activityState: .idle)
        #expect(TabParkMenuModel.action(for: shell) == nil)
        #expect(TabParkMenuModel.action(for: codex) == nil)
    }
}
