import Foundation
import GRDB
import Testing

@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// Schema and resolution guards for `config.program_status_enabled`, the
/// default-off soak gate for the Program Status Protocol (OSC 7501). The
/// column carries no SQL default, so NULL ("never chose") stays distinct from
/// 0 ("off").
@Suite("ProgramStatusFlag")
struct ProgramStatusFlagTests {

    /// The newest migration identifier before this flag's file.
    private static let lastIdentifierBeforeTheFlag = "20261002143454_config_pr_poll_schedule"

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    @Test func shippedDefaultIsOff() {
        #expect(Config.programStatusEnabledDefault == false)
        #expect(Config().programStatusEnabled == false)
    }

    @Test func nullBeforeAnyGesture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(record.program_status_enabled == nil,
                "program_status_enabled grew a DEFAULT clause; remove it.")
        #expect(try await db.config.get().programStatusEnabled == false)
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
            let raw: DatabaseValue = row["program_status_enabled"]
            #expect(raw.isNull)
            #expect(row["auto_create_notes_enabled"] == true)
        }
    }

    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.toModel(programStatusDefault: false).programStatusEnabled == false)
        #expect(untouched.toModel(programStatusDefault: true).programStatusEnabled == true)
        try await db.config.setProgramStatusEnabled(false)
        let off = try #require(try await fetchConfigRecord(db))
        #expect(off.program_status_enabled == false)
        #expect(off.toModel(programStatusDefault: true).programStatusEnabled == false)
    }

    @Test func explicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setProgramStatusEnabled(true)
        let on = try #require(try await fetchConfigRecord(db))
        #expect(on.program_status_enabled == true)
        #expect(on.toModel(programStatusDefault: false).programStatusEnabled == true)
        #expect(try await db.config.get().programStatusEnabled == true)
    }

    @Test func modelDecodesWithoutTheKey() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.programStatusEnabled == Config.programStatusEnabledDefault)
    }
}

/// The user-facing switch for `program_status_enabled`: the RPC writes the
/// column both ways and `daemon.capabilities` reports it.
@Suite("ProgramStatusToggle")
struct ProgramStatusToggleTests {

    private static func makeRouterAndDB() throws -> (RPCRouter, TBDDatabase) {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog())
        return (router, db)
    }

    private static func setEnabled(_ router: RPCRouter, _ enabled: Bool) async throws {
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.configSetProgramStatusEnabled,
            params: ConfigSetProgramStatusEnabledParams(enabled: enabled)))
        #expect(response.success, "\(String(describing: response.error))")
    }

    @Test("config.setProgramStatusEnabled method name")
    func methodName() {
        #expect(RPCMethod.configSetProgramStatusEnabled == "config.setProgramStatusEnabled")
    }

    @Test func theHandlerWritesTheColumnBothWays() async throws {
        let (router, db) = try Self.makeRouterAndDB()
        try await Self.setEnabled(router, true)
        #expect(try await db.config.get().programStatusEnabled == true)
        try await Self.setEnabled(router, false)
        #expect(try await db.config.get().programStatusEnabled == false)
        let stored = try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)?.program_status_enabled
        }
        #expect(stored == false, "an explicit off must be stored as 0, not NULL")
    }

    @Test func capabilitiesCarryTheFlagInBothStates() async throws {
        let (router, _) = try Self.makeRouterAndDB()
        for enabled in [true, false] {
            try await Self.setEnabled(router, enabled)
            let response = await router.handle(try RPCRequest(method: RPCMethod.daemonCapabilities))
            let capabilities = try #require(response.result.flatMap {
                try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: Data($0.utf8))
            })
            #expect(capabilities.programStatusEnabled == enabled)
        }
    }

    @Test func capabilitiesBeforeAnyGestureReportTheShippedDefault() async throws {
        let (router, _) = try Self.makeRouterAndDB()
        let response = await router.handle(try RPCRequest(method: RPCMethod.daemonCapabilities))
        let capabilities = try #require(response.result.flatMap {
            try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: Data($0.utf8))
        })
        #expect(capabilities.programStatusEnabled == Config.programStatusEnabledDefault)
    }

    /// An older daemon sends no field; the app falls through to the shipped default.
    @Test func capabilitiesFromAnOlderDaemonDecodeToTheDefault() throws {
        let decoded = try JSONDecoder().decode(
            DaemonCapabilitiesResult.self, from: Data(#"{"controlModeEnabled":false}"#.utf8))
        #expect(decoded.programStatusEnabled == Config.programStatusEnabledDefault)
    }
}
