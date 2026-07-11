import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Task 8: `WorktreeLifecycle.onWorktreeRemoved` fires whenever a worktree's
/// directory is actually removed from disk, so `OrphanGC.scratchpadCleanup`
/// can run event-driven instead of waiting for the next hourly sweep.
@Suite struct ArchiveScratchpadCleanupTests {
    @Test func archiveWorktreeFiresOnWorktreeRemovedWithThePath() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        var lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(dryRun: true),
            hooks: HookResolver()
        )
        let box = RemovedPathBox()
        lifecycle.onWorktreeRemoved = { path, repoPath in await box.record(path, repoPath) }

        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
        #expect(FileManager.default.fileExists(atPath: wt.path))

        try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

        #expect(!FileManager.default.fileExists(atPath: wt.path))
        #expect(await box.paths == [wt.path])
        #expect(await box.repoPaths == [repo.path], "must thread the owning repo's path alongside the worktree path")
    }

    @Test func archiveWorktreeWithoutCallbackStillArchives() async throws {
        // No `onWorktreeRemoved` set (nil default) — archive must not crash
        // or otherwise depend on the callback being present.
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
        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

        try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

        let archived = try await db.worktrees.get(id: wt.id)
        #expect(archived?.status == .archived)
    }

    @Test func forgetWorktreeDoesNotFireOnWorktreeRemoved() async throws {
        // `forget` deliberately leaves the directory on disk (no git worktree
        // remove), so it must NOT trigger scratchpad cleanup.
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        var lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(dryRun: true),
            hooks: HookResolver()
        )
        let box = RemovedPathBox()
        lifecycle.onWorktreeRemoved = { path, repoPath in await box.record(path, repoPath) }

        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

        try await lifecycle.forgetWorktree(worktreeID: wt.id)

        #expect(await box.paths.isEmpty)
    }
}

actor RemovedPathBox {
    private(set) var paths: [String] = []
    private(set) var repoPaths: [String] = []
    func record(_ path: String, _ repoPath: String) {
        paths.append(path)
        repoPaths.append(repoPath)
    }
}
