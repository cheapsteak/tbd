import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared

@Suite struct WorktreeMoveTests {

    func makeDB() throws -> TBDDatabase {
        try TBDDatabase(inMemory: true)
    }

    func makeRepo(_ db: TBDDatabase, name: String = "r") async throws -> Repo {
        try await db.repos.create(
            path: "/tmp/repo-\(UUID())",
            displayName: name,
            defaultBranch: "main"
        )
    }

    func makeWT(_ db: TBDDatabase, repo: Repo, name: String) async throws -> Worktree {
        try await db.worktrees.create(
            repoID: repo.id, name: name, branch: "tbd/\(name)",
            path: "/tmp/\(name)-\(UUID())", tmuxServer: "srv"
        )
    }

    @Test func moveToTopLevelChangesSortOrder() async throws {
        let db = try makeDB()
        let repo = try await makeRepo(db)
        _ = try await makeWT(db, repo: repo, name: "a")
        _ = try await makeWT(db, repo: repo, name: "b")
        let c = try await makeWT(db, repo: repo, name: "c")

        try await db.worktrees.move(worktreeID: c.id, newParentID: nil, newSortOrder: 0)

        let all = try await db.worktrees.list(repoID: repo.id)
            .filter { $0.parentWorktreeID == nil && $0.status != .main }
            .sorted { $0.sortOrder < $1.sortOrder }
        // c should now be at the front
        #expect(all.first?.name == "c")
    }

    @Test func nestUnderAnotherWorktreeSetsParent() async throws {
        let db = try makeDB()
        let repo = try await makeRepo(db)
        let a = try await makeWT(db, repo: repo, name: "a")
        let b = try await makeWT(db, repo: repo, name: "b")

        try await db.worktrees.move(worktreeID: b.id, newParentID: a.id, newSortOrder: 0)

        let updated = try await db.worktrees.get(id: b.id)
        #expect(updated?.parentWorktreeID == a.id)
    }

    @Test func cycleIsRejected() async throws {
        let db = try makeDB()
        let repo = try await makeRepo(db)
        let a = try await makeWT(db, repo: repo, name: "a")
        let b = try await makeWT(db, repo: repo, name: "b")
        try await db.worktrees.move(worktreeID: b.id, newParentID: a.id, newSortOrder: 0)

        await #expect(throws: (any Error).self) {
            try await db.worktrees.move(worktreeID: a.id, newParentID: b.id, newSortOrder: 0)
        }
    }

    @Test func nestingUnderSelfIsRejected() async throws {
        let db = try makeDB()
        let repo = try await makeRepo(db)
        let a = try await makeWT(db, repo: repo, name: "a")

        await #expect(throws: (any Error).self) {
            try await db.worktrees.move(worktreeID: a.id, newParentID: a.id, newSortOrder: 0)
        }
    }

    @Test func crossRepoNestSucceeds() async throws {
        let db = try makeDB()
        let r1 = try await makeRepo(db, name: "r1")
        let r2 = try await makeRepo(db, name: "r2")
        let a = try await makeWT(db, repo: r1, name: "a")
        let b = try await makeWT(db, repo: r2, name: "b")

        try await db.worktrees.move(worktreeID: b.id, newParentID: a.id, newSortOrder: 0)
        let updated = try await db.worktrees.get(id: b.id)
        #expect(updated?.parentWorktreeID == a.id)
        #expect(updated?.repoID == r2.id) // repoID unchanged
    }

    @Test func multiLevelNestingAllowed() async throws {
        let db = try makeDB()
        let repo = try await makeRepo(db)
        let a = try await makeWT(db, repo: repo, name: "a")
        let b = try await makeWT(db, repo: repo, name: "b")
        let c = try await makeWT(db, repo: repo, name: "c")
        try await db.worktrees.move(worktreeID: b.id, newParentID: a.id, newSortOrder: 0)
        try await db.worktrees.move(worktreeID: c.id, newParentID: b.id, newSortOrder: 0)
        #expect(try await db.worktrees.get(id: c.id)?.parentWorktreeID == b.id)
    }
}

@Suite struct WorktreeCreateWithParentTests {

    func makeDB() throws -> TBDDatabase { try TBDDatabase(inMemory: true) }

