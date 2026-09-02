import Foundation
import GRDB
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// Schema and resolution guards for `config.reap_holder_children_enabled`, the
/// soak gate on the `AgentReaper` leg that kills the surviving job of a dead
/// pty holder.
///
/// The column is added by `20260901180118_config_reap_holder_children` with **no
/// SQL default**, so "never chose" (NULL) stays distinguishable from
/// "explicitly off" (0). If someone adds a `DEFAULT` clause to that migration,
/// `nullBeforeAnyGesture` and `rowWrittenBeforeTheMigrationStillReadsNull` go
/// red — that is their only job. The distinction earns its keep because this
/// leg kills processes: somebody who turned it off did so deliberately and must
/// stay opted out through graduation.
@Suite("ReapHolderChildrenFlag")
struct ReapHolderChildrenFlagTests {

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
            record.reap_holder_children_enabled == nil,
            """
            config.reap_holder_children_enabled must be NULL until the toggle is \
            touched — read back \
            \(String(describing: record.reap_holder_children_enabled)). A non-nil \
            value here means 20260901180118_config_reap_holder_children grew a \
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
            let raw: DatabaseValue = row["reap_holder_children_enabled"]
            #expect(
                raw.isNull,
                "a config row written before the migration must read NULL, not \(raw)")
            // The pre-existing write survived — the migration is purely additive.
            #expect(row["auto_create_notes_enabled"] == true)
        }
    }

    // MARK: - Resolution: the three states are distinguishable

    /// NULL follows `Config.reapHolderChildrenEnabledDefault` wherever it goes;
    /// an explicit `false` does not. That property is what makes graduation a
    /// one-line constant change with no forcing `UPDATE` migration. Exercised
    /// against BOTH possible default values, so it fails if the resolution is
    /// ever wired as `?? false`.
    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)

        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.reap_holder_children_enabled == nil)
        #expect(
            untouched.toModel(reapHolderChildrenDefault: false).reapHolderChildrenEnabled == false)
        #expect(
            untouched.toModel(reapHolderChildrenDefault: true).reapHolderChildrenEnabled == true,
            "a never-chosen row must pick up a changed shipped default")

        try await db.config.setReapHolderChildrenEnabled(false)
        let explicitlyOff = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOff.reap_holder_children_enabled == false)
        #expect(
            explicitlyOff.toModel(reapHolderChildrenDefault: false)
                .reapHolderChildrenEnabled == false)
        #expect(
            explicitlyOff.toModel(reapHolderChildrenDefault: true)
                .reapHolderChildrenEnabled == false,
            "an explicit opt-out must be honored forever, whatever the shipped default becomes")
    }

    /// Mirrored for an explicit `true`: an operator who opted into the soak
    /// stays opted in even if the shipped default never moves.
    @Test func explicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setReapHolderChildrenEnabled(true)
        let explicitlyOn = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOn.reap_holder_children_enabled == true)
        #expect(
            explicitlyOn.toModel(reapHolderChildrenDefault: false).reapHolderChildrenEnabled == true)
        #expect(
            explicitlyOn.toModel(reapHolderChildrenDefault: true).reapHolderChildrenEnabled == true)
    }

    /// Isolates the RESOLUTION guard (`toModel()`'s `?? reapHolderChildrenDefault`)
    /// from the STORAGE guard (the migration's missing SQL default) by
    /// constructing a `ConfigRecord` directly — no database, no migration.
    @Test func toModelResolvesNullThroughTheInjectedDefault() {
        let record = ConfigRecord(id: "unstored", reap_holder_children_enabled: nil)
        #expect(record.toModel(reapHolderChildrenDefault: false).reapHolderChildrenEnabled == false)
        #expect(
            record.toModel(reapHolderChildrenDefault: true).reapHolderChildrenEnabled == true,
            "a NULL record must pick up whatever default is injected, not a hardcoded false")
    }

    // MARK: - The shipped default, and the wire

    /// The shipped default today: OFF. A background sweep that kills processes
    /// without a user gesture soaks behind its own switch, and the transport it
    /// backstops is itself still behind `ptyHolderEnabled`. Graduation edits
    /// this constant and nothing else.
    @Test func shippedDefaultIsOff() async throws {
        #expect(Config.reapHolderChildrenEnabledDefault == false)
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().reapHolderChildrenEnabled == false)
    }

    @Test func setterRoundtrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setReapHolderChildrenEnabled(true)
        #expect(try await db.config.get().reapHolderChildrenEnabled == true)
        try await db.config.setReapHolderChildrenEnabled(false)
        #expect(try await db.config.get().reapHolderChildrenEnabled == false)
    }

    /// JSON from a daemon that predates the flag still decodes, and the absent
    /// key means the sender knew nothing about it — the NULL column's situation,
    /// so it follows the shipped default rather than a hardcoded `false`.
    @Test func configJSONWithoutTheKeyFollowsTheShippedDefault() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.reapHolderChildrenEnabled == Config.reapHolderChildrenEnabledDefault)
    }

    /// An explicit `true` on the wire is carried, so the app and the CLI see the
    /// same state the daemon resolved rather than re-deriving it.
    @Test func configJSONRoundTripsAnExplicitChoice() throws {
        var config = Config()
        config.reapHolderChildrenEnabled = true
        let decoded = try JSONDecoder().decode(
            Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.reapHolderChildrenEnabled == true)
    }
}
