import Testing
import Foundation
import GRDB
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
        #expect(fetched?.localPath == "/tmp/new/w")
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

    /// The hydration scope, asserted per status rather than as "active only".
    ///
    /// The maps these two feed are handed out whole in every `pr.list`, so
    /// archived rows — the set that never stops growing, and that the poller
    /// (`list(status: .active)`) would never refresh — must stay out. `.main`,
    /// `.creating` and `.failed` are outside the poller's scope too, but they
    /// are bounded and `pr.refresh` accepts any worktree id, so a value recorded
    /// on one of them is real and must survive a restart. Narrowing to `.active`
    /// dropped their icons at startup.
    @Test func prHydrationCoversEveryUnarchivedStatusAndNoArchivedOne() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)
        let status = PRStatus(number: 7, url: "https://example.com/pr/7", state: .mergeable)
        let observation = PRObservation(outcome: .observed, observedAt: Date())

        var ids: [WorktreeStatus: UUID] = [:]
        for wtStatus in [WorktreeStatus.active, .main, .creating, .failed, .archived] {
            let wt = try await db.worktrees.create(
                repoID: repo.id, name: "wt-\(wtStatus.rawValue)", branch: "b-\(wtStatus.rawValue)",
                path: "/tmp/pr-scope-\(UUID())", tmuxServer: "srv", status: wtStatus)
            try await db.worktrees.setPRStatus(id: wt.id, status: status)
            try await db.worktrees.setPRObservation(id: wt.id, observation: observation)
            ids[wtStatus] = wt.id
        }

        let statuses = try await db.worktrees.allPRStatuses()
        let observations = try await db.worktrees.allPRObservations()

        for wtStatus in [WorktreeStatus.active, .main, .creating, .failed] {
            let id = try #require(ids[wtStatus])
            #expect(statuses[id] == status, "\(wtStatus.rawValue) lost its PR status at hydration")
            #expect(observations[id] != nil,
                    "\(wtStatus.rawValue) lost its PR observation at hydration")
        }
        let archived = try #require(ids[.archived])
        #expect(statuses[archived] == nil)
        #expect(observations[archived] == nil)
    }

    // MARK: - scratchOnly filter

    /// `scratchOnly: true` + `status: .archived` must return exactly the
    /// repo-less archived rows — excluding both active scratch rows and
    /// archived repo-worktree rows. This is the filter the Scratch section's
    /// Archived tab relies on; without it, `repoID: nil` alone would return
    /// every repo's rows too (nil repoID means "no repo filter").
    @Test func scratchOnlyArchivedExcludesActiveScratchAndArchivedRepoRows() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)

        let activeScratch = try await db.worktrees.createScratch(
            name: "active-scratch", displayName: "active-scratch",
            path: "/tmp/scratch-active-\(UUID())", tmuxServer: "srv-scratch"
        )
        let archivedScratch = try await db.worktrees.createScratch(
            name: "archived-scratch", displayName: "archived-scratch",
            path: "/tmp/scratch-archived-\(UUID())", tmuxServer: "srv-scratch"
        )
        try await db.worktrees.archive(id: archivedScratch.id)

        let archivedRepoWorktree = try await db.worktrees.create(
            repoID: repo.id, name: "repo-wt", branch: "b-repo",
            path: "/tmp/repo-wt-\(UUID())", tmuxServer: "srv-repo"
        )
        try await db.worktrees.archive(id: archivedRepoWorktree.id)

        let result = try await db.worktrees.list(status: .archived, scratchOnly: true)
        let ids = Set(result.map(\.id))

        #expect(ids == [archivedScratch.id])
        #expect(!ids.contains(activeScratch.id))
        #expect(!ids.contains(archivedRepoWorktree.id))
    }

    /// `scratchOnly: true` without a status filter still excludes every
    /// repo-scoped row, active or archived.
    @Test func scratchOnlyWithoutStatusReturnsOnlyRepolessRows() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)

        let scratch = try await db.worktrees.createScratch(
            name: "s", displayName: "s", path: "/tmp/scratch-\(UUID())", tmuxServer: "srv-scratch"
        )
        _ = try await db.worktrees.create(
            repoID: repo.id, name: "repo-wt", branch: "b-repo",
            path: "/tmp/repo-wt-\(UUID())", tmuxServer: "srv-repo"
        )

        let result = try await db.worktrees.list(scratchOnly: true)
        #expect(result.map(\.id) == [scratch.id])
    }

    // MARK: - nameQuery filter
    //
    // Tier 1 (in-memory DB). The archived list is paginated, so this filter has
    // to run in SQL: a client-side filter would silently miss archives in pages
    // the app never loaded.

    /// Create + archive a worktree, so it lands in the `status: .archived` set
    /// the search field queries.
    private func makeArchived(
        db: TBDDatabase, repoID: UUID, name: String, displayName: String? = nil
    ) async throws -> Worktree {
        let wt = try await db.worktrees.create(
            repoID: repoID, name: name, displayName: displayName, branch: "b-\(name)",
            path: "/tmp/\(name)-\(UUID())", tmuxServer: "srv"
        )
        try await db.worktrees.archive(id: wt.id)
        return wt
    }

    /// Overwrite a row's `archivedAt` with a deterministic value
    /// (`2026-01-01T00:00:00Z + seconds`). `archive()` has no date seam, and
    /// several archives inside the same stored-millisecond tie on the
    /// `archivedAt desc` order.
    private func stampArchivedAt(db: TBDDatabase, id: UUID, seconds: Int) async throws {
        let date = Date(timeIntervalSince1970: 1_767_225_600).addingTimeInterval(TimeInterval(seconds))
        try await db.writerForTests.write { conn in
            try conn.execute(
                sql: "UPDATE worktree SET archivedAt = ? WHERE id = ?",
                arguments: [date, id.uuidString]
            )
        }
    }

    @Test func nameQueryMatchesFolderName() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)
        let hit = try await makeArchived(db: db, repoID: repo.id, name: "curious-wolverine", displayName: "Zebra")
        _ = try await makeArchived(db: db, repoID: repo.id, name: "sleepy-otter", displayName: "Yak")

        let result = try await db.worktrees.list(repoID: repo.id, status: .archived, nameQuery: "wolverine")
        #expect(result.map(\.id) == [hit.id])
    }

    @Test func nameQueryMatchesDisplayName() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)
        let hit = try await makeArchived(db: db, repoID: repo.id, name: "aaa", displayName: "Search Rail")
        _ = try await makeArchived(db: db, repoID: repo.id, name: "bbb", displayName: "Other")

        let result = try await db.worktrees.list(repoID: repo.id, status: .archived, nameQuery: "rail")
        #expect(result.map(\.id) == [hit.id])
    }

    @Test func nameQueryIsCaseInsensitive() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)
        let hit = try await makeArchived(db: db, repoID: repo.id, name: "MixedCaseName")

        let lower = try await db.worktrees.list(repoID: repo.id, status: .archived, nameQuery: "mixedcase")
        let upper = try await db.worktrees.list(repoID: repo.id, status: .archived, nameQuery: "MIXEDCASE")
        #expect(lower.map(\.id) == [hit.id])
        #expect(upper.map(\.id) == [hit.id])
    }

    /// Substring, not prefix: a query matching only the middle of the name hits.
    @Test func nameQueryMatchesSubstringNotOnlyPrefix() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)
        let hit = try await makeArchived(db: db, repoID: repo.id, name: "tbd-archived-search")

        let result = try await db.worktrees.list(repoID: repo.id, status: .archived, nameQuery: "archiv")
        #expect(result.map(\.id) == [hit.id])
    }

    @Test func blankOrWhitespaceNameQueryAppliesNoFilter() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)
        let a = try await makeArchived(db: db, repoID: repo.id, name: "alpha")
        let b = try await makeArchived(db: db, repoID: repo.id, name: "beta")
        let all: Set<UUID> = [a.id, b.id]

        for query in ["", "   ", "\n\t "] {
            let result = try await db.worktrees.list(repoID: repo.id, status: .archived, nameQuery: query)
            #expect(Set(result.map(\.id)) == all, "query \(query.debugDescription) must not filter")
        }
        let noQuery = try await db.worktrees.list(repoID: repo.id, status: .archived, nameQuery: nil)
        #expect(Set(noQuery.map(\.id)) == all)
    }

    /// Regression: LIKE metacharacters in the user's query must be escaped.
    /// Unescaped, `%` is a wildcard that matches every row and `_` matches any
    /// single character — a search would silently stop filtering.
    @Test func likeMetacharactersInQueryMatchLiterally() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)
        let percent = try await makeArchived(db: db, repoID: repo.id, name: "fifty%off")
        let underscore = try await makeArchived(db: db, repoID: repo.id, name: "snake_case")
        _ = try await makeArchived(db: db, repoID: repo.id, name: "plain")

        // `%` is literal: matches only the row that really contains it.
        let percentHits = try await db.worktrees.list(repoID: repo.id, status: .archived, nameQuery: "%")
        #expect(percentHits.map(\.id) == [percent.id])

        // `_` is literal: "snake_case" hits, "snakeXcase" would not.
        let underscoreHits = try await db.worktrees.list(repoID: repo.id, status: .archived, nameQuery: "e_c")
        #expect(underscoreHits.map(\.id) == [underscore.id])

        // A backslash (the escape char itself) is literal too and matches nothing here.
        let backslashHits = try await db.worktrees.list(repoID: repo.id, status: .archived, nameQuery: "\\")
        #expect(backslashHits.isEmpty)
    }

    /// Composes with `status` and `repoID`: an active row with a matching name,
    /// and an archived row in another repo, are both excluded.
    @Test func nameQueryComposesWithStatusAndRepoFilters() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)
        let otherRepo = try await createRepo(db: db)

        let hit = try await makeArchived(db: db, repoID: repo.id, name: "match-me")
        let active = try await db.worktrees.create(
            repoID: repo.id, name: "match-me-too", branch: "b-active",
            path: "/tmp/active-\(UUID())", tmuxServer: "srv"
        )
        let otherRepoHit = try await makeArchived(db: db, repoID: otherRepo.id, name: "match-me-elsewhere")

        let result = try await db.worktrees.list(repoID: repo.id, status: .archived, nameQuery: "match-me")
        let ids = Set(result.map(\.id))
        #expect(ids == [hit.id])
        #expect(!ids.contains(active.id))
        #expect(!ids.contains(otherRepoHit.id))
    }

    /// Pagination applies AFTER the match filter, so offset pages over the
    /// matching set — not over all archived rows. Without this, page 2 of a
    /// search would skip matches that happened to sit behind non-matching rows.
    @Test func nameQueryPaginationPagesOverMatchesOnly() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)

        // Interleave matches and non-matches so an unfiltered offset would
        // land on the wrong rows.
        var matches: [UUID] = []
        var ordinal = 0
        for i in 1...4 {
            let hit = try await makeArchived(db: db, repoID: repo.id, name: "keep-\(i)")
            matches.append(hit.id)
            let miss = try await makeArchived(db: db, repoID: repo.id, name: "drop-\(i)")
            // `archive()` stamps `Date()`, and eight archives inside one
            // millisecond tie on the `archivedAt desc` sort — which makes page
            // boundaries arbitrary. Restamp with explicit, well-separated
            // values so the ordering under test is the query's, not the clock's.
            for id in [hit.id, miss.id] {
                ordinal += 1
                try await stampArchivedAt(db: db, id: id, seconds: ordinal)
            }
        }
        // `archivedAt desc` — newest first.
        let expected = matches.reversed().map { $0 }

        let page1 = try await db.worktrees.list(
            repoID: repo.id, status: .archived, limit: 2, offset: 0, nameQuery: "keep-"
        )
        #expect(page1.map(\.id) == Array(expected[0..<2]))

        let page2 = try await db.worktrees.list(
            repoID: repo.id, status: .archived, limit: 2, offset: 2, nameQuery: "keep-"
        )
        #expect(page2.map(\.id) == Array(expected[2..<4]))

        let page3 = try await db.worktrees.list(
            repoID: repo.id, status: .archived, limit: 2, offset: 4, nameQuery: "keep-"
        )
        #expect(page3.isEmpty)
    }
}
