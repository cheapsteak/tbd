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

        await gc.scratchpadCleanup(forRemovedWorktreePath: worktreePath)

        #expect(!FileManager.default.fileExists(atPath: scratchDir.path))
        let records = try await db.reapRecords.list(repoPath: nil)
        #expect(records.count == 1)
        #expect(records.first?.kind == .scratchpad)

        let deltas = broadcaster.snapshot()
        #expect(deltas.contains { if case .reapRecordsChanged = $0 { return true }; return false })
    }
}
