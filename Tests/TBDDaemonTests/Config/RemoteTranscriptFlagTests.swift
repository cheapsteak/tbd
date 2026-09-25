import Foundation
import GRDB
import Testing

@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// Schema and resolution guards for `config.remote_transcript_enabled`, the
/// gate on `remote.transcriptSync`, the remote transcript pane and the remote
/// composer.
///
/// The column is added by `20260924120000_config_remote_transcript_enabled`
/// with **no SQL default**, so "never chose" (NULL) stays distinguishable from
/// "explicitly off". If someone adds a `DEFAULT` clause to that migration,
/// `nullBeforeAnyGesture` and `rowWrittenBeforeTheMigrationStillReadsNull` go
/// red — that is their only job.
@Suite("RemoteTranscriptFlag")
struct RemoteTranscriptFlagTests {

    /// The last migration identifier that predates the column.
    private static let lastIdentifierBeforeTheFlag =
        "20260907215727_terminal_transcript_stream_path"

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    // MARK: - Storage: the column is genuinely NULL until somebody chooses

    @Test func nullBeforeAnyGesture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(
            record.remote_transcript_enabled == nil,
            """
            config.remote_transcript_enabled must be NULL until the toggle is \
            touched — read back \
            \(String(describing: record.remote_transcript_enabled)). A non-nil \
            value here means the migration grew a DEFAULT clause; remove it.
            """)
    }

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
            let raw: DatabaseValue = row["remote_transcript_enabled"]
            #expect(
                raw.isNull,
                "a config row written before the migration must read NULL, not \(raw)")
            #expect(row["auto_create_notes_enabled"] == true)
        }
    }

    // MARK: - Resolution: the three states are distinguishable

    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)

        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.remote_transcript_enabled == nil)
        #expect(untouched.toModel(remoteTranscriptDefault: false)
            .remoteTranscriptEnabled == false)
        #expect(
            untouched.toModel(remoteTranscriptDefault: true).remoteTranscriptEnabled,
            "a never-chosen row must pick up a changed shipped default")

        try await db.config.setRemoteTranscriptEnabled(false)
        let explicitlyOff = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOff.remote_transcript_enabled == false)
        #expect(
            explicitlyOff.toModel(remoteTranscriptDefault: true)
                .remoteTranscriptEnabled == false,
            "an explicit opt-out must be honored forever, whatever the default becomes")
    }

    @Test func explicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setRemoteTranscriptEnabled(true)
        let explicit = try #require(try await fetchConfigRecord(db))
        #expect(explicit.remote_transcript_enabled == true)
        #expect(explicit.toModel(remoteTranscriptDefault: false).remoteTranscriptEnabled)
        #expect(explicit.toModel(remoteTranscriptDefault: true).remoteTranscriptEnabled)
    }

    @Test func toModelResolvesNullThroughTheInjectedDefault() {
        let record = ConfigRecord(id: "unstored", remote_transcript_enabled: nil)
        #expect(record.toModel(remoteTranscriptDefault: false)
            .remoteTranscriptEnabled == false)
        #expect(
            record.toModel(remoteTranscriptDefault: true).remoteTranscriptEnabled,
            "a NULL record must pick up whatever default is injected, not a hardcoded false")
    }

    // MARK: - The shipped default, and the wire

    @Test func shippedDefaultIsOff() async throws {
        #expect(Config.remoteTranscriptEnabledDefault == false)
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().remoteTranscriptEnabled == false)
    }

    @Test func setterRoundtrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setRemoteTranscriptEnabled(true)
        #expect(try await db.config.get().remoteTranscriptEnabled)
        try await db.config.setRemoteTranscriptEnabled(false)
        #expect(try await db.config.get().remoteTranscriptEnabled == false)
    }

    /// The flag is its own. In particular it does not switch the composer on:
    /// the remote composer needs both, so the two are chosen separately.
    @Test func theFlagIsIndependentOfTheOthers() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setRemoteTranscriptEnabled(true)
        let config = try await db.config.get()
        #expect(config.remoteTranscriptEnabled)
        #expect(config.transcriptComposerEnabled == Config.transcriptComposerEnabledDefault)
        #expect(config.remoteBackendsEnabled == false)
    }

    @Test func configJSONWithoutTheKeyFollowsTheShippedDefault() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.remoteTranscriptEnabled == Config.remoteTranscriptEnabledDefault)
    }

    @Test func configJSONRoundTripsAnExplicitChoice() throws {
        var config = Config()
        config.remoteTranscriptEnabled = true
        let decoded = try JSONDecoder().decode(
            Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.remoteTranscriptEnabled)
    }
}

/// The flag reaches the daemon through `config.setRemoteTranscriptEnabled` and
/// comes back to the app through `daemon.capabilities`.
@Suite("RemoteTranscriptFlag RPCs")
struct RemoteTranscriptFlagRPCTests {
    let db: TBDDatabase
    let router: RPCRouter

    init() throws {
        let db = try TBDDatabase(inMemory: true)
        self.db = db
        let tmux = TmuxManager(dryRun: true)
        self.router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            startTime: Date(),
            actuationLog: makeTestActuationLog(tag: "remote-transcript-flag-rpc"))
    }

    private func capabilities() async throws -> DaemonCapabilitiesResult {
        let response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        #expect(response.success)
        return try response.decodeResult(DaemonCapabilitiesResult.self)
    }

    private func set(_ enabled: Bool) async throws -> RPCResponse {
        await router.handle(try RPCRequest(
            method: RPCMethod.configSetRemoteTranscriptEnabled,
            params: ConfigSetRemoteTranscriptEnabledParams(enabled: enabled)))
    }

    @Test func settingOnPersistsIt() async throws {
        let response = try await set(true)
        #expect(response.success)
        #expect(try await db.config.get().remoteTranscriptEnabled)
    }

    @Test func settingOffPersistsAnExplicitFalse() async throws {
        _ = try await set(true)
        let response = try await set(false)
        #expect(response.success)
        #expect(try await db.config.get().remoteTranscriptEnabled == false)
        let raw = try await db.writerForTests.read { conn in
            try Bool.fetchOne(
                conn, sql: "SELECT remote_transcript_enabled FROM config WHERE id = ?",
                arguments: [ConfigStore.singletonID])
        }
        #expect(raw == false, "an explicit off must be stored as 0, not left NULL")
    }

    @Test func capabilitiesStartAtTheShippedDefault() async throws {
        #expect(try await capabilities().remoteTranscriptEnabled
            == Config.remoteTranscriptEnabledDefault)
    }

    @Test func capabilitiesReflectTheToggleBothWays() async throws {
        _ = try await set(true)
        #expect(try await capabilities().remoteTranscriptEnabled)
        _ = try await set(false)
        #expect(try await capabilities().remoteTranscriptEnabled == false)
    }

    /// An older daemon sends no such key. It has no `remote.transcriptSync`
    /// either, so the app must fall through to the shipped default.
    @Test func anOlderDaemonsPayloadFollowsTheShippedDefault() throws {
        let legacy = #"{"controlModeEnabled":false}"#
        let decoded = try JSONDecoder().decode(
            DaemonCapabilitiesResult.self, from: Data(legacy.utf8))
        #expect(decoded.remoteTranscriptEnabled == Config.remoteTranscriptEnabledDefault)
    }

    @Test func anExplicitValueOnTheWireIsHonored() throws {
        let json = #"{"controlModeEnabled":false,"remoteTranscriptEnabled":true}"#
        let decoded = try JSONDecoder().decode(
            DaemonCapabilitiesResult.self, from: Data(json.utf8))
        #expect(decoded.remoteTranscriptEnabled)
    }
}