    @Test func createWithParentSetsField() async throws {
        let db = try makeDB()
        let repo = try await db.repos.create(
            path: "/tmp/r-\(UUID())", displayName: "R", defaultBranch: "main"
        )
        let parent = try await db.worktrees.create(
            repoID: repo.id, name: "p", branch: "tbd/p",
            path: "/tmp/p-\(UUID())", tmuxServer: "srv"
        )
        let child = try await db.worktrees.create(
            repoID: repo.id, name: "c", branch: "tbd/c",
            path: "/tmp/c-\(UUID())", tmuxServer: "srv",
            parentWorktreeID: parent.id
        )
        #expect(child.parentWorktreeID == parent.id)
    }

    @Test func sortOrderScopedToParentGroup() async throws {
        let db = try makeDB()
        let repo = try await db.repos.create(
            path: "/tmp/r-\(UUID())", displayName: "R", defaultBranch: "main"
        )
        let parent = try await db.worktrees.create(
            repoID: repo.id, name: "p", branch: "tbd/p",
            path: "/tmp/p-\(UUID())", tmuxServer: "srv"
        )
        let c1 = try await db.worktrees.create(
            repoID: repo.id, name: "c1", branch: "tbd/c1",
            path: "/tmp/c1-\(UUID())", tmuxServer: "srv",
            parentWorktreeID: parent.id
        )
        let c2 = try await db.worktrees.create(
            repoID: repo.id, name: "c2", branch: "tbd/c2",
            path: "/tmp/c2-\(UUID())", tmuxServer: "srv",
            parentWorktreeID: parent.id
        )
        #expect(c1.sortOrder != c2.sortOrder)
        #expect(c2.sortOrder > c1.sortOrder)
    }
}

@Suite struct WorktreeReconcileOrphanTests {

    @Test func parentPointingAtMissingWorktreeIsNulled() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/r-\(UUID())", displayName: "R", defaultBranch: "main")
        let p = try await db.worktrees.create(repoID: repo.id, name: "p", branch: "tbd/p", path: "/tmp/p-\(UUID())", tmuxServer: "srv")
        let c = try await db.worktrees.create(
            repoID: repo.id, name: "c", branch: "tbd/c",
            path: "/tmp/c-\(UUID())", tmuxServer: "srv",
            parentWorktreeID: p.id
        )

        try await db.worktrees.delete(id: p.id)
        try await db.worktrees.nullOrphanedParents()

        let updated = try await db.worktrees.get(id: c.id)
        #expect(updated?.parentWorktreeID == nil)
    }

    @Test func parentPointingAtArchivedWorktreeIsLeftAlone() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/r-\(UUID())", displayName: "R", defaultBranch: "main")
        let p = try await db.worktrees.create(repoID: repo.id, name: "p", branch: "tbd/p", path: "/tmp/p-\(UUID())", tmuxServer: "srv")
        let c = try await db.worktrees.create(
            repoID: repo.id, name: "c", branch: "tbd/c",
            path: "/tmp/c-\(UUID())", tmuxServer: "srv",
            parentWorktreeID: p.id
        )
        try await db.worktrees.updateStatus(id: p.id, status: .archived)

        try await db.worktrees.nullOrphanedParents()

        let updated = try await db.worktrees.get(id: c.id)
        #expect(updated?.parentWorktreeID == p.id)
    }

    @Test func cycleParentPointerIsBrokenByReconcile() async throws {
        // The public API can't create a cycle (WorktreeStore.move's cycle guard
        // refuses), so simulate a manually-introduced one by writing the
        // forbidden state directly through the writer.
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/r-\(UUID())", displayName: "R", defaultBranch: "main")
        let a = try await db.worktrees.create(repoID: repo.id, name: "a", branch: "tbd/a", path: "/tmp/a-\(UUID())", tmuxServer: "srv")
        let b = try await db.worktrees.create(
            repoID: repo.id, name: "b", branch: "tbd/b",
            path: "/tmp/b-\(UUID())", tmuxServer: "srv",
            parentWorktreeID: a.id
        )
        // Inject: a.parent = b (giving us a <-> b cycle).
        try await db.worktrees.writer.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE worktree SET parentWorktreeID = ? WHERE id = ?",
                arguments: [b.id.uuidString, a.id.uuidString]
            )
        }

        try await db.worktrees.breakCyclicParents()

        // The walk starting from `a` revisits `a` and nulls its parent — that's
        // enough to break the cycle. `b` retains its parent pointing at `a`,
        // which is now a clean depth-1 chain.
        let updatedA = try await db.worktrees.get(id: a.id)
        let updatedB = try await db.worktrees.get(id: b.id)
        #expect(updatedA?.parentWorktreeID == nil)
        #expect(updatedB?.parentWorktreeID == a.id)
    }
}
