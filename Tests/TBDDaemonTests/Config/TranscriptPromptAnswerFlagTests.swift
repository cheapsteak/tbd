import Foundation
import GRDB
import Testing
import TestSupport

@testable import TBDDaemonLib
@testable import TBDShared

/// Schema and resolution guards for `config.transcript_prompt_answer_enabled`, the
/// default-off soak gate for answering prompts from the transcript. The column carries no
/// SQL default, so NULL ("never chose") stays distinct from 0 ("off").
@Suite("TranscriptPromptAnswerFlag")
struct TranscriptPromptAnswerFlagTests {

    /// The newest migration identifier before this flag's file.
    private static let lastIdentifierBeforeTheFlag = "20261009072332_config_profile_balancing_thresholds"

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    @Test func shippedDefaultIsOff() {
        #expect(Config.transcriptPromptAnswerDefault == false)
        #expect(Config().transcriptPromptAnswerEnabled == false)
    }

    @Test func nullBeforeAnyGesture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(record.transcript_prompt_answer_enabled == nil,
                "transcript_prompt_answer_enabled grew a DEFAULT clause; remove it.")
        #expect(try await db.config.get().transcriptPromptAnswerEnabled == false)
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
            let raw: DatabaseValue = row["transcript_prompt_answer_enabled"]
            #expect(raw.isNull)
            #expect(row["auto_create_notes_enabled"] == true)
        }
    }

    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.toModel(transcriptPromptAnswerDefault: false).transcriptPromptAnswerEnabled == false)
        #expect(untouched.toModel(transcriptPromptAnswerDefault: true).transcriptPromptAnswerEnabled == true)
        try await db.config.setTranscriptPromptAnswerEnabled(false)
        let off = try #require(try await fetchConfigRecord(db))
        #expect(off.transcript_prompt_answer_enabled == false)
        #expect(off.toModel(transcriptPromptAnswerDefault: true).transcriptPromptAnswerEnabled == false)
    }

    @Test func explicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setTranscriptPromptAnswerEnabled(true)
        let on = try #require(try await fetchConfigRecord(db))
        #expect(on.transcript_prompt_answer_enabled == true)
        #expect(on.toModel(transcriptPromptAnswerDefault: false).transcriptPromptAnswerEnabled == true)
        #expect(try await db.config.get().transcriptPromptAnswerEnabled == true)
    }

    @Test func modelDecodesWithoutTheKey() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.transcriptPromptAnswerEnabled == Config.transcriptPromptAnswerDefault)
    }

    @Test func capabilitiesDecodeWithoutTheKey() throws {
        let json = #"{"controlModeEnabled":false,"controlModeSupported":false}"#
        let caps = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: Data(json.utf8))
        #expect(caps.transcriptPromptAnswerEnabled == Config.transcriptPromptAnswerDefault)
    }

    @Test func setterRPCWritesTheColumnAndCapabilitiesReportIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())
        for value in [true, false] {
            let setRequest = try RPCRequest(
                method: RPCMethod.configSetTranscriptPromptAnswerEnabled,
                params: ConfigSetTranscriptPromptAnswerEnabledParams(enabled: value))
            let set = await router.handle(setRequest)
            #expect(set.success)
            let capsResponse = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
            let caps = try capsResponse.decodeResult(DaemonCapabilitiesResult.self)
            #expect(caps.transcriptPromptAnswerEnabled == value)
        }
    }
}
