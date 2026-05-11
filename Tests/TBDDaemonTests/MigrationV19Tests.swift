import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct MigrationV19Tests {

    @Test func v19CreatesTabTableAndTabOrderColumn() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v19-repo", displayName: "V19", defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/v19-repo/wt", tmuxServer: "tbd-v19"
        )
        // tab_order defaults to empty array literal.
        let order = try await db.worktrees.getTabOrder(worktreeID: wt.id)
        #expect(order.isEmpty)
        // tab table exists and is empty.
        let tabs = try await db.tabs.listForWorktree(worktreeID: wt.id)
        #expect(tabs.isEmpty)
    }
}
