import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib

/// `TBDDatabase(inMemory:)` copies a template migrated once per process
/// instead of running the migrator in every init. These pin that a copy is
/// the database the migrator builds, that no copy writes through to the
/// template or to another copy, and that copies taken at the same moment are
/// each complete.
///
/// Tier 1 — in-memory databases only, no clock, no sleeps.
@Suite("In-memory database template")
struct InMemoryDatabaseTemplateTests {

    /// Everything a test can read back from a database, rendered with SQL's
    /// own `quote()` so a value's type and every byte of it take part in the
    /// comparison.
    struct Contents {
        /// `sqlite_master` rows: type, name, table name and SQL, sorted.
        let schema: [String]
        /// `grdb_migrations` identifiers, sorted.
        let migrations: [String]
        let userVersion: Int
        /// Every row of every table, keyed by table name, each table's rows
        /// sorted.
        let rows: [String: [String]]
    }

    static func contents(_ db: Database) throws -> Contents {
        let schema = try String.fetchAll(db, sql: """
            SELECT quote(type) || '|' || quote(name) || '|' || quote(tbl_name) || '|' || quote(sql)
            FROM sqlite_master
            """).sorted()
        let migrations = try String.fetchAll(
            db, sql: "SELECT identifier FROM grdb_migrations").sorted()
        let userVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1
        let tables = try String.fetchAll(
            db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        var rows: [String: [String]] = [:]
        for table in tables {
            let columns = try db.columns(in: table).map { column in
                "quote(\(column.name.quotedDatabaseIdentifier))"
            }
            let select = "SELECT \(columns.joined(separator: " || '|' || ")) FROM \(table.quotedDatabaseIdentifier)"
            rows[table] = try String.fetchAll(db, sql: select).sorted()
        }
        return Contents(
            schema: schema, migrations: migrations, userVersion: userVersion, rows: rows)
    }

    /// Fails if the copy skipped a migration, took a template migrated only
    /// part of the way, or holds a row a fresh run does not. Both run in one
    /// process, so this is no proof that the chain is deterministic: a
    /// surviving row stamped with the clock would most likely differ here,
    /// one taken from the environment would not.
    @Test("a copied database is the database a fresh migration builds")
    func copyMatchesAFreshMigration() throws {
        let migrator = TBDDatabase.buildMigratorForTests()
        let fresh = try DatabaseQueue()
        try migrator.migrate(fresh)
        let expected = try fresh.read { db in try Self.contents(db) }

        let copied = try TBDDatabase(inMemory: true)
        let actual = try copied.writerForTests.read { db in try Self.contents(db) }

        #expect(actual.schema == expected.schema)
        #expect(actual.migrations == expected.migrations)
        #expect(actual.userVersion == expected.userVersion)
        #expect(actual.rows == expected.rows)

        // Controls: the copy applied exactly the registered chain, and the
        // row comparison is not vacuous — the chain leaves the `config`
        // singleton behind.
        let registered = migrator.migrations.sorted()
        #expect(actual.migrations == registered)
        let configRows = expected.rows["config"] ?? []
        #expect(configRows.count == 1)
    }

    /// A row and a table written into one copy reach neither a copy built
    /// before the write nor one built after it, so the template is never
    /// written through.
    @Test("a write to one copy reaches no other copy and not the template")
    func copiesAreIndependent() throws {
        let written = try TBDDatabase(inMemory: true)
        let builtBefore = try TBDDatabase(inMemory: true)
        try written.writerForTests.write { db in
            try db.execute(
                sql: "INSERT INTO tbd_meta (key, value) VALUES (?, ?)",
                arguments: [Self.markerKey, "written"])
            try db.execute(sql: "CREATE TABLE \(Self.markerTable) (id INTEGER)")
        }
        let builtAfter = try TBDDatabase(inMemory: true)

        let seen = try [written, builtBefore, builtAfter].map { database in
            try database.writerForTests.read { db -> Marker in
                let rows = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM tbd_meta WHERE key = ?",
                    arguments: [Self.markerKey]) ?? -1
                let table = try db.tableExists(Self.markerTable)
                return Marker(rows: rows, table: table)
            }
        }
        let expected = [
            Marker(rows: 1, table: true),
            Marker(rows: 0, table: false),
            Marker(rows: 0, table: false),
        ]
        #expect(seen == expected)
    }

    /// What one database holds of the marker written in
    /// `copiesAreIndependent`: its `tbd_meta` rows, and whether its table
    /// exists.
    struct Marker: Equatable {
        let rows: Int
        let table: Bool
    }

    private static let markerKey = "in-memory-template-independence"
    private static let markerTable = "in_memory_template_independence"

    /// Builds databases from many tasks at once and checks that each copy holds
    /// every registered migration: copies taken concurrently are each complete.
    @Test("databases built at the same moment are each complete")
    func concurrentCopiesAreComplete() async throws {
        let registered = TBDDatabase.buildMigratorForTests().migrations.count
        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<Self.concurrentCopies {
                group.addTask {
                    let database = try TBDDatabase(inMemory: true)
                    return try await database.writerForTests.read { db in
                        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations") ?? 0
                    }
                }
            }
            var counts: [Int] = []
            for try await count in group {
                counts.append(count)
            }
            return counts
        }
        let expected = [Int](repeating: registered, count: Self.concurrentCopies)
        #expect(counts == expected)
    }

    private static let concurrentCopies = 8
}
