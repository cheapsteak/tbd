import Foundation
import GRDB
import Testing
import DaemonTestSupport
import TestSupport

@testable import TBDDaemonLib
@testable import TBDShared

/// Records each feature list the router hands `sessionModPluginSync`.
private final class UsagePluginSyncRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[SessionModFeature]] = []

    func append(_ features: [SessionModFeature]) {
        lock.withLock { calls.append(features) }
    }

    func snapshot() -> [[SessionModFeature]] {
        lock.withLock { calls }
    }
}

/// Schema and resolution guards for `config.session_mod_usage_enabled`, the
/// default-off soak gate for recording session usage through the session mod.
/// The column carries no SQL default, so NULL ("never chose") stays distinct
/// from 0 ("off").
@Suite("SessionModUsageFlag")
struct SessionModUsageFlagTests {

    /// The newest migration identifier before this flag's file.
    private static let lastIdentifierBeforeTheFlag = "20261019174758_config_composer_draft"

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
        #expect(Config.sessionModUsageDefault == false)
        #expect(Config().sessionModUsageEnabled == false)
    }

    @Test func nullBeforeAnyGesture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(record.session_mod_usage_enabled == nil,
                "session_mod_usage_enabled grew a DEFAULT clause; remove it.")
        #expect(try await db.config.get().sessionModUsageEnabled == Config.sessionModUsageDefault)
    }

    @Test func rowWrittenBeforeTheMigrationStillReadsNull() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: Self.lastIdentifierBeforeTheFlag)
        try queue.write { db in
            try db.execute(
                sql: "UPDATE config SET composer_draft_enabled = 1 WHERE id = ?",
                arguments: [ConfigStore.singletonID])
        }
        try migrator.migrate(queue)
        try queue.read { db in
            let row = try #require(try Row.fetchOne(
                db, sql: "SELECT * FROM config WHERE id = ?",
                arguments: [ConfigStore.singletonID]))
            let raw: DatabaseValue = row["session_mod_usage_enabled"]
            #expect(raw.isNull)
            #expect(row["composer_draft_enabled"] == true)
        }
    }

    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.toModel(sessionModUsageDefault: false).sessionModUsageEnabled == false)
        #expect(untouched.toModel(sessionModUsageDefault: true).sessionModUsageEnabled == true)
        try await db.config.setSessionModUsageEnabled(false)
        let off = try #require(try await fetchConfigRecord(db))
        #expect(off.session_mod_usage_enabled == false)
        #expect(off.toModel(sessionModUsageDefault: true).sessionModUsageEnabled == false)
    }

    @Test func explicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setSessionModUsageEnabled(true)
        let on = try #require(try await fetchConfigRecord(db))
        #expect(on.session_mod_usage_enabled == true)
        #expect(on.toModel(sessionModUsageDefault: false).sessionModUsageEnabled == true)
        #expect(try await db.config.get().sessionModUsageEnabled == true)
    }

    @Test func modelDecodesWithoutTheKey() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.sessionModUsageEnabled == Config.sessionModUsageDefault)
    }

    @Test func capabilitiesDecodeWithoutTheKey() throws {
        let json = #"{"controlModeEnabled":false,"controlModeSupported":false}"#
        let caps = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: Data(json.utf8))
        #expect(caps.sessionModUsageEnabled == Config.sessionModUsageDefault)
    }

    @Test func modelRoundTripsTheValue() throws {
        var config = Config()
        config.sessionModUsageEnabled = true
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.sessionModUsageEnabled == true)
    }

    @Test func methodName() {
        #expect(RPCMethod.configSetSessionModUsageEnabled == "config.setSessionModUsageEnabled")
    }

    @Test func setterRPCWritesTheColumnAndCapabilitiesReportIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db)
        for value in [true, false] {
            let setRequest = try RPCRequest(
                method: RPCMethod.configSetSessionModUsageEnabled,
                params: ConfigSetSessionModUsageEnabledParams(enabled: value))
            let set = await router.handle(setRequest)
            #expect(set.success)
            let capsResponse = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
            let caps = try capsResponse.decodeResult(DaemonCapabilitiesResult.self)
            #expect(caps.sessionModUsageEnabled == value)
            #expect(try await db.config.get().sessionModUsageEnabled == value)
        }
    }

    /// The setter re-syncs the plugin with the features the fresh config turns
    /// on, so composer-draft staying on keeps the mod while usage toggles.
    @Test func setterRPCSyncsThePluginWithTheFreshFeatures() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db)
        let recorder = UsagePluginSyncRecorder()
        router.sessionModPluginSync = { recorder.append($0) }

        for value in [true, false] {
            let request = try RPCRequest(
                method: RPCMethod.configSetSessionModUsageEnabled,
                params: ConfigSetSessionModUsageEnabledParams(enabled: value))
            #expect(await router.handle(request).success)
        }
        try await db.config.setComposerDraftEnabled(true)
        let again = try RPCRequest(
            method: RPCMethod.configSetSessionModUsageEnabled,
            params: ConfigSetSessionModUsageEnabledParams(enabled: true))
        #expect(await router.handle(again).success)

        #expect(recorder.snapshot() == [[.usage], [], [.composerDraft, .usage]])
    }

    // MARK: - SessionModFeature.enabled(in:)

    @Test func usageRawValue() {
        #expect(SessionModFeature.usage.rawValue == "usage")
        #expect(SessionModFeature.allCases == [.composerDraft, .transcriptStream, .usage, .promptAnswer])
    }

    @Test func enabledListsOnlyUsageWhenOnlyUsageIsOn() {
        var config = Config()
        config.sessionModUsageEnabled = true
        #expect(SessionModFeature.enabled(in: config) == [.usage])
    }

    @Test func enabledListsBothInAllCasesOrder() {
        var config = Config()
        config.composerDraftEnabled = true
        config.sessionModUsageEnabled = true
        #expect(SessionModFeature.enabled(in: config) == [.composerDraft, .usage])
    }

    @Test func enabledIsEmptyWhenBothAreOff() {
        let config = Config()
        #expect(SessionModFeature.enabled(in: config).isEmpty)
    }
}
