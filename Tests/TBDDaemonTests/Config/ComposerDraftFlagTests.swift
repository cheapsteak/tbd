import Foundation
import GRDB
import Testing
import DaemonTestSupport
import TestSupport

@testable import TBDDaemonLib
@testable import TBDShared

/// Records each feature list the router hands `sessionModPluginSync`.
private final class SessionModPluginSyncRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[SessionModFeature]] = []

    func append(_ features: [SessionModFeature]) {
        lock.withLock { calls.append(features) }
    }

    func snapshot() -> [[SessionModFeature]] {
        lock.withLock { calls }
    }
}

/// Schema and resolution guards for `config.composer_draft_enabled`, the
/// default-off soak gate for saving and restoring composer drafts. The column carries no
/// SQL default, so NULL ("never chose") stays distinct from 0 ("off").
@Suite("ComposerDraftFlag")
struct ComposerDraftFlagTests {

    /// The newest migration identifier before this flag's file.
    private static let lastIdentifierBeforeTheFlag = "20261011235918_dev_server_columns"

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    @Test func shippedDefaultIsOff() {
        #expect(Config.composerDraftDefault == false)
        #expect(Config().composerDraftEnabled == false)
    }

    @Test func nullBeforeAnyGesture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(record.composer_draft_enabled == nil,
                "composer_draft_enabled grew a DEFAULT clause; remove it.")
        #expect(try await db.config.get().composerDraftEnabled == false)
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
            let raw: DatabaseValue = row["composer_draft_enabled"]
            #expect(raw.isNull)
            #expect(row["auto_create_notes_enabled"] == true)
        }
    }

    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.toModel(composerDraftDefault: false).composerDraftEnabled == false)
        #expect(untouched.toModel(composerDraftDefault: true).composerDraftEnabled == true)
        try await db.config.setComposerDraftEnabled(false)
        let off = try #require(try await fetchConfigRecord(db))
        #expect(off.composer_draft_enabled == false)
        #expect(off.toModel(composerDraftDefault: true).composerDraftEnabled == false)
    }

    @Test func explicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setComposerDraftEnabled(true)
        let on = try #require(try await fetchConfigRecord(db))
        #expect(on.composer_draft_enabled == true)
        #expect(on.toModel(composerDraftDefault: false).composerDraftEnabled == true)
        #expect(try await db.config.get().composerDraftEnabled == true)
    }

    @Test func modelDecodesWithoutTheKey() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.composerDraftEnabled == Config.composerDraftDefault)
    }

    @Test func capabilitiesDecodeWithoutTheKey() throws {
        let json = #"{"controlModeEnabled":false,"controlModeSupported":false}"#
        let caps = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: Data(json.utf8))
        #expect(caps.composerDraftEnabled == Config.composerDraftDefault)
    }

    @Test func modelRoundTripsTheValue() throws {
        var config = Config()
        config.composerDraftEnabled = true
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.composerDraftEnabled == true)
    }

    @Test func methodName() {
        #expect(RPCMethod.configSetComposerDraftEnabled == "config.setComposerDraftEnabled")
    }

    @Test func setterRPCWritesTheColumnAndCapabilitiesReportIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())
        for value in [true, false] {
            let setRequest = try RPCRequest(
                method: RPCMethod.configSetComposerDraftEnabled,
                params: ConfigSetComposerDraftEnabledParams(enabled: value))
            let set = await router.handle(setRequest)
            #expect(set.success)
            let capsResponse = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
            let caps = try capsResponse.decodeResult(DaemonCapabilitiesResult.self)
            #expect(caps.composerDraftEnabled == value)
        }
    }

    /// The setter re-syncs the plugin with the features the fresh config turns
    /// on. The router in `setterRPCWritesTheColumnAndCapabilitiesReportIt`
    /// leaves the hook unset, which covers the other branch.
    @Test func setterRPCSyncsThePluginWithTheFreshFeatures() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())
        let recorder = SessionModPluginSyncRecorder()
        router.sessionModPluginSync = { recorder.append($0) }

        for value in [true, false] {
            let request = try RPCRequest(
                method: RPCMethod.configSetComposerDraftEnabled,
                params: ConfigSetComposerDraftEnabledParams(enabled: value))
            let response = await router.handle(request)
            #expect(response.success)
        }

        #expect(recorder.snapshot() == [[.composerDraft], []])
    }
}
