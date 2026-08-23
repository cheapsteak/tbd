import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Branching-conditional test coverage for the `useExistingBranch` flag on
/// `WorktreeLifecycle.createWorktree`. Per CLAUDE.md: when a new conditional
/// gates behavior, every branch needs its own test.
///
/// Three branches are exercised:
/// 1. `useExistingBranch: false` — current behavior preserved (creates `tbd/<name>`).
/// 2. `useExistingBranch: true` + local branch — checks out existing branch, no `-b`.
/// 3. `useExistingBranch: true` + `origin/<name>` ref — creates a local tracking branch.

@Test func testCreateWorktreeDoesNotUseExistingBranchByDefault() async throws {
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

    // useExistingBranch defaults to false — behavior is identical to the
    // legacy create flow: a fresh `tbd/<auto-name>` branch is created.
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    #expect(wt.status == .active)
    #expect(wt.branch.hasPrefix("tbd/"))
    #expect(FileManager.default.fileExists(atPath: wt.localPath))
}

@Test func testCreateWorktreeUsesExistingLocalBranch() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // Pre-seed a local branch that the new worktree will check out.
    try await shell("git branch existing-feature", at: repoDir)

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    let wt = try await lifecycle.createWorktree(
        repoID: repo.id,
        branch: "existing-feature",
        skipClaude: true,
        useExistingBranch: true
    )

    #expect(wt.status == .active)
    // The stored branch is the existing one — NOT prefixed with `tbd/`.
    #expect(wt.branch == "existing-feature")
    #expect(!wt.branch.hasPrefix("tbd/"))
    // Folder name is derived from the branch's local name (sanitized).
    #expect(wt.name == "existing-feature")
    #expect(FileManager.default.fileExists(atPath: wt.localPath))

    // Verify git also reports the worktree on the existing branch.
    // Path comparison uses `hasSuffix` because macOS resolves the temp dir
    // through a symlink (`/var/folders` → `/private/var/folders`) — git
    // reports the resolved path while the DB row keeps the unresolved one.
    let listed = try await GitManager().worktreeList(repoPath: repoDir.path)
    #expect(listed.contains { entry in
        entry.branch == "existing-feature" && entry.path.hasSuffix("/existing-feature")
    })
}

@Test func testCreateWorktreeFromRemoteRefCreatesTrackingBranch() async throws {
    // Spin up a bare "remote" repo and push a branch to it, then exercise
    // the `origin/<name>` path on a fresh clone.
    let parentDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-remote-test-\(UUID().uuidString)")
    let remoteDir = parentDir.appendingPathComponent("remote.git")
    let cloneTempDir = parentDir.appendingPathComponent("clone-host")
    let cloneRepoDir = cloneTempDir.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: cloneTempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parentDir) }

    try await shell("git init --bare -b main", at: remoteDir)

    // Seed source repo: create main, then a feature branch with one commit,
    // then push both to the bare remote.
    let sourceDir = parentDir.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    try await shell("git init -b main && git commit --allow-empty -m 'init'", at: sourceDir)
    try await shell("git checkout -b remote-feature && git commit --allow-empty -m 'feature work'", at: sourceDir)
    try await shell("git remote add origin '\(remoteDir.path)'", at: sourceDir)
    try await shell("git push origin main remote-feature", at: sourceDir)

    // Clone into the test repo (mirrors what a user would do).
    try await shell("git clone '\(remoteDir.path)' '\(cloneRepoDir.path)'", at: cloneTempDir)

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(
        db: db, tempDir: cloneTempDir, repoDir: cloneRepoDir
    )

    let wt = try await lifecycle.createWorktree(
        repoID: repo.id,
        branch: "origin/remote-feature",
        skipClaude: true,
        useExistingBranch: true
    )

    #expect(wt.status == .active)
    // Stored branch is the LOCAL tracking branch name (no `origin/` prefix).
    #expect(wt.branch == "remote-feature")
    #expect(wt.name == "remote-feature")
    #expect(FileManager.default.fileExists(atPath: wt.localPath))

    // Verify a local tracking branch was created and is what the worktree
    // is checked out on. See the path-suffix note in the local-branch test.
    let listed = try await GitManager().worktreeList(repoPath: cloneRepoDir.path)
    #expect(listed.contains { entry in
        entry.branch == "remote-feature" && entry.path.hasSuffix("/remote-feature")
    })
    let upstream = await GitManager().upstreamBranchName(
        worktreePath: wt.localPath,
        branch: wt.branch
    )
    #expect(upstream == "remote-feature")
}

