import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib

/// The loader behind the timestamp migration scheme
/// (docs/specs/2026-08-19-migration-identifier-scheme-design.md): it locates
/// `TBD_TBDDaemonLib.bundle/Migrations`, splits each `.sql` file with SQLite's
/// own lexer, and skips an `ALTER TABLE … ADD COLUMN` whose column is already
/// there.
@Suite struct SQLMigrationLoaderTests {

    // MARK: - Fixtures and scratch directories

    /// The shared splitter fixture, read from the source tree rather than from
    /// a resource bundle: the Phase 2 Python lint reads exactly these files
    /// from exactly this path, and a second copy in a bundle would be a second
    /// thing to keep in sync.
    private static var splitterFixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/TBDDaemonTests/SQLMigrationLoaderTests.swift
            .deletingLastPathComponent()          // …/Tests/TBDDaemonTests
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("MigrationSplitter")
    }

    /// A scratch directory under the process temp dir — never `~/tbd`.
    private static func makeScratchDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-sql-migration-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Splitter

    /// Both splitters — this one and the lint's — must reproduce the fixture
    /// exactly. The count assertion is the guard against the directory
    /// vanishing: a zero-case run would otherwise pass silently.
    @Test func splitterReproducesTheSharedFixture() throws {
        let directory = Self.splitterFixtureDirectory
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".sql") }
            .sorted()
        #expect(names.count >= 6, "the shared splitter fixture is missing cases: found \(names)")

        for name in names {
            let stem = String(name.dropLast(".sql".count))
            let sql = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            let expectedData = try Data(
                contentsOf: directory.appendingPathComponent("\(stem).expected.json"))
            let expected = try #require(
                try JSONSerialization.jsonObject(with: expectedData) as? [String],
                "\(stem).expected.json must be a JSON array of strings")
            #expect(SQLMigrationLoader.splitStatements(sql) == expected, "case \(stem)")
        }
    }

    @Test func splitterEmitsNothingForAnEmptyFile() {
        #expect(SQLMigrationLoader.splitStatements("").isEmpty)
        #expect(SQLMigrationLoader.splitStatements("\n\n   \n").isEmpty)
    }

    // MARK: - ADD COLUMN guard: statement recognition

    @Test func addColumnTargetRecognizesTheStrictShape() {
        #expect(SQLMigrationLoader.addColumnTarget(in: "ALTER TABLE config ADD COLUMN foo TEXT")
            .map { [$0.table, $0.column] } == ["config", "foo"])
        // COLUMN keyword is optional.
        #expect(SQLMigrationLoader.addColumnTarget(in: "alter table config add foo text")
            .map { [$0.table, $0.column] } == ["config", "foo"])
        // Double-quoted identifiers are unquoted.
        #expect(SQLMigrationLoader.addColumnTarget(in: #"ALTER TABLE "con fig" ADD COLUMN "b ar" TEXT"#)
            .map { [$0.table, $0.column] } == ["con fig", "b ar"])
        // Leading comments do not hide the statement.
        #expect(SQLMigrationLoader.addColumnTarget(in: "-- why\n/* and why */\nALTER TABLE t ADD c INTEGER")
            .map { [$0.table, $0.column] } == ["t", "c"])
    }

    /// Anything the regex does not match must execute unmodified — the guard
    /// may never silently swallow a statement it did not understand.
    @Test func addColumnTargetRejectsEverythingElse() {
        for statement in [
            "ALTER TABLE t RENAME TO u",
            "ALTER TABLE t RENAME COLUMN a TO b",
            "ALTER TABLE t DROP COLUMN a",
            "CREATE TABLE IF NOT EXISTS t (a TEXT)",
            "UPDATE t SET a = 'ALTER TABLE t ADD COLUMN c TEXT'",
            "INSERT OR IGNORE INTO t (a) VALUES (1)",
            "PRAGMA table_info(t)",
        ] {
            #expect(SQLMigrationLoader.addColumnTarget(in: statement) == nil, "\(statement)")
        }
    }

    // MARK: - ADD COLUMN guard: both branches

    private static func makeGuardFixtureQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE t (id INTEGER PRIMARY KEY, existing TEXT)")
        }
        return queue
    }

    private static func columnNames(_ queue: DatabaseQueue, table: String) throws -> [String] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                .compactMap { $0["name"] as String? }
        }
    }

    /// Branch 1: the column is already there. The statement is skipped, and
    /// nothing throws — SQLite raises `duplicate column name` at *prepare*
    /// time, so reaching `execute` at all would be fatal.
    @Test func addColumnGuardSkipsAColumnThatIsAlreadyPresent() throws {
        let queue = try Self.makeGuardFixtureQueue()
        try queue.write { db in
            try SQLMigrationLoader.apply(
                sql: "ALTER TABLE t ADD COLUMN existing TEXT;", identifier: "test", to: db)
        }
        #expect(try Self.columnNames(queue, table: "t") == ["id", "existing"])
    }

    /// Case-insensitively, because SQLite identifiers are.
    @Test func addColumnGuardSkipsOnACaseDifferingColumnName() throws {
        let queue = try Self.makeGuardFixtureQueue()
        try queue.write { db in
            try SQLMigrationLoader.apply(
                sql: "ALTER TABLE T ADD COLUMN EXISTING TEXT;", identifier: "test", to: db)
        }
        #expect(try Self.columnNames(queue, table: "t") == ["id", "existing"])
    }

    /// Branch 2: the column is absent, so the statement runs.
    @Test func addColumnGuardAddsAColumnThatIsMissing() throws {
        let queue = try Self.makeGuardFixtureQueue()
        try queue.write { db in
            try SQLMigrationLoader.apply(
                sql: "ALTER TABLE t ADD COLUMN fresh INTEGER;", identifier: "test", to: db)
        }
        #expect(try Self.columnNames(queue, table: "t") == ["id", "existing", "fresh"])
    }

    /// A skipped statement must not swallow the rest of the file.
    @Test func applyRunsEveryOtherStatementAroundASkip() throws {
        let queue = try Self.makeGuardFixtureQueue()
        try queue.write { db in
            try SQLMigrationLoader.apply(
                sql: """
                    ALTER TABLE t ADD COLUMN existing TEXT;
                    ALTER TABLE t ADD COLUMN fresh INTEGER;
                    INSERT OR IGNORE INTO t (id, existing) VALUES (1, 'a;b');
                    """,
                identifier: "test", to: db)
        }
        #expect(try Self.columnNames(queue, table: "t") == ["id", "existing", "fresh"])
        let stored = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT existing FROM t WHERE id = 1")
        }
        #expect(stored == "a;b")
    }

    // MARK: - Discovery and ordering

    @Test func discoveryFiltersToSQLAndSortsByIdentifier() throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Deliberately out of order on disk, plus the two non-`.sql` entries
        // `.copy` really does place in the bundle.
        try Self.write("", to: directory.appendingPathComponent(".gitkeep"))
        try Self.write("# notes", to: directory.appendingPathComponent("README.md"))
        try Self.write("SELECT 3;", to: directory.appendingPathComponent("20260901090000_c.sql"))
        try Self.write("SELECT 1;", to: directory.appendingPathComponent("20260819120000_a.sql"))
        try Self.write("SELECT 2;", to: directory.appendingPathComponent("20260819235959_b.sql"))

        let discovered = try SQLMigrationLoader.discover(in: directory)
        #expect(discovered.map(\.identifier) == [
            "20260819120000_a", "20260819235959_b", "20260901090000_c",
        ])
        #expect(discovered.map(\.sql) == ["SELECT 1;", "SELECT 2;", "SELECT 3;"])
    }

    /// The Swift escape hatch interleaves by identifier rather than landing
    /// last — that is the whole reason it takes a timestamp identifier.
    @Test func mergeInterleavesInlineSwiftMigrationsByIdentifier() {
        let files = [
            SQLMigrationFile(identifier: "20260819120000_a", sql: ""),
            SQLMigrationFile(identifier: "20260901090000_c", sql: ""),
        ]
        let inline = [
            RegisteredMigration(identifier: "20260825000000_b") { _ in },
            RegisteredMigration(identifier: "20261001000000_d") { _ in },
        ]
        #expect(SQLMigrationLoader.merged(files: files, inline: inline).map(\.identifier) == [
            "20260819120000_a", "20260825000000_b", "20260901090000_c", "20261001000000_d",
        ])
    }

    @Test func timestampIdentifierRecognition() {
        #expect(SQLMigrationLoader.isTimestampIdentifier("20260819120000_a"))
        #expect(!SQLMigrationLoader.isTimestampIdentifier("v84_reap_records_process_description"))
        #expect(!SQLMigrationLoader.isTimestampIdentifier("20260819120000"))
        #expect(!SQLMigrationLoader.isTimestampIdentifier("2026081912000_a"))
        #expect(!SQLMigrationLoader.isTimestampIdentifier("20260819120000-a"))
    }

    // MARK: - Integrity check, both branches

    private static func makeAppliedIdentifiersQueue(_ identifiers: [String]) throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for identifier in identifiers {
                try db.execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: [identifier])
            }
        }
        return queue
    }

    /// Branch 1: timestamp identifiers applied, zero `.sql` files discovered —
    /// the resource bundle is missing or truncated, so refuse.
    @Test func integrityCheckRefusesWhenTheBundleYieldedNothing() throws {
        let queue = try Self.makeAppliedIdentifiersQueue(["v1", "20260819120000_a"])
        #expect(throws: SQLMigrationLoaderError.self) {
            try queue.read { db in
                try SQLMigrationLoader.verifyResourceIntegrity(
                    db, discoveredIdentifiers: [], directoryPath: "/nowhere/Migrations")
            }
        }
    }

    /// Branch 2: a *partial* mismatch is legitimate — downgrading to an older
    /// build leaves applied identifiers with no corresponding file, and GRDB's
    /// `hasBeenSuperseded` already covers that.
    @Test func integrityCheckAllowsAPartialMismatch() throws {
        let queue = try Self.makeAppliedIdentifiersQueue(
            ["v1", "20260819120000_a", "20260901090000_c"])
        try queue.read { db in
            try SQLMigrationLoader.verifyResourceIntegrity(
                db, discoveredIdentifiers: ["20260819120000_a"], directoryPath: "/somewhere")
        }
    }

    /// Zero files is the normal, inert state today: with only `v`-prefixed
    /// identifiers applied there is nothing to be missing.
    @Test func integrityCheckAllowsZeroFilesWhenNoTimestampIdentifierWasApplied() throws {
        let queue = try Self.makeAppliedIdentifiersQueue(["v1", "v84_reap_records_process_description"])
        try queue.read { db in
            try SQLMigrationLoader.verifyResourceIntegrity(
                db, discoveredIdentifiers: [], directoryPath: "/nowhere")
        }
    }

    /// A brand-new database has no `grdb_migrations` table at all.
    @Test func integrityCheckAllowsAFreshDatabase() throws {
        let queue = try DatabaseQueue()
        try queue.read { db in
            try SQLMigrationLoader.verifyResourceIntegrity(
                db, discoveredIdentifiers: [], directoryPath: "/nowhere")
        }
    }

    // MARK: - Locator

    /// The tripwire for the resource bundle silently vanishing. Under the test
    /// harness it resolves through the third candidate: the bundle is a
    /// SIBLING of `TBDPackageTests.xctest`, not inside it.
    @Test func locatorResolvesTheMigrationsDirectoryUnderTheTestHarness() throws {
        let directory = try SQLMigrationLoader.locateMigrationsDirectory()
        #expect(directory.lastPathComponent == "Migrations")
        #expect(directory.deletingLastPathComponent().lastPathComponent == "TBD_TBDDaemonLib.bundle")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func locatorSearchesAtLeastThreeDistinctCandidates() {
        let candidates = SQLMigrationLoader.candidateContainerURLs()
        #expect(candidates.count >= 2)
        #expect(Set(candidates.map(\.path)).count == candidates.count, "candidates must be deduplicated")
    }

    /// Exhausting the candidate list must name every path searched — an opaque
    /// failure here is the thing `Bundle.module`'s `fatalError` gets wrong.
    @Test func locatorFailureDescribesEveryPathSearched() {
        let error = SQLMigrationLoaderError.resourceBundleNotFound(
            searched: ["/one/TBD_TBDDaemonLib.bundle/Migrations",
                       "/two/TBD_TBDDaemonLib.bundle/Migrations"])
        #expect(error.description.contains("/one/TBD_TBDDaemonLib.bundle/Migrations"))
        #expect(error.description.contains("/two/TBD_TBDDaemonLib.bundle/Migrations"))
    }

    @Test func integrityFailureNamesTheIdentifiersAndTheDirectory() {
        let error = SQLMigrationLoaderError.resourcesMissingButMigrationsApplied(
            applied: ["20260819120000_a"], directoryPath: "/nowhere/Migrations")
        #expect(error.description.contains("20260819120000_a"))
        #expect(error.description.contains("/nowhere/Migrations"))
    }

    // MARK: - The inert cutover

    /// The mechanism ships with an EMPTY `Migrations/` directory, so
    /// `buildMigrator()` is byte-for-byte today's migrator. When the first real
    /// `.sql` migration lands this expectation changes with it — deliberately.
    @Test func theShippedMigrationsDirectoryIsEmptyAndTheMigratorIsUnchanged() throws {
        let found = try SQLMigrationLoader.bundled.get()
        #expect(found.files.isEmpty, "expected an inert Migrations/ directory, found \(found.files.map(\.identifier))")
        #expect(SQLMigrationLoader.inlineTimestampMigrations.isEmpty)
        #expect(SQLMigrationLoader.migrationsForRegistration().isEmpty)

        let identifiers = TBDDatabase.buildMigratorForTests().migrations
        #expect(identifiers.first == "v1")
        #expect(identifiers.last == "v84_reap_records_process_description")
        #expect(!identifiers.contains(where: SQLMigrationLoader.isTimestampIdentifier))
    }

    /// Whatever the directory holds, the registered timestamp migrations are
    /// exactly the merged list, in identifier order, appended after the frozen
    /// block. This one keeps holding once the directory is no longer empty.
    @Test func theMigratorAppendsTheMergedListAfterTheFrozenBlock() throws {
        let expected = SQLMigrationLoader.migrationsForRegistration().map(\.identifier)
        let identifiers = TBDDatabase.buildMigratorForTests().migrations
        #expect(Array(identifiers.suffix(expected.count)) == expected)
        #expect(identifiers.filter(SQLMigrationLoader.isTimestampIdentifier) == expected)
    }

    // MARK: - Full chain

    @Test func theFullChainAppliesToAFreshInMemoryDatabase() throws {
        let queue = try DatabaseQueue()
        try TBDDatabase.buildMigratorForTests().migrate(queue)
        let applied = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
        }
        #expect(applied.contains("v1"))
        #expect(applied.contains("v84_reap_records_process_description"))
        #expect(applied.count == TBDDatabase.buildMigratorForTests().migrations.count)
    }

    /// End to end through the loader: a scratch directory of `.sql` files
    /// registers, sorts, and applies, including the ADD COLUMN skip.
    @Test func discoveredFilesRegisterAndApplyInIdentifierOrder() throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.write(
            "CREATE TABLE IF NOT EXISTS demo (id INTEGER PRIMARY KEY, a TEXT);",
            to: directory.appendingPathComponent("20260902000000_second.sql"))
        try Self.write(
            "CREATE TABLE IF NOT EXISTS earlier (id INTEGER PRIMARY KEY);",
            to: directory.appendingPathComponent("20260901000000_first.sql"))
        // Adds a column the previous file already created — the guard's job.
        try Self.write(
            "ALTER TABLE demo ADD COLUMN a TEXT;\nALTER TABLE demo ADD COLUMN b TEXT;",
            to: directory.appendingPathComponent("20260903000000_third.sql"))

        var migrator = DatabaseMigrator()
        let merged = SQLMigrationLoader.merged(
            files: try SQLMigrationLoader.discover(in: directory), inline: [])
        for migration in merged {
            migrator.registerMigration(migration.identifier, migrate: migration.body)
        }
        #expect(merged.map(\.identifier) == [
            "20260901000000_first", "20260902000000_second", "20260903000000_third",
        ])

        let queue = try DatabaseQueue()
        try migrator.migrate(queue)
        #expect(try Self.columnNames(queue, table: "demo") == ["id", "a", "b"])
    }
}
