import Foundation
import GRDB
import Testing
import TestSupport
@testable import TBDDaemonLib
import TBDShared

/// The `OrphanGC` leg that prunes the `notification` table, and the partial
/// index on its unread rows (`docs/specs/2026-10-25-state-db-retention-design.md`).
///
/// Tier 2: an in-memory database and a fixed reading of now. Every base the
/// sweep could walk is pointed inside a fenced scratch root that is never
/// created, and worktree rows are scratch rows with no repo, so the one sweep
/// that gets past the `lsof` gate runs no git and finds nothing on disk. The
/// rest fail `lsof` on purpose: the notification leg runs before that gate, so
/// a failing provider confines the sweep to the leg under test.
@Suite("OrphanGC prunes notifications")
struct NotificationRetentionTests {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60
    private let home = URL(
        fileURLWithPath: fencedScratchRoot(prefix: "tbdgcnt"), isDirectory: true)

    private func makeGC(
        db: TBDDatabase, liveCWDs: @escaping @Sendable () async -> [String]? = { nil }
    ) -> OrphanGC {
        let fixed = fixedNow
        let environment = ["TBD_HOME": home.path]
        return OrphanGC(
            db: db, git: GitManager(),
            broadcast: { _ in },
            liveCWDsProvider: liveCWDs,
            scratchpadBase: home.appendingPathComponent("s", isDirectory: true),
            now: { fixed },
            profileDirBase: home.appendingPathComponent("p", isDirectory: true),
            hangStackBase: home.appendingPathComponent("hs", isDirectory: true),
            processSnapshotProvider: { [] },
            holdersBase: home.appendingPathComponent("h", isDirectory: true),
            attachmentsBase: home.appendingPathComponent("a", isDirectory: true),
            remoteTranscriptsEnvironment: environment,
            reposBase: TBDConstants.reposDir(environment: environment),
            sessionsBase: home.appendingPathComponent("se", isDirectory: true),
            devServersBase: home.appendingPathComponent("d", isDirectory: true))
    }

    private func makeWorktree(_ db: TBDDatabase, name: String) async throws -> Worktree {
        try await db.worktrees.createScratch(
            name: name, displayName: name,
            path: home.appendingPathComponent(name).path,
            tmuxServer: "tbd-test-\(name)")
    }

    /// Inserts a row created `age` before the suite's fixed now. Through the
    /// record rather than `NotificationStore.create`, which stamps the wall
    /// clock and always writes an unread row.
    @discardableResult
    private func insert(
        _ db: TBDDatabase, worktree: UUID, read: Bool, age: TimeInterval
    ) async throws -> UUID {
        let notification = TBDNotification(
            worktreeID: worktree, type: .responseComplete, message: "turn done",
            read: read, createdAt: fixedNow.addingTimeInterval(-age))
        let record = NotificationRecord(from: notification)
        try await db.writerForTests.write { connection in try record.insert(connection) }
        return notification.id
    }

    private func exists(_ db: TBDDatabase, _ id: UUID) async throws -> Bool {
        try await db.writerForTests.read { connection in
            try Int.fetchOne(
                connection,
                sql: "SELECT COUNT(*) FROM notification WHERE id = ?",
                arguments: [id.uuidString]) == 1
        }
    }

    // MARK: - The window

