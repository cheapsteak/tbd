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
    /// row's synthetic `remote://` path is absent from it — the exact state
    /// that made an unfenced reconcile archive it.
    private func seedRemoteRow(
        db: TBDDatabase, repoPath: String
    ) async throws -> (repo: Repo, remote: Worktree) {
        let repo = try await db.repos.create(
            path: repoPath, displayName: "acme", defaultBranch: "main")
        let remote = try await db.worktrees.createRemote(
            repoID: repo.id, name: "remote", branch: "b",
            provider: "agentbox", sessionID: "s-1")
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

    /// Orphan GC's scratchpad reconciliation maps a worktree row's stored path
    /// to a scratchpad slug and deletes that directory once the worktree path
    /// itself is absent from disk. A remote row's path is the synthetic
    /// `remote://` URI, which is absent by construction — so an unfenced fetch
    /// makes every archived remote lane a standing reap candidate on every
    /// sweep.
    ///
    /// Both tests below discriminate by construction: a directory really is
    /// planted at the remote row's slug, so an unfenced run deletes it and
    /// records the reap. Asserting the row's own columns would prove nothing —
    /// orphan GC never writes to the worktree table.
    ///
    /// Each also plants a second scratchpad behind an archived *local* row
    /// whose directory is gone, so a run that reaped nothing at all cannot pass
    /// by doing nothing.
    private struct ScratchpadFixture {
        let repoID: UUID
        let remoteScratchpad: URL
        let localScratchpad: URL
    }

    /// Plants `base/<slug>` for one archived remote row and one archived local
    /// row whose worktree directory does not exist.
    private func seedScratchpads(
        db: TBDDatabase, repoPath: String, base: URL
    ) async throws -> ScratchpadFixture {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let (repo, remote) = try await seedRemoteRow(db: db, repoPath: repoPath)
        try await db.worktrees.archive(id: remote.id)

        let goneLocalPath = "/tmp/tbd-gone-wt-\(UUID().uuidString)"
        let local = try await db.worktrees.create(
            repoID: repo.id, name: "gone-wt", branch: "gone-wt",
            path: goneLocalPath, tmuxServer: "tbd-test")
        try await db.worktrees.archive(id: local.id)

        let remoteDir = base.appendingPathComponent(
            ScratchpadCollector.slug(forWorktreePath: remote.localPath))
        let localDir = base.appendingPathComponent(
            ScratchpadCollector.slug(forWorktreePath: goneLocalPath))
        for dir in [remoteDir, localDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return ScratchpadFixture(
            repoID: repo.id, remoteScratchpad: remoteDir, localScratchpad: localDir)
    }

    @Test func orphanGCSweepNeverReapsARemoteRowsScratchpad() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        let base = tempDir.appendingPathComponent("scratchpads", isDirectory: true)
        let fixture = try await seedScratchpads(db: db, repoPath: repoDir.path, base: base)

        let gc = OrphanGC(
            db: db, git: GitManager(), broadcast: { _ in },
            lsofProvider: { [] }, scratchpadBase: base)
        let result = await gc.sweep(dryRun: false)

        #expect(FileManager.default.fileExists(atPath: fixture.remoteScratchpad.path),
                "the sweep reaped a directory sitting at a remote row's scratchpad slug")
        #expect(!FileManager.default.fileExists(atPath: fixture.localScratchpad.path),
                "the sweep reaped nothing at all — the remote arm proves nothing")
        #expect(result.reaped == 1)
        #expect(!result.planned.contains { $0.contains(fixture.remoteScratchpad.path) },
                "the remote row reached the reap-candidate plan: \(result.planned)")

        let reaped = try await db.reapRecords.list(repoPath: nil).map(\.worktreePath)
        #expect(reaped == [fixture.localScratchpad.path])
    }

    /// `repo.remove` runs the same reconciliation over EVERY row the repo owns
    /// — every status — right before `deleteForRepo`, so it needs the same
    /// fence as the periodic sweep.
    @Test func repoRemovalReconciliationNeverReapsARemoteRowsScratchpad() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        let base = tempDir.appendingPathComponent("scratchpads", isDirectory: true)
        let fixture = try await seedScratchpads(db: db, repoPath: repoDir.path, base: base)

        let gc = OrphanGC(
            db: db, git: GitManager(), broadcast: { _ in },
            lsofProvider: { [] }, scratchpadBase: base)
        await gc.reconcileScratchpadsBeforeRepoRemoval(
            repoID: fixture.repoID, repoPath: repoDir.path)

        #expect(FileManager.default.fileExists(atPath: fixture.remoteScratchpad.path),
                "repo-removal reconciliation reaped a remote row's scratchpad slug")
        #expect(!FileManager.default.fileExists(atPath: fixture.localScratchpad.path),
                "the reconciliation reaped nothing at all — the remote arm proves nothing")

        let reaped = try await db.reapRecords.list(repoPath: nil).map(\.worktreePath)
        #expect(reaped == [fixture.localScratchpad.path])
    }
}
