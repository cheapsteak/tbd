import Testing
@testable import TBDApp
@testable import TBDShared

@Suite("Worktree row conflict fallback")
struct WorktreeRowConflictFallbackTests {
    @Test("uses the hand-raised slash icon for conflict fallback")
    func usesConflictFallbackIcon() {
        #expect(WorktreeRowConflictFallback.iconName == "hand.raised.slash.fill")
    }

    @Test("conflict fallback appears when there is no PR and no notification")
    func conflictFallbackWithoutPR() {
        let showsFallback = WorktreeRowConflictFallback.shouldShow(
            prStatus: nil,
            hasConflicts: true,
            hasNotification: false
        )

        #expect(showsFallback)
    }

    @Test("notification badge takes precedence over conflict fallback")
    func notificationWinsOverConflictFallback() {
        let showsFallback = WorktreeRowConflictFallback.shouldShow(
            prStatus: nil,
            hasConflicts: true,
            hasNotification: true
        )

        #expect(!showsFallback)
    }

    @Test("PR status suppresses conflict fallback")
    func prStatusSuppressesConflictFallback() {
        let showsFallback = WorktreeRowConflictFallback.shouldShow(
            prStatus: PRStatus(number: 12, url: "https://example.com/12", state: .pending),
            hasConflicts: true,
            hasNotification: false
        )

        #expect(!showsFallback)
    }
}
