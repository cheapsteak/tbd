import Foundation
import GRDB
import Testing
import TestSupport

@testable import TBDDaemonLib
@testable import TBDShared

/// Schema and resolution guards for `config.start_admission_enabled` and
/// `config.agent_background_enabled`, the default-off gates for agent start
/// admission and background priority. Neither column carries a SQL default, so
/// NULL ("never chose") stays distinct from 0 ("off").
@Suite("StartAdmissionFlags")
struct StartAdmissionFlagTests {

    /// The newest migration identifier before these flags' files.
    private static let lastIdentifierBeforeTheFlags = "20261020170000_config_session_mod_usage"

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    private func makeRouter(_ db: TBDDatabase) -> RPCRouter {
        let tmux = TmuxManager(dryRun: true)
        return RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux, startTime: Date(), actuationLog: makeTestActuationLog())
    }

    @Test func shippedDefaultsAreOff() {
        #expect(Config.startAdmissionDefault == false)
        #expect(Config.agentBackgroundDefault == false)
        #expect(Config().startAdmissionEnabled == false)
        #expect(Config().agentBackgroundEnabled == false)
    }

    @Test func nullBeforeAnyGesture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(record.start_admission_enabled == nil,
                "start_admission_enabled grew a DEFAULT clause; remove it.")
        #expect(record.agent_background_enabled == nil,
                "agent_background_enabled grew a DEFAULT clause; remove it.")
        let config = try await db.config.get()
        #expect(config.startAdmissionEnabled == false)
        #expect(config.agentBackgroundEnabled == false)
    }

    @Test func rowWrittenBeforeTheMigrationsStillReadsNull() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: Self.lastIdentifierBeforeTheFlags)
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
            let admission: DatabaseValue = row["start_admission_enabled"]
            let background: DatabaseValue = row["agent_background_enabled"]
            #expect(admission.isNull)
            #expect(background.isNull)
            #expect(row["auto_create_notes_enabled"] == true)
        }
    }

    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.toModel(startAdmissionDefault: false).startAdmissionEnabled == false)
        #expect(untouched.toModel(startAdmissionDefault: true).startAdmissionEnabled == true)
        #expect(untouched.toModel(agentBackgroundDefault: false).agentBackgroundEnabled == false)
        #expect(untouched.toModel(agentBackgroundDefault: true).agentBackgroundEnabled == true)

        try await db.config.setStartAdmissionEnabled(false)
        try await db.config.setAgentBackgroundEnabled(false)
        let off = try #require(try await fetchConfigRecord(db))
        #expect(off.start_admission_enabled == false)
        #expect(off.agent_background_enabled == false)
        #expect(off.toModel(startAdmissionDefault: true).startAdmissionEnabled == false)
        #expect(off.toModel(agentBackgroundDefault: true).agentBackgroundEnabled == false)
    }

    @Test func explicitTrueSticksAndTheFlagsAreIndependent() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setStartAdmissionEnabled(true)
        var config = try await db.config.get()
        #expect(config.startAdmissionEnabled == true)
        #expect(config.agentBackgroundEnabled == false)

        try await db.config.setAgentBackgroundEnabled(true)
        config = try await db.config.get()
        #expect(config.startAdmissionEnabled == true)
        #expect(config.agentBackgroundEnabled == true)
    }

    @Test func modelDecodesWithoutTheKeys() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.startAdmissionEnabled == Config.startAdmissionDefault)
        #expect(config.agentBackgroundEnabled == Config.agentBackgroundDefault)
    }

    @Test func capabilitiesDecodeWithoutTheKeys() throws {
        let json = #"{"controlModeEnabled":false,"controlModeSupported":false}"#
        let caps = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: Data(json.utf8))
        #expect(caps.startAdmissionEnabled == Config.startAdmissionDefault)
        #expect(caps.agentBackgroundEnabled == Config.agentBackgroundDefault)
    }

    @Test func modelRoundTripsTheValues() throws {
        var config = Config()
        config.startAdmissionEnabled = true
        config.agentBackgroundEnabled = true
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.startAdmissionEnabled == true)
        #expect(decoded.agentBackgroundEnabled == true)
    }

    @Test func methodNames() {
        #expect(RPCMethod.configSetStartAdmissionEnabled == "config.setStartAdmissionEnabled")
        #expect(RPCMethod.configSetAgentBackgroundEnabled == "config.setAgentBackgroundEnabled")
    }

    @Test func setterRPCsWriteTheColumnsAndCapabilitiesReportThem() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db)
        for value in [true, false] {
            let admission = await router.handle(try RPCRequest(
                method: RPCMethod.configSetStartAdmissionEnabled,
                params: ConfigSetStartAdmissionEnabledParams(enabled: value)))
            #expect(admission.success)
            let background = await router.handle(try RPCRequest(
                method: RPCMethod.configSetAgentBackgroundEnabled,
                params: ConfigSetAgentBackgroundEnabledParams(enabled: !value)))
            #expect(background.success)
            let capsResponse = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
            let caps = try capsResponse.decodeResult(DaemonCapabilitiesResult.self)
            #expect(caps.startAdmissionEnabled == value)
            #expect(caps.agentBackgroundEnabled == !value)
        }
    }
}
