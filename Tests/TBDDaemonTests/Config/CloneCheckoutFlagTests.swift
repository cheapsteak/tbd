import Foundation
import GRDB
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// Schema and resolution guards for `config.clone_checkout_enabled`, the
/// default-off soak gate for clone-backed worktree checkout. The column
/// carries no SQL default, so NULL ("never chose") stays distinct from 0
/// ("off").
@Suite("CloneCheckoutFlag")
struct CloneCheckoutFlagTests {

    /// The newest migration identifier before this flag's file.
    private static let lastIdentifierBeforeTheFlag = "20261009072332_config_profile_balancing_thresholds"

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    @Test func shippedDefaultIsOff() {
        #expect(Config.cloneCheckoutDefault == false)
        #expect(Config().cloneCheckoutEnabled == false)
    }

    @Test func nullBeforeAnyGesture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(record.clone_checkout_enabled == nil,
                "clone_checkout_enabled grew a DEFAULT clause; remove it.")
        #expect(try await db.config.get().cloneCheckoutEnabled == false)
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
            let raw: DatabaseValue = row["clone_checkout_enabled"]
            #expect(raw.isNull)
            #expect(row["auto_create_notes_enabled"] == true)
        }
    }

    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.toModel(cloneCheckoutDefault: false).cloneCheckoutEnabled == false)
        #expect(untouched.toModel(cloneCheckoutDefault: true).cloneCheckoutEnabled == true)
        try await db.config.setCloneCheckoutEnabled(false)
        let off = try #require(try await fetchConfigRecord(db))
        #expect(off.clone_checkout_enabled == false)
        #expect(off.toModel(cloneCheckoutDefault: true).cloneCheckoutEnabled == false)
    }

    @Test func explicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setCloneCheckoutEnabled(true)
        let on = try #require(try await fetchConfigRecord(db))
        #expect(on.clone_checkout_enabled == true)
        #expect(on.toModel(cloneCheckoutDefault: false).cloneCheckoutEnabled == true)
        #expect(try await db.config.get().cloneCheckoutEnabled == true)
    }

    @Test func modelDecodesWithoutTheKey() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.cloneCheckoutEnabled == Config.cloneCheckoutDefault)
    }

    @Test func modelRoundTripsTheValue() throws {
        var config = Config()
        config.cloneCheckoutEnabled = true
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.cloneCheckoutEnabled == true)
    }
}
