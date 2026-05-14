import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct MigrationV24Tests {

    @Test func conductorTableIsDropped() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let row = try Row.fetchOne(
                dbConn,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'conductor'"
            )
            #expect(row == nil, "v24 should drop the conductor table created in v10")
        }
    }

    @Test func conductorPseudoRepoIsDeleted() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let row = try Row.fetchOne(
                dbConn,
                sql: "SELECT id FROM repo WHERE id = ?",
                arguments: ["00000000-0000-0000-0000-000000000001"]
            )
            #expect(row == nil, "v24 should delete the synthetic conductor pseudo-repo inserted by v10")
        }
    }

    @Test func conductorStatusWorktreesAreDeleted() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let count = try Int.fetchOne(
                dbConn,
                sql: "SELECT COUNT(*) FROM worktree WHERE status = 'conductor'"
            ) ?? 0
            #expect(count == 0, "v24 should delete any worktree row with the legacy conductor status")
        }
    }
}
