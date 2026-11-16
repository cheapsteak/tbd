import Foundation
import GRDB
import Testing
import DaemonTestSupport
import TestSupport

@testable import TBDDaemonLib
@testable import TBDShared

/// Schema and resolution guards for `config.session_restore_enabled`, the
/// default-off gate for restarting the sessions a startup parked. The column
/// carries no SQL default, so NULL ("never chose") stays distinct from 0
/// ("off").
@Suite("SessionRestoreFlag")
struct SessionRestoreFlagTests {

    /// The newest migration identifier before this flag's file.
    private static let lastIdentifierBeforeTheFlag = "20261104175902_auto_close_setup_default_on"

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    private func makeRouter(_ db: TBDDatabase) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())
    }

    @Test func shippedDefaultIsOff() {
        #expect(Config.sessionRestoreDefault == false)
        #expect(Config().sessionRestoreEnabled == false)
    }

    @Test func nullBeforeAnyGesture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(record.session_restore_enabled == nil,
                "session_restore_enabled grew a DEFAULT clause; remove it.")
        #expect(try await db.config.get().sessionRestoreEnabled == Config.sessionRestoreDefault)
    }

    @Test func rowWrittenBeforeTheMigrationStillReadsNull() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: Self.lastIdentifierBeforeTheFlag)
        try queue.write { db in
            try db.execute(
                sql: "UPDATE config SET clone_checkout_enabled = 1 WHERE id = ?",
                arguments: [ConfigStore.singletonID])
        }
        try migrator.migrate(queue)
        try queue.read { db in
            let row = try #require(try Row.fetchOne(
                db, sql: "SELECT * FROM config WHERE id = ?",
                arguments: [ConfigStore.singletonID]))
            let raw: DatabaseValue = row["session_restore_enabled"]
            #expect(raw.isNull)
            #expect(row["clone_checkout_enabled"] == true)
        }
    }

    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.toModel(sessionRestoreDefault: false).sessionRestoreEnabled == false)
        #expect(untouched.toModel(sessionRestoreDefault: true).sessionRestoreEnabled == true)
        try await db.config.setSessionRestore(false)
        let off = try #require(try await fetchConfigRecord(db))
        #expect(off.session_restore_enabled == false)
        #expect(off.toModel(sessionRestoreDefault: true).sessionRestoreEnabled == false)
    }

    @Test func explicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setSessionRestore(true)
        let on = try #require(try await fetchConfigRecord(db))
        #expect(on.session_restore_enabled == true)
        #expect(on.toModel(sessionRestoreDefault: false).sessionRestoreEnabled == true)
        #expect(try await db.config.get().sessionRestoreEnabled == true)
    }

    @Test func modelDecodesWithoutTheKey() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.sessionRestoreEnabled == Config.sessionRestoreDefault)
    }

    @Test func capabilitiesDecodeWithoutTheKey() throws {
        let json = #"{"controlModeEnabled":false,"controlModeSupported":false}"#
        let caps = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: Data(json.utf8))
        #expect(caps.sessionRestoreEnabled == Config.sessionRestoreDefault)
    }

    @Test func modelRoundTripsTheValue() throws {
        var config = Config()
        config.sessionRestoreEnabled = true
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.sessionRestoreEnabled == true)
    }

    @Test func initializersCarryTheValue() {
        #expect(Config(sessionRestoreEnabled: true).sessionRestoreEnabled == true)
        #expect(DaemonCapabilitiesResult(sessionRestoreEnabled: true)
            .sessionRestoreEnabled == true)
    }

    @Test func methodName() {
        #expect(RPCMethod.configSetSessionRestore == "config.setSessionRestore")
    }

    @Test func setterRPCWritesTheColumnAndCapabilitiesReportIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db)
        for value in [true, false] {
            let setRequest = try RPCRequest(
                method: RPCMethod.configSetSessionRestore,
                params: ConfigSetSessionRestoreParams(enabled: value))
            let set = await router.handle(setRequest)
            #expect(set.success)
            let capsResponse = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
            let caps = try capsResponse.decodeResult(DaemonCapabilitiesResult.self)
            #expect(caps.sessionRestoreEnabled == value)
            #expect(try await db.config.get().sessionRestoreEnabled == value)
        }
    }
}
