import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct MigrationV23Tests {

    @Test func parentColumnExists() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let columns = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(worktree)")
            let names = columns.compactMap { $0["name"] as String? }
            #expect(names.contains("parentWorktreeID"))
        }
    }

    @Test func parentColumnDefaultsToNull() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v23-repo-\(UUID().uuidString)",
            displayName: "V23",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "w",
            branch: "b",
            path: "/tmp/v23-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-v23"
        )
        #expect(wt.parentWorktreeID == nil)

        try await db.writerForTests.read { dbConn in
            let row = try Row.fetchOne(
                dbConn,
                sql: "SELECT parentWorktreeID FROM worktree WHERE id = ?",
                arguments: [wt.id.uuidString]
            )
            #expect(row?["parentWorktreeID"] as String? == nil)
        }

        // Round-trip via the store API.
        let fetched = try await db.worktrees.get(id: wt.id)
        #expect(fetched?.parentWorktreeID == nil)
    }
}
