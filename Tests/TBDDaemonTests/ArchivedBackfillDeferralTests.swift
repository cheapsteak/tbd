import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The archived-worktree backfill runs *after* the RPC listener binds, and
/// therefore alongside RPCs that can mutate the rows it is repairing.
///
/// Tier 2 (real git subprocesses, real in-memory DB, no wall-clock waits).
@Suite("ArchivedBackfillDeferralTests")
struct ArchivedBackfillDeferralTests {

    /// A repairable broken row: an archived worktree whose DB branch is the
    /// pre-rename name, with the rename recorded in the repo's reflog. Built
    /// exactly the way `testBackfillRepairsRenamedBranch` builds it.
    private struct BrokenRow {
        let repo: Repo
        let worktreeID: UUID
        let staleBranch: String
        let renamedBranch: String
    }

    private func makeBrokenArchivedRow(
        db: TBDDatabase, git: GitManager, tempDir: URL, repoDir: URL
    ) async throws -> BrokenRow {
        let lifecycle = WorktreeLifecycle(
            db: db, git: git, tmux: TmuxManager(dryRun: true), hooks: HookResolver()
        )
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
        let staleBranch = wt.branch
        let renamedBranch = "renamed-\(UUID().uuidString.prefix(6))"
        try await shell("git branch -m \(renamedBranch)", at: URL(fileURLWithPath: wt.localPath))
        try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

        // Roll the DB row back to the pre-rename name — the legacy state the
        // backfill exists to repair.
        try await db.worktrees.updateBranch(id: wt.id, branch: staleBranch)
        try await db.worktrees.updateArchivedHeadSHA(id: wt.id, sha: nil)

        return BrokenRow(
            repo: repo, worktreeID: wt.id,
            staleBranch: staleBranch, renamedBranch: renamedBranch)
    }

    // MARK: - Ordering: the backfill is not in the pre-bind phase

    /// `Daemon.start()` runs `performStartupReconciliation` at step 8d and
    /// binds the RPC listener with `sock.start()` at step 9 — so anything
    /// inside that method is work the socket waits on. On a box with 1,825
    /// archived rows the backfill's one-`git`-subprocess-per-row pass held the
    /// bind for ~3 minutes. This test pins the backfill *out* of that method:
    /// a repairable row must still be broken when startup reconciliation
    /// returns, and repaired only once the deferred task (step 11a-backfill,
    /// after the bind) has run.
    @Test("startup reconciliation does not repair archived rows; the deferred task does")
    func backfillIsDeferredPastTheListenerBind() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let git = GitManager()
        let broken = try await makeBrokenArchivedRow(
            db: db, git: git, tempDir: tempDir, repoDir: repoDir)
        let lifecycle = WorktreeLifecycle(
            db: db, git: git, tmux: TmuxManager(dryRun: true), hooks: HookResolver()
        )

        await Daemon().performStartupReconciliation(
            mockMode: nil, database: db, git: git, lifecycle: lifecycle,
            actuationLog: makeTestActuationLog())

        let afterReconcile = try #require(try await db.worktrees.get(id: broken.worktreeID))
        #expect(
            afterReconcile.branch == broken.staleBranch,
            "the backfill must not run inside performStartupReconciliation — the socket bind waits on it")
        #expect(afterReconcile.archivedHeadSHA == nil)

        let task = try #require(
            Daemon.startArchivedWorktreeBackfill(mockMode: nil, database: db, git: git),
            "live mode must start the deferred backfill task")
        await task.value

        let afterBackfill = try #require(try await db.worktrees.get(id: broken.worktreeID))
        #expect(afterBackfill.branch == broken.renamedBranch)
        #expect(afterBackfill.archivedHeadSHA?.isEmpty == false)
    }

    // MARK: - Mock gate: both branches

    @Test("mock ON: no backfill task is started and nothing is repaired")
    func mockModeStartsNoBackfill() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let git = GitManager()
        let broken = try await makeBrokenArchivedRow(
            db: db, git: git, tempDir: tempDir, repoDir: repoDir)

        let task = Daemon.startArchivedWorktreeBackfill(
            mockMode: .enabled(fixturePath: "/tmp/does-not-exist.json"),
            database: db, git: git)
        #expect(task == nil)

        let after = try #require(try await db.worktrees.get(id: broken.worktreeID))
        #expect(after.branch == broken.staleBranch)
        #expect(after.archivedHeadSHA == nil)
    }

    // MARK: - Compare-and-swap: a row that changed under the pass is not clobbered

    @Test("a row revived under the pass keeps its branch")
    func revivedRowIsNotClobberedMidPass() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let git = GitManager()
        let broken = try await makeBrokenArchivedRow(
            db: db, git: git, tempDir: tempDir, repoDir: repoDir)
        let backfill = ArchivedWorktreeBackfill(db: db, git: git)

        // The snapshot `runForRepo` would have taken, ...
        let snapshot = try #require(try await db.worktrees.get(id: broken.worktreeID))
        let renameMap = await backfill.mineReflogRenames(repoPath: broken.repo.path)
        #expect(renameMap[broken.staleBranch] == broken.renamedBranch)

        // ... and then an RPC revives the row before the write lands.
        try await db.worktrees.revive(id: broken.worktreeID)

        await backfill.attemptRepair(
            worktree: snapshot, repo: broken.repo, renameMap: renameMap)

        let after = try #require(try await db.worktrees.get(id: broken.worktreeID))
        #expect(after.status == .active)
        #expect(after.branch == broken.staleBranch, "a revived row must not be rewritten by the pass")
        #expect(after.archivedHeadSHA == nil)
    }

    // MARK: - Cancellation

    /// A gate that lets the test cancel the backfill task before its pass
    /// begins, with no wall-clock race: the task parks here, the test cancels,
    /// and only then is the gate opened.
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// Cancellation contract: a cancelled pass returns without repairing and
    /// without hanging, and the same fixture is genuinely repairable when the
    /// pass is not cancelled (the control arm — without it this assertion
    /// would pass just as happily against a fixture nothing could repair).
    ///
    /// This test does **not** discriminate the `Task.isCancelled` guards on
    /// its own: `runBoundedProcess`'s `CancellationRelay` already kills every
    /// `git` child of a cancelled task, so `refExists` answers false, the
    /// reflog read comes back empty, and no repair is reachable whether or not
    /// the loops check cancellation. What the guards buy is the *early return*
    /// — not spawning one doomed subprocess per archived row on the way out —
    /// and that is a subprocess count, which this tree has no seam to observe.
    @Test("a cancelled pass repairs nothing; the same fixture repairs when not cancelled")
    func cancelledPassRepairsNothing() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let git = GitManager()
        let broken = try await makeBrokenArchivedRow(
            db: db, git: git, tempDir: tempDir, repoDir: repoDir)
        let backfill = ArchivedWorktreeBackfill(db: db, git: git)

        let gate = Gate()
        let task = Task {
            await gate.wait()
            await backfill.run()
        }
        task.cancel()
        await gate.open()
        await task.value

        let after = try #require(try await db.worktrees.get(id: broken.worktreeID))
        #expect(after.branch == broken.staleBranch)
        #expect(after.archivedHeadSHA == nil)

        // Control arm: the fixture really was repairable.
        await backfill.run()
        let control = try #require(try await db.worktrees.get(id: broken.worktreeID))
        #expect(control.branch == broken.renamedBranch)
    }
}

