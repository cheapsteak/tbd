import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Helpers (private to this file to avoid colliding with helpers in
// WorktreeLifecycleTests, which are file-private over there).

private func sh(_ command: String, at dir: URL) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    process.currentDirectoryURL = dir
    process.environment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin",
        "HOME": NSHomeDirectory(),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_AUTHOR_NAME": "Test",
        "GIT_AUTHOR_EMAIL": "test@test.com",
        "GIT_COMMITTER_NAME": "Test",
        "GIT_COMMITTER_EMAIL": "test@test.com",
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        throw NSError(domain: "shell", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "\(command)\n\(output)"])
    }
}

private func makeRepo() async throws -> (tempDir: URL, repoDir: URL) {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-test-\(UUID().uuidString)")
    let repoDir = tempDir.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    try await sh("git init -b main && git commit --allow-empty -m 'init'", at: repoDir)
    return (tempDir, repoDir)
}

private func makeRepoRow(db: TBDDatabase, tempDir: URL, repoDir: URL) async throws -> Repo {
    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )
    let override = tempDir.appendingPathComponent(".tbd/worktrees").path
    try await db.repos.updateWorktreeRoot(id: repo.id, path: override)
    return try await db.repos.get(id: repo.id)!
}

// MARK: - Archive captures branch + SHA

