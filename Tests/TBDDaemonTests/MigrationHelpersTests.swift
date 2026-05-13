import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib

@Suite struct MigrationHelpersTests {

    // MARK: addColumnIfMissing

    @Test func addColumnIfMissingAddsWhenAbsent() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE t (id TEXT PRIMARY KEY)")
            try db.addColumnIfMissing(table: "t", column: "name", type: .text)
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(t)")
                .compactMap { $0["name"] as String? }
            #expect(cols.contains("name"))
        }
    }

    @Test func addColumnIfMissingIsNoOpWhenPresent() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE t (id TEXT PRIMARY KEY, name TEXT)")
            // Should not throw "duplicate column name"
            try db.addColumnIfMissing(table: "t", column: "name", type: .text)
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(t)")
                .compactMap { $0["name"] as String? }
            #expect(cols.filter { $0 == "name" }.count == 1)
        }
    }

    @Test func addColumnIfMissingIsCaseInsensitive() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            // Column declared in uppercase
            try db.execute(sql: "CREATE TABLE t (id TEXT PRIMARY KEY, FOO TEXT)")
            // Helper called with lowercase — should detect existing and skip
            try db.addColumnIfMissing(table: "t", column: "foo", type: .text)
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(t)")
                .compactMap { $0["name"] as String? }
            // Only the original FOO column should be present
            #expect(cols.filter { $0.lowercased() == "foo" }.count == 1)
        }
    }

    @Test func addColumnIfMissingAppliesDefault() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE t (id TEXT PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO t (id) VALUES ('a')")
            try db.addColumnIfMissing(
                table: "t",
                column: "flag",
                type: .boolean,
                defaults: false
            )
            // Existing row should observe the default
            let value = try Bool.fetchOne(db, sql: "SELECT flag FROM t WHERE id = 'a'")
            #expect(value == false)
            // Newly inserted row without specifying flag should also pick up default
            try db.execute(sql: "INSERT INTO t (id) VALUES ('b')")
            let value2 = try Bool.fetchOne(db, sql: "SELECT flag FROM t WHERE id = 'b'")
            #expect(value2 == false)
        }
    }

    // MARK: createTableIfNotExists

    @Test func createTableIfNotExistsCreatesWhenAbsent() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.createTableIfNotExists("widget") { t in
                t.primaryKey("id", .text).notNull()
                t.column("name", .text).notNull()
            }
            #expect(try db.tableExists("widget"))
        }
    }

    @Test func createTableIfNotExistsIsNoOpWhenPresent() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE widget (id TEXT PRIMARY KEY, name TEXT)")
            // Different body should not throw; existing table wins.
            try db.createTableIfNotExists("widget") { t in
                t.primaryKey("id", .text).notNull()
                t.column("other", .text)
            }
            // Verify table still has the original shape (no 'other' column).
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(widget)")
                .compactMap { $0["name"] as String? }
            #expect(cols.contains("name"))
            #expect(!cols.contains("other"))
        }
    }

    // MARK: addIndexIfMissing

    @Test func addIndexIfMissingCreatesWhenAbsent() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE t (id TEXT PRIMARY KEY, slot TEXT)")
            try db.addIndexIfMissing(
                "idx_t_slot",
                on: "t",
                columns: ["slot"],
                unique: true,
                where: "slot IS NOT NULL"
            )
            let found = try Bool.fetchOne(
                db,
                sql: "SELECT 1 FROM sqlite_master WHERE type='index' AND name=?",
                arguments: ["idx_t_slot"]
            )
            #expect(found == true)
        }
    }

    @Test func addIndexIfMissingIsNoOpWhenPresent() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE t (id TEXT PRIMARY KEY, slot TEXT)")
            try db.execute(sql: "CREATE INDEX idx_t_slot ON t(slot)")
            // Should be a no-op without raising "index already exists".
            try db.addIndexIfMissing("idx_t_slot", on: "t", columns: ["slot"])
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name=?",
                arguments: ["idx_t_slot"]
            )
            #expect(count == 1)
        }
    }

    // MARK: Regression — branch renumbering collision

    /// Reproduces the May 13 2026 outage: an additive migration is registered
    /// once under `v_old_id` (using raw `t.add(column:)`), then re-registered
    /// in a parallel branch under `v_new_id`. Without the helper, GRDB sees
    /// the new ID as unapplied and re-runs the body — SQLite throws
    /// `duplicate column name`. With the helper, the body becomes a logged
    /// no-op.
    @Test func renumberCollisionIsNoOpWithHelper() throws {
        let queue = try DatabaseQueue()

        // Pre-create the schema base shared by both migrators.
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE worktree (id TEXT PRIMARY KEY)")
        }

        // Migrator A — original ID, raw add(column:)
        var migratorA = DatabaseMigrator()
        migratorA.registerMigration("v_old_id") { db in
            try db.alter(table: "worktree") { t in
                t.add(column: "archivedHeadSHA", .text)
            }
        }
        try migratorA.migrate(queue)

        // Migrator B — renumbered ID, same additive change via helper.
        var migratorB = DatabaseMigrator()
        migratorB.registerMigration("v_new_id") { db in
            try db.addColumnIfMissing(
                table: "worktree",
                column: "archivedHeadSHA",
                type: .text
            )
        }
        // Should NOT throw "duplicate column name".
        try migratorB.migrate(queue)

        // Column should still exist exactly once.
        try queue.read { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(worktree)")
                .compactMap { $0["name"] as String? }
            #expect(cols.filter { $0.lowercased() == "archivedheadsha" }.count == 1)
        }
    }
}
