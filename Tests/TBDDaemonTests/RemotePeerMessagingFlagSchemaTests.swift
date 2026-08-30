import Foundation
import GRDB
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// Schema guards for `config.remote_peer_messaging_enabled`
/// (`docs/specs/2026-08-29-remote-peer-messaging-design.md`, "Flag and
/// rollout").
///
/// The column is added by `20260830003851_config_remote_peer_messaging` with
/// **no SQL default**, so "never chose" (NULL) stays distinguishable from
/// "explicitly off" (0). If someone adds a `DEFAULT` clause to that migration,
/// `remotePeerMessagingIsNullBeforeAnyGesture` goes red — that is its only job.
/// The distinction earns its keep here: the bridge publishes records and
/// sockets into directories shared with every Claude Code session on the
/// machine, so somebody who turned it off did so deliberately and must stay
/// opted out through graduation.
@Suite("RemotePeerMessagingFlagSchema")
struct RemotePeerMessagingFlagSchemaTests {

    /// The last migration identifier that predates the flag's column. Migrating
    /// only this far reproduces the schema a real pre-flag daemon ran on.
    private static let lastIdentifierBeforeTheFlag = "20260824214437_auto_create_notes_setting"

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    // MARK: - Storage: the column is genuinely NULL until somebody chooses

    /// **The load-bearing test.** The `config` singleton row is inserted by v1,
    /// so every install — fresh or years old — has a row that predates this
    /// column. After the migration that row must read NULL, not `0`: a SQL
    /// default would backfill it and make "never chose" indistinguishable from
    /// a deliberate opt-out.
    @Test func remotePeerMessagingIsNullBeforeAnyGesture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(
            record.remote_peer_messaging_enabled == nil,
            """
            config.remote_peer_messaging_enabled must be NULL until the toggle \
            is touched — read back \
            \(String(describing: record.remote_peer_messaging_enabled)). A \
            non-nil value here means \
            20260830003851_config_remote_peer_messaging grew a DEFAULT clause; \
            remove it.
            """)
    }

    /// The same guard against a row written by a real pre-flag daemon: migrate
    /// only as far as the last identifier that predates the column, write to
    /// the config row, then finish migrating.
    @Test func rowWrittenBeforeTheMigrationStillReadsNull() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: Self.lastIdentifierBeforeTheFlag)

        // A pre-flag daemon touching config: the row exists and has been
        // written to, but knows nothing about the new column.
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
            let raw: DatabaseValue = row["remote_peer_messaging_enabled"]
            #expect(
                raw.isNull,
                "a config row written before the migration must read NULL, not \(raw)")
            // The pre-existing write survived — the migration is purely additive.
            #expect(row["auto_create_notes_enabled"] == true)
        }
    }

    // MARK: - Resolution: the three states are distinguishable

    /// NULL follows `Config.remotePeerMessagingDefault` wherever it goes; an
    /// explicit `false` does not. That property is what makes graduation a
    /// one-line constant change with no forcing `UPDATE` migration. Exercised
    /// against BOTH possible default values, so it fails if the resolution is
    /// ever wired as `?? false`.
    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)

        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.remote_peer_messaging_enabled == nil)
        #expect(
            untouched.toModel(remotePeerMessagingDefault: false)
                .remotePeerMessagingEnabled == false)
        #expect(
            untouched.toModel(remotePeerMessagingDefault: true)
                .remotePeerMessagingEnabled == true,
            "a never-chosen row must pick up a changed shipped default")

        try await db.config.setRemotePeerMessagingEnabled(false)
        let explicitlyOff = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOff.remote_peer_messaging_enabled == false)
        #expect(
            explicitlyOff.toModel(remotePeerMessagingDefault: false)
                .remotePeerMessagingEnabled == false)
        #expect(
            explicitlyOff.toModel(remotePeerMessagingDefault: true)
                .remotePeerMessagingEnabled == false,
            "an explicit opt-out must be honored forever, whatever the shipped default becomes")
    }

    /// Mirrored for an explicit `true`: an operator who opted into the soak
    /// stays opted in even if the shipped default never moves.
    @Test func explicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setRemotePeerMessagingEnabled(true)
        let explicitlyOn = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOn.remote_peer_messaging_enabled == true)
        #expect(
            explicitlyOn.toModel(remotePeerMessagingDefault: false)
                .remotePeerMessagingEnabled == true)
        #expect(
            explicitlyOn.toModel(remotePeerMessagingDefault: true)
                .remotePeerMessagingEnabled == true)
    }

    /// Isolates the RESOLUTION guard (`toModel()`'s
    /// `?? remotePeerMessagingDefault`) from the STORAGE guard (the migration's
    /// missing SQL default) by constructing a `ConfigRecord` directly — no
    /// database, no migration. It catches a hardening into `?? false` even if
    /// the migration guard were broken at the same time.
    @Test func toModelResolvesNullThroughTheInjectedDefault() {
        let record = ConfigRecord(id: "unstored", remote_peer_messaging_enabled: nil)
        #expect(
            record.toModel(remotePeerMessagingDefault: false)
                .remotePeerMessagingEnabled == false)
        #expect(
            record.toModel(remotePeerMessagingDefault: true)
                .remotePeerMessagingEnabled == true,
            "a NULL record must pick up whatever default is injected, not a hardcoded false")
    }

    // MARK: - The shipped default, and the wire

    /// The shipped default today: OFF. The bridge acts without a user gesture
    /// and writes into a shared directory, so it soaks behind its own switch.
    /// Graduation edits this constant and nothing else.
    @Test func shippedDefaultIsOff() async throws {
        #expect(Config.remotePeerMessagingDefault == false)
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().remotePeerMessagingEnabled == false)
    }

    @Test func setRemotePeerMessagingEnabledRoundtrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setRemotePeerMessagingEnabled(true)
        #expect(try await db.config.get().remotePeerMessagingEnabled == true)
        try await db.config.setRemotePeerMessagingEnabled(false)
        #expect(try await db.config.get().remotePeerMessagingEnabled == false)
    }

    /// JSON from a daemon that predates the flag still decodes, and the absent
    /// key means the sender knew nothing about it — the NULL column's
    /// situation, so it follows the shipped default rather than a hardcoded
    /// `false`.
    @Test func configJSONWithoutTheKeyFollowsTheShippedDefault() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.remotePeerMessagingEnabled == Config.remotePeerMessagingDefault)
    }

    /// An explicit `true` on the wire is carried, so the app and the CLI see the
    /// same state the daemon resolved rather than re-deriving it.
    @Test func configJSONRoundTripsAnExplicitChoice() throws {
        var config = Config()
        config.remotePeerMessagingEnabled = true
        let decoded = try JSONDecoder().decode(
            Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.remotePeerMessagingEnabled == true)
    }
}
