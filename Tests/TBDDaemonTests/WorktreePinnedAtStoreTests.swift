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

    @Test("a fresh worktree has no pin sort order")
    func pinSortOrderDefaultsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/r", displayName: "r", defaultBranch: "main")
        let wt = try await db.worktrees.create(repoID: repo.id, name: "w", displayName: "w",
                                               branch: "b", path: "/tmp/w", tmuxServer: "s")
        #expect(wt.pinSortOrder == nil)
        #expect(try await db.worktrees.get(id: wt.id)?.pinSortOrder == nil)
    }

    @Test("reorderPins writes 0..<n in list order")
    func reorderPinsWritesIndices() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/r", displayName: "r", defaultBranch: "main")
        var made: [Worktree] = []
        for name in ["a", "b", "c"] {
            made.append(try await db.worktrees.create(repoID: repo.id, name: name, displayName: name,
                                                      branch: "b", path: "/tmp/\(name)", tmuxServer: "s"))
        }
        // Reverse order: c, b, a
        try await db.worktrees.reorderPins(worktreeIDs: [made[2].id, made[1].id, made[0].id])
        #expect(try await db.worktrees.get(id: made[2].id)?.pinSortOrder == 0)
        #expect(try await db.worktrees.get(id: made[1].id)?.pinSortOrder == 1)
        #expect(try await db.worktrees.get(id: made[0].id)?.pinSortOrder == 2)
    }

    @Test("a worktree absent from the list is pushed after the ordered ones")
    func reorderPinsPushesAbsentRows() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/r", displayName: "r", defaultBranch: "main")
        let a = try await db.worktrees.create(repoID: repo.id, name: "a", displayName: "a",
                                              branch: "b", path: "/tmp/a", tmuxServer: "s")
        let outsider = try await db.worktrees.create(repoID: repo.id, name: "z", displayName: "z",
                                                     branch: "b", path: "/tmp/z", tmuxServer: "s")
        try await db.worktrees.reorderPins(worktreeIDs: [a.id])
        #expect(try await db.worktrees.get(id: a.id)?.pinSortOrder == 0)
        let outsiderOrder = try #require(await db.worktrees.get(id: outsider.id)?.pinSortOrder)
        #expect(outsiderOrder >= 1)   // after the single ordered row at index 0
    }

    @Test("nextPinSortOrder returns one past the current maximum")
    func nextPinSortOrderAppends() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/r", displayName: "r", defaultBranch: "main")
        #expect(try await db.worktrees.nextPinSortOrder() == 0)   // nothing pinned yet
        let a = try await db.worktrees.create(repoID: repo.id, name: "a", displayName: "a",
                                              branch: "b", path: "/tmp/a", tmuxServer: "s")
        try await db.worktrees.reorderPins(worktreeIDs: [a.id])   // a → 0
        #expect(try await db.worktrees.nextPinSortOrder() == 1)
    }
}