    @Test func readNotificationOlderThanWindowIsDeleted() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db, name: "wt-old-read")
        let id = try await insert(db, worktree: wt.id, read: true, age: 8 * day)

        _ = await makeGC(db: db).sweep()

        #expect(try await exists(db, id) == false, "a read row 8 days old survived the sweep")
    }

    @Test func readNotificationInsideWindowIsKept() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db, name: "wt-young-read")
        let id = try await insert(db, worktree: wt.id, read: true, age: 6 * day)

        let result = await makeGC(db: db).sweep()

        #expect(try await exists(db, id), "a read row 6 days old was pruned inside the window")
        #expect(result.planned.contains { $0.contains("notifications") } == false)
    }

    @Test func unreadNotificationOnActiveWorktreeIsKept() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db, name: "wt-old-unread")
        let id = try await insert(db, worktree: wt.id, read: false, age: 90 * day)

        _ = await makeGC(db: db).sweep()

        #expect(try await exists(db, id), "an unread row on an active worktree was pruned")
        #expect(try await db.notifications.unreadSummaryByWorktree()[wt.id] != nil)
    }

    // MARK: - Archived worktrees

    @Test func archivedWorktreeNotificationsAreDeleted() async throws {
        let db = try TBDDatabase(inMemory: true)
        let archived = try await makeWorktree(db, name: "wt-archived")
        let active = try await makeWorktree(db, name: "wt-active")
        let freshUnread = try await insert(db, worktree: archived.id, read: false, age: 0)
        let freshRead = try await insert(db, worktree: archived.id, read: true, age: day)
        let oldUnread = try await insert(db, worktree: archived.id, read: false, age: 90 * day)
        let bystander = try await insert(db, worktree: active.id, read: false, age: 0)
        try await db.worktrees.archive(id: archived.id)

        let result = await makeGC(db: db).sweep()

        #expect(try await exists(db, freshUnread) == false)
        #expect(try await exists(db, freshRead) == false)
        #expect(try await exists(db, oldUnread) == false)
        #expect(try await exists(db, bystander), "an active worktree's unread row went with the archived one's")
        #expect(result.planned.contains("REAP notifications 3"))
    }

    @Test func revivedWorktreeKeepsItsUnread() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db, name: "wt-revived")
        let id = try await insert(db, worktree: wt.id, read: false, age: day)
        try await db.worktrees.archive(id: wt.id)
        try await db.worktrees.revive(id: wt.id)

        _ = await makeGC(db: db).sweep()

        #expect(try await exists(db, id), "a revived worktree lost its unread row")
    }

    // MARK: - The sweep

    /// The leg sits before the `lsof` gate, so an `lsof` outage, which skips
    /// every other leg, still prunes — and the result reports it.
    @Test func sweepRunsNotificationLegWhenLsofFails() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db, name: "wt-lsof")
        let id = try await insert(db, worktree: wt.id, read: true, age: 8 * day)

        let result = await makeGC(db: db, liveCWDs: { nil }).sweep()

        #expect(try await exists(db, id) == false, "an lsof outage skipped the notification leg")
        #expect(result.planned.contains { $0.contains("lsof unavailable") })
        #expect(result.planned.contains("REAP notifications 1"))
        #expect(result.reaped == 1)
    }

    /// The leg on a sweep that gets past the `lsof` gate: it prunes there too,
    /// and its count joins the sweep's total.
    @Test func aHealthySweepPrunesAndCountsNotifications() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db, name: "wt-healthy")
        let id = try await insert(db, worktree: wt.id, read: true, age: 8 * day)

        let result = await makeGC(db: db, liveCWDs: { [] }).sweep()

        #expect(try await exists(db, id) == false)
        #expect(result.planned.contains { $0.contains("lsof unavailable") } == false)
        #expect(result.planned.contains("REAP notifications 1"))
        #expect(result.reaped >= 1)
    }

    @Test func sweepWithGCDisabledDeletesNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(false)
        let archived = try await makeWorktree(db, name: "wt-gc-off-archived")
        let active = try await makeWorktree(db, name: "wt-gc-off")
        let oldRead = try await insert(db, worktree: active.id, read: true, age: 8 * day)
        let onArchived = try await insert(db, worktree: archived.id, read: false, age: 0)
        try await db.worktrees.archive(id: archived.id)

        let result = await makeGC(db: db, liveCWDs: { [] }).sweep()

        #expect(try await exists(db, oldRead), "a read row was pruned with gcEnabled off")
        #expect(try await exists(db, onArchived), "an archived worktree's row was pruned with gcEnabled off")
        #expect(result.planned == ["gc disabled"])
    }

    /// A dry run counts what a real run would remove and removes nothing,
    /// whatever `gcEnabled` says.
    @Test func dryRunReportsTheCountAndDeletesNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(false)
        let wt = try await makeWorktree(db, name: "wt-dry")
        let oldRead = try await insert(db, worktree: wt.id, read: true, age: 8 * day)
        let alsoOld = try await insert(db, worktree: wt.id, read: true, age: 30 * day)
        let young = try await insert(db, worktree: wt.id, read: true, age: day)

        let result = await makeGC(db: db).sweep(dryRun: true)

        #expect(try await exists(db, oldRead), "a dry run deleted a notification")
        #expect(try await exists(db, alsoOld), "a dry run deleted a notification")
        #expect(try await exists(db, young))
        #expect(result.planned.contains("REAP notifications 2"))
        #expect(result.reaped == 0)
    }

    // MARK: - The store

    /// The count a dry run reports and the rows a real run removes come from
    /// one predicate, so they agree.
    @Test func countExpiredMatchesWhatDeleteExpiredRemoves() async throws {
        let db = try TBDDatabase(inMemory: true)
        let archived = try await makeWorktree(db, name: "wt-store-archived")
        let active = try await makeWorktree(db, name: "wt-store-active")
        try await insert(db, worktree: active.id, read: true, age: 8 * day)
        try await insert(db, worktree: active.id, read: true, age: 6 * day)
        try await insert(db, worktree: active.id, read: false, age: 90 * day)
        try await insert(db, worktree: archived.id, read: false, age: 0)
        try await db.worktrees.archive(id: archived.id)
        let cutoff = fixedNow.addingTimeInterval(-OrphanGC.notificationReadRetention)

        let counted = try await db.notifications.countExpired(readBefore: cutoff)
        let removed = try await db.notifications.deleteExpired(readBefore: cutoff)

        #expect(counted == 2)
        #expect(removed == 2)
        #expect(try await db.notifications.countExpired(readBefore: cutoff) == 0)
    }

    // MARK: - The index

    @Test func unreadIndexExists() async throws {
        let db = try TBDDatabase(inMemory: true)

        let sql = try await db.writerForTests.read { connection in
            try String.fetchOne(
                connection,
                sql: """
                    SELECT sql FROM sqlite_master
                    WHERE type = 'index' AND name = 'idx_notification_unread_worktree'
                    """)
        }

        let definition = try #require(sql, "the unread notification index is missing")
        #expect(definition.contains("ON notification(worktreeID)"))
        #expect(definition.contains("WHERE read = 0"))
    }

    /// Mark-read filters on `read = 0` so SQLite searches the partial index
    /// rather than scanning the whole table.
    @Test func markReadSearchesThroughTheUnreadIndex() async throws {
        let db = try TBDDatabase(inMemory: true)

        let details = try await db.writerForTests.write { connection in
            try Row.fetchAll(
                connection,
                sql: "EXPLAIN QUERY PLAN \(NotificationStore.markReadSQL)",
                arguments: [UUID().uuidString]
            ).compactMap { $0["detail"] as String? }
        }

        #expect(
            details.contains { $0.contains("USING INDEX idx_notification_unread_worktree") },
            "mark-read does not use the unread index: \(details)")
    }

    /// The `read = 0` filter changes what mark-read touches, not its outcome:
    /// every row of the worktree ends up read, and no other worktree's row
    /// changes.
    @Test func markReadStillLeavesEveryRowOfTheWorktreeRead() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db, name: "wt-mark")
        let other = try await makeWorktree(db, name: "wt-other")
        try await insert(db, worktree: wt.id, read: false, age: day)
        try await insert(db, worktree: wt.id, read: false, age: 0)
        try await insert(db, worktree: wt.id, read: true, age: 2 * day)
        try await insert(db, worktree: other.id, read: false, age: 0)

        try await db.notifications.markRead(worktreeID: wt.id)

        let worktreeID = wt.id.uuidString
        let unreadOnWorktree = try await db.writerForTests.read { connection in
            try Int.fetchOne(
                connection,
                sql: "SELECT COUNT(*) FROM notification WHERE worktreeID = ? AND read = 0",
                arguments: [worktreeID])
        }
        #expect(unreadOnWorktree == 0)
        #expect(try await db.notifications.unread(worktreeID: other.id).count == 1)
    }

    /// A row written before the index existed reads back unchanged after the
    /// migration that adds it.
    @Test func theIndexMigrationLeavesExistingRowsUnchanged() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: SchemaBaselineDriftTests.frozenBlockLastIdentifier)

        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let repoID = UUID().uuidString
        let worktreeID = UUID()
        let notificationID = UUID()
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                    VALUES (?, '/tmp/notification-index-repo', 'Index', 'main', ?)
                    """,
                arguments: [repoID, epoch])
            try db.execute(
                sql: """
                    INSERT INTO worktree
                        (id, repoID, name, displayName, branch, path, status, createdAt, tmuxServer)
                    VALUES (?, ?, 'idx', 'idx', 'main', '/tmp/notification-index-wt',
                            'active', ?, 'tbd-notification-index')
                    """,
                arguments: [worktreeID.uuidString, repoID, epoch])
            try db.execute(
                sql: """
                    INSERT INTO notification (id, worktreeID, type, message, read, createdAt)
                    VALUES (?, ?, 'error', 'build failed', 0, ?)
                    """,
                arguments: [notificationID.uuidString, worktreeID.uuidString, epoch])
        }

        try migrator.migrate(queue, upTo: "20261025031506_notification_unread_index")

        let model = try queue.read { db in
            try NotificationRecord.fetchOne(db, key: notificationID.uuidString)?.toModel()
        }
        let row = try #require(model, "the row did not read back after the migration")
        #expect(row.worktreeID == worktreeID)
        #expect(row.type == .error)
        #expect(row.message == "build failed")
        #expect(row.read == false)
        #expect(row.createdAt == epoch)
    }
}
