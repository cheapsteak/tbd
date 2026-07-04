import Testing
import Foundation
@testable import TBDApp
@testable import TBDShared

/// Direct proof of `AppState.worktreeIDsToAutoMarkRead`, the pure decision
/// behind `refreshNotifications`' auto-mark-read reconcile. The invariant
/// under test: the `notifications.markRead` RPC fires only when a visible
/// worktree actually has unread rows — never as a blanket per-visible-worktree
/// call on every poll tick — while a notification that arrives WHILE its
/// worktree is visible still gets marked read.
@MainActor
@Suite("refreshNotifications auto-mark-read guard")
struct NotificationAutoMarkReadTests {
    private func summary() -> UnreadSummary {
        UnreadSummary(type: .taskComplete, mostRecentAt: Date())
    }

    @Test("no unread state fires zero RPCs, however many worktrees are visible")
    func idleTickFiresNothing() {
        let visible: Set<UUID> = [UUID(), UUID(), UUID()]
        let result = AppState.worktreeIDsToAutoMarkRead(unreadSummaries: [:], visible: visible)
        #expect(result.isEmpty)
    }

    @Test("a notification arriving while its worktree is visible is marked read")
    func arriveWhileVisibleIsMarkedRead() {
        let visibleID = UUID()
        let result = AppState.worktreeIDsToAutoMarkRead(
            unreadSummaries: [visibleID: summary()],
            visible: [visibleID]
        )
        #expect(result == [visibleID])
    }

    @Test("unread on a non-visible worktree is left unread")
    func nonVisibleUnreadIsNotMarkedRead() {
        let hiddenID = UUID()
        let result = AppState.worktreeIDsToAutoMarkRead(
            unreadSummaries: [hiddenID: summary()],
            visible: [UUID()]
        )
        #expect(result.isEmpty)
    }

    @Test("mixed state marks only the visible worktree with unread rows")
    func mixedStateMarksOnlyVisibleUnread() {
        let visibleUnread = UUID()
        let hiddenUnread = UUID()
        let visibleWithoutUnread = UUID()
        let result = AppState.worktreeIDsToAutoMarkRead(
            unreadSummaries: [visibleUnread: summary(), hiddenUnread: summary()],
            visible: [visibleUnread, visibleWithoutUnread]
        )
        #expect(result == [visibleUnread])
    }
}
