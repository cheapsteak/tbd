import Foundation
import GRDB
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// Schema and resolution guards for `config.update_mode`, the setting that says
/// whether the daemon watches for a newer `main` and whether it may install one
/// (`docs/specs/2026-09-04-automatic-version-updates-design.md` §6).
///
/// The column is added by `20260904172536_config_update_mode` with **no SQL
/// default**, so "never chose" (NULL) stays distinguishable from "explicitly
/// off". If someone adds a `DEFAULT` clause to that migration,
/// `nullBeforeAnyGesture` and `rowWrittenBeforeTheMigrationStillReadsNull` go
/// red — that is their only job.
///
/// This is the first of these settings that is not a Bool, which adds one
/// state its siblings do not have: a stored string no `UpdateMode` case
/// matches. That resolves like NULL rather than to a hardcoded `.off`, because
/// a mode this build cannot run is not a mode it should claim to be in.
@Suite("UpdateModeFlag")
struct UpdateModeFlagTests {

    /// The last migration identifier that predates the setting's column.
    /// Migrating only this far reproduces the schema a real pre-flag daemon ran
    /// on.
    private static let lastIdentifierBeforeTheFlag = "20260902140000_config_gc_retained_transcripts"

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    // MARK: - Storage: the column is genuinely NULL until somebody chooses

    /// **The load-bearing test.** The `config` singleton row is inserted by v1,
    /// so every install has a row that predates this column. After the
    /// migration that row must read NULL, not `'off'`.
    @Test func nullBeforeAnyGesture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(
            record.update_mode == nil,
            """
            config.update_mode must be NULL until the setting is touched — read \
            back \(String(describing: record.update_mode)). A non-nil value here \
            means 20260904172536_config_update_mode grew a DEFAULT clause; remove it.
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
            let raw: DatabaseValue = row["update_mode"]
            #expect(
                raw.isNull,
                "a config row written before the migration must read NULL, not \(raw)")
            // The pre-existing write survived — the migration is purely additive.
            #expect(row["auto_create_notes_enabled"] == true)
        }
    }

    // MARK: - Resolution: the states are distinguishable

    /// NULL follows `Config.updateModeDefault` wherever it goes; an explicit
    /// `off` does not. That property is what makes graduation a one-line
    /// constant change with no forcing `UPDATE` migration for the rows that
    /// chose. Exercised against BOTH candidate defaults, so it fails if the
    /// resolution is ever wired as `?? .off`.
    @Test func explicitOffSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)

        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.update_mode == nil)
        #expect(untouched.toModel(updateModeDefault: .off).updateMode == .off)
        #expect(
            untouched.toModel(updateModeDefault: .check).updateMode == .check,
            "a never-chosen row must pick up a changed shipped default")

        try await db.config.setUpdateMode(.off)
        let explicitlyOff = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOff.update_mode == "off")
        #expect(explicitlyOff.toModel(updateModeDefault: .off).updateMode == .off)
        #expect(
            explicitlyOff.toModel(updateModeDefault: .check).updateMode == .off,
            "an explicit opt-out must be honored forever, whatever the shipped default becomes")
    }

    /// Mirrored for an explicit non-default choice: an operator who opted into
    /// the soak stays opted in even if the shipped default never moves.
    @Test func explicitAutoSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setUpdateMode(.auto)
        let explicit = try #require(try await fetchConfigRecord(db))
        #expect(explicit.update_mode == "auto")
        #expect(explicit.toModel(updateModeDefault: .off).updateMode == .auto)
        #expect(explicit.toModel(updateModeDefault: .check).updateMode == .auto)
    }

    /// Isolates the RESOLUTION guard (`toModel()`'s `?? updateModeDefault`)
    /// from the STORAGE guard (the migration's missing SQL default) by
    /// constructing a `ConfigRecord` directly — no database, no migration.
    @Test func toModelResolvesNullThroughTheInjectedDefault() {
        let record = ConfigRecord(id: "unstored", update_mode: nil)
        #expect(record.toModel(updateModeDefault: .off).updateMode == .off)
        #expect(
            record.toModel(updateModeDefault: .auto).updateMode == .auto,
            "a NULL record must pick up whatever default is injected, not a hardcoded .off")
    }

    /// The state this setting has and its Bool siblings do not: a stored name
    /// no case matches — an older build reading a column a newer one wrote, or
    /// a hand-edited database. It resolves like NULL, so the daemon never
    /// claims to be in a mode it cannot run.
    @Test func anUnrecognisedNameResolvesThroughTheDefaultToo() {
        let record = ConfigRecord(id: "unstored", update_mode: "aggressive")
        #expect(record.toModel(updateModeDefault: .off).updateMode == .off)
        #expect(record.toModel(updateModeDefault: .check).updateMode == .check)
    }

    // MARK: - The shipped default, and the wire

    /// The shipped default today: OFF. `check` makes a periodic network call
    /// and `auto` rebuilds and replaces the whole installation, so neither
    /// happens without a gesture. Graduation edits this constant.
    @Test func shippedDefaultIsOff() async throws {
        #expect(Config.updateModeDefault == .off)
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().updateMode == .off)
    }

    @Test func setterRoundtripsEveryMode() async throws {
        let db = try TBDDatabase(inMemory: true)
        for mode in UpdateMode.allCases {
            try await db.config.setUpdateMode(mode)
            #expect(try await db.config.get().updateMode == mode)
        }
    }

    /// The setting is its own. Choosing `auto` must not turn on anything else.
    @Test func theSettingIsIndependentOfTheOtherFlags() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setUpdateMode(.auto)
        let config = try await db.config.get()
        #expect(config.updateMode == .auto)
        #expect(config.remoteDeleteEnabled == Config.remoteDeleteEnabledDefault)
        #expect(config.gcEnabled == true)
    }

    /// JSON from a daemon that predates the setting still decodes, and the
    /// absent key means the sender knew nothing about it — the NULL column's
    /// situation, so it follows the shipped default.
    @Test func configJSONWithoutTheKeyFollowsTheShippedDefault() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.updateMode == Config.updateModeDefault)
    }

    /// A name a newer daemon invented must not fail the whole decode and lose
    /// every other setting on the wire with it.
    @Test func configJSONWithAnUnknownNameKeepsTheRestOfTheConfig() throws {
        let json = #"{"updateMode":"aggressive","gcEnabled":false}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.updateMode == Config.updateModeDefault)
        #expect(config.gcEnabled == false)
    }

    @Test func configJSONRoundTripsAnExplicitChoice() throws {
        var config = Config()
        config.updateMode = .check
        let decoded = try JSONDecoder().decode(
            Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.updateMode == .check)
    }

    /// The capabilities payload carries the same resolved value, so the app's
    /// picker and the daemon can never disagree about which of them last wrote
    /// the column.
    @Test func capabilitiesCarryTheModeAndDefaultWhenAbsent() throws {
        let encoded = try JSONEncoder().encode(
            DaemonCapabilitiesResult(controlModeEnabled: false, updateMode: .auto))
        #expect(try JSONDecoder().decode(
            DaemonCapabilitiesResult.self, from: encoded).updateMode == .auto)

        let legacy = #"{"controlModeEnabled":false}"#
        #expect(try JSONDecoder().decode(
            DaemonCapabilitiesResult.self, from: Data(legacy.utf8)).updateMode
            == Config.updateModeDefault)
    }
}
