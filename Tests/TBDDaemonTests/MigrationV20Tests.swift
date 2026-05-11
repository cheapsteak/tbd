import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct MigrationV20Tests {

    @Test func v20AddsActiveTabIDColumnDefaultingToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v20-repo", displayName: "V20", defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/v20-repo/wt", tmuxServer: "tbd-v20"
        )
        // Newly created worktrees have no stored active tab.
        let activeID = try await db.worktrees.getActiveTabID(worktreeID: wt.id)
        #expect(activeID == nil)
    }

    @Test func setActiveTabIDPersistsAndRoundTrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v20a-repo", displayName: "V20a", defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/v20a-repo/wt", tmuxServer: "tbd-v20a"
        )
        let tabID = UUID()
        try await db.worktrees.setActiveTabID(worktreeID: wt.id, tabID: tabID)
        let fetched = try await db.worktrees.getActiveTabID(worktreeID: wt.id)
        #expect(fetched == tabID)
    }

    @Test func setActiveTabIDNilClearsStoredValue() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v20b-repo", displayName: "V20b", defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/v20b-repo/wt", tmuxServer: "tbd-v20b"
        )
        let tabID = UUID()
        try await db.worktrees.setActiveTabID(worktreeID: wt.id, tabID: tabID)
        try await db.worktrees.setActiveTabID(worktreeID: wt.id, tabID: nil)
        let fetched = try await db.worktrees.getActiveTabID(worktreeID: wt.id)
        #expect(fetched == nil)
    }

    @Test func getActiveTabIDReturnsNilForUnknownWorktree() async throws {
        let db = try TBDDatabase(inMemory: true)
        let fetched = try await db.worktrees.getActiveTabID(worktreeID: UUID())
        #expect(fetched == nil)
    }
}
