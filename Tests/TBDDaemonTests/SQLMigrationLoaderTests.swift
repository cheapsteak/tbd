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

    /// The shared ADD COLUMN fixture, read from the source tree for the same
    /// reason: `scripts/lint-migrations.py --emit-add-column-targets` reads
    /// exactly this file, and the two sides here are two regex *engines*
    /// running one pattern rather than two bindings to one implementation.
    private static var addColumnFixtureURL: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/TBDDaemonTests/SQLMigrationLoaderTests.swift
            .deletingLastPathComponent()          // …/Tests/TBDDaemonTests
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("MigrationAddColumn")
            .appendingPathComponent("add-column-targets.json")
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
        #expect(names.count >= 7, "the shared splitter fixture is missing cases: found \(names)")

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

    // MARK: - CRLF

    /// In Swift `"\r\n"` is a SINGLE `Character` that does not equal `"\n"`, so
    /// scanning a line comment for `"\n"` finds nothing in a CRLF file and
    /// reports the whole remainder as noise.
    ///
    /// Consequence one: a comment followed by a statement with no trailing
    /// semicolon is dropped, the file contributes ZERO statements, and GRDB
    /// still records the identifier as applied — a silent, permanent no-op.
    @Test func splitterKeepsACommentedTrailerInACRLFFile() {
        let sql = "-- note\r\nALTER TABLE config ADD COLUMN foo TEXT"
        #expect(SQLMigrationLoader.splitStatements(sql) == [sql])
    }

    /// Consequence two: with the comment swallowing the statement, the ADD
    /// COLUMN guard never matches, so a duplicate column reaches SQLite and
    /// throws at prepare time — the daemon fails to start.
    @Test func addColumnGuardSeesThroughACRLFComment() {
        #expect(SQLMigrationLoader.addColumnTarget(in: "-- why\r\nALTER TABLE t ADD c INTEGER")
            .map { [$0.table, $0.column] } == ["t", "c"])
        // A bare CR is a newline too, and so is a comment that ends the file.
        #expect(SQLMigrationLoader.addColumnTarget(in: "-- why\rALTER TABLE t ADD c INTEGER")
            .map { [$0.table, $0.column] } == ["t", "c"])
        #expect(SQLMigrationLoader.addColumnTarget(in: "-- no statement follows\r\n") == nil)
    }

    /// End to end: a CRLF migration file really does apply.
    @Test func aCRLFMigrationFileApplies() throws {
        let queue = try Self.makeGuardFixtureQueue()
        try queue.write { db in
            try SQLMigrationLoader.apply(
                sql: "-- one\r\nALTER TABLE t ADD COLUMN existing TEXT;\r\n"
                    + "-- two\r\nALTER TABLE t ADD COLUMN fresh INTEGER",
                identifier: "test", to: db)
        }
        #expect(try Self.columnNames(queue, table: "t") == ["id", "existing", "fresh"])
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

    /// Every case in the shared fixture, which the lint reads too. The count
    /// assertion guards against the file vanishing: a zero-case run would
    /// otherwise pass silently.
    @Test func addColumnTargetMatchesTheSharedFixture() throws {
        let data = try Data(contentsOf: Self.addColumnFixtureURL)
        let cases = try #require(
            try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            "add-column-targets.json must be a JSON array of objects")
        #expect(cases.count >= 16, "the shared ADD COLUMN fixture is missing cases")

        for testCase in cases {
            let name = testCase["name"] as? String ?? "<unnamed>"
            let sql = try #require(testCase["sql"] as? String, "case \(name) has no sql")
            // `null` means "must decline". Anything that is neither null nor
            // an array of strings is a malformed case, not a declining one —
            // reading it as nil would turn a typo into a passing assertion.
            let expected = testCase["target"] as? [String]
            #expect(expected != nil || testCase["target"] is NSNull,
                    "case \(name): target must be [table, column] or null")
            let actual = SQLMigrationLoader.addColumnTarget(in: sql).map { [$0.table, $0.column] }
            #expect(actual == expected, "case \(name)")
        }
    }

    /// An untyped column is legal SQLite — it takes BLOB affinity — and the
    /// splitter hands each statement over with its `;` still attached, so the
    /// character after the identifier is `;` where a typed column has a space.
    @Test func addColumnTargetReadsAnUntypedColumn() {
        #expect(SQLMigrationLoader.addColumnTarget(in: "ALTER TABLE t ADD COLUMN foo;")
            .map { [$0.table, $0.column] } == ["t", "foo"])
        #expect(SQLMigrationLoader.addColumnTarget(in: "ALTER TABLE t ADD COLUMN foo")
            .map { [$0.table, $0.column] } == ["t", "foo"])
        #expect(SQLMigrationLoader.addColumnTarget(in: "ALTER TABLE t ADD foo;")
            .map { [$0.table, $0.column] } == ["t", "foo"])
    }

    /// A comment may butt straight against the column identifier.
    @Test func addColumnTargetReadsAColumnFollowedByAComment() {
        #expect(SQLMigrationLoader.addColumnTarget(in: "ALTER TABLE t ADD COLUMN foo-- why\n")
            .map { [$0.table, $0.column] } == ["t", "foo"])
        #expect(SQLMigrationLoader.addColumnTarget(in: "ALTER TABLE t ADD COLUMN foo/* why */ TEXT;")
            .map { [$0.table, $0.column] } == ["t", "foo"])
    }

    /// `COLUMN` is optional in the shape, so wherever the column identifier
    /// cannot be matched the engine backtracks and captures the keyword
    /// itself. Believing such a capture against a table that has a column
    /// named `column` would SKIP a statement that never ran, so a bare keyword
    /// capture is declined and the statement executes unmodified.
    @Test func addColumnTargetDeclinesABareKeywordCapture() {
        for statement in [
            "ALTER TABLE t ADD CONSTRAINT fk FOREIGN KEY (a) REFERENCES u (b);",
            "ALTER TABLE t ADD COLUMN column;",
            "ALTER TABLE t ADD column;",
            #"ALTER TABLE t ADD COLUMN "foo"TEXT;"#,
        ] {
            #expect(SQLMigrationLoader.addColumnTarget(in: statement) == nil, "\(statement)")
        }
        // Quoted, `"column"` is an ordinary identifier: the comparison happens
        // before unquoting, so it is unaffected.
        #expect(SQLMigrationLoader.addColumnTarget(in: #"ALTER TABLE t ADD COLUMN "column";"#)
            .map { [$0.table, $0.column] } == ["t", "column"])
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

    /// The shape the terminator set exists for: an untyped duplicate column.
    /// The statement arrives from the splitter as `… ADD COLUMN existing;`, so
    /// the identifier is followed by `;`. A terminator set of whitespace or
    /// end-of-input backtracks there and reads the keyword `COLUMN` as the
    /// column name, which no table has — so the duplicate reaches SQLite and
    /// `duplicate column name` is raised at prepare time.
    @Test func addColumnGuardSkipsAnUntypedColumnThatIsAlreadyPresent() throws {
        let queue = try Self.makeGuardFixtureQueue()
        try queue.write { db in
            try SQLMigrationLoader.apply(
                sql: "ALTER TABLE t ADD COLUMN existing;", identifier: "test", to: db)
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

    /// And the other branch of the same shape: untyped and absent, so it runs.
    /// SQLite gives such a column BLOB affinity.
    @Test func addColumnGuardAddsAnUntypedColumnThatIsMissing() throws {
        let queue = try Self.makeGuardFixtureQueue()
        try queue.write { db in
            try SQLMigrationLoader.apply(
                sql: "ALTER TABLE t ADD COLUMN fresh;", identifier: "test", to: db)
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
        #expect(!SQLMigrationLoader.isTimestampIdentifier(
            SchemaBaselineDriftTests.frozenBlockLastIdentifier))
        #expect(!SQLMigrationLoader.isTimestampIdentifier("20260819120000"))
        #expect(!SQLMigrationLoader.isTimestampIdentifier("2026081912000_a"))
        #expect(!SQLMigrationLoader.isTimestampIdentifier("20260819120000-a"))
    }

    // MARK: - Gate two: report, never refuse

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

    /// Branch 1: timestamp identifiers applied, zero `.sql` files discovered.
    /// That gets logged, naming the directory and the identifiers — and does
    /// NOT refuse. "Directory present, zero files" is the ordinary state of a
    /// worktree branched before the first migration landed, and any worktree's
    /// `scripts/restart.sh` replaces the daemon machine-wide, so refusing here
    /// would brick the fleet on a routine branch switch.
    @Test func gateTwoReportsAMissingBundleAndDoesNotRefuse() throws {
        let queue = try Self.makeAppliedIdentifiersQueue(["v1", "20260819120000_a"])
        let reported = try queue.read { db in
            try SQLMigrationLoader.reportMissingResources(
                db, discoveredIdentifiers: [], directoryPath: "/nowhere/Migrations")
        }
        let message = try #require(reported, "gate two must report this case")
        #expect(message.contains("20260819120000_a"))
        #expect(message.contains("/nowhere/Migrations"))
    }

    /// Branch 2: a *partial* mismatch is legitimate — downgrading to an older
    /// build leaves applied identifiers with no corresponding file, and GRDB's
    /// `hasBeenSuperseded` already covers that. Nothing is reported.
    @Test func gateTwoStaysSilentOnAPartialMismatch() throws {
        let queue = try Self.makeAppliedIdentifiersQueue(
            ["v1", "20260819120000_a", "20260901090000_c"])
        let reported = try queue.read { db in
            try SQLMigrationLoader.reportMissingResources(
                db, discoveredIdentifiers: ["20260819120000_a"], directoryPath: "/somewhere")
        }
        #expect(reported == nil)
    }

    /// Zero files is the normal, inert state today: with only `v`-prefixed
    /// identifiers applied there is nothing to be missing.
    @Test func gateTwoStaysSilentWhenNoTimestampIdentifierWasApplied() throws {
        let queue = try Self.makeAppliedIdentifiersQueue(
            ["v1", SchemaBaselineDriftTests.frozenBlockLastIdentifier])
        let reported = try queue.read { db in
            try SQLMigrationLoader.reportMissingResources(
                db, discoveredIdentifiers: [], directoryPath: "/nowhere")
        }
        #expect(reported == nil)
    }

    /// A brand-new database has no `grdb_migrations` table at all.
    @Test func gateTwoStaysSilentOnAFreshDatabase() throws {
        let queue = try DatabaseQueue()
        let reported = try queue.read { db in
            try SQLMigrationLoader.reportMissingResources(
                db, discoveredIdentifiers: [], directoryPath: "/nowhere")
        }
        #expect(reported == nil)
    }

    // MARK: - Gate one: refuse

    /// Gate one throws even on a fresh database with nothing applied: a daemon
    /// that cannot find its migration resources at all must fail at startup,
    /// naming every path it searched. Both `init(path:)` and `init(inMemory:)`
    /// run this before they migrate.
    @Test func gateOneThrowsWhenTheLocatorFoundNothing() throws {
        let queue = try DatabaseQueue()
        let failure = Result<BundledMigrations, SQLMigrationLoaderError>.failure(
            .resourceBundleNotFound(searched: ["/one/TBD_TBDDaemonLib.bundle/Migrations"]))
        let thrown = #expect(throws: SQLMigrationLoaderError.self) {
            try queue.read { db in
                try SQLMigrationLoader.verifyResourceIntegrity(db, bundled: failure)
            }
        }
        #expect(thrown?.description.contains("/one/TBD_TBDDaemonLib.bundle/Migrations") == true)
    }

    /// Gate one passes with the real bundle, and gate two then says nothing on
    /// a fresh database — the path both initializers take today.
    @Test func verifyResourceIntegrityPassesAgainstTheShippedBundle() throws {
        let queue = try DatabaseQueue()
        try queue.read { db in try SQLMigrationLoader.verifyResourceIntegrity(db) }
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
        #expect(candidates.count >= 3, "searched: \(candidates.map(\.path))")
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

    @Test func gateTwoMessageNamesTheIdentifiersAndTheDirectory() {
        let message = SQLMigrationLoader.missingResourcesMessage(
            applied: ["20260819120000_a"], directoryPath: "/nowhere/Migrations")
        #expect(message.contains("20260819120000_a"))
        #expect(message.contains("/nowhere/Migrations"))
    }

    // MARK: - Shipped migration manifest

    /// Every shipped timestamp migration is named here deliberately. Adding or
    /// removing a resource must update this manifest, while the frozen Swift
    /// block remains independently pinned by `SchemaBaselineDriftTests`.
    @Test func theShippedMigrationsMatchTheExpectedManifest() throws {
        let expected = [
            "20260816122608_worktree_remote_parent_assigned",
            "20260816181509_remote_create_defaults",
            "20260824214437_auto_create_notes_setting",
            "20260825024814_codex_transcript_boundary",
            "20260825060216_terminal_session_incarnation",
            "20260829210843_pending_terminal_incarnation",
            "20260830003851_config_remote_peer_messaging",
            "20260830022625_shadow_peer_artifacts",
            "20260831055718_config_pty_holder",
            "20260831055719_terminal_transport",
        ]
        let found = try SQLMigrationLoader.bundled.get()
        #expect(found.files.map(\.identifier) == expected)
        #expect(SQLMigrationLoader.inlineTimestampMigrations.isEmpty)
        #expect(SQLMigrationLoader.migrationsForRegistration().map(\.identifier) == expected)
    }

    /// Every `.sql` file committed under `Sources/TBDDaemon/Database/Migrations/`
    /// reaches the running process through the resource bundle, and nothing
    /// else does.
    ///
    /// The manifest above is the *intent* check: it fails when a migration is
    /// added or removed without anyone saying so out loud. This is the
    /// *plumbing* check — the source tree is the authority on which migrations
    /// exist, and a build that shipped a different set (none at all, or a set
    /// copied from some other tree) surfaces here as one mismatch rather than
    /// as scattered "no such column" failures at runtime. A hand-written
    /// manifest cannot catch that, and a derived list cannot catch an
    /// unnoticed addition, so both are kept.
    @Test func theShippedMigrationsAreExactlyTheCommittedOnes() throws {
        let committed = try FileManager.default
            .contentsOfDirectory(atPath: Self.repositoryMigrationsDirectory.path)
            .filter { $0.hasSuffix(".sql") }
            .map { String($0.dropLast(".sql".count)) }
            .sorted()
        let found = try SQLMigrationLoader.bundled.get()
        #expect(found.files.map(\.identifier) == committed, """
            The shipped Migrations/ bundle does not match the committed directory. \
            Bundle: \(found.files.map(\.identifier)). Committed: \(committed).
            """)
        #expect(found.files.allSatisfy { SQLMigrationLoader.isTimestampIdentifier($0.identifier) })
    }

    /// The frozen Swift block is closed: it still starts at `v1`, still ends at
    /// the identifier `SchemaBaselineDriftTests` names, and every timestamp
    /// migration lands after it. A `vN` appended to the block by a rebase would
    /// move that tail; a timestamp migration must never be able to.
    @Test func theFrozenBlockStillEndsWhereItDid() throws {
        let identifiers = TBDDatabase.buildMigratorForTests().migrations
        #expect(identifiers.first == "v1")
        let frozen = identifiers.prefix { !SQLMigrationLoader.isTimestampIdentifier($0) }
        #expect(frozen.last == SchemaBaselineDriftTests.frozenBlockLastIdentifier)
        #expect(SQLMigrationLoader.inlineTimestampMigrations.isEmpty)
    }

    /// The committed migrations directory in the checkout, resolved from this
    /// source file rather than from any TBD-owned path, so `scripts/test.sh`'s
    /// fenced `TBD_HOME` cannot redirect it.
    private static var repositoryMigrationsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TBDDaemonTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Sources/TBDDaemon/Database/Migrations")
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
        #expect(applied.contains(SchemaBaselineDriftTests.frozenBlockLastIdentifier))
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
