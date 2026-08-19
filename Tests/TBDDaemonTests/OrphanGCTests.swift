import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared
import TestSupport

/// Thread-safe collector for broadcast `StateDelta`s, mirroring the pattern
/// in `RPCRouterWorktreeCreateBroadcastTests`.
private final class BroadcastDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [StateDelta] = []

    func append(_ delta: StateDelta) {
        lock.lock(); defer { lock.unlock() }
        deltas.append(delta)
    }

    func snapshot() -> [StateDelta] {
        lock.lock(); defer { lock.unlock() }
        return deltas
    }
}

@Suite("OrphanGC")
struct OrphanGCTests {
    // MARK: - Helpers

    /// Well past the default 3600s grace window relative to a worktree just
    /// created by this test process.
    private static let farFuture: @Sendable () -> Date = { Date().addingTimeInterval(3 * 3600) }

    @discardableResult
    private func makeAgentWorktree(repo: URL, name: String, branch: String? = nil) async throws -> String {
        try await shell("mkdir -p .claude/worktrees", at: repo)
        try await shell("git worktree add .claude/worktrees/\(name) -b \(branch ?? name)", at: repo)
        guard let cReal = realpath(repo.path + "/.claude/worktrees/" + name, nil) else {
            return repo.path + "/.claude/worktrees/" + name
        }
        defer { free(cReal) }
        return String(cString: cReal)
    }

    private func makeGC(
        db: TBDDatabase,
        git: GitManager,
        broadcaster: BroadcastDeltas,
        scratchpadBase: URL? = nil,
        now: @escaping @Sendable () -> Date = OrphanGCTests.farFuture
    ) -> OrphanGC {
        OrphanGC(
            db: db,
            git: git,
            broadcast: { broadcaster.append($0) },
            lsofProvider: { [] },
            scratchpadBase: scratchpadBase,
            now: now
        )
    }

    // MARK: - gcEnabled gate

    @Test func sweepDisabledDoesNothing() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(false)
        _ = try await db.repos.create(path: repo.path, displayName: "acme", defaultBranch: "main")

        let wtPath = try await makeAgentWorktree(repo: repo, name: "agent-x")

        let broadcaster = BroadcastDeltas()
        let gc = makeGC(db: db, git: GitManager(), broadcaster: broadcaster)

        let result = await gc.sweep()

