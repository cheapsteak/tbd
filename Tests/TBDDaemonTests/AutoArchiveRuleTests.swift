import Testing
import Foundation
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

// MARK: - Child-creation + reparent rules (no git repo needed)

@Suite struct AutoArchiveRuleTests {

    private func makeDB() throws -> TBDDatabase {
        try TBDDatabase(inMemory: true)
    }

    private func makeLifecycle(db: TBDDatabase) -> WorktreeLifecycle {
        WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(dryRun: true),
            hooks: HookResolver()
        )
    }

    // MARK: - Child-creation disarms parent

    /// Creating a child worktree with an explicit parent should flip the
    /// parent's autoArchiveOnMerge override to false (disarm it).
    @Test func creatingChildDisarmsParent() async throws {
        let db = try makeDB()
        let repo = try await db.repos.create(
            path: "/tmp/repoG-\(UUID().uuidString)", displayName: "repoG", defaultBranch: "main")
        let parent = try await db.worktrees.create(
            repoID: repo.id, name: "p", branch: "bp",
            path: "/tmp/repoG/p-\(UUID().uuidString)", tmuxServer: "s")
        try await db.worktrees.setAutoArchiveOnMerge(id: parent.id, value: true)

        let lifecycle = makeLifecycle(db: db)
        _ = try await lifecycle.beginCreateWorktree(
            repoID: repo.id,
            parentWorktreeID: parent.id)

        let after = try await db.worktrees.get(id: parent.id)
        #expect(after?.autoArchiveOnMerge == false,
                "parent armed with auto-archive must be disarmed when a child is created")
    }

    /// Creating a worktree without a parent should not affect an unrelated armed
    /// worktree in the same repo.
    @Test func creatingWorktreeWithoutParentPreservesOtherArmedWorktrees() async throws {
        let db = try makeDB()
        let repo = try await db.repos.create(
            path: "/tmp/repoG2-\(UUID().uuidString)", displayName: "repoG2", defaultBranch: "main")
        let unrelated = try await db.worktrees.create(
            repoID: repo.id, name: "u", branch: "bu",
            path: "/tmp/repoG2/u-\(UUID().uuidString)", tmuxServer: "s")
        try await db.worktrees.setAutoArchiveOnMerge(id: unrelated.id, value: true)

        let lifecycle = makeLifecycle(db: db)
        _ = try await lifecycle.beginCreateWorktree(
            repoID: repo.id,
            suppressAutoParent: true)

        let after = try await db.worktrees.get(id: unrelated.id)
        #expect(after?.autoArchiveOnMerge == true,
                "an unrelated armed worktree must remain armed when no parent is resolved")
    }

    // MARK: - Reparent disarms new parent

    /// Moving a child under a new parent via the RPC handler should disarm
    /// the new parent's auto-archive setting.
    @Test func reparentingDisarmsNewParent() async throws {
        let db = try makeDB()
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date()
        )

        let repo = try await db.repos.create(
            path: "/tmp/repoI-\(UUID().uuidString)", displayName: "repoI", defaultBranch: "main")
        let newParent = try await db.worktrees.create(
            repoID: repo.id, name: "np", branch: "bnp",
            path: "/tmp/repoI/np-\(UUID().uuidString)", tmuxServer: "s")
        let child = try await db.worktrees.create(
            repoID: repo.id, name: "c", branch: "bc",
            path: "/tmp/repoI/c-\(UUID().uuidString)", tmuxServer: "s")
        try await db.worktrees.setAutoArchiveOnMerge(id: newParent.id, value: true)

        let request = try RPCRequest(
            method: RPCMethod.worktreeMove,
            params: WorktreeMoveParams(
                worktreeID: child.id,
                newParentID: newParent.id,
                newSortOrder: 0))
        let response = await router.handle(request)
        #expect(response.success, "worktree.move RPC must succeed")

        let after = try await db.worktrees.get(id: newParent.id)
        #expect(after?.autoArchiveOnMerge == false,
                "new parent armed with auto-archive must be disarmed when a child is moved under it")
    }

    /// Moving a worktree to top-level (newParentID = nil) should not disarm
    /// any worktree.
    @Test func movingToTopLevelDoesNotDisarmAnything() async throws {
        let db = try makeDB()
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date()
        )

        let repo = try await db.repos.create(
            path: "/tmp/repoJ-\(UUID().uuidString)", displayName: "repoJ", defaultBranch: "main")
        let oldParent = try await db.worktrees.create(
            repoID: repo.id, name: "op", branch: "bop",
            path: "/tmp/repoJ/op-\(UUID().uuidString)", tmuxServer: "s")
        let child = try await db.worktrees.create(
            repoID: repo.id, name: "c", branch: "bc",
            path: "/tmp/repoJ/c-\(UUID().uuidString)", tmuxServer: "s",
            parentWorktreeID: oldParent.id)
        try await db.worktrees.setAutoArchiveOnMerge(id: oldParent.id, value: true)

        let request = try RPCRequest(
            method: RPCMethod.worktreeMove,
            params: WorktreeMoveParams(
                worktreeID: child.id,
                newParentID: nil,
                newSortOrder: 0))
        let response = await router.handle(request)
        #expect(response.success, "worktree.move to top-level must succeed")

        let after = try await db.worktrees.get(id: oldParent.id)
        #expect(after?.autoArchiveOnMerge == true,
                "old parent must remain armed when child is moved to top-level (no new parent)")
    }
}

// MARK: - Revive disarms worktree (requires real git repo)

@Test func reviveDisarmsWorktree() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    // Create and archive a worktree, then arm it.
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    try await db.worktrees.setAutoArchiveOnMerge(id: wt.id, value: true)
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    // Revive it — this should disarm the auto-archive flag.
    let revived = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: true)

    #expect(revived.status == .active)
    let after = try await db.worktrees.get(id: wt.id)
    #expect(after?.autoArchiveOnMerge == false,
            "reviving a worktree must disarm its auto-archive flag so a still-merged PR can't re-archive it immediately")
}
