import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared

@Suite struct WorktreeStoreTests {
    func makeDB() throws -> TBDDatabase {
        try TBDDatabase(inMemory: true)
    }

    func createRepo(db: TBDDatabase) async throws -> Repo {
        try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "Test Repo",
            defaultBranch: "main"
        )
    }

    @Test func createAssignsSortOrder() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)

        let wt1 = try await db.worktrees.create(
            repoID: repo.id, name: "first", branch: "b1",
            path: "/tmp/wt1-\(UUID())", tmuxServer: "srv1"
        )
        let wt2 = try await db.worktrees.create(
            repoID: repo.id, name: "second", branch: "b2",
            path: "/tmp/wt2-\(UUID())", tmuxServer: "srv2"
        )
        let wt3 = try await db.worktrees.create(
            repoID: repo.id, name: "third", branch: "b3",
            path: "/tmp/wt3-\(UUID())", tmuxServer: "srv3"
        )

        #expect(wt1.sortOrder == 1)
        #expect(wt2.sortOrder == 2)
        #expect(wt3.sortOrder == 3)
    }

    @Test func listReturnsSortedBySortOrder() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)

        let wt1 = try await db.worktrees.create(
            repoID: repo.id, name: "first", branch: "b1",
            path: "/tmp/wt1-\(UUID())", tmuxServer: "srv1"
        )
        let wt2 = try await db.worktrees.create(
            repoID: repo.id, name: "second", branch: "b2",
            path: "/tmp/wt2-\(UUID())", tmuxServer: "srv2"
        )
        let wt3 = try await db.worktrees.create(
            repoID: repo.id, name: "third", branch: "b3",
            path: "/tmp/wt3-\(UUID())", tmuxServer: "srv3"
        )

        let listed = try await db.worktrees.list(repoID: repo.id)
        #expect(listed.map(\.id) == [wt1.id, wt2.id, wt3.id])
    }

    @Test func reorderChangesListOrder() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)

        let wt1 = try await db.worktrees.create(
            repoID: repo.id, name: "first", branch: "b1",
            path: "/tmp/wt1-\(UUID())", tmuxServer: "srv1"
        )
        let wt2 = try await db.worktrees.create(
            repoID: repo.id, name: "second", branch: "b2",
            path: "/tmp/wt2-\(UUID())", tmuxServer: "srv2"
        )
        let wt3 = try await db.worktrees.create(
            repoID: repo.id, name: "third", branch: "b3",
            path: "/tmp/wt3-\(UUID())", tmuxServer: "srv3"
        )

        // Reorder: third, first, second
        try await db.worktrees.reorder(repoID: repo.id, worktreeIDs: [wt3.id, wt1.id, wt2.id])

        let listed = try await db.worktrees.list(repoID: repo.id)
        #expect(listed.map(\.id) == [wt3.id, wt1.id, wt2.id])
        #expect(listed.map(\.sortOrder) == [0, 1, 2])
    }

    @Test func reorderDoesNotAffectOtherRepos() async throws {
        let db = try makeDB()
        let repo1 = try await createRepo(db: db)
        let repo2 = try await createRepo(db: db)

        let wt1 = try await db.worktrees.create(
            repoID: repo1.id, name: "r1-first", branch: "b1",
            path: "/tmp/wt1-\(UUID())", tmuxServer: "srv1"
        )
        let wt2 = try await db.worktrees.create(
            repoID: repo1.id, name: "r1-second", branch: "b2",
            path: "/tmp/wt2-\(UUID())", tmuxServer: "srv2"
        )
        let wt3 = try await db.worktrees.create(
            repoID: repo2.id, name: "r2-first", branch: "b3",
            path: "/tmp/wt3-\(UUID())", tmuxServer: "srv3"
        )

        // Reorder repo1 only
        try await db.worktrees.reorder(repoID: repo1.id, worktreeIDs: [wt2.id, wt1.id])

        let repo1List = try await db.worktrees.list(repoID: repo1.id)
        #expect(repo1List.map(\.id) == [wt2.id, wt1.id])

        let repo2List = try await db.worktrees.list(repoID: repo2.id)
        #expect(repo2List.map(\.id) == [wt3.id])
    }

    @Test func createWithExplicitDisplayName() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)

        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "auto-name",
            displayName: "My Custom Name",
            branch: "b1",
            path: "/tmp/wt-\(UUID())", tmuxServer: "srv"
        )
        #expect(wt.displayName == "My Custom Name")

        // Verify persistence
        let fetched = try await db.worktrees.get(id: wt.id)
        #expect(fetched?.displayName == "My Custom Name")
    }

    @Test func createWithoutDisplayNameDefaultsToName() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)

        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "auto-name",
            branch: "b1",
            path: "/tmp/wt-\(UUID())", tmuxServer: "srv"
        )
        #expect(wt.displayName == "auto-name")
    }

    @Test func worktreeStoreUpdatesPath() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "feat",
            path: "/tmp/old/w", tmuxServer: "srv"
        )
        try await db.worktrees.updatePath(id: wt.id, path: "/tmp/new/w")
        let fetched = try await db.worktrees.get(id: wt.id)
        #expect(fetched?.path == "/tmp/new/w")
    }

    @Test func worktreeStoreCanMarkFailed() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "feat",
            path: "/tmp/r/.tbd/worktrees/w", tmuxServer: "srv"
        )
        try await db.worktrees.updateStatus(id: wt.id, status: .failed)
        let fetched = try await db.worktrees.get(id: wt.id)
        #expect(fetched?.status == .failed)
    }

    @Test func listWithLimitReturnsFirstNRows() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)

        let wt1 = try await db.worktrees.create(
            repoID: repo.id, name: "first", branch: "b1",
            path: "/tmp/wt1-\(UUID())", tmuxServer: "srv1"
        )
        let wt2 = try await db.worktrees.create(
            repoID: repo.id, name: "second", branch: "b2",
            path: "/tmp/wt2-\(UUID())", tmuxServer: "srv2"
        )
        _ = try await db.worktrees.create(
            repoID: repo.id, name: "third", branch: "b3",
            path: "/tmp/wt3-\(UUID())", tmuxServer: "srv3"
        )

        let listed = try await db.worktrees.list(repoID: repo.id, limit: 2)
        #expect(listed.map(\.id) == [wt1.id, wt2.id])
    }

    @Test func listWithOffsetSkipsFirstNRows() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)

        _ = try await db.worktrees.create(
            repoID: repo.id, name: "first", branch: "b1",
            path: "/tmp/wt1-\(UUID())", tmuxServer: "srv1"
        )
        let wt2 = try await db.worktrees.create(
            repoID: repo.id, name: "second", branch: "b2",
            path: "/tmp/wt2-\(UUID())", tmuxServer: "srv2"
        )
        let wt3 = try await db.worktrees.create(
            repoID: repo.id, name: "third", branch: "b3",
            path: "/tmp/wt3-\(UUID())", tmuxServer: "srv3"
        )

        let listed = try await db.worktrees.list(repoID: repo.id, limit: 3, offset: 1)
        #expect(listed.map(\.id) == [wt2.id, wt3.id])
    }

    @Test func listWithLimitAndOffsetPaginates() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)

        let wt1 = try await db.worktrees.create(
            repoID: repo.id, name: "first", branch: "b1",
            path: "/tmp/wt1-\(UUID())", tmuxServer: "srv1"
        )
        let wt2 = try await db.worktrees.create(
            repoID: repo.id, name: "second", branch: "b2",
            path: "/tmp/wt2-\(UUID())", tmuxServer: "srv2"
        )
        let wt3 = try await db.worktrees.create(
            repoID: repo.id, name: "third", branch: "b3",
            path: "/tmp/wt3-\(UUID())", tmuxServer: "srv3"
        )
        let wt4 = try await db.worktrees.create(
            repoID: repo.id, name: "fourth", branch: "b4",
            path: "/tmp/wt4-\(UUID())", tmuxServer: "srv4"
        )

        let page1 = try await db.worktrees.list(repoID: repo.id, limit: 2, offset: 0)
        #expect(page1.map(\.id) == [wt1.id, wt2.id])

        let page2 = try await db.worktrees.list(repoID: repo.id, limit: 2, offset: 2)
        #expect(page2.map(\.id) == [wt3.id, wt4.id])
    }

    @Test func archivedWorktreesSortedByArchivedAtDesc() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)

        // Create active worktrees (will be sorted by sortOrder)
        let wt1 = try await db.worktrees.create(
            repoID: repo.id, name: "active1", branch: "b1",
            path: "/tmp/wt1-\(UUID())", tmuxServer: "srv1"
        )

        // Archive them at different times
        try await db.worktrees.archive(id: wt1.id)

        // Create another active, then archive it
        let wt2 = try await db.worktrees.create(
            repoID: repo.id, name: "active2", branch: "b2",
            path: "/tmp/wt2-\(UUID())", tmuxServer: "srv2"
        )
        try await db.worktrees.archive(id: wt2.id)

        // List archived should have wt2 first (archived most recently)
        let archived = try await db.worktrees.list(repoID: repo.id, status: .archived)
        #expect(archived.map(\.id) == [wt2.id, wt1.id])
    }

    @Test func archivedWorktreesPaginationWithArchivedAtDesc() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)

        // Create and archive 5 worktrees
        var worktreeIDs: [UUID] = []
        for i in 1...5 {
            let wt = try await db.worktrees.create(
                repoID: repo.id, name: "wt\(i)", branch: "b\(i)",
                path: "/tmp/wt\(i)-\(UUID())", tmuxServer: "srv\(i)"
            )
            try await db.worktrees.archive(id: wt.id)
            worktreeIDs.append(wt.id)
        }

        // Most recent archives should come first (reverse of creation order)
        let page1 = try await db.worktrees.list(repoID: repo.id, status: .archived, limit: 2, offset: 0)
        #expect(page1.map(\.id) == [worktreeIDs[4], worktreeIDs[3]])

        let page2 = try await db.worktrees.list(repoID: repo.id, status: .archived, limit: 2, offset: 2)
        #expect(page2.map(\.id) == [worktreeIDs[2], worktreeIDs[1]])

        let page3 = try await db.worktrees.list(repoID: repo.id, status: .archived, limit: 2, offset: 4)
        #expect(page3.map(\.id) == [worktreeIDs[0]])
    }

    // MARK: - excludeArchived filter

    @Test func excludeArchivedTrueReturnsOnlyNonArchived() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)

        let active = try await db.worktrees.create(
            repoID: repo.id, name: "active", branch: "b-active",
            path: "/tmp/active-\(UUID())", tmuxServer: "srv"
        )
        let main = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main",
            path: "/tmp/main-\(UUID())", tmuxServer: "srv"
        )
        let toArchive = try await db.worktrees.create(
            repoID: repo.id, name: "archived-wt", branch: "b-arch",
            path: "/tmp/arch-\(UUID())", tmuxServer: "srv"
        )
        try await db.worktrees.archive(id: toArchive.id)

        let result = try await db.worktrees.list(repoID: repo.id, excludeArchived: true)
        let ids = Set(result.map(\.id))
        #expect(ids.contains(active.id))
        #expect(ids.contains(main.id))
        #expect(!ids.contains(toArchive.id))
    }

    @Test func excludeArchivedFalseReturnsEverything() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)

        let active = try await db.worktrees.create(
            repoID: repo.id, name: "active", branch: "b-active",
            path: "/tmp/active-\(UUID())", tmuxServer: "srv"
        )
        let toArchive = try await db.worktrees.create(
            repoID: repo.id, name: "archived-wt", branch: "b-arch",
            path: "/tmp/arch-\(UUID())", tmuxServer: "srv"
        )
        try await db.worktrees.archive(id: toArchive.id)

        // excludeArchived=false (the default) must return all rows
        let result = try await db.worktrees.list(repoID: repo.id, excludeArchived: false)
        let ids = Set(result.map(\.id))
        #expect(ids.contains(active.id))
        #expect(ids.contains(toArchive.id))
    }

    @Test func excludeArchivedComposesWithRepoIDFilter() async throws {
        let db = try makeDB()
        let repo1 = try await createRepo(db: db)
        let repo2 = try await createRepo(db: db)

        let active1 = try await db.worktrees.create(
            repoID: repo1.id, name: "r1-active", branch: "b1",
            path: "/tmp/r1a-\(UUID())", tmuxServer: "srv"
        )
        let arch1 = try await db.worktrees.create(
            repoID: repo1.id, name: "r1-arch", branch: "b1-arch",
            path: "/tmp/r1ar-\(UUID())", tmuxServer: "srv"
        )
        try await db.worktrees.archive(id: arch1.id)

        let active2 = try await db.worktrees.create(
            repoID: repo2.id, name: "r2-active", branch: "b2",
            path: "/tmp/r2a-\(UUID())", tmuxServer: "srv"
        )

        let repo1Result = try await db.worktrees.list(repoID: repo1.id, excludeArchived: true)
        let repo1IDs = Set(repo1Result.map(\.id))
        #expect(repo1IDs.contains(active1.id))
        #expect(!repo1IDs.contains(arch1.id))
        #expect(!repo1IDs.contains(active2.id))
    }

    @Test func excludeArchivedOrderIsSortOrderAsc() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)

        let wt1 = try await db.worktrees.create(
            repoID: repo.id, name: "first", branch: "b1",
            path: "/tmp/wt1-\(UUID())", tmuxServer: "srv"
        )
        let wt2 = try await db.worktrees.create(
            repoID: repo.id, name: "second", branch: "b2",
            path: "/tmp/wt2-\(UUID())", tmuxServer: "srv"
        )
        let arch = try await db.worktrees.create(
            repoID: repo.id, name: "archived", branch: "b3",
            path: "/tmp/arch-\(UUID())", tmuxServer: "srv"
        )
        try await db.worktrees.archive(id: arch.id)

        let result = try await db.worktrees.list(repoID: repo.id, excludeArchived: true)
        let ids = result.map(\.id)
        #expect(ids == [wt1.id, wt2.id])
        #expect(result.map(\.sortOrder) == [1, 2])
    }

    @Test func prStatusRoundTripsThroughDB() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)

        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "pr-wt", branch: "pr-branch",
            path: "/tmp/pr-wt-\(UUID())", tmuxServer: "srv"
        )

        // Newly created worktree has no PR status.
        #expect(try await db.worktrees.get(id: wt.id)?.prStatus == nil)

        let status = PRStatus(
            number: 42,
            url: "https://example.com/pr/42",
            state: .mergeable,
            reason: "Ready to merge"
        )
        try await db.worktrees.setPRStatus(id: wt.id, status: status)

        let reloaded = try await db.worktrees.get(id: wt.id)
        #expect(reloaded?.prStatus == status)
        #expect(try await db.worktrees.allPRStatuses()[wt.id] == status)

        // Clearing with nil removes the persisted status.
        try await db.worktrees.setPRStatus(id: wt.id, status: nil)
        #expect(try await db.worktrees.get(id: wt.id)?.prStatus == nil)
        #expect(try await db.worktrees.allPRStatuses()[wt.id] == nil)
    }
}
