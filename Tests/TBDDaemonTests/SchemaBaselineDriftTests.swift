import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib

/// Guards the frozen `v1`–`v84` Swift migration block against silent drift.
///
/// `Tests/TBDDaemonTests/Fixtures/schema-baseline-v84.sql` is the schema that
/// block produces against an empty database, generated once by
/// `scripts/gen-migration-baseline.sh` and committed. It is not a live
/// snapshot in the style of Rails' `schema.rb` — nothing rewrites it on every
/// migration. The block it was generated from is frozen: those migrations
/// have already run on user machines and cannot change, and (once the SQL
/// migration lint lands) a mechanical check forbids editing migration
/// history.
///
/// If `driftAgainstCommittedBaseline` below ever fails, that means the frozen
/// block changed — a real problem, not a chore to fix by regenerating the
/// fixture. Stop and escalate rather than re-running the generator.
@Suite("Schema baseline (v1-v84)")
struct SchemaBaselineDriftTests {

    /// Absolute path to the committed fixture, resolved from this source
    /// file's own location so it works identically under `swift test` and
    /// under `scripts/test.sh`'s fenced `TBD_HOME` — this file lives in the
    /// real checkout, not under any TBD-owned path the fence redirects.
    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/schema-baseline-v84.sql")
    }

    /// Renders the schema produced by a migrated database as SQL text.
    ///
    /// Deliberately schema-only: `sqlite_master.sql` never holds row data, so
    /// this naturally excludes `grdb_migrations`' 84 applied-migration rows
    /// along with every other table's contents — those are bookkeeping and
    /// user data, not schema, and including them would make the fixture
    /// churn on things this test does not care about. `grdb_migrations`'
    /// `CREATE TABLE` statement IS included: it is a real object the
    /// migrator creates, and the fixture's job is to reflect the schema that
    /// results from running v1-v84, not to hand-pick which tables count.
    ///
    /// SQLite's own internal objects (`sqlite_%`: the master table itself,
    /// autoindexes backing `UNIQUE`/`PRIMARY KEY` constraints) are excluded —
    /// they are not migration output, they are SQLite's bookkeeping about the
    /// objects that are.
    ///
    /// Ordered tables-then-indexes-then-triggers-then-views, name ascending
    /// within each group, rather than a flat sort by name: a flat sort would
    /// still be deterministic, but it is not safe to *replay* — an index
    /// alphabetically before its own table would come first and fail to
    /// apply against an empty database. The lint's chain-apply check
    /// (spec: "The frozen baseline fixture") replays this fixture before
    /// applying `.sql` migrations on top, so replay order is load-bearing,
    /// not cosmetic.
    static func dumpSchema(_ db: Database) throws -> String {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT sql FROM sqlite_master
                WHERE sql IS NOT NULL
                  AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
                ORDER BY
                    CASE type
                        WHEN 'table' THEN 0
                        WHEN 'index' THEN 1
                        WHEN 'trigger' THEN 2
                        WHEN 'view' THEN 3
                        ELSE 4
                    END,
                    name
                """
        )
        let statements: [String] = rows.compactMap { $0["sql"] }
        return statements.map { "\($0);\n" }.joined()
    }

    /// The last identifier in the frozen block. `migrate(upTo:)` stops here, so
    /// the dump covers `v1`–`v84` and nothing else.
    static let frozenBlockLastIdentifier = "v84_reap_records_process_description"

    /// Migrate a fresh database through the frozen block ONLY.
    ///
    /// `upTo:` is load-bearing, in both the drift check and the generator.
    /// `buildMigrator()` appends every discovered `.sql` migration after the
    /// frozen block, so a plain `migrate(queue)` would dump v1–v84 *plus* the
    /// timestamp migrations. The drift check would then fail on the first real
    /// migration with "the frozen block no longer produces the committed
    /// schema", pointing its author at a bug that does not exist — and the
    /// generator would bake those same migrations into the supposedly frozen
    /// baseline, making the fixture a live schema snapshot, which is the thing
    /// the design explicitly rejects.
    private static func migrateFreshDatabase() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try TBDDatabase.buildMigratorForTests().migrate(queue, upTo: frozenBlockLastIdentifier)
        // Guards the `upTo:` above: if it is ever dropped, this says so
        // directly instead of leaving the drift diff to imply that the frozen
        // block changed.
        let applied = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
        }
        #expect(!applied.contains(where: SQLMigrationLoader.isTimestampIdentifier), """
            The baseline database ran past the frozen block into the timestamp \
            migrations. The baseline covers v1-v84 only — restore `upTo:`.
            """)
        return queue
    }

    @Test("v1-v84 still produce exactly the committed baseline schema")
    func driftAgainstCommittedBaseline() throws {
        let queue = try Self.migrateFreshDatabase()
        let dumped = try queue.read { db in try Self.dumpSchema(db) }
        let committed = try String(contentsOf: Self.fixtureURL, encoding: .utf8)

        #expect(dumped == committed, """
            The frozen v1-v84 Swift migration block no longer produces the schema \
            committed at Tests/TBDDaemonTests/Fixtures/schema-baseline-v84.sql. That \
            block is frozen — this is a real problem, not a signal to regenerate the \
            fixture. See docs/specs/2026-08-19-migration-identifier-scheme-design.md, \
            "The frozen baseline fixture".
            """)
    }

    /// The generator, gated off by default so it can never run as part of a
    /// normal `scripts/test.sh` pass and silently rewrite the fixture it is
    /// supposed to be checked against. `scripts/gen-migration-baseline.sh`
    /// sets the env var and filters to just this test.
    ///
    /// Precedent for the gating shape:
    /// `Tests/TBDDaemonTests/FlakyQuarantineSelfTests.swift`'s `alwaysFails()`.
    @Test(
        "regenerate schema-baseline-v84.sql (on demand only, via scripts/gen-migration-baseline.sh)",
        .enabled(if: ProcessInfo.processInfo.environment["TBD_GENERATE_MIGRATION_BASELINE"] == "1")
    )
    func generateBaseline() throws {
        let queue = try Self.migrateFreshDatabase()
        let dumped = try queue.read { db in try Self.dumpSchema(db) }
        try dumped.write(to: Self.fixtureURL, atomically: true, encoding: .utf8)
    }
}
