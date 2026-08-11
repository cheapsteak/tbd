import Testing
import TestSupport
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

/// Reconcile archives any DB row whose path is absent from git's worktree
/// list. A remote row's path is never in that list, so without a fence
/// reconcile tears down every remote lane on every sweep — including killing
/// tmux windows and deleting terminal rows. A second loop in the same function
/// rewrites `tmuxServer` on any row whose value differs from the repo's
/// canonical name, which an empty string always does.
@Suite struct ReconcileRemoteRowFenceTests {

    private func makeLifecycle(db: TBDDatabase) -> WorktreeLifecycle {
        WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(dryRun: true),
            hooks: HookResolver()
        )
    }

    /// A real git repo with no extra worktrees, plus one remote row. `git
    /// worktree list` reports only the repo's own checkout, so the remote
    /// row's (empty) path is absent from it — the exact state that made an
    /// unfenced reconcile archive it.
    private func seedRemoteRow(
        db: TBDDatabase, repoPath: String
    ) async throws -> (repo: Repo, remote: Worktree) {
        let repo = try await db.repos.create(
            path: repoPath, displayName: "acme", defaultBranch: "main")
        let remote = try await db.worktrees.create(
            repoID: repo.id, name: "remote", branch: "b", path: "", tmuxServer: "",
            location: .remote(provider: "agentbox", sessionID: "s-1"))
        return (repo, remote)
    }

    @Test func reconcileLeavesARemoteRowActive() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let (repo, remote) = try await seedRemoteRow(db: db, repoPath: repoDir.path)

        try await makeLifecycle(db: db).reconcile(
            repoID: repo.id, actuationLog: makeTestActuationLog())

        let after = try #require(try await db.worktrees.get(id: remote.id))
        #expect(after.status == .active, "reconcile archived a remote row")
        #expect(after.archivedAt == nil)
    }

    /// The canonicalization loop rewrites tmuxServer on any row whose value
    /// differs from the repo's canonical name — which an empty string always
    /// does. A remote row must come out untouched.
    @Test func reconcileLeavesARemoteRowsTmuxServerEmpty() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let (repo, remote) = try await seedRemoteRow(db: db, repoPath: repoDir.path)

        try await makeLifecycle(db: db).reconcile(
            repoID: repo.id, actuationLog: makeTestActuationLog())

        let after = try #require(try await db.worktrees.get(id: remote.id))
        #expect(after.tmuxServer == "", "reconcile canonicalized a remote row's tmux server")
    }

    /// Orphan GC keys on filesystem paths and snapshot refs, and a remote row
    /// has neither, so it needs no fence of its own. This asserts that claim
    /// rather than trusting it — with the master switch pinned ON and the
    /// scratchpad base pointed at a temp dir, so a sweep that really runs is
    /// what leaves the row alone.
    @Test func orphanGCSweepLeavesARemoteRowIntact() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        let (_, remote) = try await seedRemoteRow(db: db, repoPath: repoDir.path)

        let gc = OrphanGC(
            db: db,
            git: GitManager(),
            broadcast: { _ in },
            lsofProvider: { [] },
            scratchpadBase: tempDir.appendingPathComponent("scratchpads", isDirectory: true)
        )
        _ = await gc.sweep(dryRun: false)

        let after = try #require(try await db.worktrees.get(id: remote.id))
        #expect(after.status == .active)
    }
}
