import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib

@Suite struct MigrationV36Tests {

    @Test func scratchInstructionsColumnExists() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let columns = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(config)")
            let names = columns.compactMap { $0["name"] as String? }
            #expect(names.contains("scratch_instructions"))
        }
    }

    @Test func scratchInstructionsDefaultsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.scratchInstructions == nil)
    }
}
