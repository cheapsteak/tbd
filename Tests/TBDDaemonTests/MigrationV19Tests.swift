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

    @Test func setLabelInsertsRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v19a-repo", displayName: "V19a", defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/v19a-repo/wt", tmuxServer: "tbd-v19a"
        )
        let tabID = UUID()
        try await db.tabs.setLabel(tabID: tabID, worktreeID: wt.id, label: "Custom Name")
        let tabs = try await db.tabs.listForWorktree(worktreeID: wt.id)
        #expect(tabs.count == 1)
        #expect(tabs.first?.label == "Custom Name")
        #expect(tabs.first?.id == tabID)
    }

    @Test func setLabelNilDeletesRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v19b-repo", displayName: "V19b", defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/v19b-repo/wt", tmuxServer: "tbd-v19b"
        )
        let tabID = UUID()
        try await db.tabs.setLabel(tabID: tabID, worktreeID: wt.id, label: "X")
        try await db.tabs.setLabel(tabID: tabID, worktreeID: wt.id, label: nil)
        let tabs = try await db.tabs.listForWorktree(worktreeID: wt.id)
        #expect(tabs.isEmpty)
    }

    @Test func setLabelReplacesExistingRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v19c-repo", displayName: "V19c", defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/v19c-repo/wt", tmuxServer: "tbd-v19c"
        )
        let tabID = UUID()
        try await db.tabs.setLabel(tabID: tabID, worktreeID: wt.id, label: "First")
        try await db.tabs.setLabel(tabID: tabID, worktreeID: wt.id, label: "Second")
        let tabs = try await db.tabs.listForWorktree(worktreeID: wt.id)
        #expect(tabs.count == 1)
        #expect(tabs.first?.label == "Second")
    }

    @Test func deleteForWorktreeRemovesAll() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v19d-repo", displayName: "V19d", defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/v19d-repo/wt", tmuxServer: "tbd-v19d"
        )
        try await db.tabs.setLabel(tabID: UUID(), worktreeID: wt.id, label: "A")
        try await db.tabs.setLabel(tabID: UUID(), worktreeID: wt.id, label: "B")
        try await db.tabs.deleteForWorktree(worktreeID: wt.id)
        #expect(try await db.tabs.listForWorktree(worktreeID: wt.id).isEmpty)
    }
}
