import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Auto-create notes config schema")
struct AutoCreateNotesSchemaTests {
    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { connection in
            try ConfigRecord.fetchOne(connection, key: ConfigStore.singletonID)
        }
    }

    @Test("migration adds a nullable column without a schema default")
    func migrationKeepsNeverChosenDistinct() async throws {
        let db = try TBDDatabase(inMemory: true)

        let column = try db.writerForTests.read { connection in
            return try Row.fetchAll(connection, sql: "PRAGMA table_info(config)")
                .first { ($0["name"] as String) == "auto_create_notes_enabled" }
        }

        let required = try #require(column)
        #expect((required["notnull"] as Int) == 0)
        #expect((required["dflt_value"] as DatabaseValue).isNull)

        let record = try #require(try await fetchConfigRecord(db))
        #expect(record.auto_create_notes_enabled == nil)
    }

    @Test("NULL follows the injected default")
    func nullFollowsInjectedDefault() {
        let record = ConfigRecord(id: "unstored", auto_create_notes_enabled: nil)

        #expect(record.toModel(autoCreateNotesDefault: false).autoCreateNotesEnabled == false)
        #expect(record.toModel(autoCreateNotesDefault: true).autoCreateNotesEnabled == true)
    }

    @Test("explicit false and true persist independently of the shipped default")
    func explicitValuesPersist() async throws {
        let db = try TBDDatabase(inMemory: true)

        try await db.config.setAutoCreateNotes(false)
        var record = try #require(try await fetchConfigRecord(db))
        #expect(record.auto_create_notes_enabled == false)
        #expect(record.toModel(autoCreateNotesDefault: true).autoCreateNotesEnabled == false)
        #expect(record.toModel(autoCreateNotesDefault: false).autoCreateNotesEnabled == false)

        try await db.config.setAutoCreateNotes(true)
        record = try #require(try await fetchConfigRecord(db))
        #expect(record.auto_create_notes_enabled == true)
        #expect(record.toModel(autoCreateNotesDefault: true).autoCreateNotesEnabled == true)
        #expect(record.toModel(autoCreateNotesDefault: false).autoCreateNotesEnabled == true)
    }

    @Test("the shipped default preserves automatic Notes tabs")
    func shippedDefaultIsOn() async throws {
        #expect(Config.autoCreateNotesDefault == true)
        #expect(Config().autoCreateNotesEnabled == true)

        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().autoCreateNotesEnabled == true)
    }

    @Test("legacy Config JSON defaults the setting on")
    func legacyJSONDefaultsOn() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(config.autoCreateNotesEnabled == true)
    }

    @Test("Config JSON round-trips explicit values", arguments: [false, true])
    func configJSONRoundTrips(_ enabled: Bool) throws {
        let encoded = try JSONEncoder().encode(Config(autoCreateNotesEnabled: enabled))
        let decoded = try JSONDecoder().decode(Config.self, from: encoded)
        #expect(decoded.autoCreateNotesEnabled == enabled)
    }
}
