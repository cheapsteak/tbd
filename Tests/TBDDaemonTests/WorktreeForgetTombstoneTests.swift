import Foundation
import GRDB
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The forget-tombstone feature: `forget` inserts a `forgotten_worktree` row
/// keyed by path, and reconcile skips tombstoned paths in its re-adopt pass —
/// so forgetting a worktree under a TBD-managed prefix finally sticks.
///
/// Branch coverage for the new gating conditional in reconcile:
///   - tombstone present  → path NOT re-adopted (the bug this feature fixes).
///   - tombstone absent   → path IS adopted (ungated behavior intact).
/// Plus the escape hatch: adopt/create at a tombstoned path clears the
/// tombstone, restoring normal reconcile behavior.
///
/// Uses `createTestRepoResolvingSymlinks` throughout: reconcile compares DB
/// paths against `git worktree list` output, which reports realpath()-resolved
/// paths (/private/var/... on macOS).

private func makeLifecycle(db: TBDDatabase) -> WorktreeLifecycle {
    WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )
}

/// The bug this feature fixes: a forgotten worktree under a TBD-managed prefix
/// must NOT be resurrected by the next reconcile pass.
@Test func testForgetSticksThroughReconcileForManagedPrefix() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = makeLifecycle(db: db)
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    // Created under the repo's worktreeRoot override → an acceptable prefix
    // for reconcile's re-adopt pass.
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    #expect(FileManager.default.fileExists(atPath: wt.localPath))

    try await lifecycle.forgetWorktree(worktreeID: wt.id)
    #expect(try await db.forgottenWorktrees.contains(path: wt.localPath),
            "forget must insert a tombstone for the worktree path")

    // The directory is still on disk AND still registered with git — exactly
    // the situation that used to make reconcile resurrect the row.
    try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog(), reapSharedScratchTmuxResources: true)

    let active = try await db.worktrees.list(repoID: repo.id, status: .active)
    #expect(!active.contains { $0.localPath == wt.localPath },
            "reconcile must not re-adopt a tombstoned path")
    let all = try await db.worktrees.list()
    #expect(!all.contains { $0.localPath == wt.localPath },
            "no row (any status) may be re-created for a tombstoned path")
}

/// Ungated branch: a plain untracked git worktree under the managed prefix
/// (no tombstone) must still be adopted by reconcile.
@Test func testReconcileStillAdoptsUntombstonedWorktree() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = makeLifecycle(db: db)
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    // Register a git worktree under the managed prefix WITHOUT any DB row.
    let base = try #require(repo.worktreeRoot)
    try FileManager.default.createDirectory(
        atPath: base, withIntermediateDirectories: true
    )
    let wtPath = (base as NSString).appendingPathComponent("stray")
    try await shell("git worktree add -b stray-branch '\(wtPath)'", at: repoDir)

    try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog(), reapSharedScratchTmuxResources: true)

    let active = try await db.worktrees.list(repoID: repo.id, status: .active)
    #expect(active.contains { $0.localPath == wtPath },
            "reconcile must still adopt untombstoned worktrees under the managed prefix")
}

/// Escape hatch (adopt): deliberately re-adopting a forgotten path clears the
/// tombstone, and reconcile treats the path normally again afterwards.
@Test func testAdoptClearsTombstoneAndReconcileResumes() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = makeLifecycle(db: db)
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    try await lifecycle.forgetWorktree(worktreeID: wt.id)
    #expect(try await db.forgottenWorktrees.contains(path: wt.localPath))

    // Adopt the same path back — the tombstone must be cleared.
    let outcome = try await lifecycle.adoptWorktree(repoID: repo.id, path: wt.localPath)
    #expect(outcome.worktree.localPath == wt.localPath)
    #expect(!(try await db.forgottenWorktrees.contains(path: wt.localPath)),
            "adopt must clear the forget tombstone for its path")

    // Back to normal: with the tombstone gone, reconcile re-adopts the path
    // after its row disappears (proves the skip was tombstone-driven, not
    // some other latent state).
    try await db.worktrees.delete(id: outcome.worktree.id)
    try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog(), reapSharedScratchTmuxResources: true)
    let active = try await db.worktrees.list(repoID: repo.id, status: .active)
    #expect(active.contains { $0.localPath == wt.localPath },
            "after the tombstone is cleared, reconcile behavior is back to normal")
}

/// Escape hatch (create): creating a worktree at a tombstoned path clears the
/// tombstone.
@Test func testCreateClearsTombstoneAtItsPath() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = makeLifecycle(db: db)
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    // Pre-seed a tombstone at the exact path create will resolve for this
    // folder name (worktreeRoot override + folder).
    let base = try #require(repo.worktreeRoot)
    let expectedPath = (base as NSString).appendingPathComponent("reborn")
    try await db.forgottenWorktrees.insert(path: expectedPath, repoID: repo.id)
    #expect(try await db.forgottenWorktrees.contains(path: expectedPath))

    let wt = try await lifecycle.createWorktree(
        repoID: repo.id, folder: "reborn", skipClaude: true
    )
    #expect(wt.localPath == expectedPath)
    #expect(!(try await db.forgottenWorktrees.contains(path: expectedPath)),
            "create must clear the forget tombstone for its path")
}

/// Forget is idempotent with respect to the tombstone: re-forgetting a path
/// (forget → adopt → forget) must not throw on the primary-key conflict.
@Test func testReForgettingSamePathDoesNotThrow() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = makeLifecycle(db: db)
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    try await lifecycle.forgetWorktree(worktreeID: wt.id)
    // Seed a second tombstone insert directly (same primary key).
    try await db.forgottenWorktrees.insert(path: wt.localPath, repoID: repo.id)
    #expect(try await db.forgottenWorktrees.contains(path: wt.localPath))
}

@Suite struct MigrationForgottenWorktreeTests {

    /// v35 applies on a fresh DB: table + columns + repoID index all present.
    @Test func forgottenWorktreeTableExists() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let columns = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(forgotten_worktree)")
            let names = columns.compactMap { $0["name"] as String? }
            #expect(names.contains("path"))
            #expect(names.contains("repoID"))
            #expect(names.contains("forgottenAt"))

            let indexExists = try Bool.fetchOne(dbConn, sql: """
                SELECT 1 FROM sqlite_master
                WHERE type = 'index' AND name = 'idx_forgotten_worktree_repoID'
                """) ?? false
            #expect(indexExists, "repoID index must be created by v35")
        }
    }

    /// Store round-trip against the fresh schema: insert → contains → delete.
    @Test func storeRoundTrip() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repoID = UUID()
        let path = "/tmp/v35-\(UUID().uuidString)"

        #expect(!(try await db.forgottenWorktrees.contains(path: path)))
        try await db.forgottenWorktrees.insert(path: path, repoID: repoID)
        #expect(try await db.forgottenWorktrees.contains(path: path))
        #expect(try await db.forgottenWorktrees.allPaths().contains(path))

        try await db.forgottenWorktrees.delete(path: path)
        #expect(!(try await db.forgottenWorktrees.contains(path: path)))
        #expect(!(try await db.forgottenWorktrees.allPaths().contains(path)))
    }
}
