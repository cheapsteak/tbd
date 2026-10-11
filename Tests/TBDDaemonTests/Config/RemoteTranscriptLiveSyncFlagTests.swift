import Foundation
import GRDB
import Testing

@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// Schema and resolution guards for `config.remote_transcript_live_sync_enabled`,
/// the default-off soak gate for tail-first loading, earlier-history loading
/// and hint-driven background sync of remote transcripts. The column carries no
/// SQL default, so NULL ("never chose") stays distinct from 0 ("off").
@Suite("RemoteTranscriptLiveSyncFlag")
struct RemoteTranscriptLiveSyncFlagTests {

    /// The newest migration identifier before this flag's file.
    private static let lastIdentifierBeforeTheFlag = "20261002143454_config_pr_poll_schedule"

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    @Test func shippedDefaultIsOff() {
        #expect(Config.remoteTranscriptLiveSyncEnabledDefault == false)
        #expect(Config().remoteTranscriptLiveSyncEnabled == false)
    }

    @Test func nullBeforeAnyGesture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(record.remote_transcript_live_sync_enabled == nil,
                "remote_transcript_live_sync_enabled grew a DEFAULT clause; remove it.")
        #expect(try await db.config.get().remoteTranscriptLiveSyncEnabled == false)
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
            let raw: DatabaseValue = row["remote_transcript_live_sync_enabled"]
            #expect(raw.isNull)
            #expect(row["auto_create_notes_enabled"] == true)
        }
    }

    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.toModel(remoteTranscriptLiveSyncDefault: false)
            .remoteTranscriptLiveSyncEnabled == false)
        #expect(untouched.toModel(remoteTranscriptLiveSyncDefault: true)
            .remoteTranscriptLiveSyncEnabled == true)
        try await db.config.setRemoteTranscriptLiveSyncEnabled(false)
        let off = try #require(try await fetchConfigRecord(db))
        #expect(off.remote_transcript_live_sync_enabled == false)
        #expect(off.toModel(remoteTranscriptLiveSyncDefault: true)
            .remoteTranscriptLiveSyncEnabled == false)
    }

    @Test func explicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setRemoteTranscriptLiveSyncEnabled(true)
        let on = try #require(try await fetchConfigRecord(db))
        #expect(on.remote_transcript_live_sync_enabled == true)
        #expect(on.toModel(remoteTranscriptLiveSyncDefault: false)
            .remoteTranscriptLiveSyncEnabled == true)
        #expect(try await db.config.get().remoteTranscriptLiveSyncEnabled == true)
    }

    @Test func modelDecodesWithoutTheKey() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.remoteTranscriptLiveSyncEnabled == Config.remoteTranscriptLiveSyncEnabledDefault)
    }

    /// The resolved value survives the `config.get` wire round trip, so the
    /// app sees an explicit `true` rather than falling back to the default.
    @Test func modelRoundTripsAnExplicitTrue() throws {
        var config = Config()
        config.remoteTranscriptLiveSyncEnabled = true
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(Config.self, from: data).remoteTranscriptLiveSyncEnabled == true)
    }

    @Test func capabilitiesDecodeWithoutTheKeyFollowTheDefault() throws {
        let json = #"{"controlModeEnabled":false}"#
        let r = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: Data(json.utf8))
        #expect(r.remoteTranscriptLiveSyncEnabled == Config.remoteTranscriptLiveSyncEnabledDefault)
    }

    @Test("config.setRemoteTranscriptLiveSyncEnabled method name")
    func methodName() {
        #expect(RPCMethod.configSetRemoteTranscriptLiveSyncEnabled
            == "config.setRemoteTranscriptLiveSyncEnabled")
    }

    @Test(arguments: [true, false])
    func theSetterRPCWritesTheColumnAndCapabilitiesReportIt(_ enabled: Bool) async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog())

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.configSetRemoteTranscriptLiveSyncEnabled,
            params: ConfigSetRemoteLiveSyncEnabledParams(enabled: enabled)))
        #expect(response.success, "\(String(describing: response.error))")

        let record = try #require(try await fetchConfigRecord(db))
        #expect(record.remote_transcript_live_sync_enabled == enabled)
        #expect(try await db.config.get().remoteTranscriptLiveSyncEnabled == enabled)

        let capsResponse = await router.handle(try RPCRequest(method: RPCMethod.daemonCapabilities))
        let capabilities = try #require(capsResponse.result.flatMap {
            try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: Data($0.utf8))
        })
        #expect(capabilities.remoteTranscriptLiveSyncEnabled == enabled)
    }
}
