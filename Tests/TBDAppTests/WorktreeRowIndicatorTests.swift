import Testing
@testable import TBDApp
@testable import TBDShared

@Suite("Worktree row indicator")
struct WorktreeRowIndicatorTests {
    @Test("conflict fallback appears when there is no PR and no notification")
    func conflictFallbackWithoutPR() {
        let indicator = WorktreeRowIndicator.make(
            prStatus: nil,
            hasConflicts: true,
            hasNotification: false
        )

        #expect(indicator == .conflict)
    }

    @Test("notification badge takes precedence over conflict fallback")
    func notificationWinsOverConflictFallback() {
        let indicator = WorktreeRowIndicator.make(
            prStatus: nil,
            hasConflicts: true,
            hasNotification: true
        )

        #expect(indicator == nil)
    }

    @Test("PR status suppresses conflict fallback")
    func prStatusSuppressesConflictFallback() {
        let indicator = WorktreeRowIndicator.make(
            prStatus: PRStatus(number: 12, url: "https://example.com/12", state: .pending),
            hasConflicts: true,
            hasNotification: false
        )

        #expect(indicator == nil)
    }
}