@Test func testArchiveCapturesRenamedBranch() async throws {
    let (tempDir, repoDir) = try await makeRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(),
        tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await makeRepoRow(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

    let originalBranch = wt.branch

    // Rename the branch from inside the worktree (simulates user `git branch -m`).
    let newBranch = "renamed-\(UUID().uuidString.prefix(6))"
    try await sh("git branch -m \(newBranch)", at: URL(fileURLWithPath: wt.path))

    // Archive — should detect the rename and persist the new branch.
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    let archived = try await db.worktrees.get(id: wt.id)
    #expect(archived?.branch == newBranch)
    #expect(archived?.branch != originalBranch)
}

@Test func testArchiveCapturesHeadSHA() async throws {
    let (tempDir, repoDir) = try await makeRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(),
        tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await makeRepoRow(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

    let expectedSHA = try await GitManager().headSHA(worktreePath: wt.path)

    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    let archived = try await db.worktrees.get(id: wt.id)
    #expect(archived?.archivedHeadSHA == expectedSHA)
    #expect(archived?.archivedHeadSHA?.isEmpty == false)
}

// MARK: - Revive happy path / fallback / unrecoverable

@Test func testReviveUsesLiveBranchWhenPresent() async throws {
    let (tempDir, repoDir) = try await makeRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(),
        tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await makeRepoRow(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    let revived = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: true)
    #expect(revived.status == .active)
    #expect(FileManager.default.fileExists(atPath: revived.path))
}

@Test func testReviveFallsBackToSHAWhenBranchMissing() async throws {
    let (tempDir, repoDir) = try await makeRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(),
        tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await makeRepoRow(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

    // Capture SHA before archive.
    let sha = try await GitManager().headSHA(worktreePath: wt.path)

    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    // Now mutate the DB row: rename the branch in the DB to a value that
    // doesn't exist in git, leaving archivedHeadSHA intact. This simulates
    // the buggy case where the user renamed before archive but archive
    // captured the renamed name correctly — except later that branch was
    // also deleted (or here, was never created). To trigger the SHA
    // fallback path we need the DB branch to NOT exist in git.
    let bogus = "tbd/never-existed-\(UUID().uuidString.prefix(6))"
    try await db.worktrees.updateBranch(id: wt.id, branch: bogus)
    try await db.worktrees.updateArchivedHeadSHA(id: wt.id, sha: sha)

    let revived = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: true)
    #expect(revived.status == .active)
    #expect(FileManager.default.fileExists(atPath: revived.path))

    // The new worktree should be on the (newly created) bogus branch, with HEAD == sha.
    let revivedSHA = try await GitManager().headSHA(worktreePath: revived.path)
    #expect(revivedSHA == sha)
}

@Test func testReviveThrowsBranchMissingNoFallback() async throws {
    let (tempDir, repoDir) = try await makeRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(),
        tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await makeRepoRow(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    // Wipe both the branch (rename to something non-existent) and the SHA.
    let bogus = "tbd/never-existed-\(UUID().uuidString.prefix(6))"
    try await db.worktrees.updateBranch(id: wt.id, branch: bogus)
    try await db.worktrees.updateArchivedHeadSHA(id: wt.id, sha: nil)

    do {
        _ = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: true)
        Issue.record("expected branchMissingNoFallback to throw")
    } catch let error as WorktreeLifecycleError {
        guard case .branchMissingNoFallback(let branch) = error else {
            Issue.record("wrong WorktreeLifecycleError case: \(error)")
            return
        }
        #expect(branch == bogus)
        let desc = error.localizedDescription
        #expect(desc.contains(bogus))
        #expect(desc.lowercased().contains("branch"))
    }
}

// MARK: - Backfill

@Test func testBackfillReflogParser() {
    let sample = """
    abc123 commit: hello
    def456 Branch: renamed refs/heads/old-name to refs/heads/new-name
    111222 Branch: renamed refs/heads/another-old to refs/heads/another-new
    333444 commit: unrelated
    """
    let map = ArchivedWorktreeBackfill.parseReflogRenames(sample)
    #expect(map["old-name"] == "new-name")
    #expect(map["another-old"] == "another-new")
    #expect(map.count == 2)
}

@Test func testBackfillRepairsRenamedBranch() async throws {
    let (tempDir, repoDir) = try await makeRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let git = GitManager()
    let lifecycle = WorktreeLifecycle(
        db: db, git: git, tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await makeRepoRow(db: db, tempDir: tempDir, repoDir: repoDir)

    // Build a worktree, rename its branch in git, archive (the archive
    // capture will pick up the rename — so we then simulate the legacy buggy
    // state by rolling the DB branch back to the original name).
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    let originalBranch = wt.branch
    let renamedBranch = "renamed-\(UUID().uuidString.prefix(6))"
    try await sh("git branch -m \(renamedBranch)", at: URL(fileURLWithPath: wt.path))
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    // Roll the DB row back so it has the *old* branch name. This mimics the
    // legacy bug where archive ran on rows whose branch was already stale.
    try await db.worktrees.updateBranch(id: wt.id, branch: originalBranch)
    try await db.worktrees.updateArchivedHeadSHA(id: wt.id, sha: nil)

    let backfill = ArchivedWorktreeBackfill(db: db, git: git)
    await backfill.run()

    let repaired = try await db.worktrees.get(id: wt.id)
    #expect(repaired?.branch == renamedBranch)
    #expect(repaired?.archivedHeadSHA != nil)
    #expect(repaired?.archivedHeadSHA?.isEmpty == false)

    // Idempotency: a second run should not change anything.
    let beforeSecond = repaired
    await backfill.run()
    let afterSecond = try await db.worktrees.get(id: wt.id)
    #expect(afterSecond?.branch == beforeSecond?.branch)
    #expect(afterSecond?.archivedHeadSHA == beforeSecond?.archivedHeadSHA)
}

@Test func testBackfillLeavesUnrecoverableRows() async throws {
    let (tempDir, repoDir) = try await makeRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let git = GitManager()
    let lifecycle = WorktreeLifecycle(
        db: db, git: git, tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await makeRepoRow(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    // Smash the branch to something that never appears anywhere in the reflog.
    let bogus = "tbd/never-existed-\(UUID().uuidString.prefix(6))"
    try await db.worktrees.updateBranch(id: wt.id, branch: bogus)
    let priorSHA = try await db.worktrees.get(id: wt.id)?.archivedHeadSHA

    let backfill = ArchivedWorktreeBackfill(db: db, git: git)
    await backfill.run()

    // Branch should remain bogus — backfill never deletes or invents.
    let after = try await db.worktrees.get(id: wt.id)
    #expect(after?.branch == bogus)
    #expect(after?.archivedHeadSHA == priorSHA)
}

@Test func testBackfillNoOpForValidRows() async throws {
    let (tempDir, repoDir) = try await makeRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let git = GitManager()
    let lifecycle = WorktreeLifecycle(
        db: db, git: git, tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await makeRepoRow(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    let beforeBranch = try await db.worktrees.get(id: wt.id)?.branch
    let beforeSHA = try await db.worktrees.get(id: wt.id)?.archivedHeadSHA

    let backfill = ArchivedWorktreeBackfill(db: db, git: git)
    await backfill.run()

    let after = try await db.worktrees.get(id: wt.id)
    #expect(after?.branch == beforeBranch)
    #expect(after?.archivedHeadSHA == beforeSHA)
}
