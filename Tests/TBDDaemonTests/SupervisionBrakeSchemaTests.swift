import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

/// Schema-level guards for the supervision fleet brake
/// (`docs/specs/2026-07-26-fleet-supervision-design.md` §3, §7).
///
/// The whole reason this suite exists is the tri-state on
/// `config.supervision_enabled`: like `queued_prompt_enabled` before it, that
/// column is added with **no SQL default**, so "never chose" (NULL) stays
/// distinguishable from "explicitly off" (0). If someone re-adds
/// `defaults: false` to `v75_config_supervision_enabled`,
/// `supervisionEnabledIsNullBeforeAnyGesture` goes red — that is its only job.
@Suite("SupervisionBrakeSchema")
struct SupervisionBrakeSchemaTests {

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    // MARK: - v75: the flag is genuinely NULL until somebody touches the toggle

    /// **The load-bearing test.** The `config` singleton row is inserted by
    /// v1, so every install — fresh or years old — has a row that predates
    /// v75. After v75 that row's `supervision_enabled` must read NULL, not
    /// `0`. A SQL default would backfill it to `0` and make "never chose"
    /// indistinguishable from a deliberate opt-out, which is exactly what the
    /// no-default convention exists to prevent. (Cautionary precedent:
    /// `auto_hibernate_enabled` shipped WITH a SQL default and needed a
    /// forcing migration later — this test is what would have caught that
    /// defect before it shipped.)
    @Test func supervisionEnabledIsNullBeforeAnyGesture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(
            record.supervision_enabled == nil,
            """
            config.supervision_enabled must be NULL until the toggle is \
            touched — read back \(String(describing: record.supervision_enabled)). \
            A non-nil value here means v75_config_supervision_enabled grew a \
            `defaults:` argument; remove it.
            """
        )
    }

    /// The same guard against a row written by a real pre-v75 daemon: migrate
    /// only through v74, write to the config row, then finish migrating.
    @Test func rowWrittenBeforeV75StillReadsNull() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: "v74_worktree_pending_prompt")

        // A pre-v75 daemon touching config: the row exists and has been
        // written to, but knows nothing about the new column.
        try queue.write { db in
            try db.execute(
                sql: "UPDATE config SET delivery_verification_enabled = 1 WHERE id = ?",
                arguments: [ConfigStore.singletonID]
            )
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let row = try #require(try Row.fetchOne(
                db, sql: "SELECT * FROM config WHERE id = ?",
                arguments: [ConfigStore.singletonID]))
            let raw: DatabaseValue = row["supervision_enabled"]
            #expect(
                raw.isNull,
                "a config row written before v75 must read NULL, not \(raw)"
            )
            // The pre-existing write survived — v75 is purely additive.
            #expect(row["delivery_verification_enabled"] == true)
        }
    }

    // MARK: - The three states are distinguishable

    /// NULL follows `Config.supervisionEnabledDefault` wherever it goes; an
    /// explicit `false` does not. This is the property that makes graduation
    /// a one-line constant change with no forcing `UPDATE` migration.
    /// Exercised against BOTH possible default values, not just today's
    /// constant, so this test would fail if the tri-state resolution were
    /// wired as `?? false` instead of `?? supervisionEnabledDefault`.
    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)

        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.supervision_enabled == nil)
        #expect(untouched.toModel(supervisionEnabledDefault: false).supervisionEnabled == false)
        #expect(
            untouched.toModel(supervisionEnabledDefault: true).supervisionEnabled == true,
            "a never-chosen row must pick up a changed shipped default"
        )

        try await db.config.setSupervisionEnabled(enabled: false)
        let explicitlyOff = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOff.supervision_enabled == false)
        #expect(explicitlyOff.toModel(supervisionEnabledDefault: false).supervisionEnabled == false)
        #expect(
            explicitlyOff.toModel(supervisionEnabledDefault: true).supervisionEnabled == false,
            "an explicit opt-out (pulling the brake) must be honored forever, whatever the shipped default becomes"
        )
    }

    /// Same property, mirrored for an explicit `true` — an operator who
    /// releases the brake stays released even if the shipped default were
    /// ever flipped back to off.
    @Test func explicitTrueSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)

        try await db.config.setSupervisionEnabled(enabled: true)
        let explicitlyOn = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOn.supervision_enabled == true)
        #expect(explicitlyOn.toModel(supervisionEnabledDefault: false).supervisionEnabled == true)
        #expect(explicitlyOn.toModel(supervisionEnabledDefault: true).supervisionEnabled == true)
    }

    /// Isolates the RESOLUTION guard (`toModel()`'s `?? supervisionEnabledDefault`)
    /// from the STORAGE guard (the migration's no-SQL-default) by constructing
    /// a `ConfigRecord` directly — no database, no migration involved. If
    /// `toModel()` were ever hardened from `supervision_enabled ??
    /// supervisionEnabledDefault` into `supervision_enabled ?? false`, this is
    /// the test that would catch it, and it would catch it even if the
    /// migration guard above were *also* broken at the same time — the two
    /// failures can't be mistaken for each other because this one never reads
    /// the database.
    @Test func toModelResolvesNullThroughTheInjectedDefaultRegardlessOfStorage() {
        let record = ConfigRecord(id: "unstored", supervision_enabled: nil)
        #expect(record.toModel(supervisionEnabledDefault: false).supervisionEnabled == false)
        #expect(
            record.toModel(supervisionEnabledDefault: true).supervisionEnabled == true,
            "a NULL record must pick up whatever default is injected, not a hardcoded false"
        )
    }

    /// The shipped default today. Graduation edits this constant and nothing
    /// else.
    @Test func shippedDefaultIsOff() async throws {
        #expect(Config.supervisionEnabledDefault == false)
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().supervisionEnabled == false)
    }

    @Test func setSupervisionEnabledRoundtrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setSupervisionEnabled(enabled: true)
        #expect(try await db.config.get().supervisionEnabled == true)
        try await db.config.setSupervisionEnabled(enabled: false)
        #expect(try await db.config.get().supervisionEnabled == false)
    }

    /// Restart-equivalent: reopening the store against the same on-disk file
    /// and reading back must return the persisted value, not the in-memory
    /// default.
    @Test func setSupervisionEnabledSurvivesReopeningTheStore() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervision-brake-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("state.db").path

        do {
            let db = try TBDDatabase(path: dbPath)
            try await db.config.setSupervisionEnabled(enabled: true)
            #expect(try await db.config.get().supervisionEnabled == true)
        }

        // Reopen — simulates a daemon restart reading the same file back.
        let reopened = try TBDDatabase(path: dbPath)
        #expect(try await reopened.config.get().supervisionEnabled == true)
    }
}
