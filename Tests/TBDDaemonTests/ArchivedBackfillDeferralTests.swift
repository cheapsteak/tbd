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

    // MARK: - The premise is re-verified immediately before the write

    /// A1: `beginReviveWorktree` recreates the *stale* branch name from
    /// `archivedHeadSHA` and leaves the row `.archived` on that name for the
    /// whole of its work, so status and branch alone cannot tell a mid-revive
    /// row from an untouched one. What can is the premise the repair rests on:
    /// the branch does not resolve. `attemptRepair` re-probes it right before
    /// the write, and abandons the repair when it resolves again.
    @Test("a row whose branch resolves again by write time is not repaired")
    func branchResolvingAgainAbandonsTheRepair() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let git = GitManager()
        let broken = try await makeBrokenArchivedRow(
            db: db, git: git, tempDir: tempDir, repoDir: repoDir)
        let backfill = ArchivedWorktreeBackfill(db: db, git: git)

        // The snapshot the pass decided from, taken while the branch is gone.
        let snapshot = try #require(try await db.worktrees.get(id: broken.worktreeID))
        let renameMap = await backfill.mineReflogRenames(repoPath: broken.repo.path)
        #expect(renameMap[broken.staleBranch] == broken.renamedBranch)

        // ... and then a revive recreates the stale branch at the archived SHA,
        // leaving the row `.archived` on that same branch while it works.
        let sha = try await git.headSHA(repoPath: broken.repo.path, ref: broken.renamedBranch)
        try await shell("git branch \(broken.staleBranch) \(sha)", at: URL(fileURLWithPath: broken.repo.path))

        await backfill.attemptRepair(
            worktree: snapshot, repo: broken.repo, renameMap: renameMap)

        let after = try #require(try await db.worktrees.get(id: broken.worktreeID))
        #expect(
            after.branch == broken.staleBranch,
            "the branch resolves again, so the premise of the repair no longer holds")
        #expect(after.archivedHeadSHA == nil)
    }

    /// A2, end to end: revive recreates the stale branch, the user re-archives,
    /// and the row comes back `.archived` on that same branch name. A stale
    /// write here is durable — `refreshGitStatuses` only syncs branches for
    /// `.active` rows, so nothing would ever correct it and the next revive
    /// would check out the wrong branch.
    @Test("a row revived and re-archived under the pass is not repaired")
    func revivedAndReArchivedRowIsNotRepaired() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let git = GitManager()
        let broken = try await makeBrokenArchivedRow(
            db: db, git: git, tempDir: tempDir, repoDir: repoDir)
        let backfill = ArchivedWorktreeBackfill(db: db, git: git)

        let snapshot = try #require(try await db.worktrees.get(id: broken.worktreeID))
        let renameMap = await backfill.mineReflogRenames(repoPath: broken.repo.path)

        // Revive: the stale branch is recreated at the archived SHA and the row
        // goes active. Then the user archives again on that same branch.
        let sha = try await git.headSHA(repoPath: broken.repo.path, ref: broken.renamedBranch)
        try await shell("git branch \(broken.staleBranch) \(sha)", at: URL(fileURLWithPath: broken.repo.path))
        try await db.worktrees.revive(id: broken.worktreeID)
        try await db.worktrees.archive(id: broken.worktreeID, archivedHeadSHA: sha)

        await backfill.attemptRepair(
            worktree: snapshot, repo: broken.repo, renameMap: renameMap)

        let after = try #require(try await db.worktrees.get(id: broken.worktreeID))
        #expect(after.status == .archived)
        #expect(after.branch == broken.staleBranch, "a re-archived row must not be rewritten")
        #expect(after.archivedAt != snapshot.archivedAt)
    }

    /// A2, isolated on `archivedAt`: the revive/re-archive cycle happened and
    /// the branch is missing again by the time the pass writes (the user
    /// renamed or deleted it after re-archiving), so the re-probe above finds
    /// nothing wrong. Only the changed `archivedAt` distinguishes this row from
    /// the one the snapshot described.
    @Test("a re-archived row is refused even when its branch is missing again")
    func reArchivedRowWithMissingBranchIsNotRepaired() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let git = GitManager()
        let broken = try await makeBrokenArchivedRow(
            db: db, git: git, tempDir: tempDir, repoDir: repoDir)
        let backfill = ArchivedWorktreeBackfill(db: db, git: git)

        let snapshot = try #require(try await db.worktrees.get(id: broken.worktreeID))
        let renameMap = await backfill.mineReflogRenames(repoPath: broken.repo.path)

        // A full revive / re-archive cycle at the row level. The branch stays
        // missing in the repo, so the pre-write re-probe has nothing to catch.
        try await db.worktrees.revive(id: broken.worktreeID)
        try await db.worktrees.archive(id: broken.worktreeID)
        #expect(await git.refExists(repoPath: broken.repo.path, ref: broken.staleBranch) == false)

        await backfill.attemptRepair(
            worktree: snapshot, repo: broken.repo, renameMap: renameMap)

        let after = try #require(try await db.worktrees.get(id: broken.worktreeID))
        #expect(after.branch == broken.staleBranch)
        #expect(after.archivedHeadSHA == nil)
    }

    // MARK: - The repo-wide ref map is a negative filter, not an authority

    /// `runForRepo` hoists one `git for-each-ref` per repo and skips any row
    /// whose branch it names, which spares a subprocess per row on a healthy
    /// fleet. The map covers only `refs/heads` and `refs/remotes/origin`, so a
    /// branch *absent* from it must still be confirmed with `refExists` before
    /// the row counts as broken — otherwise rows git resolves fine get
    /// reclassified and repaired for the first time.
    ///
    /// Here the DB's branch name resolves as a **tag**: outside both namespaces
    /// the map covers, and with a rename for that same name sitting in the
    /// reflog, so a map treated as authoritative would classify the row broken
    /// and hand it to `attemptRepair`.
    ///
    /// The assertion is on the pass's own counts, not just the row. An
    /// authoritative map does not in fact corrupt this row — `attemptRepair`'s
    /// pre-write re-probe of the same branch catches it a moment later and
    /// abandons the repair — so the DB looks identical either way and only the
    /// counts tell the two apart. Two guards covering one outcome is the
    /// intent, not an accident; this pins the outer one so it cannot rot behind
    /// the inner one.
    @Test("a branch resolving outside the ref map's namespaces is left alone")
    func refMapAbsenceFallsBackToRefExists() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let git = GitManager()
        let broken = try await makeBrokenArchivedRow(
            db: db, git: git, tempDir: tempDir, repoDir: repoDir)

        let sha = try await git.headSHA(repoPath: broken.repo.path, ref: broken.renamedBranch)
        try await shell("git tag \(broken.staleBranch) \(sha)", at: URL(fileURLWithPath: broken.repo.path))
        let tips = try await git.refTips(repoPath: broken.repo.path)
        #expect(tips[broken.staleBranch] == nil, "a tag is outside refs/heads and refs/remotes/origin")
        #expect(await git.refExists(repoPath: broken.repo.path, ref: broken.staleBranch))

        let stats = await ArchivedWorktreeBackfill(db: db, git: git)
            .runForRepo(repo: broken.repo)

        #expect(
            stats.refExistsProbes == 1,
            "a branch the map does not name must still be confirmed with refExists")
        #expect(
            stats.repairAttempts == 0,
            "the ref map is a fast negative filter; git decides what actually resolves")

        let after = try #require(try await db.worktrees.get(id: broken.worktreeID))
        #expect(after.branch == broken.staleBranch)
        #expect(after.archivedHeadSHA == nil)
    }

    /// The map's positive leg, and the saving that motivated it: every archived
    /// row resolves through `refs/heads`, so one `for-each-ref` answers all of
    /// them, not one `rev-parse` each, and every row is left as it was found.
    @Test("a repo whose archived branches all resolve costs no per-row probe")
    func healthyRepoIsLeftUntouched() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let git = GitManager()
        let lifecycle = WorktreeLifecycle(
            db: db, git: git, tmux: TmuxManager(dryRun: true), hooks: HookResolver()
        )
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        var ids: [UUID: String] = [:]
        for _ in 0..<3 {
            let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
            try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)
            ids[wt.id] = wt.branch
        }

        // The premise: every archived row's branch is named by the repo-wide
        // ref map, so the fast path answers all of them and no row ever reaches
        // a `refExists` probe or the reflog.
        let tips = try await git.refTips(repoPath: repo.path)
        for branch in ids.values {
            #expect(tips[branch] != nil, "archive keeps the branch, so the ref map names it")
        }

        let stats = await ArchivedWorktreeBackfill(db: db, git: git).runForRepo(repo: repo)
        #expect(
            stats == .init(refExistsProbes: 0, repairAttempts: 0),
            "the repo-wide ref map answered every row; no row cost a subprocess")

        for (id, branch) in ids {
            let after = try #require(try await db.worktrees.get(id: id))
            #expect(after.branch == branch)
        }
    }

    /// The degraded leg: when `refTips` is unavailable the pass must behave
    /// exactly as it did before the map existed — every probe a subprocess,
    /// every repairable row still repaired. `nil` is what a failed
    /// `for-each-ref` leaves behind.
    @Test("a nil ref map still repairs a broken row")
    func nilRefMapStillRepairs() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let git = GitManager()
        let broken = try await makeBrokenArchivedRow(
            db: db, git: git, tempDir: tempDir, repoDir: repoDir)
        let backfill = ArchivedWorktreeBackfill(db: db, git: git)

        let snapshot = try #require(try await db.worktrees.get(id: broken.worktreeID))
        let renameMap = await backfill.mineReflogRenames(repoPath: broken.repo.path)
        await backfill.attemptRepair(
            worktree: snapshot, repo: broken.repo, renameMap: renameMap, refTips: nil)

        let after = try #require(try await db.worktrees.get(id: broken.worktreeID))
        #expect(after.branch == broken.renamedBranch)
        #expect(after.archivedHeadSHA?.isEmpty == false)
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
    /// `git` child of a cancelled task, so `refTips` and `refExists` fail, the
    /// reflog read comes back empty, and no repair is reachable whether or not
    /// the loops check cancellation. What the guards buy is the *early return*
    /// — not spawning the doomed subprocesses still ahead of the pass on the
    /// way out — and that is a subprocess count, which this tree has no seam to
    /// observe.
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
/// the deferred backfill: the write lands only if the row still matches the
/// three fields the caller's decision rested on — status, branch, and the
/// archive timestamp. Tier 1 — in-memory DB, no subprocesses.
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

    /// The row's archive timestamp as the backfill reads it: through
    /// `listLocal(repoID:status:)`, the same query `runForRepo` snapshots from.
    private func listedArchivedAt(db: TBDDatabase, wt: Worktree) async throws -> Date? {
        let listed = try await db.worktrees.listLocal(repoID: wt.repoID, status: .archived)
        return try #require(listed.first { $0.id == wt.id }).archivedAt
    }

    /// The `archivedAt` half of the CAS is only worth anything if a `Date`
    /// survives the write-read-compare round trip through GRDB unchanged. If it
    /// did not, the guard would silently refuse every repair — a vacuous guard
    /// that looks like a working one. So: seed a row, read the timestamp back
    /// the way the pass reads it, and compare-and-swap with exactly that value.
    @Test("round trip: an archivedAt read back through listLocal() satisfies the CAS")
    func archivedAtSurvivesTheRoundTrip() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await seedArchivedWorktree(db: db, branch: "old")

        let readBack = try await listedArchivedAt(db: db, wt: wt)
        #expect(readBack != nil, "an archived row carries an archive timestamp")

        let repaired = try await db.worktrees.repairArchivedBranch(
            id: wt.id, expectedBranch: "old", newBranch: "new",
            expectedArchivedAt: readBack, archivedHeadSHA: "deadbeef")
        #expect(repaired, "a Date read back through listLocal() must still match the stored row")

        let after = try #require(try await db.worktrees.get(id: wt.id))
        #expect(after.branch == "new")
    }

    @Test("success: an unchanged archived row is repaired and gets its missing SHA")
    func repairsUnchangedRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await seedArchivedWorktree(db: db, branch: "old")
        let archivedAt = try await listedArchivedAt(db: db, wt: wt)

        let repaired = try await db.worktrees.repairArchivedBranch(
            id: wt.id, expectedBranch: "old", newBranch: "new",
            expectedArchivedAt: archivedAt, archivedHeadSHA: "deadbeef")
        #expect(repaired)

        let after = try #require(try await db.worktrees.get(id: wt.id))
        #expect(after.branch == "new")
        #expect(after.archivedHeadSHA == "deadbeef")
    }

    @Test("success: an existing archivedHeadSHA is preserved, never overwritten")
    func preservesExistingHeadSHA() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await seedArchivedWorktree(db: db, branch: "old", archivedHeadSHA: "original")
        let archivedAt = try await listedArchivedAt(db: db, wt: wt)

        let repaired = try await db.worktrees.repairArchivedBranch(
            id: wt.id, expectedBranch: "old", newBranch: "new",
            expectedArchivedAt: archivedAt, archivedHeadSHA: "replacement")
        #expect(repaired)

        let after = try #require(try await db.worktrees.get(id: wt.id))
        #expect(after.branch == "new")
        #expect(after.archivedHeadSHA == "original")
    }

    @Test("missing row: returns false")
    func refusesMissingRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repaired = try await db.worktrees.repairArchivedBranch(
            id: UUID(), expectedBranch: "old", newBranch: "new",
            expectedArchivedAt: Date(), archivedHeadSHA: nil)
        #expect(!repaired)
    }

    @Test("status changed: a revived row is refused and left untouched")
    func refusesRevivedRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await seedArchivedWorktree(db: db, branch: "old")
        let archivedAt = try await listedArchivedAt(db: db, wt: wt)
        try await db.worktrees.revive(id: wt.id)

        let repaired = try await db.worktrees.repairArchivedBranch(
            id: wt.id, expectedBranch: "old", newBranch: "new",
            expectedArchivedAt: archivedAt, archivedHeadSHA: "deadbeef")
        #expect(!repaired)

        let after = try #require(try await db.worktrees.get(id: wt.id))
        #expect(after.branch == "old")
        #expect(after.archivedHeadSHA == nil)
    }

    @Test("branch changed: a re-archived row on another branch is refused")
    func refusesChangedBranch() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await seedArchivedWorktree(db: db, branch: "old")
        let archivedAt = try await listedArchivedAt(db: db, wt: wt)
        try await db.worktrees.updateBranch(id: wt.id, branch: "someone-elses-branch")

        let repaired = try await db.worktrees.repairArchivedBranch(
            id: wt.id, expectedBranch: "old", newBranch: "new",
            expectedArchivedAt: archivedAt, archivedHeadSHA: "deadbeef")
        #expect(!repaired)

        let after = try #require(try await db.worktrees.get(id: wt.id))
        #expect(after.branch == "someone-elses-branch")
        #expect(after.archivedHeadSHA == nil)
    }

    /// The revive path recreates the *stale* branch name from
    /// `archivedHeadSHA`, so a row revived and archived again comes back
    /// `.archived` on exactly the branch the pass expected: status and branch
    /// agree, and only the archive timestamp says the row is not the one the
    /// snapshot described. Without that third field this write lands, and
    /// nothing corrects it afterwards — `refreshGitStatuses` syncs branches for
    /// `.active` rows only.
    @Test("archivedAt changed: a row revived and re-archived on the same branch is refused")
    func refusesReArchivedRowOnTheSameBranch() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await seedArchivedWorktree(db: db, branch: "old")
        let archivedAt = try await listedArchivedAt(db: db, wt: wt)

        try await db.worktrees.revive(id: wt.id)
        try await db.worktrees.archive(id: wt.id, archivedHeadSHA: "post-revive-sha")
        let reArchivedAt = try await listedArchivedAt(db: db, wt: wt)
        #expect(reArchivedAt != archivedAt, "every archive stamps a fresh timestamp")

        let repaired = try await db.worktrees.repairArchivedBranch(
            id: wt.id, expectedBranch: "old", newBranch: "new",
            expectedArchivedAt: archivedAt, archivedHeadSHA: "deadbeef")
        #expect(!repaired)

        let after = try #require(try await db.worktrees.get(id: wt.id))
        #expect(after.branch == "old")
        #expect(after.archivedHeadSHA == "post-revive-sha")
    }
}