        #expect(result.reaped == 0)
        #expect(FileManager.default.fileExists(atPath: wtPath))
        let records = try await db.reapRecords.list(repoPath: nil)
        #expect(records.isEmpty)
        #expect(broadcaster.snapshot().isEmpty)
    }

    // MARK: - Enabled sweep reaps + records + broadcasts

    @Test func sweepEnabledReapsAndRecordsAndBroadcasts() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try TBDDatabase(inMemory: true)
        _ = try await db.repos.create(path: repo.path, displayName: "acme", defaultBranch: "main")

        let wtPath = try await makeAgentWorktree(repo: repo, name: "agent-x")

        let broadcaster = BroadcastDeltas()
        let gc = makeGC(db: db, git: GitManager(), broadcaster: broadcaster)

        let result = await gc.sweep()

        #expect(result.reaped == 1)
        #expect(!FileManager.default.fileExists(atPath: wtPath))

        let records = try await db.reapRecords.list(repoPath: nil)
        #expect(records.count == 1)
        #expect(records.first?.kind == .agentWorktree)
        #expect(records.first?.worktreePath == wtPath)

        let deltas = broadcaster.snapshot()
        #expect(deltas.contains { if case .reapRecordsChanged = $0 { return true }; return false })
    }

    // MARK: - Sweep-companion scratchpad reap stamps the agent worktree's own repoPath

    @Test func sweepReapsCompanionScratchpadStampedWithAgentWorktreeRepoPath() async throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("orphan-gc-companion-repopath-test-\(UUID().uuidString)")
        let base = sandbox.appendingPathComponent("base")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try TBDDatabase(inMemory: true)
        _ = try await db.repos.create(path: repo.path, displayName: "acme", defaultBranch: "main")

        let wtPath = try await makeAgentWorktree(repo: repo, name: "agent-x")

        // The agent worktree's own Claude Code scratchpad, planted so the
        // sweep's reap-then-clean-companion-scratchpad path (OrphanGC.swift
        // ~149-155) has something to find.
        let slug = ScratchpadCollector.slug(forWorktreePath: wtPath)
        let scratchDir = base.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        try "hi".write(to: scratchDir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let broadcaster = BroadcastDeltas()
        let gc = makeGC(db: db, git: GitManager(), broadcaster: broadcaster, scratchpadBase: base)

        let result = await gc.sweep()

        #expect(result.reaped == 2, "one agent-worktree reap + one companion scratchpad reap")
        let records = try await db.reapRecords.list(repoPath: nil)
        #expect(records.count == 2)

        let agentRecord = try #require(records.first { $0.kind == .agentWorktree })
        #expect(agentRecord.repoPath == repo.path)

        let scratchRecord = try #require(records.first { $0.kind == .scratchpad })
        #expect(scratchRecord.worktreePath == scratchDir.path)
        #expect(scratchRecord.repoPath == repo.path, "companion scratchpad must carry the same repoPath as its agent worktree")
    }

    // MARK: - Dry run plans without mutating

    @Test func sweepDryRunPlansWithoutMutating() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try TBDDatabase(inMemory: true)
        _ = try await db.repos.create(path: repo.path, displayName: "acme", defaultBranch: "main")

        let wtPath = try await makeAgentWorktree(repo: repo, name: "agent-x")

        let broadcaster = BroadcastDeltas()
        let gc = makeGC(db: db, git: GitManager(), broadcaster: broadcaster)

        let result = await gc.sweep(dryRun: true)

        #expect(!result.planned.isEmpty)
        #expect(result.planned.contains { $0.contains("REAP agent-worktree") && $0.contains(wtPath) })
        #expect(result.reaped == 0)
        #expect(FileManager.default.fileExists(atPath: wtPath))

        let records = try await db.reapRecords.list(repoPath: nil)
        #expect(records.isEmpty)
        #expect(broadcaster.snapshot().isEmpty)
    }

    // MARK: - Restore round trip

    @Test func restoreRoundTrip() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try TBDDatabase(inMemory: true)
        _ = try await db.repos.create(path: repo.path, displayName: "acme", defaultBranch: "main")

        let wtPath = try await makeAgentWorktree(repo: repo, name: "agent-x")

        let broadcaster = BroadcastDeltas()
        let gc = makeGC(db: db, git: GitManager(), broadcaster: broadcaster)

        let sweepResult = await gc.sweep()
        #expect(sweepResult.reaped == 1)
        #expect(!FileManager.default.fileExists(atPath: wtPath))

        let record = try #require(try await db.reapRecords.list(repoPath: nil).first)

        try await gc.restore(recordID: record.id)

        #expect(FileManager.default.fileExists(atPath: wtPath))
        let restored = try await db.reapRecords.get(id: record.id)
        #expect(restored?.restoredAt != nil)

        let deltas = broadcaster.snapshot()
        let changedCount = deltas.filter { if case .reapRecordsChanged = $0 { return true }; return false }.count
        #expect(changedCount == 2, "expected one broadcast from sweep + one from restore")
    }

    // MARK: - profileDir reap records

    /// The quarantine path is the only handle a user has on a reaped profile
    /// directory — `.profileDir` has no restore path — so it must survive the
    /// round trip through the store alongside the new kind.
    @Test("a profileDir reap record round-trips through the store with its quarantine path")
    func profileDirRecordRoundTrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = ReapRecord(
            kind: .profileDir,
            repoPath: "",
            worktreePath: "/tmp/acme/profiles/1f2e3d4c-0000-0000-0000-000000000001",
            apparentBytes: 4096,
            quarantinePath: "/tmp/acme/profiles/.reaped/1f2e3d4c-0000-0000-0000-000000000001-20260815T101500Z",
            reapedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
        try await db.reapRecords.insert(record)

        let fetched = try await db.reapRecords.list(repoPath: nil)
        #expect(fetched.count == 1)
        #expect(fetched.first?.kind == .profileDir)
        #expect(fetched.first?.quarantinePath == record.quarantinePath)
        #expect(fetched.first?.worktreePath == record.worktreePath)
    }

    /// `.profileDir` must stay un-restorable, and that is a contract rather
    /// than an oversight: the `model_profiles` row the directory depends on is
    /// already gone by the time the collector runs, so renaming it back out of
    /// quarantine would recreate an orphan for the very next sweep. Recovery is
    /// by hand, from the `quarantinePath` this record carries.
    @Test("restore refuses a profileDir record and leaves the quarantine in place")
    func restoreRejectsProfileDirRecords() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = ReapRecord(
            kind: .profileDir,
            repoPath: "",
            worktreePath: "/tmp/acme/profiles/1f2e3d4c-0000-0000-0000-000000000002",
            quarantinePath: "/tmp/acme/profiles/.reaped/1f2e3d4c-0000-0000-0000-000000000002-20260815T101500Z"
        )
        try await db.reapRecords.insert(record)
        let gc = OrphanGC(db: db, git: GitManager(), broadcast: { _ in }, lsofProvider: { [] })

        await #expect(throws: OrphanGCError.unsupportedKind(.profileDir)) {
            try await gc.restore(recordID: record.id)
        }
        // A refused restore must not consume the record: the quarantine path is
        // still the user's only handle on the data.
        let fetched = try await db.reapRecords.get(id: record.id)
        #expect(fetched?.restoredAt == nil)
        #expect(fetched?.quarantinePath == record.quarantinePath)
    }

    /// Every other kind deletes outright, so the column stays NULL for them —
    /// and a record written without one must decode as `nil`, not as "".
    @Test("a non-quarantined reap record round-trips with a nil quarantine path")
    func nonQuarantinedRecordHasNilQuarantinePath() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.reapRecords.insert(
            ReapRecord(kind: .scratchpad, repoPath: "", worktreePath: "/tmp/acme/scratch-1")
        )
        let fetched = try await db.reapRecords.list(repoPath: nil)
        #expect(fetched.first?.quarantinePath == nil)
    }

    // MARK: - Snapshot retention (anchor rule)

    @Test func snapshotRetentionDeletesOldRefs() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let git = GitManager()
        try await shell("git branch alive-branch", at: repo)
        let sha = try await resolvedHeadSHA(repo: repo)

        let aliveRef = "refs/tbd/snapshots/alive-1"
        let goneRef = "refs/tbd/snapshots/gone-1"
        try await git.updateRef(repoPath: repo.path, ref: aliveRef, sha: sha)
        try await git.updateRef(repoPath: repo.path, ref: goneRef, sha: sha)

        let db = try TBDDatabase(inMemory: true)
        let fixedNow = Date()
        let oldReapedAt = fixedNow.addingTimeInterval(-40 * 86400)

        let aliveRecord = ReapRecord(
            kind: .agentWorktree, repoPath: repo.path, worktreePath: repo.path + "/nonexistent-alive",
            branch: "alive-branch", headSHA: sha, snapshotRef: aliveRef, reapedAt: oldReapedAt
        )
        let goneRecord = ReapRecord(
            kind: .agentWorktree, repoPath: repo.path, worktreePath: repo.path + "/nonexistent-gone",
            branch: "deleted-branch", headSHA: sha, snapshotRef: goneRef, reapedAt: oldReapedAt
        )
        try await db.reapRecords.insert(aliveRecord)
        try await db.reapRecords.insert(goneRecord)

        let broadcaster = BroadcastDeltas()
        let gc = makeGC(db: db, git: git, broadcaster: broadcaster, now: { fixedNow })

        _ = await gc.sweep()

        let remainingRefs = try await git.listRefs(repoPath: repo.path, prefix: "refs/tbd/snapshots")
        #expect(!remainingRefs.contains(aliveRef), "ref anchored by a still-existing branch must be deleted")
        #expect(remainingRefs.contains(goneRef), "ref whose branch is gone must be kept forever (anchor rule)")
    }

    private func resolvedHeadSHA(repo: URL) async throws -> String {
        let git = GitManager()
        let entries = try await git.worktreeListDetailed(repoPath: repo.path)
        if let entry = entries.first { return entry.headSHA }
        // Fresh repo, no worktrees registered besides the main checkout —
        // `worktreeListDetailed` always includes the main worktree itself.
        throw NSError(domain: "OrphanGCTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "no HEAD found"])
    }

    // MARK: - lsof outcome parsing (parseLiveCWDs)

    @Test func parseLiveCWDsTimedOutReturnsNil() {
        #expect(OrphanGC.parseLiveCWDs(.timedOut) == nil,
                "a timed-out lsof must be 'unavailable', never 'no live processes'")
    }

    @Test func parseLiveCWDsNonZeroExitReturnsNil() {
        let outcome = BoundedProcessOutcome.completed(
            status: 1, stdout: Data("p123\nn/some/path\n".utf8), stderr: Data()
        )
        #expect(OrphanGC.parseLiveCWDs(outcome) == nil,
                "partial output from a failed lsof is not a complete cwd picture — fail toward keep")
    }

    @Test func parseLiveCWDsParsesCompletedOutput() {
        // Nonexistent paths pass through canon() unchanged (realpath fallback),
        // so expectations are deterministic. Mixed lines: p-prefixed pid
        // headers are dropped, n-prefixed cwds are kept (prefix stripped),
        // duplicates are deduped preserving first-seen order, and a bare "n"
        // (empty path) is dropped.
        let stdout = """
        p101
        n/nonexistent/gc-test/wt-a
        p102
        n/nonexistent/gc-test/wt-b
        p103
        n/nonexistent/gc-test/wt-a
        p104
        n
        """
        let outcome = BoundedProcessOutcome.completed(status: 0, stdout: Data(stdout.utf8), stderr: Data())
        let parsed = OrphanGC.parseLiveCWDs(outcome)
        #expect(parsed?.paths == ["/nonexistent/gc-test/wt-a", "/nonexistent/gc-test/wt-b"])
    }

    // MARK: - lsof unavailable skips the entire sweep

    @Test func sweepSkipsEntirelyWhenLiveCWDsUnavailable() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try TBDDatabase(inMemory: true)
        _ = try await db.repos.create(path: repo.path, displayName: "acme", defaultBranch: "main")

        let wtPath = try await makeAgentWorktree(repo: repo, name: "agent-x")

        let broadcaster = BroadcastDeltas()
        // Internal seam: a nil-returning provider simulates the real lsof
        // path's timeout/spawn-failure/non-zero-exit sentinel.
        let gc = OrphanGC(
            db: db,
            git: GitManager(),
            broadcast: { broadcaster.append($0) },
            liveCWDsProvider: { nil },
            scratchpadBase: nil,
            now: OrphanGCTests.farFuture
        )

        let result = await gc.sweep()

        #expect(result.reaped == 0)
        #expect(result.planned.contains { $0.contains("lsof unavailable") })
        #expect(FileManager.default.fileExists(atPath: wtPath),
                "an lsof outage must never be treated as 'no live processes'")
        let records = try await db.reapRecords.list(repoPath: nil)
        #expect(records.isEmpty)
        #expect(broadcaster.snapshot().isEmpty)
    }

    // MARK: - Dry-run scratchpad reconciliation

    @Test func sweepDryRunPlansScratchpadReconciliationWithoutMutating() async throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("orphan-gc-reconcile-test-\(UUID().uuidString)")
        let base = sandbox.appendingPathComponent("base")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let db = try TBDDatabase(inMemory: true)
        // Repo path deliberately nonexistent: candidates() returns [] and the
        // sweep's agent-worktree loop is a no-op, isolating reconciliation.
        let repo = try await db.repos.create(
            path: sandbox.appendingPathComponent("repo").path, displayName: "acme", defaultBranch: "main"
        )
        // Archived worktree row whose directory never existed on disk.
        let goneWorktreePath = sandbox.appendingPathComponent("gone-wt").path
        let row = try await db.worktrees.create(
            repoID: repo.id, name: "gone-wt", branch: "gone-wt",
            path: goneWorktreePath, tmuxServer: "test-server"
        )
        try await db.worktrees.archive(id: row.id)

        // Its scratchpad, however, survives in the injected base.
        let slug = ScratchpadCollector.slug(forWorktreePath: goneWorktreePath)
        let scratchDir = base.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        try "hi".write(to: scratchDir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let broadcaster = BroadcastDeltas()
        let gc = makeGC(db: db, git: GitManager(), broadcaster: broadcaster, scratchpadBase: base)

        let result = await gc.sweep(dryRun: true)

        #expect(result.planned.contains { $0.contains("REAP scratchpad") && $0.contains(scratchDir.path) })
        #expect(result.reaped == 0)
        #expect(FileManager.default.fileExists(atPath: scratchDir.path),
                "dry run must not remove the scratchpad")
        let records = try await db.reapRecords.list(repoPath: nil)
        #expect(records.isEmpty)
        #expect(broadcaster.snapshot().isEmpty)
    }

    @Test func sweepReconciliationStampsArchivedWorktreesOwningRepoPath() async throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("orphan-gc-reconcile-repopath-test-\(UUID().uuidString)")
        let base = sandbox.appendingPathComponent("base")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let db = try TBDDatabase(inMemory: true)
        // Repo path deliberately nonexistent: candidates() returns [] and the
        // sweep's agent-worktree loop is a no-op, isolating reconciliation.
        let repo = try await db.repos.create(
            path: sandbox.appendingPathComponent("repo").path, displayName: "acme", defaultBranch: "main"
        )
        let goneWorktreePath = sandbox.appendingPathComponent("gone-wt").path
        let row = try await db.worktrees.create(
            repoID: repo.id, name: "gone-wt", branch: "gone-wt",
            path: goneWorktreePath, tmuxServer: "test-server"
        )
        try await db.worktrees.archive(id: row.id)

        let slug = ScratchpadCollector.slug(forWorktreePath: goneWorktreePath)
        let scratchDir = base.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        try "hi".write(to: scratchDir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let broadcaster = BroadcastDeltas()
        let gc = makeGC(db: db, git: GitManager(), broadcaster: broadcaster, scratchpadBase: base)

        let result = await gc.sweep()

        #expect(result.reaped == 1)
        #expect(!FileManager.default.fileExists(atPath: scratchDir.path))
        let records = try await db.reapRecords.list(repoPath: nil)
        let record = try #require(records.first)
        #expect(record.kind == .scratchpad)
        #expect(record.repoPath == repo.path, "reconcile must resolve the archived row's repoID to its repo.path")
    }

    // MARK: - Event-driven scratchpad cleanup

    @Test func scratchpadEventCleanup() async throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("orphan-gc-scratch-test-\(UUID().uuidString)")
        let base = sandbox.appendingPathComponent("base")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let worktreePath = "/Users/chang/tbd/worktrees/removed-wt"
        let slug = ScratchpadCollector.slug(forWorktreePath: worktreePath)
        let scratchDir = base.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        try "hi".write(to: scratchDir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let db = try TBDDatabase(inMemory: true)
        let broadcaster = BroadcastDeltas()
        let gc = makeGC(db: db, git: GitManager(), broadcaster: broadcaster, scratchpadBase: base)

        await gc.scratchpadCleanup(forRemovedWorktreePath: worktreePath, repoPath: "/Users/chang/tbd")

        #expect(!FileManager.default.fileExists(atPath: scratchDir.path))
        let records = try await db.reapRecords.list(repoPath: nil)
        #expect(records.count == 1)
        #expect(records.first?.kind == .scratchpad)
        #expect(records.first?.repoPath == "/Users/chang/tbd", "event path must stamp the caller's repoPath")

        let deltas = broadcaster.snapshot()
        #expect(deltas.contains { if case .reapRecordsChanged = $0 { return true }; return false })
    }

    @Test func scratchpadEventCleanupKeepsWhenWorktreeDirStillExists() async throws {
        // Guards against the case where `completeArchiveWorktree`'s
        // `try?`-swallowed `git.worktreeRemove` actually failed: the
        // worktree directory is still there, so the scratchpad must not be
        // orphan-classified (and deleted) out from under a live session.
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("orphan-gc-scratch-dir-still-exists-test-\(UUID().uuidString)")
        let base = sandbox.appendingPathComponent("base")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let worktreeDir = sandbox.appendingPathComponent("still-here-wt")
        try FileManager.default.createDirectory(at: worktreeDir, withIntermediateDirectories: true)

        let slug = ScratchpadCollector.slug(forWorktreePath: worktreeDir.path)
        let scratchDir = base.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        try "hi".write(to: scratchDir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let db = try TBDDatabase(inMemory: true)
        let broadcaster = BroadcastDeltas()
        let gc = makeGC(db: db, git: GitManager(), broadcaster: broadcaster, scratchpadBase: base)

        await gc.scratchpadCleanup(forRemovedWorktreePath: worktreeDir.path, repoPath: "/Users/chang/tbd")

        #expect(FileManager.default.fileExists(atPath: scratchDir.path),
                "worktree dir still on disk — the removal must have failed, so the scratchpad stays intact")
        let records = try await db.reapRecords.list(repoPath: nil)
        #expect(records.isEmpty)
        #expect(broadcaster.snapshot().isEmpty)
    }

    // MARK: - Repo-removal scratchpad reconciliation

    /// Medium-2 review finding: `repo.remove` deletes ALL worktree rows for
    /// a repo (every status, incl. archived) via `deleteForRepo`, with no
    /// chance for the sweep's own reconciliation to catch up afterward.
    /// `reconcileScratchpadsBeforeRepoRemoval` must be called first and
    /// reclaim every row's scratchpad while the rows still resolve to a path.
    @Test func reconcileScratchpadsBeforeRepoRemovalReapsGoneRowsAcrossStatuses() async throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("orphan-gc-repo-removal-test-\(UUID().uuidString)")
        let base = sandbox.appendingPathComponent("base")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: sandbox.appendingPathComponent("repo").path, displayName: "acme", defaultBranch: "main"
        )

        // Archived row whose worktree dir is gone — its scratchpad survives.
        let archivedPath = sandbox.appendingPathComponent("archived-wt").path
        let archivedRow = try await db.worktrees.create(
            repoID: repo.id, name: "archived-wt", branch: "archived-wt",
            path: archivedPath, tmuxServer: "test-server"
        )
        try await db.worktrees.archive(id: archivedRow.id)

        // Active row whose worktree dir still exists on disk — its
        // scratchpad must be left alone (mirrors `reconcile`'s own
        // gone-only filter).
        let activePath = sandbox.appendingPathComponent("active-wt").path
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: activePath), withIntermediateDirectories: true)
        _ = try await db.worktrees.create(
            repoID: repo.id, name: "active-wt", branch: "active-wt",
            path: activePath, tmuxServer: "test-server"
        )

        let archivedSlug = ScratchpadCollector.slug(forWorktreePath: archivedPath)
        let archivedScratchDir = base.appendingPathComponent(archivedSlug)
        try FileManager.default.createDirectory(at: archivedScratchDir, withIntermediateDirectories: true)
        try "hi".write(to: archivedScratchDir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let activeSlug = ScratchpadCollector.slug(forWorktreePath: activePath)
        let activeScratchDir = base.appendingPathComponent(activeSlug)
        try FileManager.default.createDirectory(at: activeScratchDir, withIntermediateDirectories: true)

        let broadcaster = BroadcastDeltas()
        let gc = makeGC(db: db, git: GitManager(), broadcaster: broadcaster, scratchpadBase: base)

        await gc.reconcileScratchpadsBeforeRepoRemoval(repoID: repo.id, repoPath: repo.path)

        #expect(!FileManager.default.fileExists(atPath: archivedScratchDir.path),
                "the archived row's gone-worktree scratchpad must be reclaimed before the row disappears")
        #expect(FileManager.default.fileExists(atPath: activeScratchDir.path),
                "a scratchpad whose worktree dir still exists must be left alone")

        let records = try await db.reapRecords.list(repoPath: nil)
        #expect(records.count == 1)
        #expect(records.first?.kind == .scratchpad)
        #expect(records.first?.worktreePath == archivedScratchDir.path)
        #expect(records.first?.repoPath == repo.path, "must stamp the caller's repoPath, not a resolved one")

        let deltas = broadcaster.snapshot()
        #expect(deltas.contains { if case .reapRecordsChanged = $0 { return true }; return false })
    }

    @Test func reconcileScratchpadsBeforeRepoRemovalDisabledDoesNothing() async throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("orphan-gc-repo-removal-disabled-test-\(UUID().uuidString)")
        let base = sandbox.appendingPathComponent("base")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(false)
        let repo = try await db.repos.create(
            path: sandbox.appendingPathComponent("repo").path, displayName: "acme", defaultBranch: "main"
        )
        let goneWorktreePath = sandbox.appendingPathComponent("gone-wt").path
        let row = try await db.worktrees.create(
            repoID: repo.id, name: "gone-wt", branch: "gone-wt",
            path: goneWorktreePath, tmuxServer: "test-server"
        )
        try await db.worktrees.archive(id: row.id)

        let slug = ScratchpadCollector.slug(forWorktreePath: goneWorktreePath)
        let scratchDir = base.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)

        let broadcaster = BroadcastDeltas()
        let gc = makeGC(db: db, git: GitManager(), broadcaster: broadcaster, scratchpadBase: base)

        await gc.reconcileScratchpadsBeforeRepoRemoval(repoID: repo.id, repoPath: repo.path)

        #expect(FileManager.default.fileExists(atPath: scratchDir.path),
                "the gcEnabled master switch must suppress repo-removal reconciliation too")
        let records = try await db.reapRecords.list(repoPath: nil)
        #expect(records.isEmpty)
        #expect(broadcaster.snapshot().isEmpty)
    }

    @Test func scratchpadEventCleanupDisabledDoesNothing() async throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("orphan-gc-scratch-disabled-test-\(UUID().uuidString)")
        let base = sandbox.appendingPathComponent("base")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let worktreePath = "/Users/chang/tbd/worktrees/removed-wt"
        let slug = ScratchpadCollector.slug(forWorktreePath: worktreePath)
        let scratchDir = base.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        try "hi".write(to: scratchDir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(false)
        let broadcaster = BroadcastDeltas()
        let gc = makeGC(db: db, git: GitManager(), broadcaster: broadcaster, scratchpadBase: base)

        await gc.scratchpadCleanup(forRemovedWorktreePath: worktreePath, repoPath: "/Users/chang/tbd")

        #expect(FileManager.default.fileExists(atPath: scratchDir.path),
                "the gcEnabled master switch must suppress event-driven deletion too")
        let records = try await db.reapRecords.list(repoPath: nil)
        #expect(records.isEmpty)
        #expect(broadcaster.snapshot().isEmpty)
    }
}
