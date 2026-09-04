import Foundation
import GRDB
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// Schema and resolution guards for `config.holder_row_reconcile_enabled`, the
/// soak gate on the reconcile arm that judges holder-backed session rows and
/// deletes the ones nothing can reach any more.
///
/// The column is added by `20260903193500_config_holder_row_reconcile` with **no
/// SQL default**, so "never chose" (NULL) stays distinguishable from
/// "explicitly off" (0). If someone adds a `DEFAULT` clause to that migration,
/// `nullBeforeAnyGesture` and `rowWrittenBeforeTheMigrationStillReadsNull` go
/// red — that is their only job. The distinction earns its keep because this
/// arm destroys terminal and tab rows: somebody who turned it off did so
/// deliberately and must stay opted out through graduation.
@Suite("HolderRowReconcileFlag")
struct HolderRowReconcileFlagTests {

    /// The last migration identifier that predates the flag's column. Migrating
    /// only this far reproduces the schema a real pre-flag daemon ran on.
    private static let lastIdentifierBeforeTheFlag = "20260901180118_config_reap_holder_children"

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    // MARK: - Storage: the column is genuinely NULL until somebody chooses

    /// **The load-bearing test.** The `config` singleton row is inserted by v1,
    /// so every install has a row that predates this column. After the
    /// migration that row must read NULL, not `0`.
    @Test func nullBeforeAnyGesture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(
            record.holder_row_reconcile_enabled == nil,
            """
            config.holder_row_reconcile_enabled must be NULL until the toggle is \
            touched — read back \
            \(String(describing: record.holder_row_reconcile_enabled)). A non-nil \
            value here means 20260903193500_config_holder_row_reconcile grew a \
            DEFAULT clause; remove it.
            """)
    }

    /// The same guard against a row written by a real pre-flag daemon: migrate
    /// only as far as the last identifier that predates the column, write to the
    /// config row, then finish migrating.
    @Test func rowWrittenBeforeTheMigrationStillReadsNull() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: Self.lastIdentifierBeforeTheFlag)

        try queue.write { db in
            try db.execute(
                sql: "UPDATE config SET auto_create_notes_enabled = 1 WHERE id = ?",
                arguments: [ConfigStore.singletonID])
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let row = try #require(try Row.fetchOne(
                db, sql: "SELECT * FROM config WHERE id = ?",
                arguments: [ConfigStore.singletonID]))
            let raw: DatabaseValue = row["holder_row_reconcile_enabled"]
            #expect(
                raw.isNull,
                "a config row written before the migration must read NULL, not \(raw)")
            // The pre-existing write survived — the migration is purely additive.
            #expect(row["auto_create_notes_enabled"] == true)
        }
    }

    // MARK: - Resolution: the three states are distinguishable

    /// NULL follows `Config.holderRowReconcileEnabledDefault` wherever it goes;
    /// an explicit `false` does not. That property is what makes graduation a
    /// one-line constant change with no forcing `UPDATE` migration. Exercised
    /// against BOTH possible default values, so it fails if the resolution is
    /// ever wired as `?? false`.
    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)

        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.holder_row_reconcile_enabled == nil)
        #expect(
            untouched.toModel(holderRowReconcileDefault: false).holderRowReconcileEnabled == false)
        #expect(
            untouched.toModel(holderRowReconcileDefault: true).holderRowReconcileEnabled == true,
            "a never-chosen row must pick up a changed shipped default")

        try await db.config.setHolderRowReconcileEnabled(false)
        let explicitlyOff = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOff.holder_row_reconcile_enabled == false)
        #expect(
            explicitlyOff.toModel(holderRowReconcileDefault: false)
                .holderRowReconcileEnabled == false)
        #expect(
            explicitlyOff.toModel(holderRowReconcileDefault: true)
                .holderRowReconcileEnabled == false,
            "an explicit opt-out must be honored forever, whatever the shipped default becomes")
    }

    /// Mirrored for an explicit `true`: an operator who opted into the soak
    /// stays opted in even if the shipped default never moves.
    @Test func explicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setHolderRowReconcileEnabled(true)
        let explicitlyOn = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOn.holder_row_reconcile_enabled == true)
        #expect(
            explicitlyOn.toModel(holderRowReconcileDefault: false)
                .holderRowReconcileEnabled == true)
        #expect(
            explicitlyOn.toModel(holderRowReconcileDefault: true)
                .holderRowReconcileEnabled == true)
    }

    /// Isolates the RESOLUTION guard (`toModel()`'s `?? holderRowReconcileDefault`)
    /// from the STORAGE guard (the migration's missing SQL default) by
    /// constructing a `ConfigRecord` directly — no database, no migration.
    @Test func toModelResolvesNullThroughTheInjectedDefault() {
        let record = ConfigRecord(id: "unstored", holder_row_reconcile_enabled: nil)
        #expect(record.toModel(holderRowReconcileDefault: false).holderRowReconcileEnabled == false)
        #expect(
            record.toModel(holderRowReconcileDefault: true).holderRowReconcileEnabled == true,
            "a NULL record must pick up whatever default is injected, not a hardcoded false")
    }

    // MARK: - The shipped default, and the wire

    /// The shipped default today: OFF. A background sweep that deletes database
    /// rows without a user gesture soaks behind its own switch, and it cannot
    /// borrow `ptyHolderEnabled` for that — that gate has to be ON for a holder
    /// row to exist at all.
    @Test func shippedDefaultIsOff() async throws {
        #expect(Config.holderRowReconcileEnabledDefault == false)
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().holderRowReconcileEnabled == false)
    }

    /// The arm is its own opt-in, not a rider on either sibling holder gate:
    /// enabling the file sweep or the process reaper must leave it off.
    @Test func theSiblingHolderGatesDoNotEnableIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCHolderRendezvousEnabled(true)
        try await db.config.setReapHolderChildrenEnabled(true)
        try await db.config.setGCRowlessHoldersEnabled(true)
        #expect(
            try await db.config.get().holderRowReconcileEnabled == false,
            "enabling a holder file sweep or process reaper must not enable the row sweep")
    }

    @Test func setterRoundtrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setHolderRowReconcileEnabled(true)
        #expect(try await db.config.get().holderRowReconcileEnabled == true)
        try await db.config.setHolderRowReconcileEnabled(false)
        #expect(try await db.config.get().holderRowReconcileEnabled == false)
    }

    /// JSON from a daemon that predates the flag still decodes, and the absent
    /// key means the sender knew nothing about it — the NULL column's situation,
    /// so it follows the shipped default rather than a hardcoded `false`.
    @Test func configJSONWithoutTheKeyFollowsTheShippedDefault() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.holderRowReconcileEnabled == Config.holderRowReconcileEnabledDefault)
    }

    /// An explicit `true` on the wire is carried, so the app and the CLI see the
    /// same state the daemon resolved rather than re-deriving it.
    @Test func configJSONRoundTripsAnExplicitChoice() throws {
        var config = Config()
        config.holderRowReconcileEnabled = true
        let decoded = try JSONDecoder().decode(
            Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.holderRowReconcileEnabled == true)
    }
}
