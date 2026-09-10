import Foundation
import GRDB
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// Schema and resolution guards for `config.limit_rotation_enabled`,
/// the soak gate for automatically resuming sessions on another account
/// when hitting a hard limit (design 2026-09-05 §7).
///
/// The column is added by `20260905080316_config_limit_rotation` with
/// **no SQL default**, so "never chose" (NULL) stays distinguishable from
/// "explicitly off" (0). If someone adds a `DEFAULT` clause to that migration,
/// `nullBeforeAnyGesture` and `rowWrittenBeforeTheMigrationStillReadsNull` go
/// red — that is their only job. The distinction earns its keep because an
/// explicit opt-out must be honored through graduation.
@Suite("LimitRotationFlag")
struct LimitRotationFlagTests {

    /// The last migration identifier that predates the flag's column. Migrating
    /// only this far reproduces the schema a real pre-flag daemon ran on.
    private static let lastIdentifierBeforeTheFlag = "20260905080315_config_profile_balancing"

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
            record.limit_rotation_enabled == nil,
            """
            config.limit_rotation_enabled must be NULL until the toggle \
            is touched — read back \
            \(String(describing: record.limit_rotation_enabled)). A non-nil \
            value here means 20260905080316_config_limit_rotation grew a \
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
            let raw: DatabaseValue = row["limit_rotation_enabled"]
            #expect(
                raw.isNull,
                "a config row written before the migration must read NULL, not \(raw)")
            // The pre-existing write survived — the migration is purely additive.
            #expect(row["auto_create_notes_enabled"] == true)
        }
    }

    // MARK: - Resolution: the three states are distinguishable

    /// NULL follows `Config.limitRotationEnabledDefault` wherever it
    /// goes; an explicit `false` does not. That property is what makes
    /// graduation a one-line constant change with no forcing `UPDATE`
    /// migration. Exercised against BOTH possible default values, so it fails
    /// if the resolution is ever wired as `?? false`.
    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)

        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.limit_rotation_enabled == nil)
        #expect(
            untouched.toModel(limitRotationDefault: false)
                .limitRotationEnabled == false)
        #expect(
            untouched.toModel(limitRotationDefault: true)
                .limitRotationEnabled == true,
            "a never-chosen row must pick up a changed shipped default")

        try await db.config.setLimitRotationEnabled(false)
        let explicitlyOff = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOff.limit_rotation_enabled == false)
        #expect(
            explicitlyOff.toModel(limitRotationDefault: false)
                .limitRotationEnabled == false)
        #expect(
            explicitlyOff.toModel(limitRotationDefault: true)
                .limitRotationEnabled == false,
            "an explicit opt-out must be honored forever, whatever the shipped default becomes")
    }

    /// Mirrored for an explicit `true`: an operator who opted into rotation
    /// stays opted in even if the shipped default never moves.
    @Test func explicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setLimitRotationEnabled(true)
        let explicitlyOn = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOn.limit_rotation_enabled == true)
        #expect(
            explicitlyOn.toModel(limitRotationDefault: false)
                .limitRotationEnabled == true)
        #expect(
            explicitlyOn.toModel(limitRotationDefault: true)
                .limitRotationEnabled == true)
    }

    /// Isolates the RESOLUTION guard (`toModel()`'s
    /// `?? limitRotationDefault`) from the STORAGE guard (the
    /// migration's missing SQL default) by constructing a `ConfigRecord`
    /// directly — no database, no migration.
    @Test func toModelResolvesNullThroughTheInjectedDefault() {
        let record = ConfigRecord(id: "unstored", limit_rotation_enabled: nil)
        #expect(
            record.toModel(limitRotationDefault: false)
                .limitRotationEnabled == false)
        #expect(
            record.toModel(limitRotationDefault: true)
                .limitRotationEnabled == true,
            "a NULL record must pick up whatever default is injected, not a hardcoded false")
    }

    // MARK: - The shipped default, and the wire

    /// The shipped default today: OFF. Automatic rotation soaks behind its own switch.
    /// Graduation edits this constant and nothing else.
    @Test func shippedDefaultIsOff() async throws {
        #expect(Config.limitRotationEnabledDefault == false)
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().limitRotationEnabled == false)
    }

    @Test func setterRoundtrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setLimitRotationEnabled(true)
        #expect(try await db.config.get().limitRotationEnabled == true)
        try await db.config.setLimitRotationEnabled(false)
        #expect(try await db.config.get().limitRotationEnabled == false)
    }

    /// The gate is its own opt-in: turning on the balancing flag
    /// must not enable rotation, and vice versa.
    @Test func theBalancingFlagDoesNotEnableThisLeg() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setProfileBalancingEnabled(true)
        let config = try await db.config.get()
        #expect(config.profileBalancingEnabled == true)
        #expect(config.limitRotationEnabled == false)
    }

    /// JSON from a daemon that predates the flag still decodes, and the absent
    /// key means the sender knew nothing about it — the NULL column's situation,
    /// so it follows the shipped default rather than a hardcoded `false`.
    @Test func configJSONWithoutTheKeyFollowsTheShippedDefault() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(
            config.limitRotationEnabled == Config.limitRotationEnabledDefault)
    }

    /// An explicit `true` on the wire is carried, so the app and the CLI see the
    /// same state the daemon resolved rather than re-deriving it.
    @Test func configJSONRoundTripsAnExplicitChoice() throws {
        var config = Config()
        config.limitRotationEnabled = true
        let decoded = try JSONDecoder().decode(
            Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.limitRotationEnabled == true)
    }
}