@Test func testCreateWorktreeForExistingBranchDeDupesAgainstArchivedRowPath() async throws {
    // Regression: re-opening an existing branch whose PREVIOUS worktree was
    // archived must not collide with the archived row's `path` (the
    // `worktree.localPath` column is globally UNIQUE, including archived rows).
    // Archived worktrees keep their `path` but have no directory on disk, so
    // the old filesystem-only uniqueness check returned the base name
    // unchanged and the insert threw `UNIQUE constraint failed: worktree.localPath`.
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try await shell("git branch existing-feature", at: repoDir)

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    // Simulate the archived previous worktree: a row whose `path` is exactly
    // what beginCreateWorktree would compute for `existing-feature`, archived,
    // with NO directory on disk.
    let layout = WorktreeLayout()
    let basePath = layout.basePath(for: repo)
    let archivedPath = (basePath as NSString).appendingPathComponent("existing-feature")
    #expect(!FileManager.default.fileExists(atPath: archivedPath))
    _ = try await db.worktrees.create(
        repoID: repo.id,
        name: "existing-feature",
        branch: "existing-feature",
        path: archivedPath,
        tmuxServer: "tbd-test",
        status: .archived
    )

    // Re-open the same branch. This must NOT throw and must pick a de-duped
    // folder name distinct from the archived row's path.
    let pending = try await lifecycle.beginCreateWorktree(
        repoID: repo.id,
        branch: "existing-feature",
        skipClaude: true,
        useExistingBranch: true
    )
    #expect(pending.name == "existing-feature-2")
    #expect(pending.localPath != archivedPath)
    #expect(pending.localPath.hasSuffix("/existing-feature-2"))

    // Drive completion and confirm the worktree goes active with a real
    // checkout at the de-duped path.
    let completion = try await lifecycle.completeCreateWorktree(
        worktreeID: pending.id,
        skipClaude: true,
        existingBranchRef: "existing-feature"
    )
    if case .preSessionPending(let phase3) = completion {
        await phase3.value
    }
    let completed = try #require(try await db.worktrees.get(id: pending.id))
    #expect(completed.status == .active)
    #expect(FileManager.default.fileExists(atPath: completed.localPath))

    let listed = try await GitManager().worktreeList(repoPath: repoDir.path)
    #expect(listed.contains { entry in
        entry.branch == "existing-feature" && entry.path.hasSuffix("/existing-feature-2")
    })
}

@Test func testCreateWorktreeWithExistingBranchFolderConflictAppendsSuffix() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // Two local branches sharing a sanitized folder name.
    try await shell("git branch feature/auth-refactor", at: repoDir)
    try await shell("git branch feature/auth-refactor-other", at: repoDir)

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    let first = try await lifecycle.createWorktree(
        repoID: repo.id,
        branch: "feature/auth-refactor",
        skipClaude: true,
        useExistingBranch: true
    )
    // `feature/auth-refactor` -> sanitized `feature-auth-refactor`.
    #expect(first.name == "feature-auth-refactor")

    // Pre-create a stray directory that collides with the next sanitized name
    // so the suffix path runs even though the branches differ.
    let layout = WorktreeLayout()
    let basePath = layout.basePath(for: repo)
    let collidingPath = (basePath as NSString).appendingPathComponent("feature-auth-refactor-other")
    try FileManager.default.createDirectory(atPath: collidingPath, withIntermediateDirectories: true)

    let second = try await lifecycle.createWorktree(
        repoID: repo.id,
        branch: "feature/auth-refactor-other",
        skipClaude: true,
        useExistingBranch: true
    )
    // The conflict-resolver appends `-2`, `-3`, etc.
    #expect(second.name == "feature-auth-refactor-other-2")
    #expect(second.branch == "feature/auth-refactor-other")
}


// MARK: - Named branch that already exists, WITHOUT `useExistingBranch`
//
// The `useExistingBranch` flag above is the deliberate, opt-in path. These
// cover the accidental one: `tbd worktree create --branch <name>` where the
// branch happens to already exist locally — which is every branch that already
// has a PR, i.e. the normal case when spawning a session onto existing work.
//
// It used to fail with "Worktree creation failed (see daemon logs)". Cause was
// `git worktree add -b <branch>`, fatal when the ref exists; all four attempts
// (two base branches, then both again after the folder-rename retry, which
// keeps a user-specified branch) hit the same wall.

@Test func testNamedExistingBranchIsCheckedOutWithoutTheFlag() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try await shell("git branch already-here", at: repoDir)

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    // Note: no `useExistingBranch`. This is the plain create path.
    let wt = try await lifecycle.createWorktree(
        repoID: repo.id, branch: "already-here", skipClaude: true
    )

    #expect(wt.status == .active)
    #expect(wt.branch == "already-here", "should have adopted the existing branch, not renamed around it")
    #expect(FileManager.default.fileExists(atPath: wt.localPath))

    let listed = try await GitManager().worktreeList(repoPath: repoDir.path)
    #expect(listed.contains { $0.branch == "already-here" })
}

/// The other side of the same gate: a named branch that does NOT exist still
/// takes the create-it path. Without this, "always check out" would silently
/// replace worktree creation with worktree adoption.
@Test func testNamedAbsentBranchIsStillCreated() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    let wt = try await lifecycle.createWorktree(
        repoID: repo.id, branch: "brand-new-branch", skipClaude: true
    )

    #expect(wt.status == .active)
    #expect(wt.branch == "brand-new-branch")
    let listed = try await GitManager().worktreeList(repoPath: repoDir.path)
    #expect(listed.contains { $0.branch == "brand-new-branch" })
}

/// Branch exists but is already checked out somewhere else — git refuses, and
/// the point of the fix is that its stderr survives into the thrown error,
/// because that stderr names the directory holding the branch. A bare
/// "creation failed" leaves the user hunting for a path the tool already knew.
@Test func testBranchCheckedOutElsewhereReportsTheHoldingPath() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try await shell("git branch contested", at: repoDir)

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    let first = try await lifecycle.createWorktree(
        repoID: repo.id, branch: "contested", skipClaude: true
    )
    #expect(first.status == .active)

    await #expect(throws: WorktreeLifecycleError.self) {
        _ = try await lifecycle.createWorktree(
            repoID: repo.id, folder: "second-take", branch: "contested", skipClaude: true
        )
    }

    do {
        _ = try await lifecycle.createWorktree(
            repoID: repo.id, folder: "third-take", branch: "contested", skipClaude: true
        )
        Issue.record("expected a second checkout of 'contested' to fail")
    } catch {
        let text = String(describing: error)
        #expect(text.contains("contested"), "error does not name the branch: \(text)")
        #expect(text.contains("already used by worktree"),
                "git's stderr was swallowed; it is what names the holding directory: \(text)")
    }
}
