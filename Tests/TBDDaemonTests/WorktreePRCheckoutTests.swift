import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Task 2: PR-head checkout. Covers the GitManager primitive
/// (`fetchPullRequestHead` / `localBranchExists`) plus the lifecycle PR-create
/// dispatch, including the collision-safety guard that the `+` force refspec
/// must never clobber an unrelated pre-existing local branch of the same name.
@Suite struct WorktreePRCheckoutTests {

    /// Builds a bare "origin" carrying `refs/pull/<number>/head` at a commit
    /// that `main` does not contain, plus a fresh clone tracking it. Returns
    /// the clone's temp dir (caller owns cleanup), repo dir, and the pull-head
    /// SHA. Mirrors how GitHub exposes a PR: the commit is reachable only
    /// through the pull ref, not through any `refs/heads/*` branch.
    private func makePRFixture(number: Int) async throws -> (tempDir: URL, cloneRepoDir: URL, prSHA: String) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-pr-test-\(UUID().uuidString)")
        let remoteDir = parent.appendingPathComponent("remote.git")
        let sourceDir = parent.appendingPathComponent("source")
        let cloneTempDir = parent.appendingPathComponent("clone-host")
        let cloneRepoDir = cloneTempDir.appendingPathComponent("repo")
        for dir in [remoteDir, sourceDir, cloneTempDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        try await shell("git init --bare -b main", at: remoteDir)
        try await shell("git init -b main && git commit --allow-empty -m 'init'", at: sourceDir)
        try await shell("git remote add origin '\(remoteDir.path)' && git push origin main", at: sourceDir)
        // A PR-head commit main never gets: push it so its objects land in the
        // bare, then expose it ONLY through refs/pull/<n>/head and delete the
        // normal branch — exactly the shape of a fork/teammate PR.
        try await shell("git checkout -b prwork && git commit --allow-empty -m 'pr work'", at: sourceDir)
        try await shell("git push origin prwork", at: sourceDir)
        let prSHA = try await GitManager().headSHA(repoPath: sourceDir.path, ref: "prwork")
        try await shell("git update-ref refs/pull/\(number)/head \(prSHA)", at: remoteDir)
        try await shell("git update-ref -d refs/heads/prwork", at: remoteDir)

        try await shell("git clone '\(remoteDir.path)' '\(cloneRepoDir.path)'", at: cloneTempDir)
        return (cloneTempDir, cloneRepoDir, prSHA)
    }

