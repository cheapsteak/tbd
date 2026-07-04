import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib

@Suite struct MigrationV37Tests {

    @Test func scratchRenamePromptColumnExists() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let columns = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(config)")
            let names = columns.compactMap { $0["name"] as String? }
            #expect(names.contains("scratch_rename_prompt"))
        }
    }

    @Test func scratchProfileOverrideIDColumnExists() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let columns = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(config)")
            let names = columns.compactMap { $0["name"] as String? }
            #expect(names.contains("scratch_profile_override_id"))
        }
    }

    @Test func scratchRenamePromptDefaultsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.scratchRenamePrompt == nil)
    }

    @Test func scratchProfileOverrideIDDefaultsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.scratchProfileOverrideID == nil)
    }
}
