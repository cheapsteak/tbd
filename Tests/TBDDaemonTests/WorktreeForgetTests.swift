import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// `forget` removes a worktree from TBD's tracking but, unlike `archive`,
/// leaves the directory on disk. These tests pin both branches of that gating
/// behavior:
///   - forget KEEPS the directory (and removes the row from every listing).
///   - archive REMOVES the directory (the contrasting branch).

@Test func testForgetKeepsDirectoryAndRemovesFromTracking() async throws {
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
    #expect(FileManager.default.fileExists(atPath: wt.path))

    // Drop a gitignored-style artifact to prove forget preserves on-disk files.
    let marker = (wt.path as NSString).appendingPathComponent("keep-me.txt")
    try "preserve".write(toFile: marker, atomically: true, encoding: .utf8)

    // Seed a tab override row so the tab-cleanup assertion is meaningful.
    let terminalsBefore = try await db.terminals.list(worktreeID: wt.id)
    let firstTerminal = try #require(terminalsBefore.first)
    try await db.tabs.setLabel(tabID: firstTerminal.id, worktreeID: wt.id, label: "Renamed")
    #expect(!(try await db.tabs.listForWorktree(worktreeID: wt.id)).isEmpty)

    try await lifecycle.forgetWorktree(worktreeID: wt.id)

    // 1. Directory (and its files) still on disk — forget did NOT run
    //    `git worktree remove`.
    #expect(FileManager.default.fileExists(atPath: wt.path),
            "forget must NOT delete the worktree directory")
    #expect(FileManager.default.fileExists(atPath: marker),
            "forget must preserve files inside the worktree directory")

    // 2. Row is hard-deleted — absent from active AND archived listings.
    #expect(try await db.worktrees.get(id: wt.id) == nil,
            "forget must hard-delete the worktree row")
    let active = try await db.worktrees.list(repoID: repo.id, status: .active)
    #expect(!active.contains { $0.id == wt.id },
            "forgotten worktree must not appear in the active list")
    let archived = try await db.worktrees.list(repoID: repo.id, status: .archived)
    #expect(!archived.contains { $0.id == wt.id },
            "forgotten worktree must not appear in the archived list")

    // 3. Terminals + tabs cleaned up — no orphan rows.
    let terminals = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminals.isEmpty, "forget must delete the worktree's terminals")
    let tabs = try await db.tabs.listForWorktree(worktreeID: wt.id)
    #expect(tabs.isEmpty, "forget must delete the worktree's tabs")
}

/// Contrasting branch: `archive` DOES delete the directory. This anchors the
/// behavioral difference forget is built to invert.
@Test func testArchiveRemovesDirectoryUnlikeForget() async throws {
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
    #expect(FileManager.default.fileExists(atPath: wt.path))

    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    #expect(!FileManager.default.fileExists(atPath: wt.path),
            "archive must delete the worktree directory (contrast with forget)")
}

@Test func testForgetWorktreeNotFound() async throws {
    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    await #expect(throws: WorktreeLifecycleError.self) {
        try await lifecycle.forgetWorktree(worktreeID: UUID())
    }
}

@Test func testForgetRefusesMainWorktree() async throws {
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
    let main = try await db.worktrees.createMain(
        repoID: repo.id,
        name: "main",
        branch: "main",
        path: repoDir.path,
        tmuxServer: TmuxManager.serverName(forRepoPath: repo.path)
    )

    await #expect(throws: WorktreeLifecycleError.self) {
        try await lifecycle.forgetWorktree(worktreeID: main.id)
    }

    // The main row must survive a refused forget.
    #expect(try await db.worktrees.get(id: main.id) != nil)
}