// MARK: - The compare-and-swap write itself

/// `WorktreeStore.repairArchivedBranch` is the whole concurrency position of
/// the deferred backfill: the write lands only if the row is still the one the
/// caller decided to repair. Tier 1 — in-memory DB, no subprocesses.
@Suite("RepairArchivedBranchTests")
struct RepairArchivedBranchTests {

    private func seedArchivedWorktree(
        db: TBDDatabase, branch: String, archivedHeadSHA: String? = nil
    ) async throws -> Worktree {
        let repo = try await db.repos.create(
            path: "/tmp/tbd-repair-cas-\(UUID().uuidString)",
            displayName: "cas-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", displayName: "WT", branch: branch,
            path: "/tmp/tbd-repair-cas-wt-\(UUID().uuidString)",
            tmuxServer: "cas-server")
        try await db.worktrees.archive(id: wt.id, archivedHeadSHA: archivedHeadSHA)
        return wt
    }

    @Test("success: an unchanged archived row is repaired and gets its missing SHA")
    func repairsUnchangedRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await seedArchivedWorktree(db: db, branch: "old")

        let repaired = try await db.worktrees.repairArchivedBranch(
            id: wt.id, expectedBranch: "old", newBranch: "new", archivedHeadSHA: "deadbeef")
        #expect(repaired)

        let after = try #require(try await db.worktrees.get(id: wt.id))
        #expect(after.branch == "new")
        #expect(after.archivedHeadSHA == "deadbeef")
    }

    @Test("success: an existing archivedHeadSHA is preserved, never overwritten")
    func preservesExistingHeadSHA() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await seedArchivedWorktree(db: db, branch: "old", archivedHeadSHA: "original")

        let repaired = try await db.worktrees.repairArchivedBranch(
            id: wt.id, expectedBranch: "old", newBranch: "new", archivedHeadSHA: "replacement")
        #expect(repaired)

        let after = try #require(try await db.worktrees.get(id: wt.id))
        #expect(after.branch == "new")
        #expect(after.archivedHeadSHA == "original")
    }

    @Test("missing row: returns false")
    func refusesMissingRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repaired = try await db.worktrees.repairArchivedBranch(
            id: UUID(), expectedBranch: "old", newBranch: "new", archivedHeadSHA: nil)
        #expect(!repaired)
    }

    @Test("status changed: a revived row is refused and left untouched")
    func refusesRevivedRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await seedArchivedWorktree(db: db, branch: "old")
        try await db.worktrees.revive(id: wt.id)

        let repaired = try await db.worktrees.repairArchivedBranch(
            id: wt.id, expectedBranch: "old", newBranch: "new", archivedHeadSHA: "deadbeef")
        #expect(!repaired)

        let after = try #require(try await db.worktrees.get(id: wt.id))
        #expect(after.branch == "old")
        #expect(after.archivedHeadSHA == nil)
    }

    @Test("branch changed: a re-archived row on another branch is refused")
    func refusesChangedBranch() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await seedArchivedWorktree(db: db, branch: "old")
        try await db.worktrees.updateBranch(id: wt.id, branch: "someone-elses-branch")

        let repaired = try await db.worktrees.repairArchivedBranch(
            id: wt.id, expectedBranch: "old", newBranch: "new", archivedHeadSHA: "deadbeef")
        #expect(!repaired)

        let after = try #require(try await db.worktrees.get(id: wt.id))
        #expect(after.branch == "someone-elses-branch")
        #expect(after.archivedHeadSHA == nil)
    }
}
