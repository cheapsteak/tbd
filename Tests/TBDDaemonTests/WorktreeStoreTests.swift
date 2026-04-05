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
}
