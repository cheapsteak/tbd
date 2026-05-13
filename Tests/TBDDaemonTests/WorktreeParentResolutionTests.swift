import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared

@Suite struct WorktreeParentResolutionTests {

    @Test func suppressAutoParentBeatsEverything() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/r-\(UUID())", displayName: "R", defaultBranch: "main")
        let caller = try await db.worktrees.create(
            repoID: repo.id, name: "caller", branch: "tbd/caller",
            path: "/tmp/caller-\(UUID())", tmuxServer: "srv"
        )

        let resolved = try await ParentResolver.resolve(
            db: db,
            explicitParent: caller.id,
            siblingOf: nil,
            caller: caller.id,
            suppressAutoParent: true
        )
        #expect(resolved == nil)
    }

    @Test func explicitParentBeatsSiblingAndCaller() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/r-\(UUID())", displayName: "R", defaultBranch: "main")
        let p = try await db.worktrees.create(repoID: repo.id, name: "p", branch: "tbd/p", path: "/tmp/p-\(UUID())", tmuxServer: "srv")
        let other = try await db.worktrees.create(repoID: repo.id, name: "o", branch: "tbd/o", path: "/tmp/o-\(UUID())", tmuxServer: "srv")

        let resolved = try await ParentResolver.resolve(
            db: db,
            explicitParent: p.id,
            siblingOf: other.id,
            caller: other.id,
            suppressAutoParent: false
        )
        #expect(resolved == p.id)
    }

    @Test func siblingResolvesToCallerParent() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/r-\(UUID())", displayName: "R", defaultBranch: "main")
        let p = try await db.worktrees.create(repoID: repo.id, name: "p", branch: "tbd/p", path: "/tmp/p-\(UUID())", tmuxServer: "srv")
        let child = try await db.worktrees.create(
            repoID: repo.id, name: "c", branch: "tbd/c",
            path: "/tmp/c-\(UUID())", tmuxServer: "srv",
            parentWorktreeID: p.id
        )

        let resolved = try await ParentResolver.resolve(
            db: db, explicitParent: nil, siblingOf: child.id, caller: nil, suppressAutoParent: false
        )
        #expect(resolved == p.id)
    }

    @Test func siblingOfTopLevelResolvesToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/r-\(UUID())", displayName: "R", defaultBranch: "main")
        let top = try await db.worktrees.create(repoID: repo.id, name: "top", branch: "tbd/top", path: "/tmp/top-\(UUID())", tmuxServer: "srv")

        let resolved = try await ParentResolver.resolve(
            db: db, explicitParent: nil, siblingOf: top.id, caller: nil, suppressAutoParent: false
        )
        #expect(resolved == nil)
    }

    @Test func callerBecomesParentByDefault() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/r-\(UUID())", displayName: "R", defaultBranch: "main")
        let caller = try await db.worktrees.create(repoID: repo.id, name: "caller", branch: "tbd/caller", path: "/tmp/caller-\(UUID())", tmuxServer: "srv")

        let resolved = try await ParentResolver.resolve(
            db: db, explicitParent: nil, siblingOf: nil, caller: caller.id, suppressAutoParent: false
        )
        #expect(resolved == caller.id)
    }

    @Test func mainCallerFallsBackToFlat() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/r-\(UUID())", displayName: "R", defaultBranch: "main")
        let main = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main",
            path: "/tmp/main-\(UUID())", tmuxServer: "srv"
        )

        let resolved = try await ParentResolver.resolve(
            db: db, explicitParent: nil, siblingOf: nil, caller: main.id, suppressAutoParent: false
        )
        #expect(resolved == nil)
    }

    @Test func missingCallerFallsBackToFlat() async throws {
        let db = try TBDDatabase(inMemory: true)
        let resolved = try await ParentResolver.resolve(
            db: db, explicitParent: nil, siblingOf: nil, caller: UUID(), suppressAutoParent: false
        )
        #expect(resolved == nil)
    }

    @Test func explicitArchivedParentIsRejected() async throws {
        // Spawning a child under an archived parent would produce an invisible
        // row in the sidebar (topLevelWorktrees filters out children;
        // WorktreeSubtreeView skips archived parents). Reject before creation.
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/r-\(UUID())", displayName: "R", defaultBranch: "main")
        let p = try await db.worktrees.create(repoID: repo.id, name: "p", branch: "tbd/p", path: "/tmp/p-\(UUID())", tmuxServer: "srv")
        try await db.worktrees.updateStatus(id: p.id, status: .archived)

        await #expect(throws: WorktreeMoveError.parentIsArchived) {
            _ = try await ParentResolver.resolve(
                db: db,
                explicitParent: p.id,
                siblingOf: nil,
                caller: nil,
                suppressAutoParent: false
            )
        }
    }

    @Test func archivedCallerFallsBackToFlat() async throws {
        // CLI invoked from a terminal whose TBD_WORKTREE_ID points at a
        // worktree that's since been archived. Auto-parent silently falls
        // back to top-level instead of producing an invisible child.
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/r-\(UUID())", displayName: "R", defaultBranch: "main")
        let caller = try await db.worktrees.create(repoID: repo.id, name: "caller", branch: "tbd/caller", path: "/tmp/caller-\(UUID())", tmuxServer: "srv")
        try await db.worktrees.updateStatus(id: caller.id, status: .archived)

        let resolved = try await ParentResolver.resolve(
            db: db, explicitParent: nil, siblingOf: nil, caller: caller.id, suppressAutoParent: false
        )
        #expect(resolved == nil)
    }

    @Test func archivedSiblingFallsBackToFlat() async throws {
        // --sibling pointing at an archived worktree: silently fall back to
        // top-level instead of inheriting the archived row's (possibly also
        // archived) parent chain.
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/r-\(UUID())", displayName: "R", defaultBranch: "main")
        let s = try await db.worktrees.create(repoID: repo.id, name: "s", branch: "tbd/s", path: "/tmp/s-\(UUID())", tmuxServer: "srv")
        try await db.worktrees.updateStatus(id: s.id, status: .archived)

        let resolved = try await ParentResolver.resolve(
            db: db, explicitParent: nil, siblingOf: s.id, caller: nil, suppressAutoParent: false
        )
        #expect(resolved == nil)
    }
}
