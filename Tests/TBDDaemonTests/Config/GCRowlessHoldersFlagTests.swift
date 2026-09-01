import Foundation
import GRDB
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// Schema and resolution guards for `config.gc_rowless_holders_enabled`, the
/// soak gate on the sweep that kills a pty holder this installation owns which
/// no session row claims.
///
/// The column is added by `20260901161500_config_gc_rowless_holders` with **no
/// SQL default**, so "never chose" (NULL) stays distinguishable from
/// "explicitly off" (0). If someone adds a `DEFAULT` clause to that migration,
/// `nullBeforeAnyGesture` and `rowWrittenBeforeTheMigrationStillReadsNull` go
/// red — that is their only job. The distinction earns its keep because this
/// phase kills processes: somebody who turned it off did so deliberately and
/// must stay opted out through graduation.
///
/// It is a **different flag** from `gc_holder_rendezvous_enabled`, and
/// `theTwoHolderGCFlagsAreIndependent` is what holds that apart: one unlinks
/// files, the other signals processes, and enabling the first must never enable
/// the second.
@Suite("GCRowlessHoldersFlag")
struct GCRowlessHoldersFlagTests {

    /// The last migration identifier that predates the flag's column. Migrating
    /// only this far reproduces the schema a real pre-flag daemon ran on.
    private static let lastIdentifierBeforeTheFlag = "20260901135111_config_gc_holder_rendezvous"

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
            record.gc_rowless_holders_enabled == nil,
            """
            config.gc_rowless_holders_enabled must be NULL until the toggle is \
            touched — read back \
            \(String(describing: record.gc_rowless_holders_enabled)). A non-nil \
            value here means 20260901161500_config_gc_rowless_holders grew a \
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
            let raw: DatabaseValue = row["gc_rowless_holders_enabled"]
            #expect(
                raw.isNull,
                "a config row written before the migration must read NULL, not \(raw)")
            // The pre-existing write survived — the migration is purely additive.
            #expect(row["auto_create_notes_enabled"] == true)
        }
    }

    // MARK: - Resolution: the three states are distinguishable

    /// NULL follows `Config.gcRowlessHoldersEnabledDefault` wherever it goes; an
    /// explicit `false` does not. That property is what makes graduation a
    /// one-line constant change with no forcing `UPDATE` migration. Exercised
    /// against BOTH possible default values, so it fails if the resolution is
    /// ever wired as `?? false`.
    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)

        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.gc_rowless_holders_enabled == nil)
        #expect(
            untouched.toModel(gcRowlessHoldersDefault: false).gcRowlessHoldersEnabled == false)
        #expect(
            untouched.toModel(gcRowlessHoldersDefault: true).gcRowlessHoldersEnabled == true,
            "a never-chosen row must pick up a changed shipped default")

        try await db.config.setGCRowlessHoldersEnabled(false)
        let explicitlyOff = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOff.gc_rowless_holders_enabled == false)
        #expect(
            explicitlyOff.toModel(gcRowlessHoldersDefault: false)
                .gcRowlessHoldersEnabled == false)
        #expect(
            explicitlyOff.toModel(gcRowlessHoldersDefault: true)
                .gcRowlessHoldersEnabled == false,
            "an explicit opt-out must be honored forever, whatever the shipped default becomes")
    }

    /// Mirrored for an explicit `true`: an operator who opted into the soak
    /// stays opted in even if the shipped default never moves.
    @Test func explicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCRowlessHoldersEnabled(true)
        let explicitlyOn = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOn.gc_rowless_holders_enabled == true)
        #expect(
            explicitlyOn.toModel(gcRowlessHoldersDefault: false).gcRowlessHoldersEnabled == true)
        #expect(
            explicitlyOn.toModel(gcRowlessHoldersDefault: true).gcRowlessHoldersEnabled == true)
    }

    /// Isolates the RESOLUTION guard (`toModel()`'s `?? gcRowlessHoldersDefault`)
    /// from the STORAGE guard (the migration's missing SQL default) by
    /// constructing a `ConfigRecord` directly — no database, no migration.
    @Test func toModelResolvesNullThroughTheInjectedDefault() {
        let record = ConfigRecord(id: "unstored", gc_rowless_holders_enabled: nil)
        #expect(record.toModel(gcRowlessHoldersDefault: false).gcRowlessHoldersEnabled == false)
        #expect(
            record.toModel(gcRowlessHoldersDefault: true).gcRowlessHoldersEnabled == true,
            "a NULL record must pick up whatever default is injected, not a hardcoded false")
    }

    // MARK: - Independence from the file-unlinking sibling

    /// **Enabling file cleanup must not enable a process killer**, and the
    /// reverse. Two columns, two setters, and neither moves the other — the
    /// whole reason this is not the rendezvous flag.
    @Test func theTwoHolderGCFlagsAreIndependent() async throws {
        let db = try TBDDatabase(inMemory: true)

        try await db.config.setGCHolderRendezvousEnabled(true)
        var config = try await db.config.get()
        #expect(config.gcHolderRendezvousEnabled == true)
        #expect(
            config.gcRowlessHoldersEnabled == false,
            "turning the rendezvous file sweep on must not turn the process killer on")

        try await db.config.setGCRowlessHoldersEnabled(true)
        try await db.config.setGCHolderRendezvousEnabled(false)
        config = try await db.config.get()
        #expect(config.gcHolderRendezvousEnabled == false)
        #expect(
            config.gcRowlessHoldersEnabled == true,
            "turning the file sweep off must not turn the process killer off")
    }

    // MARK: - The shipped default, and the wire

    /// The shipped default today: OFF. A background sweep that kills processes
    /// soaks behind its own switch, and the transport whose orphans it reclaims
    /// is itself still behind `ptyHolderEnabled`. Graduation edits this constant
    /// and nothing else.
    @Test func shippedDefaultIsOff() async throws {
        #expect(Config.gcRowlessHoldersEnabledDefault == false)
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().gcRowlessHoldersEnabled == false)
    }

    @Test func setterRoundtrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCRowlessHoldersEnabled(true)
        #expect(try await db.config.get().gcRowlessHoldersEnabled == true)
        try await db.config.setGCRowlessHoldersEnabled(false)
        #expect(try await db.config.get().gcRowlessHoldersEnabled == false)
    }

    /// JSON from a daemon that predates the flag still decodes, and the absent
    /// key means the sender knew nothing about it — the NULL column's situation,
    /// so it follows the shipped default rather than a hardcoded `false`.
    @Test func configJSONWithoutTheKeyFollowsTheShippedDefault() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.gcRowlessHoldersEnabled == Config.gcRowlessHoldersEnabledDefault)
    }

    /// An explicit `true` on the wire is carried, so the app and the CLI see the
    /// same state the daemon resolved rather than re-deriving it.
    @Test func configJSONRoundTripsAnExplicitChoice() throws {
        var config = Config()
        config.gcRowlessHoldersEnabled = true
        let decoded = try JSONDecoder().decode(
            Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.gcRowlessHoldersEnabled == true)
    }
}
