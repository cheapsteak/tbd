import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Notification Unread Summary Tests")
struct NotificationUnreadSummaryTests {

    // Helper: create a real worktree row in the DB so notification FK passes.
    private func makeWorktree(_ db: TBDDatabase, name: String) async throws -> Worktree {
        let repo = try await db.repos.create(
            path: "/tmp/test-\(UUID().uuidString)",
            displayName: "test",
            defaultBranch: "main"
        )
        return try await db.worktrees.create(
            repoID: repo.id,
            name: name,
            branch: "tbd/\(name)",
            path: "/tmp/test/.tbd/worktrees/\(name)",
            tmuxServer: "tbd-test"
        )
    }

    @Test func emptyStoreReturnsEmpty() async throws {
        let db = try TBDDatabase(inMemory: true)
        let summary = try await db.notifications.unreadSummaryByWorktree()
        #expect(summary.isEmpty)
    }

    @Test func singleWorktreeSingleNotification() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db, name: "wt-single")
        let n = try await db.notifications.create(worktreeID: wt.id, type: .responseComplete)
        let summary = try await db.notifications.unreadSummaryByWorktree()
        #expect(summary.count == 1)
        #expect(summary[wt.id]?.type == .responseComplete)
        // SQLite round-trip rounds to millisecond precision, so allow small delta.
        let delta = abs((summary[wt.id]?.mostRecentAt.timeIntervalSince1970 ?? 0) - n.createdAt.timeIntervalSince1970)
        #expect(delta < 0.001)
    }

    @Test func picksHighestSeverityAcrossNotifications() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db, name: "wt-severity")
        _ = try await db.notifications.create(worktreeID: wt.id, type: .responseComplete)
        _ = try await db.notifications.create(worktreeID: wt.id, type: .error)
        _ = try await db.notifications.create(worktreeID: wt.id, type: .taskComplete)
        let summary = try await db.notifications.unreadSummaryByWorktree()
        #expect(summary[wt.id]?.type == .error)
    }

    @Test func picksMostRecentTimestamp() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db, name: "wt-recent")
        let a = try await db.notifications.create(worktreeID: wt.id, type: .responseComplete)
        try await Task.sleep(nanoseconds: 10_000_000)
        let b = try await db.notifications.create(worktreeID: wt.id, type: .taskComplete)
        let summary = try await db.notifications.unreadSummaryByWorktree()
        // SQLite stores at millisecond precision; allow tolerance.
        let expected = max(a.createdAt, b.createdAt).timeIntervalSince1970
        let actual = summary[wt.id]?.mostRecentAt.timeIntervalSince1970 ?? 0
        #expect(abs(actual - expected) < 0.001)
    }

    @Test func skipsReadNotifications() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db, name: "wt-read")
        _ = try await db.notifications.create(worktreeID: wt.id, type: .error)
        try await db.notifications.markRead(worktreeID: wt.id)
        let summary = try await db.notifications.unreadSummaryByWorktree()
        #expect(summary.isEmpty)
    }

    @Test func groupsByWorktree() async throws {
        let db = try TBDDatabase(inMemory: true)
        let a = try await makeWorktree(db, name: "wt-a")
        let b = try await makeWorktree(db, name: "wt-b")
        _ = try await db.notifications.create(worktreeID: a.id, type: .error)
        _ = try await db.notifications.create(worktreeID: b.id, type: .responseComplete)
        let summary = try await db.notifications.unreadSummaryByWorktree()
        #expect(summary.count == 2)
        #expect(summary[a.id]?.type == .error)
        #expect(summary[b.id]?.type == .responseComplete)
    }
}
