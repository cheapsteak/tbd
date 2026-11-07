import Foundation
import GRDB
import Testing
import DaemonTestSupport

@testable import TBDDaemonLib
@testable import TBDShared

/// Schema and resolution guards for `config.phone_control_enabled`, the
/// default-off gate on phone control. The column has no SQL default, so NULL
/// ("never chose") stays distinct from 0 ("off").
@Suite("PhoneControlFlag")
struct PhoneControlFlagTests {

    /// The newest migration identifier before the phone control file.
    private static let lastIdentifierBeforeTheFlag = "20261106120000_config_session_restore"

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    @Test func shippedDefaultIsOff() {
        #expect(Config.phoneControlEnabledDefault == false)
        #expect(Config().phoneControlEnabled == false)
    }

    @Test func phoneControlColumnIsNullBeforeAnyChoice() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: Self.lastIdentifierBeforeTheFlag)
        try queue.write { db in
            try db.execute(
                sql: "UPDATE config SET queued_prompt_enabled = 1 WHERE id = ?",
                arguments: [ConfigStore.singletonID])
        }
        try migrator.migrate(queue)
        try queue.read { db in
            let row = try #require(try Row.fetchOne(
                db, sql: "SELECT * FROM config WHERE id = ?",
                arguments: [ConfigStore.singletonID]))
            let raw: DatabaseValue = row["phone_control_enabled"]
            #expect(raw.isNull, "a pre-migration row must read NULL, not \(raw)")
            #expect((row["phone_relay_url"] as DatabaseValue).isNull)
            #expect((row["phone_loader_url"] as DatabaseValue).isNull)
            let record = try #require(try ConfigRecord.fetchOne(db, key: ConfigStore.singletonID))
            #expect(record.phone_control_enabled == nil)
            #expect(record.toModel().phoneControlEnabled == Config.phoneControlEnabledDefault)
        }
    }

    @Test func aFreshInstallReadsNullAndResolvesToTheDefault() async throws {
        let fresh = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(fresh))
        #expect(record.phone_control_enabled == nil,
                "phone_control_enabled grew a DEFAULT clause; remove it.")
        let config = try await fresh.config.get()
        #expect(config.phoneControlEnabled == Config.phoneControlEnabledDefault)
    }

    @Test func explicitFalseSurvivesADefaultFlip() async throws {
        let db = try TBDDatabase(inMemory: true)
        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.toModel(phoneControlDefault: false).phoneControlEnabled == false)
        #expect(untouched.toModel(phoneControlDefault: true).phoneControlEnabled == true)

        try await db.config.setPhoneControlEnabled(false)
        let explicitlyOff = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOff.phone_control_enabled == false)
        #expect(explicitlyOff.toModel(phoneControlDefault: true).phoneControlEnabled == false)
    }

    @Test func explicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPhoneControlEnabled(true)
        let explicitlyOn = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOn.toModel(phoneControlDefault: false).phoneControlEnabled == true)
        #expect(try await db.config.get().phoneControlEnabled == true)
    }

    @Test func relayAndLoaderURLsStoreAndClear() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPhoneRelayURL("https://acme-relay.acme.workers.dev")
        #expect(try await db.config.get().phoneRelayURL == "https://acme-relay.acme.workers.dev")
        try await db.config.setPhoneRelayURL(nil)
        #expect(try await db.config.get().phoneRelayURL == nil)

        #expect(try await db.config.get().resolvedPhoneLoaderURL == Config.phoneLoaderURLDefault)
        try await db.config.setPhoneLoaderURL("https://acme.github.io/loader/")
        #expect(try await db.config.get().resolvedPhoneLoaderURL == "https://acme.github.io/loader/")
        try await db.config.setPhoneLoaderURL(nil)
        #expect(try await db.config.get().resolvedPhoneLoaderURL == Config.phoneLoaderURLDefault)
    }

    @Test func modelDecodesWithoutTheKeys() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.phoneControlEnabled == false)
        #expect(config.phoneRelayURL == nil)
        #expect(config.phoneLoaderURL == nil)
    }

    @Test func modelRoundTripsTheValues() throws {
        var config = Config()
        config.phoneControlEnabled = true
        config.phoneRelayURL = "https://acme-relay.acme.workers.dev"
        config.phoneLoaderURL = "https://acme.github.io/loader/"
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.phoneControlEnabled == true)
        #expect(decoded.phoneRelayURL == "https://acme-relay.acme.workers.dev")
        #expect(decoded.phoneLoaderURL == "https://acme.github.io/loader/")
    }
}
