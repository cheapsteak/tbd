import Testing
@testable import TBDApp
@testable import TBDShared

@Suite("Worktree row conflict fallback")
struct WorktreeRowConflictFallbackTests {
    @Test("uses the git-merge-conflict icon for conflict fallback")
    func usesConflictFallbackIcon() {
        #expect(WorktreeRowConflictFallback.iconName == "git-merge-conflict")
    }

    @Test("conflict fallback does NOT appear when there is no PR")
    func conflictFallbackWithoutPR() {
        let showsFallback = WorktreeRowConflictFallback.shouldShow(
            prStatus: nil,
            hasConflicts: true,
            hasNotification: false
        )

        #expect(!showsFallback)
    }

    @Test("notification badge takes precedence over conflict fallback")
    func notificationWinsOverConflictFallback() {
        let showsFallback = WorktreeRowConflictFallback.shouldShow(
            prStatus: PRStatus(number: 12, url: "https://example.com/12", state: .pending),
            hasConflicts: true,
            hasNotification: true
        )

        #expect(!showsFallback)
    }

    @Test("conflict fallback appears when a PR is present and the branch has conflicts")
    func prStatusSuppressesConflictFallback() {
        let showsFallback = WorktreeRowConflictFallback.shouldShow(
            prStatus: PRStatus(number: 12, url: "https://example.com/12", state: .pending),
            hasConflicts: true,
            hasNotification: false
        )

        #expect(showsFallback)
    }
}
