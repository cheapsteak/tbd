import Foundation
import GRDB
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// Schema and resolution guards for `config.pr_poll_schedule_enabled`, the
/// default-off soak gate for schedule-based PR polling. The column carries no
/// SQL default, so NULL ("never chose") stays distinct from 0 ("off").
@Suite("PRPollScheduleFlag")
struct PRPollScheduleFlagTests {

    /// The newest migration identifier before this flag's file.
    private static let lastIdentifierBeforeTheFlag = "20260924120000_config_remote_transcript_enabled"

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    @Test func shippedDefaultIsOff() {
        #expect(Config.prPollScheduleDefault == false)
        #expect(Config().prPollScheduleEnabled == false)
    }

    @Test func nullBeforeAnyGesture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(record.pr_poll_schedule_enabled == nil,
                "pr_poll_schedule_enabled grew a DEFAULT clause; remove it.")
        #expect(try await db.config.get().prPollScheduleEnabled == false)
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
            let raw: DatabaseValue = row["pr_poll_schedule_enabled"]
            #expect(raw.isNull)
            #expect(row["auto_create_notes_enabled"] == true)
        }
    }

    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.toModel(prPollScheduleDefault: false).prPollScheduleEnabled == false)
        #expect(untouched.toModel(prPollScheduleDefault: true).prPollScheduleEnabled == true)
        try await db.config.setPRPollScheduleEnabled(false)
        let off = try #require(try await fetchConfigRecord(db))
        #expect(off.pr_poll_schedule_enabled == false)
        #expect(off.toModel(prPollScheduleDefault: true).prPollScheduleEnabled == false)
    }

    @Test func explicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPRPollScheduleEnabled(true)
        let on = try #require(try await fetchConfigRecord(db))
        #expect(on.pr_poll_schedule_enabled == true)
        #expect(on.toModel(prPollScheduleDefault: false).prPollScheduleEnabled == true)
        #expect(try await db.config.get().prPollScheduleEnabled == true)
    }

    @Test func modelDecodesWithoutTheKey() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.prPollScheduleEnabled == Config.prPollScheduleDefault)
    }
}