    /// `localBranchExists` gates the force-refspec in `fetchPullRequestHead`,
    /// so it must fail CLOSED: only the benign "ref missing" exit-1 case may
    /// return `false`. A non-exit-1 failure (here: `show-ref` run inside a
    /// plain, non-git directory exits 128 with "fatal: not a git repository")
    /// must propagate as a thrown `GitError` instead of being reported as
    /// "branch absent".
    @Test func localBranchExistsThrowsOnNonRefMissingFailure() async throws {
        let notARepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-not-a-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: notARepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: notARepo) }

        let git = GitManager()
        await #expect(throws: GitError.self) {
            _ = try await git.localBranchExists(repoPath: notARepo.path, name: "whatever")
        }
    }

    @Test func fetchPullRequestHeadCreatesLocalBranchAtPullCommit() async throws {
        let (tempDir, cloneRepoDir, prSHA) = try await makePRFixture(number: 7)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let git = GitManager()
        let existsBefore = try await git.localBranchExists(repoPath: cloneRepoDir.path, name: "pr-7")
        #expect(existsBefore == false)

        try await git.fetchPullRequestHead(repoPath: cloneRepoDir.path, number: 7, localBranch: "pr-7")

        let existsAfter = try await git.localBranchExists(repoPath: cloneRepoDir.path, name: "pr-7")
        #expect(existsAfter == true)
        let sha = try await git.headSHA(repoPath: cloneRepoDir.path, ref: "refs/heads/pr-7")
        #expect(sha == prSHA)
    }

    @Test func createFromPRChecksOutPullHeadAndStampsNumber() async throws {
        let (tempDir, cloneRepoDir, prSHA) = try await makePRFixture(number: 7)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()
        )
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: cloneRepoDir)

        let wt = try await lifecycle.createWorktree(
            repoID: repo.id, branch: "feature-x", skipClaude: true,
            useExistingBranch: true, prNumber: 7, checkoutPRHead: true
        )

        #expect(wt.status == .active)
        #expect(wt.branch == "feature-x")
        #expect(wt.prNumber == 7)
        // Worktree HEAD sits on the pull-ref commit, not on main.
        let head = try await GitManager().headSHA(worktreePath: wt.path)
        #expect(head == prSHA)

        let stored = try #require(try await db.worktrees.get(id: wt.id))
        #expect(stored.prNumber == 7)
        // The contents came from refs/pull/7/head, which a fork may have
        // authored — the row must say so, or every later spawn/wake/revive
        // would pre-accept Claude's folder-trust dialog for it.
        #expect(stored.foreignHead == true)
    }

    @Test func createFromPRDoesNotClobberExistingLocalBranch() async throws {
        let (tempDir, cloneRepoDir, prSHA) = try await makePRFixture(number: 7)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Pre-existing, unrelated local branch sharing the PR head name. The
        // `+refs/pull/7/head:refs/heads/feature-x` refspec would force-rewrite
        // it — the lifecycle must uniquify the local branch name first.
        try await shell("git branch feature-x", at: cloneRepoDir)
        let originalSHA = try await GitManager().headSHA(repoPath: cloneRepoDir.path, ref: "refs/heads/feature-x")
        #expect(originalSHA != prSHA)

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()
        )
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: cloneRepoDir)

        let wt = try await lifecycle.createWorktree(
            repoID: repo.id, branch: "feature-x", skipClaude: true,
            useExistingBranch: true, prNumber: 7, checkoutPRHead: true
        )

        // Landed on the uniquified branch at the pull-ref commit...
        #expect(wt.branch == "feature-x-2")
        #expect(wt.prNumber == 7)
        let head = try await GitManager().headSHA(worktreePath: wt.path)
        #expect(head == prSHA)

        // ...and the original branch is untouched by the force refspec.
        let afterSHA = try await GitManager().headSHA(repoPath: cloneRepoDir.path, ref: "refs/heads/feature-x")
        #expect(afterSHA == originalSHA)
    }

    /// Decorated same-repo row: `prNumber` is set for status tracking, but
    /// `checkoutPRHead` is false, so selecting it must behave exactly like
    /// picking that existing branch — NO pull-ref fetch, NO `feature-x-2` clone.
    @Test func createFromDecoratedBranchRowChecksOutExistingBranch() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await shell("git branch feature-x", at: repoDir)
        let branchSHA = try await GitManager().headSHA(repoPath: repoDir.path, ref: "refs/heads/feature-x")

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()
        )
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        // prNumber stamped, checkoutPRHead omitted (defaults false).
        let wt = try await lifecycle.createWorktree(
            repoID: repo.id, branch: "feature-x", skipClaude: true,
            useExistingBranch: true, prNumber: 9
        )

        #expect(wt.status == .active)
        #expect(wt.branch == "feature-x")     // existing branch, not uniquified
        #expect(wt.prNumber == 9)             // still stamped for status tracking
        let head = try await GitManager().headSHA(worktreePath: wt.path)
        #expect(head == branchSHA)
        // No stray duplicate branch was created by a pull-ref fetch.
        let dupExists = try await GitManager().localBranchExists(repoPath: repoDir.path, name: "feature-x-2")
        #expect(dupExists == false)

        let listed = try await GitManager().worktreeList(repoPath: repoDir.path)
        #expect(listed.contains { $0.branch == "feature-x" && $0.path.hasSuffix("/feature-x") })

        // ...and because the contents are an ordinary same-repo branch, the row
        // is NOT foreign-head, so folder-trust seeding still applies to it.
        let stored = try #require(try await db.worktrees.get(id: wt.id))
        #expect(stored.foreignHead == false)
    }
}
