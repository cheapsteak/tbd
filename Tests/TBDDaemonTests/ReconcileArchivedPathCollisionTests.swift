import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// A git worktree recreated at a path an archived row still holds — the shape
/// someone leaves behind by running `git worktree add` again after the
/// worktree they were working in was archived. `worktree.path` is UNIQUE
/// across every row while reconcile's re-adopt pass only skips live rows, so
/// the adoption insert threw out of `reconcile` and aborted the rest of the
/// repo's pass (terminals, tmux, health) on every run until the directory
/// went away.
///
/// Uses `createTestRepoResolvingSymlinks`: reconcile compares DB paths
/// against `git worktree list`, which reports realpath()-resolved paths.

private func makeLifecycle(db: TBDDatabase) -> WorktreeLifecycle {
    WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )
}

@Test func reconcileLeavesAWorktreeRecreatedAtAnArchivedPathUnadopted() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = makeLifecycle(db: db)
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let base = try #require(repo.worktreeRoot)
    try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)

    // The archived row names the path; its directory left with that archive.
    let path = (base as NSString).appendingPathComponent("helper")
    let archived = try await db.worktrees.create(
        repoID: repo.id, name: "helper", branch: "helper",
        path: path, tmuxServer: "tbd-test"
    )
    try await db.worktrees.archive(id: archived.id)

    // A worktree recreated at that path, plus an ordinary stray beside it
    // that the same pass must still adopt.
    try await shell("git worktree add -b helper-again '\(path)'", at: repoDir)
    let stray = (base as NSString).appendingPathComponent("stray")
    try await shell("git worktree add -b stray-branch '\(stray)'", at: repoDir)

    try await lifecycle.reconcile(
        repoID: repo.id, actuationLog: makeTestActuationLog(),
        reapSharedScratchTmuxResources: true
    )

    let atPath = try await db.worktrees.list().filter { $0.localPath == path }
    #expect(atPath.map(\.id) == [archived.id], "no second row may be minted for the held path")
    #expect(atPath.first?.status == .archived)
    #expect(FileManager.default.fileExists(atPath: path), "reconcile never removes the directory")

    let active = try await db.worktrees.list(repoID: repo.id, status: .active)
    #expect(active.contains { $0.localPath == stray },
            "the collision must not stop the rest of the pass")
}
