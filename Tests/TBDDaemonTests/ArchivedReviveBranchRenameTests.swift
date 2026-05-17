import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// MARK: - Archive captures branch + SHA

@Test func testArchiveCapturesRenamedBranch() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(),
        tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

    let originalBranch = wt.branch

    // Rename the branch from inside the worktree (simulates user `git branch -m`).
    let newBranch = "renamed-\(UUID().uuidString.prefix(6))"
    try await shell("git branch -m \(newBranch)", at: URL(fileURLWithPath: wt.path))

    // Archive — should detect the rename and persist the new branch.
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    let archived = try await db.worktrees.get(id: wt.id)
    #expect(archived?.branch == newBranch)
    #expect(archived?.branch != originalBranch)
}

@Test func testArchiveCapturesHeadSHA() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(),
        tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

    let expectedSHA = try await GitManager().headSHA(worktreePath: wt.path)

    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    let archived = try await db.worktrees.get(id: wt.id)
    #expect(archived?.archivedHeadSHA == expectedSHA)
    #expect(archived?.archivedHeadSHA?.isEmpty == false)
}

// MARK: - Revive happy path / fallback / unrecoverable

@Test func testReviveUsesLiveBranchWhenPresent() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(),
        tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    let revived = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: true)
    #expect(revived.status == .active)
    #expect(FileManager.default.fileExists(atPath: revived.path))
}

@Test func testReviveFallsBackToSHAWhenBranchMissing() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(),
        tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
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
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(),
        tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
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
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let git = GitManager()
    let lifecycle = WorktreeLifecycle(
        db: db, git: git, tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    // Build a worktree, rename its branch in git, archive (the archive
    // capture will pick up the rename — so we then simulate the legacy buggy
    // state by rolling the DB branch back to the original name).
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    let originalBranch = wt.branch
    let renamedBranch = "renamed-\(UUID().uuidString.prefix(6))"
    try await shell("git branch -m \(renamedBranch)", at: URL(fileURLWithPath: wt.path))
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
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let git = GitManager()
    let lifecycle = WorktreeLifecycle(
        db: db, git: git, tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
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
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let git = GitManager()
    let lifecycle = WorktreeLifecycle(
        db: db, git: git, tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
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

// MARK: - Revive must --resume archived Claude sessions

/// Captures the argv tmux would have been invoked with so we can assert the
/// shell command body. Mirrors the recorder pattern in ModelProfileSpawnTests.
private final class TmuxArgvRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }
    func record(_ args: [String]) {
        lock.lock(); defer { lock.unlock() }
        _calls.append(args)
    }
    /// Last argv element of each call — the shell command body for new-window.
    var shellBodies: [String] { calls.compactMap { $0.last } }
}

@Test func testReviveSpawnsClaudeWithResumeFlag() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let recorder = TmuxArgvRecorder()
    let tmux = TmuxManager(dryRun: true, dryRunRecorder: { args in recorder.record(args) })
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()
    )
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    // Create + archive with skipClaude so create-side doesn't spawn anything.
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    // Seed an archived Claude session ID so the revive path believes there's
    // a conversation to resume.
    let sessionID = "AAAAAAAA-1111-2222-3333-444444444444"
    try await db.worktrees.setArchivedClaudeSessions(id: wt.id, sessions: [sessionID])

    // Revive with skipClaude=false so setupTerminals actually spawns claude.
    _ = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: false)

    // Find the new-window invocation whose shell body launches claude.
    let claudeBodies = recorder.shellBodies.filter { $0.contains("claude ") }
    #expect(!claudeBodies.isEmpty, "expected at least one claude spawn during revive; recorded: \(recorder.shellBodies)")

    let body = claudeBodies.first ?? ""
    #expect(body.contains("--resume \(sessionID)"),
            "revive should spawn claude with --resume <archivedSession>, got: \(body)")
    #expect(!body.contains("--session-id \(sessionID)"),
            "revive must NOT spawn claude with --session-id <archivedSession> (that's the bug — it starts a fresh session and loses the conversation), got: \(body)")
}

@Test func testReviveResumesEveryArchivedSession() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let recorder = TmuxArgvRecorder()
    let tmux = TmuxManager(dryRun: true, dryRunRecorder: { args in recorder.record(args) })
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()
    )
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    let sessionA = "AAAAAAAA-1111-2222-3333-444444444444"
    let sessionB = "BBBBBBBB-1111-2222-3333-444444444444"
    let sessionC = "CCCCCCCC-1111-2222-3333-444444444444"
    try await db.worktrees.setArchivedClaudeSessions(
        id: wt.id, sessions: [sessionA, sessionB, sessionC]
    )

    _ = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: false)

    let claudeBodies = recorder.shellBodies.filter { $0.contains("claude ") }
    // One per archived session — first via primary terminal, rest via dropFirst loop.
    #expect(claudeBodies.count == 3,
            "expected 3 claude spawns (one per archived session), got \(claudeBodies.count): \(claudeBodies)")
    for sid in [sessionA, sessionB, sessionC] {
        #expect(claudeBodies.contains { $0.contains("--resume \(sid)") },
                "missing --resume \(sid) in any claude spawn body; got: \(claudeBodies)")
        #expect(!claudeBodies.contains { $0.contains("--session-id \(sid)") },
                "should not spawn --session-id \(sid) on revive; got: \(claudeBodies)")
    }
}
