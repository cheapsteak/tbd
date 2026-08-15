import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2 (real git subprocesses, real filesystem, no tmux — `dryRun: true`).
///
/// Covers what a *failed* revive leaves behind. Revive re-adds the git worktree
/// two ways, and only one of them creates a branch:
///
/// - the branch still exists → `git worktree add <path> <branch>` checks out a
///   branch the user owns, so nothing there is ours to delete;
/// - the branch is gone → `git worktree add -b <branch> <path> <sha>` recreates
///   it from the archived HEAD, the fourth `-b` call site in the lifecycle and
///   the same create-then-fail-later shape the create path had to be fixed for.
///
/// The failure is induced with a `post-checkout` hook that exits 1 — a real
/// repo-level thing (LFS, direnv, and friends install one) and, verified
/// against git 2.50, the shape that leaks the most: git creates the branch,
/// writes the directory, registers the worktree, runs the hook, and exits 1
/// with all three standing. It is also what makes the cleanup's
/// `worktree prune` load-bearing here — `git branch -D` refuses a branch a live
/// registration claims ("cannot delete branch 'x' used by worktree at …").
@Suite struct WorktreeReviveFailureCleanupTests {

    /// Makes every `git worktree add` in `repoDir` fail *after* git has created
    /// the branch, the directory and the registration.
    private func installFailingPostCheckoutHook(_ repoDir: URL) throws {
        let hook = repoDir.appendingPathComponent(".git/hooks/post-checkout")
        try "#!/bin/sh\necho 'post-checkout veto' >&2\nexit 1\n"
            .write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: hook.path
        )
    }

    /// Every local branch. Deliberately not `listBranches`, which filters out
    /// branches checked out in a worktree — exactly the ones these tests need
    /// to see.
    private func localBranches(_ repoDir: URL) async throws -> [String] {
        try await GitManager()
            .listRefs(repoPath: repoDir.path, prefix: "refs/heads")
            .map { String($0.dropFirst("refs/heads/".count)) }
    }

    private func makeLifecycle(db: TBDDatabase) -> WorktreeLifecycle {
        WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()
        )
    }

    /// A created-then-archived worktree, which is how a row acquires the
    /// `archivedHeadSHA` the recreate leg needs.
    private func makeArchivedWorktree(
        lifecycle: WorktreeLifecycle, repoID: UUID
    ) async throws -> Worktree {
        let worktree = try await lifecycle.createWorktree(repoID: repoID, skipClaude: true)
        try await lifecycle.archiveWorktree(worktreeID: worktree.id, force: true)
        return worktree
    }

    // MARK: - The archived-SHA recreate leg

    /// The bug: `worktreeAddNewBranch` creates `<branch>` and a failure after
    /// that used to leak the branch, the directory and the registration, with no
    /// cleanup at any layer — strictly worse than a failed *create*, which at
    /// least removed the directory.
    ///
    /// Red against the unfixed tree, on all three:
    ///   ✘ the failed recreate leaked the branch it made: ["main", "tbd/…"]
    ///   ✘ the failed recreate left a directory at …/tbd/worktrees/…/…
    ///   ✘ stray worktree registrations: ["…/repo", "…/tbd/worktrees/…"]
    @Test func failedRecreateFromArchivedSHALeavesNothingBehind() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let archived = try await makeArchivedWorktree(lifecycle: lifecycle, repoID: repo.id)

        // Point the row at a branch git does not have, so the revive takes the
        // archived-SHA leg. The same shape as a branch renamed or deleted
        // between archive and revive, without racing the archive's own capture.
        let missingBranch = "tbd/deleted-before-revive"
        try await db.worktrees.updateBranch(id: archived.id, branch: missingBranch)
        try installFailingPostCheckoutHook(repoDir)

        do {
            _ = try await lifecycle.reviveWorktree(worktreeID: archived.id, skipClaude: true)
            Issue.record("expected the post-checkout veto to fail the revive")
        } catch {
            #expect(String(describing: error).contains("post-checkout veto"),
                    "the revive failed for an unexpected reason: \(error)")
        }

        let branches = try await localBranches(repoDir)
        #expect(!branches.contains(missingBranch),
                "the failed recreate leaked the branch it made: \(branches)")
        #expect(!FileManager.default.fileExists(atPath: archived.localPath),
                "the failed recreate left a directory at \(archived.localPath)")
        let listed = try await GitManager().worktreeList(repoPath: repoDir.path)
        #expect(listed.count == 1, "stray worktree registrations: \(listed.map(\.path))")
    }

    /// The success arm of the same conditional: a recreate that works keeps the
    /// branch it just made and the checkout it just wrote.
    ///
    /// Asserts preserved behavior, so it is mutation-checked: running
    /// `cleanUpFailedWorktreeAdd` unconditionally after the recreate (rather
    /// than only from its `catch`) deletes the fresh branch and the directory,
    /// and this fails on both.
    @Test func successfulRecreateFromArchivedSHAKeepsItsNewBranch() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let archived = try await makeArchivedWorktree(lifecycle: lifecycle, repoID: repo.id)

        let missingBranch = "tbd/deleted-before-revive"
        try await db.worktrees.updateBranch(id: archived.id, branch: missingBranch)

        let revived = try await lifecycle.reviveWorktree(
            worktreeID: archived.id, skipClaude: true
        )

        #expect(revived.status == .active)
        #expect(FileManager.default.fileExists(atPath: revived.localPath),
                "the revive reported success without a checkout at \(revived.localPath)")
        let branches = try await localBranches(repoDir)
        #expect(branches.contains(missingBranch),
                "the successful recreate lost the branch it made: \(branches)")
    }

    // MARK: - The existing-branch leg

    /// The hard constraint: this leg checks out a branch the user owns and
    /// creates nothing, so a failure must delete nothing — while still removing
    /// the directory git left, which is the half nobody was doing.
    ///
    /// Half red against the unfixed tree, half mutation-checked. Red half:
    ///   ✘ the failed checkout left a directory at …/tbd/worktrees/…/…
    /// The branch half asserts preserved behavior — the unfixed tree deletes no
    /// branches on this path at all — so it is mutation-checked instead:
    /// routing this leg's `catch` through `cleanUpFailedWorktreeAdd(
    /// branchPreExisted: false, branchNameWasAlreadyTaken: false)`, the obvious
    /// treat-both-legs-alike version of this fix, makes it fail.
    @Test func failedCheckoutOfAnExistingBranchKeepsTheUsersBranch() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        // Archiving leaves the branch standing, which is what routes the revive
        // through `worktreeAddExisting`.
        let archived = try await makeArchivedWorktree(lifecycle: lifecycle, repoID: repo.id)
        #expect(try await localBranches(repoDir).contains(archived.branch),
                "fixture: the archive was expected to leave the branch behind")
        try installFailingPostCheckoutHook(repoDir)

        do {
            _ = try await lifecycle.reviveWorktree(worktreeID: archived.id, skipClaude: true)
            Issue.record("expected the post-checkout veto to fail the revive")
        } catch {
            #expect(String(describing: error).contains("post-checkout veto"),
                    "the revive failed for an unexpected reason: \(error)")
        }

        let branches = try await localBranches(repoDir)
        #expect(branches.contains(archived.branch),
                "the failed checkout deleted the user's branch: \(branches)")
        #expect(!FileManager.default.fileExists(atPath: archived.localPath),
                "the failed checkout left a directory at \(archived.localPath)")
    }
}
