import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct MigrationV35Tests {

    @Test func repoIDBecomesNullableAndPromotedColumnAdded() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: "v34_worktree_pr_status")

        // Seed a pre-v35 repo + worktree row via raw SQL (repoID NOT NULL era).
        let repoID = "11111111-1111-1111-1111-111111111111"
        let wtID = "22222222-2222-2222-2222-222222222222"
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                VALUES (?, '/tmp/v35-repo', 'V35', 'main', ?)
                """, arguments: [repoID, Date()])
            try db.execute(sql: """
                INSERT INTO worktree (id, repoID, name, displayName, branch, path, status, createdAt, tmuxServer)
                VALUES (?, ?, 'w', 'w', 'main', '/tmp/v35-wt', 'active', ?, 'tbd-v35')
                """, arguments: [wtID, repoID, Date()])
        }

        // Run v35.
        try migrator.migrate(queue)

        try queue.read { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(worktree)")
            let repoIDCol = cols.first { ($0["name"] as String?) == "repoID" }
            #expect((repoIDCol?["notnull"] as Int?) == 0, "repoID must be nullable after v35")
            let names = cols.compactMap { $0["name"] as String? }
            #expect(names.contains("promotedToRepoID"))
            // Old row survived the rebuild.
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM worktree WHERE id = ?", arguments: [wtID]) ?? -1
            #expect(count == 1)
        }
    }

    @Test func scratchRowWithNullRepoIDRoundTrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await db.worktrees.createScratch(
            name: "20260702-worrying-pike", displayName: "20260702-worrying-pike",
            path: "/tmp/scratch-\(UUID().uuidString)", tmuxServer: "tbd-scratch")
        #expect(wt.repoID == nil)
        #expect(wt.isScratch)
        let fetched = try await db.worktrees.get(id: wt.id)
        #expect(fetched?.repoID == nil)
        #expect(fetched?.isScratch == true)
        #expect(fetched?.branch == "")
    }
}
