import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared

/// `WorktreeStore.moveMany`: the sidebar's all-or-nothing drop. Every check
/// runs before any write, the destination group is renumbered 0…n−1, and the
/// result is the group's unarchived rows in their new order, with whether a
/// carried row changed parent.
@Suite struct WorktreeMoveManyTests {

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

    func makeWT(
        _ db: TBDDatabase, repo: Repo, name: String, parent: UUID? = nil
    ) async throws -> Worktree {
        try await db.worktrees.create(
            repoID: repo.id, name: name, branch: "tbd/\(name)",
            path: "/tmp/\(name)-\(UUID())", tmuxServer: "srv",
            parentWorktreeID: parent
        )
    }

    func makeMain(_ db: TBDDatabase, repo: Repo) async throws -> Worktree {
        try await db.worktrees.create(
            repoID: repo.id, name: "main", branch: "main",
            path: "/tmp/main-\(UUID())", tmuxServer: "srv", status: .main
        )
    }

    func makeScratch(_ db: TBDDatabase, name: String) async throws -> Worktree {
        try await db.worktrees.createScratch(
            name: name, displayName: name,
            path: "/tmp/scratch-\(name)-\(UUID())", tmuxServer: "srv"
        )
    }

    /// The rows under `parentID`, in sortOrder.
    func children(_ db: TBDDatabase, of parentID: UUID) async throws -> [UUID] {
        try await db.worktrees.list()
            .filter { $0.parentWorktreeID == parentID }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.id)
    }

    /// The repo's top-level group (no parent, not main), in sortOrder.
    func topLevel(_ db: TBDDatabase, repo: Repo) async throws -> [UUID] {
        try await db.worktrees.list(repoID: repo.id)
            .filter { $0.parentWorktreeID == nil && $0.status != .main }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.id)
    }

    /// What the database holds for each of `ids`, as the entries `moveMany`
    /// returns.
    func entries(_ db: TBDDatabase, _ ids: [UUID]) async throws -> [WorktreeOrderEntry] {
        var result: [WorktreeOrderEntry] = []
        for id in ids {
            let row = try #require(try await db.worktrees.get(id: id))
            result.append(WorktreeOrderEntry(
                worktreeID: id, parentWorktreeID: row.parentWorktreeID, sortOrder: row.sortOrder))
        }
        return result
    }

    struct RowState: Equatable {
        let parentWorktreeID: UUID?
        let sortOrder: Int
        let remoteParentAssigned: Bool
    }

    /// Every row's placement, to prove a refused move wrote nothing.
    func snapshot(_ db: TBDDatabase) async throws -> [UUID: RowState] {
        var result: [UUID: RowState] = [:]
        for row in try await db.worktrees.list() {
            result[row.id] = RowState(
                parentWorktreeID: row.parentWorktreeID,
                sortOrder: row.sortOrder,
                remoteParentAssigned: row.remoteParentAssigned)
        }
        return result
    }

    // MARK: - Placement

    @Test func nestsRowsAsLastChildrenInOrder() async throws {
        let db = try makeDB()
        let repo = try await makeRepo(db)
        let parent = try await makeWT(db, repo: repo, name: "parent")
        let existing = try await makeWT(db, repo: repo, name: "existing", parent: parent.id)
        let a = try await makeWT(db, repo: repo, name: "a")
        let b = try await makeWT(db, repo: repo, name: "b")

        _ = try await db.worktrees.moveMany(
            worktreeIDs: [b.id, a.id], newParentID: parent.id, before: nil)

        #expect(try await children(db, of: parent.id) == [existing.id, b.id, a.id])
        #expect(try await db.worktrees.get(id: a.id)?.parentWorktreeID == parent.id)
        #expect(try await db.worktrees.get(id: b.id)?.parentWorktreeID == parent.id)
        #expect(try await topLevel(db, repo: repo) == [parent.id])
    }

    @Test func placesBeforeSiblingAndRenumbersGroup() async throws {
        let db = try makeDB()
        let repo = try await makeRepo(db)
        let mainRow = try await makeMain(db, repo: repo)
        let a = try await makeWT(db, repo: repo, name: "a")
        let b = try await makeWT(db, repo: repo, name: "b")
        let c = try await makeWT(db, repo: repo, name: "c")
        let d = try await makeWT(db, repo: repo, name: "d")
        let mainOrderBefore = try #require(try await db.worktrees.get(id: mainRow.id)).sortOrder

        _ = try await db.worktrees.moveMany(worktreeIDs: [d.id], newParentID: nil, before: b.id)

        let expected = [a.id, d.id, b.id, c.id]
        #expect(try await topLevel(db, repo: repo) == expected)
        let orders = try await entries(db, expected).map(\.sortOrder)
        #expect(orders == Array(0..<expected.count))
        // The main row is outside the top-level group and keeps its place.
        #expect(try await db.worktrees.get(id: mainRow.id)?.sortOrder == mainOrderBefore)
    }

    @Test func unNestsToTopLevelOfOwnRepo() async throws {
        let db = try makeDB()
        let home = try await makeRepo(db, name: "home")
        let other = try await makeRepo(db, name: "other")
        let parent = try await makeWT(db, repo: home, name: "parent")
        let sibling = try await makeWT(db, repo: other, name: "sibling")
        // Nested across repos: the child's own repo decides where it un-nests to.
        let child = try await makeWT(db, repo: other, name: "child", parent: parent.id)

        let result = try await db.worktrees.moveMany(
            worktreeIDs: [child.id], newParentID: nil, before: nil)

        #expect(try await db.worktrees.get(id: child.id)?.parentWorktreeID == nil)
        #expect(try await topLevel(db, repo: other) == [sibling.id, child.id])
        #expect(try await topLevel(db, repo: home) == [parent.id])
        #expect(try await children(db, of: parent.id).isEmpty)
        let resultIDs = result.entries.map { $0.worktreeID }
        #expect(resultIDs == [sibling.id, child.id])
        #expect(result.reparented)
    }

    /// Scratch rows have a NULL `repoID`. A group query written `repoID = ?`
    /// matches no row for NULL, so the siblings would keep their old numbers
    /// and collide with the moved row's; `repoID IS ?` makes them shift.
    @Test func reordersScratchRowsWithNullRepoID() async throws {
        let db = try makeDB()
        let repo = try await makeRepo(db)
        let repoRow = try await makeWT(db, repo: repo, name: "repo-row")
        let s1 = try await makeScratch(db, name: "s1")
        let s2 = try await makeScratch(db, name: "s2")
        let s3 = try await makeScratch(db, name: "s3")
        let repoRowOrderBefore = try #require(try await db.worktrees.get(id: repoRow.id)).sortOrder

        let result = try await db.worktrees.moveMany(
            worktreeIDs: [s1.id], newParentID: nil, before: s3.id)

        // s2 and s3 must be renumbered around s1 for this order to hold.
        let expected = [s2.id, s1.id, s3.id]
        #expect(try await entries(db, expected).map(\.sortOrder) == [0, 1, 2])
        #expect(result.entries == [
            WorktreeOrderEntry(worktreeID: s2.id, parentWorktreeID: nil, sortOrder: 0),
            WorktreeOrderEntry(worktreeID: s1.id, parentWorktreeID: nil, sortOrder: 1),
            WorktreeOrderEntry(worktreeID: s3.id, parentWorktreeID: nil, sortOrder: 2),
        ])
        // A reorder among the rows' own siblings changes no parent.
        #expect(!result.reparented)
        // The repo's top-level group is a different group and is not touched.
        #expect(try await db.worktrees.get(id: repoRow.id)?.sortOrder == repoRowOrderBefore)
    }

    // MARK: - Refusals write nothing

    @Test func rejectsScratchGettingAParent() async throws {
        let db = try makeDB()
        let repo = try await makeRepo(db)
        let parent = try await makeWT(db, repo: repo, name: "parent")
        let a = try await makeWT(db, repo: repo, name: "a")
        let scratch = try await makeScratch(db, name: "s")
        let before = try await snapshot(db)

        await #expect(throws: WorktreeMoveError.scratchCannotNest) {
            try await db.worktrees.moveMany(
                worktreeIDs: [a.id, scratch.id], newParentID: parent.id, before: nil)
        }

        #expect(try await snapshot(db) == before)
    }

    @Test func rejectsCycleAndWritesNothing() async throws {
        let db = try makeDB()
        let repo = try await makeRepo(db)
        let ancestor = try await makeWT(db, repo: repo, name: "ancestor")
        let target = try await makeWT(db, repo: repo, name: "target", parent: ancestor.id)
        let bystander = try await makeWT(db, repo: repo, name: "bystander")
        let before = try await snapshot(db)

        // `bystander` alone would be a valid move; carrying `ancestor` under its
        // own child closes a cycle, so neither row moves.
        await #expect(throws: WorktreeMoveError.cycle) {
            try await db.worktrees.moveMany(
                worktreeIDs: [bystander.id, ancestor.id], newParentID: target.id, before: nil)
        }

        #expect(try await snapshot(db) == before)
    }

    @Test func rejectsMainRow() async throws {
        let db = try makeDB()
        let repo = try await makeRepo(db)
        let mainRow = try await makeMain(db, repo: repo)
        let a = try await makeWT(db, repo: repo, name: "a")
        let before = try await snapshot(db)

        await #expect(throws: WorktreeMoveError.carriesMain) {
            try await db.worktrees.moveMany(worktreeIDs: [a.id, mainRow.id], newParentID: nil, before: nil)
        }

        #expect(try await snapshot(db) == before)
    }

    @Test func rejectsBeforeOutsideGroup() async throws {
        let db = try makeDB()
        let repo = try await makeRepo(db)
        let parent = try await makeWT(db, repo: repo, name: "parent")
        _ = try await makeWT(db, repo: repo, name: "child", parent: parent.id)
        let a = try await makeWT(db, repo: repo, name: "a")
        let topLevelRow = try await makeWT(db, repo: repo, name: "top")
        let before = try await snapshot(db)

        // A top-level row is not among `parent`'s children.
        await #expect(throws: WorktreeMoveError.beforeNotInGroup) {
            try await db.worktrees.moveMany(
                worktreeIDs: [a.id], newParentID: parent.id, before: topLevelRow.id)
        }
        // Nor is a row that does not exist.
        await #expect(throws: WorktreeMoveError.beforeNotInGroup) {
            try await db.worktrees.moveMany(worktreeIDs: [a.id], newParentID: nil, before: UUID())
        }

        #expect(try await snapshot(db) == before)
    }

    @Test func rejectsBeforeThatIsCarried() async throws {
        let db = try makeDB()
        let repo = try await makeRepo(db)
        let a = try await makeWT(db, repo: repo, name: "a")
        let b = try await makeWT(db, repo: repo, name: "b")
        _ = try await makeWT(db, repo: repo, name: "c")
        let before = try await snapshot(db)

        await #expect(throws: WorktreeMoveError.beforeIsCarried) {
            try await db.worktrees.moveMany(worktreeIDs: [a.id, b.id], newParentID: nil, before: b.id)
        }

        #expect(try await snapshot(db) == before)
    }

    @Test func rejectsTopLevelRowsFromTwoRepos() async throws {
        let db = try makeDB()
        let first = try await makeRepo(db, name: "first")
        let second = try await makeRepo(db, name: "second")
        let a = try await makeWT(db, repo: first, name: "a")
        let b = try await makeWT(db, repo: second, name: "b")
        let scratch = try await makeScratch(db, name: "s")
        let before = try await snapshot(db)

        await #expect(throws: WorktreeMoveError.mixedGroups) {
            try await db.worktrees.moveMany(worktreeIDs: [a.id, b.id], newParentID: nil, before: nil)
        }
        // A scratch row and a repo row are two groups too.
        await #expect(throws: WorktreeMoveError.mixedGroups) {
            try await db.worktrees.moveMany(
                worktreeIDs: [scratch.id, a.id], newParentID: nil, before: nil)
        }

        #expect(try await snapshot(db) == before)
    }

    @Test func rejectsAnEmptyMove() async throws {
        let db = try makeDB()
        await #expect(throws: WorktreeMoveError.emptyMove) {
            try await db.worktrees.moveMany(worktreeIDs: [], newParentID: nil, before: nil)
        }
    }

    // MARK: - Adoption marker

    @Test func setsRemoteParentAssignedOnlyWhenParentChanges() async throws {
        let db = try makeDB()
        let repo = try await makeRepo(db)
        let parent = try await makeWT(db, repo: repo, name: "parent")
        let first = try await db.worktrees.createRemote(
            repoID: repo.id, name: "first", branch: "tbd/first",
            provider: "fake", sessionID: "first")
        let second = try await db.worktrees.createRemote(
            repoID: repo.id, name: "second", branch: "tbd/second",
            provider: "fake", sessionID: "second")
        let local = try await makeWT(db, repo: repo, name: "local")

        // A reorder that keeps the parent says nothing about nesting.
        _ = try await db.worktrees.moveMany(
            worktreeIDs: [second.id], newParentID: nil, before: first.id)
        #expect(try await db.worktrees.get(id: second.id)?.remoteParentAssigned == false)
        #expect(try await db.worktrees.get(id: first.id)?.remoteParentAssigned == false)

        // A changed parent spends the remote row's adoption assignment.
        _ = try await db.worktrees.moveMany(
            worktreeIDs: [first.id, local.id], newParentID: parent.id, before: nil)
        #expect(try await db.worktrees.get(id: first.id)?.remoteParentAssigned == true)
        #expect(try await db.worktrees.get(id: second.id)?.remoteParentAssigned == false)
        // Local rows are never adoption's business.
        #expect(try await db.worktrees.get(id: local.id)?.remoteParentAssigned == false)
    }

    // MARK: - Result

    /// The result is every unarchived row of the destination group, each
    /// with its parent and new sortOrder, and it matches what the database
    /// now holds. An archived row in the group is renumbered with the rest
    /// but left out of the result, which the delta broadcasts.
    @Test func returnsTheDestinationGroupWithoutArchivedRows() async throws {
        let db = try makeDB()
        let repo = try await makeRepo(db)
        let parent = try await makeWT(db, repo: repo, name: "parent")
        let c1 = try await makeWT(db, repo: repo, name: "c1", parent: parent.id)
        let archived = try await makeWT(db, repo: repo, name: "archived", parent: parent.id)
        try await db.worktrees.updateStatus(id: archived.id, status: .archived)
        let c2 = try await makeWT(db, repo: repo, name: "c2", parent: parent.id)
        let mover = try await makeWT(db, repo: repo, name: "mover")

        let result = try await db.worktrees.moveMany(
            worktreeIDs: [mover.id], newParentID: parent.id, before: c2.id)

        // The whole group's new order, archived row included.
        let renumbered = [c1.id, archived.id, mover.id, c2.id]
        let stored = try await entries(db, renumbered)
        let storedOrders = stored.map { $0.sortOrder }
        #expect(storedOrders == [0, 1, 2, 3])
        // The result is that order without the archived row.
        let expected = stored.filter { $0.worktreeID != archived.id }
        #expect(result.entries == expected)
        let resultIDs = result.entries.map { $0.worktreeID }
        #expect(resultIDs == [c1.id, mover.id, c2.id])
        #expect(result.reparented)
    }
}
