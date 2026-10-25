import Testing
import Foundation
import GRDB
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

    /// Overwrites a notification's `createdAt`. `create()` stamps `Date()`
    /// and takes no date, so a test that orders by time sets the stamps
    /// through the test writer, as `WorktreeStoreTests.stampArchivedAt` does.
    private func stampCreatedAt(_ db: TBDDatabase, id: UUID, _ date: Date) async throws {
        try await db.writerForTests.write { conn in
            try conn.execute(
                sql: "UPDATE notification SET createdAt = ? WHERE id = ?",
                arguments: [date, id.uuidString]
            )
        }
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
        let b = try await db.notifications.create(worktreeID: wt.id, type: .taskComplete)
        // Two creates in a row can share a stored millisecond, so the rows get
        // explicit, distinct stamps. The first-created row is the more recent
        // one, so the summary cannot pass by keeping the last row it reads.
        let older = Date(timeIntervalSince1970: 1_767_225_600)
        let newer = older.addingTimeInterval(60)
        try await stampCreatedAt(db, id: a.id, newer)
        try await stampCreatedAt(db, id: b.id, older)
        let summary = try await db.notifications.unreadSummaryByWorktree()
        // SQLite stores at millisecond precision; allow tolerance.
        let expected = newer.timeIntervalSince1970
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
