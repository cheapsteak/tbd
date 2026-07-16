import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
import TBDShared

@Suite struct MigrationV54Tests {

    @Test func prNumberColumnExists() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let columns = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(worktree)")
            let names = columns.compactMap { $0["name"] as String? }
            #expect(names.contains("pr_number"))
        }
    }

    @Test func existingRowDecodesNilPRNumber() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/v54-\(UUID())", displayName: "v54", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/v54-wt-\(UUID())", tmuxServer: "srv"
        )
        let fetched = try await db.worktrees.get(id: wt.id)
        #expect(fetched?.prNumber == nil)
    }

    @Test func prNumberRoundTripsThroughDB() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/v54b-\(UUID())", displayName: "v54b", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w2", branch: "b2",
            path: "/tmp/v54-wt2-\(UUID())", tmuxServer: "srv"
        )
        try await db.writerForTests.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE worktree SET pr_number = ? WHERE id = ?",
                arguments: [454, wt.id.uuidString]
            )
        }
        let fetched = try await db.worktrees.get(id: wt.id)
        #expect(fetched?.prNumber == 454)
    }
}
