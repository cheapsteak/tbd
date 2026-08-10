import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared
import TestSupport

/// Thread-safe `StateDelta` collector, matching `OrphanGCTests`.
private final class BroadcastDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [StateDelta] = []
    func append(_ delta: StateDelta) {
        lock.lock(); defer { lock.unlock() }
        deltas.append(delta)
    }
}

@Suite("OrphanGC reclaims the deletion queue")
struct OrphanGCDeletionQueueTests {

    private func makeGC(db: TBDDatabase, git: GitManager = GitManager()) -> OrphanGC {
        OrphanGC(
            db: db, git: git,
            broadcast: { _ in },
            lsofProvider: { [] },
            scratchpadBase: nil,
            now: { Date() }
        )
    }

    /// A real linked worktree at `<repo>/.tbd/worktrees/<name>` with an
    /// `.archived` row pointing at it — the shape a pre-queue archive left
    /// behind when its removal was killed partway.
    private func makeInterruptedArchive(
        db: TBDDatabase, repo: URL, repoID: UUID, name: String
    ) async throws -> String {
        try await shell("mkdir -p .tbd/worktrees", at: repo)
        try await shell("git worktree add .tbd/worktrees/\(name) -b \(name)", at: repo)
        let path = repo.path + "/.tbd/worktrees/" + name
        let wt = try await db.worktrees.create(
            repoID: repoID, name: name, branch: name,
            path: path, tmuxServer: "tbd-test"
        )
        try await db.worktrees.updateStatus(id: wt.id, status: .archived)
        return path
    }

    /// A stray `.deleting/<uuid>` entry a previous daemon run queued but
    /// never finished draining — the step-1 fixture shape, factored out so
    /// the gated-behavior tests can prove step 1 respects the same gates as
    /// step 2 without duplicating the queue-dir plumbing.
    private func makeQueuedEntry(repo: URL) throws -> String {
        let pool = repo.path + "/.tbd/worktrees"
        let queueDir = WorktreeDeletionQueue().queueDir(forPool: pool)
        let entry = queueDir + "/" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: entry, withIntermediateDirectories: true)
        try "junk".write(
            toFile: entry + "/f.txt", atomically: true, encoding: .utf8)
        return entry
    }

    @Test func sweepDrainsLeftoverQueueEntries() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        _ = try await db.repos.create(
            path: repo.path, displayName: "acme", defaultBranch: "main")

        let entry = try makeQueuedEntry(repo: repo)

        let result = await makeGC(db: db).sweep()

        #expect(!FileManager.default.fileExists(atPath: entry))
        #expect(result.planned.contains("REAP queued-deletion \(entry)"))
    }

    @Test func sweepReclaimsAnInterruptedArchive() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        let repoRow = try await db.repos.create(
            path: repo.path, displayName: "acme", defaultBranch: "main")
        let path = try await makeInterruptedArchive(
            db: db, repo: repo, repoID: repoRow.id, name: "zombie")

        let result = await makeGC(db: db).sweep()

        #expect(!FileManager.default.fileExists(atPath: path))
        let registered = try await GitManager().worktreeList(repoPath: repo.path)
        #expect(!registered.contains { $0.path == path })
        let records = try await db.reapRecords.list(repoPath: nil)
        #expect(records.contains { $0.kind == .archivedWorktree && $0.worktreePath == path })
        #expect(result.reaped >= 1)
    }

    @Test func sweepKeepsAnArchivedWorktreeOutsideTBDPrefixes() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        let repoRow = try await db.repos.create(
            path: repo.path, displayName: "acme", defaultBranch: "main")

        // An adopted worktree: real, linked, archived — but somewhere TBD
        // never puts its own worktrees, so provenance is unprovable.
        let outside = tmp.appendingPathComponent("elsewhere").path
        try FileManager.default.createDirectory(
            atPath: outside, withIntermediateDirectories: true)
        let path = outside + "/adopted"
        try await shell("git worktree add \(path) -b adopted", at: repo)
        let wt = try await db.worktrees.create(
            repoID: repoRow.id, name: "adopted", branch: "adopted",
            path: path, tmuxServer: "tbd-test")
        try await db.worktrees.updateStatus(id: wt.id, status: .archived)

        let result = await makeGC(db: db).sweep()

        #expect(FileManager.default.fileExists(atPath: path))
        #expect(result.planned.contains("KEEP not-tbd-prefix \(path)"))
    }

    @Test func dryRunPlansWithoutTouchingDisk() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        let repoRow = try await db.repos.create(
            path: repo.path, displayName: "acme", defaultBranch: "main")
        let path = try await makeInterruptedArchive(
            db: db, repo: repo, repoID: repoRow.id, name: "zombie")
        // Also cover step 1 (already-queued entries): without this fixture,
        // nothing here proves `dryRun` suppresses `deletionQueueCollector
        // .drain(entry)` in the queued-deletion loop — only that it
        // suppresses step 2's archive reap.
        let entry = try makeQueuedEntry(repo: repo)

        let result = await makeGC(db: db).sweep(dryRun: true)

        #expect(FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.fileExists(atPath: entry))
        #expect(result.reaped == 0)
        #expect(result.planned.contains("REAP archived-worktree \(path)"))
        #expect(result.planned.contains("REAP queued-deletion \(entry)"))
        let records = try await db.reapRecords.list(repoPath: nil)
        #expect(records.isEmpty)
    }

    @Test func sweepDoesNothingWhenGCDisabled() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(false)
        let repoRow = try await db.repos.create(
            path: repo.path, displayName: "acme", defaultBranch: "main")
        let path = try await makeInterruptedArchive(
            db: db, repo: repo, repoID: repoRow.id, name: "zombie")
        // Also cover step 1: without this fixture, nothing here proves
        // `gcEnabled == false` suppresses `deletionQueueCollector.drain(entry)`
        // in the queued-deletion loop — only that it suppresses step 2.
        let entry = try makeQueuedEntry(repo: repo)

        let result = await makeGC(db: db).sweep()

        #expect(FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.fileExists(atPath: entry))
        #expect(result.reaped == 0)
        let records = try await db.reapRecords.list(repoPath: nil)
        #expect(records.isEmpty)
    }
}
