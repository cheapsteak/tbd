import Foundation
import GRDB
import Testing
import DaemonTestSupport
import TestSupport

@testable import TBDDaemonLib
@testable import TBDShared

/// Schema and resolution guards for `config.ghostty_daemon_emulator_enabled`,
/// the default-off gate for the daemon's libghostty-vt emulator. The column
/// carries no SQL default, so NULL ("never chose") stays distinct from 0
/// ("off").
@Suite("GhosttyDaemonEmulatorFlag")
struct GhosttyDaemonEmulatorFlagTests {

    /// The newest migration identifier before this flag's file.
    private static let lastIdentifierBeforeTheFlag = "20261110021849_local_agent_sessions"

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
        #expect(Config.ghosttyDaemonEmulatorDefault == false)
        #expect(Config().ghosttyDaemonEmulatorEnabled == false)
    }

    @Test func nullBeforeAnyGesture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(record.ghostty_daemon_emulator_enabled == nil,
                "ghostty_daemon_emulator_enabled grew a DEFAULT clause; remove it.")
        #expect(try await db.config.get().ghosttyDaemonEmulatorEnabled == Config.ghosttyDaemonEmulatorDefault)
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
            let raw: DatabaseValue = row["ghostty_daemon_emulator_enabled"]
            #expect(raw.isNull)
            #expect(row["clone_checkout_enabled"] == true)
        }
    }

    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.toModel(ghosttyDaemonEmulatorDefault: false).ghosttyDaemonEmulatorEnabled == false)
        #expect(untouched.toModel(ghosttyDaemonEmulatorDefault: true).ghosttyDaemonEmulatorEnabled == true)
        try await db.config.setGhosttyDaemonEmulator(false)
        let off = try #require(try await fetchConfigRecord(db))
        #expect(off.ghostty_daemon_emulator_enabled == false)
        #expect(off.toModel(ghosttyDaemonEmulatorDefault: true).ghosttyDaemonEmulatorEnabled == false)
    }

    @Test func explicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGhosttyDaemonEmulator(true)
        let on = try #require(try await fetchConfigRecord(db))
        #expect(on.ghostty_daemon_emulator_enabled == true)
        #expect(on.toModel(ghosttyDaemonEmulatorDefault: false).ghosttyDaemonEmulatorEnabled == true)
        #expect(try await db.config.get().ghosttyDaemonEmulatorEnabled == true)
    }

    @Test func modelDecodesWithoutTheKey() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.ghosttyDaemonEmulatorEnabled == Config.ghosttyDaemonEmulatorDefault)
    }

    @Test func capabilitiesDecodeWithoutTheKey() throws {
        let json = #"{"controlModeEnabled":false,"controlModeSupported":false}"#
        let caps = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: Data(json.utf8))
        #expect(caps.ghosttyDaemonEmulatorEnabled == Config.ghosttyDaemonEmulatorDefault)
    }

    @Test func modelAndCapabilitiesRoundTripTheValue() throws {
        var config = Config()
        config.ghosttyDaemonEmulatorEnabled = true
        let decodedConfig = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(decodedConfig.ghosttyDaemonEmulatorEnabled == true)

        var caps = DaemonCapabilitiesResult(controlModeEnabled: false)
        caps.ghosttyDaemonEmulatorEnabled = true
        let decodedCaps = try JSONDecoder().decode(
            DaemonCapabilitiesResult.self, from: JSONEncoder().encode(caps))
        #expect(decodedCaps.ghosttyDaemonEmulatorEnabled == true)
    }

    @Test func methodName() {
        #expect(RPCMethod.configSetGhosttyDaemonEmulator == "config.setGhosttyDaemonEmulator")
    }

    @Test func setterRPCWritesTheColumnAndCapabilitiesReportIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db)
        for value in [true, false] {
            let setRequest = try RPCRequest(
                method: RPCMethod.configSetGhosttyDaemonEmulator,
                params: ConfigSetGhosttyDaemonEmulatorParams(enabled: value))
            let set = await router.handle(setRequest)
            #expect(set.success)
            let capsResponse = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
            let caps = try capsResponse.decodeResult(DaemonCapabilitiesResult.self)
            #expect(caps.ghosttyDaemonEmulatorEnabled == value)
            #expect(try await db.config.get().ghosttyDaemonEmulatorEnabled == value)
        }
    }
}
