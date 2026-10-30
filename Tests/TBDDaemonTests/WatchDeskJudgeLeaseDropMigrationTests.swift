import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib

/// `20261024184718_drop_watch_desk_judge_lease` removes the judge-lease table
/// the frozen block's `v68_watch_desk_judge_lease` created, rows and all, and
/// leaves the worktree rows it referenced in place.
@Suite struct WatchDeskJudgeLeaseDropMigrationTests {
    private static let migrationID = "20261024184718_drop_watch_desk_judge_lease"
    private static let table = "watch_desk_judge_lease"

    @Test func aDatabaseMigratedToHeadHasNoJudgeLeaseTable() async throws {
        let db = try TBDDatabase(inMemory: true)
        let table = Self.table
        let exists = try await db.writerForTests.read { connection in
            try connection.tableExists(table)
        }
        #expect(!exists)
    }

    @Test func aLeaseRowFromAnEarlierBuildGoesWithTheTable() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: SchemaBaselineDriftTests.frozenBlockLastIdentifier)

        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let repoID = UUID().uuidString
        let worktreeID = UUID().uuidString
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                    VALUES (?, '/tmp/judge-lease-repo', 'Lease', 'main', ?)
                    """,
                arguments: [repoID, epoch])
            try db.execute(
                sql: """
                    INSERT INTO worktree
                        (id, repoID, name, displayName, branch, path, status, createdAt, tmuxServer)
                    VALUES (?, ?, 'desk', 'desk', 'main', '/tmp/judge-lease-wt',
                            'active', ?, 'tbd-judge-lease')
                    """,
                arguments: [worktreeID, repoID, epoch])
            try db.execute(
                sql: """
                    INSERT INTO watch_desk_judge_lease
                        (worktree_id, terminal_id, token, generation,
                         acquired_at, renewed_at, expires_at)
                    VALUES (?, ?, ?, 3, ?, ?, ?)
                    """,
                arguments: [
                    worktreeID, UUID().uuidString, UUID().uuidString,
                    epoch, epoch, epoch.addingTimeInterval(60),
                ])
        }
        let leaseRows = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM watch_desk_judge_lease")
        }
        #expect(leaseRows == 1)

        try migrator.migrate(queue, upTo: Self.migrationID)

        let tableExists = try queue.read { db in try db.tableExists(Self.table) }
        let worktreeRows = try queue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM worktree WHERE id = ?", arguments: [worktreeID])
        }
        #expect(!tableExists)
        #expect(worktreeRows == 1)
    }

    /// `IF EXISTS` is what lets the migration run against a database that has
    /// already lost the table, whatever order the timestamp migrations ran in.
    @Test func theMigrationAppliesWhenTheTableIsAlreadyGone() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: SchemaBaselineDriftTests.frozenBlockLastIdentifier)
        try queue.write { db in try db.execute(sql: "DROP TABLE watch_desk_judge_lease") }

        try migrator.migrate(queue, upTo: Self.migrationID)

        let applied = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
        }
        let tableExists = try queue.read { db in try db.tableExists(Self.table) }
        #expect(applied.contains(Self.migrationID))
        #expect(!tableExists)
    }
}
