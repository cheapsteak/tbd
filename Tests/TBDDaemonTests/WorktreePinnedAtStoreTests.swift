import Testing
import Foundation
import TBDShared
@testable import TBDDaemonLib

/// Tier 1: in-memory DB only, no clock, no filesystem, no `~/tbd`.
@Suite struct WorktreePinnedAtStoreTests {

    @Test func freshWorktreeReadsBackUnpinned() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/repoPin", displayName: "repoPin", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", displayName: "w", branch: "b",
            path: "/tmp/repoPin/w", tmuxServer: "s", status: .active)
        #expect(wt.pinnedAt == nil)
        #expect(try await db.worktrees.get(id: wt.id)?.pinnedAt == nil)
    }

    @Test func setPinnedStoresAndClearsTheTimestamp() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/repoPin2", displayName: "repoPin2", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", displayName: "w", branch: "b",
            path: "/tmp/repoPin2/w", tmuxServer: "s", status: .active)

        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try await db.worktrees.setPinned(id: wt.id, pinnedAt: stamp)
        #expect(try await db.worktrees.get(id: wt.id)?.pinnedAt == stamp)

        try await db.worktrees.setPinned(id: wt.id, pinnedAt: nil)
        #expect(try await db.worktrees.get(id: wt.id)?.pinnedAt == nil)
    }
}
