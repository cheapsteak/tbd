import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

/// `v80_clear_scratch_pr_observation` erases the PR attempt outcome recorded
/// against scratch rows.
///
/// The guard in `RPCRouter.isPollable` stops new ones being written, but it
/// cannot reach the ones already on disk: the daemon re-hydrates them into
/// `PRStatusManager` at every start, and the app seeds `prObservations` straight
/// off the worktree row, so a scratch lane kept its unresolvable "?" badge
/// across the fix and across restarts. The column is the only place both readers
/// look, so the column is where it gets cleared.
@Suite struct MigrationV80Tests {

    /// The value under test is written BEFORE v80 runs, which is the only way to
    /// prove the migration does anything: a row inserted afterwards would be
    /// clean for a reason that has nothing to do with this migration.
    private static func migrateToV79() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: "v79_reap_records_quarantine_path")
        return queue
    }

    private static let observation = """
        {"observedAt":808761353.9,"outcome":{"outcome":"undetermined","cause":"the forge query failed"}}
        """

    private static func insertWorktree(
        _ queue: DatabaseQueue, id: String, repoID: String?, path: String
    ) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO worktree
                  (id, repoID, name, displayName, branch, path, status, createdAt,
                   tmuxServer, prObservation)
                VALUES (?, ?, 'w', 'w', '', ?, 'active', ?, 'tbd-x', ?)
                """,
                arguments: [id, repoID, path, Date(), observation])
        }
    }

    private static func observation(_ queue: DatabaseQueue, id: String) throws -> String? {
        try queue.read { db in
            try String.fetchOne(db, sql: "SELECT prObservation FROM worktree WHERE id = ?",
                                arguments: [id])
        }
    }

    @Test func scratchRowLosesItsRecordedOutcome() throws {
        let queue = try Self.migrateToV79()
        let scratchID = "E3DB7381-0000-0000-0000-000000000000"
        try Self.insertWorktree(queue, id: scratchID, repoID: nil, path: "/tmp/v80-scratch")
        #expect(try Self.observation(queue, id: scratchID) != nil, "precondition: the lie is on the row")

        try TBDDatabase.buildMigratorForTests().migrate(queue)

        #expect(try Self.observation(queue, id: scratchID) == nil)
    }

    /// Guard the scope. A repo-scoped row's outcome is a real reading of a real
    /// forge attempt, and an outage that spans a restart must still be visible after
    /// this migration runs, which is the whole reason the column is persisted.
    @Test func repoScopedRowKeepsItsRecordedOutcome() throws {
        let queue = try Self.migrateToV79()
        let repoID = "11111111-1111-1111-1111-111111111111"
        let regularID = "22222222-0000-0000-0000-000000000000"
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                VALUES (?, '/tmp/v80-repo', 'V80', 'main', ?)
                """,
                arguments: [repoID, Date()])
        }
        try Self.insertWorktree(queue, id: regularID, repoID: repoID, path: "/tmp/v80-wt")

        try TBDDatabase.buildMigratorForTests().migrate(queue)

        #expect(try Self.observation(queue, id: regularID) != nil)
    }
}
