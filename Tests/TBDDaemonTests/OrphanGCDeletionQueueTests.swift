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

    private func makeGC(
        db: TBDDatabase, git: GitManager = GitManager(), now: @escaping @Sendable () -> Date = { Date() },
        beforeInterruptedArchiveReap: (@Sendable () async -> Void)? = nil
    ) -> OrphanGC {
        OrphanGC(
            db: db, git: git,
            broadcast: { _ in },
            liveCWDsProvider: { [] },
            scratchpadBase: nil,
            now: now,
            beforeInterruptedArchiveReap: beforeInterruptedArchiveReap,
            // Injected empty rather than defaulted. `sweep(dryRun: true)`
            // reaches the orphan-process phase regardless of
            // `gcOrphanProcessesEnabled`, and the default provider is the real
            // `/bin/ps -axww` over every process on the machine — a subprocess
            // this suite has no business spawning (`Tests/CLAUDE.md`: prefer the
            // injection seam). Behaviour-preserving: `liveCWDsProvider` is empty
            // too, so every pid's cwd is unreadable and the phase already plans
            // nothing.
            processSnapshotProvider: { [] }
        )
    }

    /// A real linked worktree at `<repo>/.tbd/worktrees/<name>` with an
    /// `.archived` row pointing at it — the shape a pre-queue archive left
    /// behind when its removal was killed partway.
    ///
    /// `stampArchivedAt` picks which of the two archived-row shapes the
    /// fixture wears. `false` uses `updateStatus`, leaving `archivedAt` nil —
    /// the pre-stamp leftover the grace gate deliberately does not hold.
    /// `true` goes through `WorktreeStore.archive`, which stamps the row
    /// `now`, so the grace window applies and the caller controls whether the
    /// sweep sees it as recent by choosing the GC's `now`.
    @discardableResult
    private func makeInterruptedArchive(
        db: TBDDatabase, repo: URL, repoID: UUID, name: String,
        stampArchivedAt: Bool = false
    ) async throws -> String {
        try await shell("mkdir -p .tbd/worktrees", at: repo)
        try await shell("git worktree add .tbd/worktrees/\(name) -b \(name)", at: repo)
        let path = repo.path + "/.tbd/worktrees/" + name
        let wt = try await db.worktrees.create(
            repoID: repoID, name: name, branch: name,
            path: path, tmuxServer: "tbd-test"
        )
        if stampArchivedAt {
            try await db.worktrees.archive(id: wt.id)
        } else {
            try await db.worktrees.updateStatus(id: wt.id, status: .archived)
        }
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
        let record = try #require(records.first {
            $0.kind == .archivedWorktree && $0.worktreePath == path
        })
        // The record has to carry what was reclaimed, not just that something
        // was. `ReclaimedSummary.archivedWorktreeRollup` sums `?? 0`, so a nil
        // here renders "N interrupted archives reclaimed · Zero KB" on a
        // machine where the motivating measurement was tens of gigabytes.
        // Measuring must therefore happen before the rename, while the
        // directory is still at `path`.
        let bytes = try #require(record.apparentBytes)
        #expect(bytes > 0)
        #expect(result.reaped >= 1)
    }

    @Test func sweepKeepsAnArchiveInsideTheGraceWindow() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        let repoRow = try await db.repos.create(
            path: repo.path, displayName: "acme", defaultBranch: "main")
        // Stamped just now: indistinguishable, by row and directory alone,
        // from an archive whose phase-2 hook is still running.
        let path = try await makeInterruptedArchive(
            db: db, repo: repo, repoID: repoRow.id, name: "inflight",
            stampArchivedAt: true)

        let result = await makeGC(db: db).sweep()

        #expect(FileManager.default.fileExists(atPath: path))
        #expect(result.planned.contains("KEEP grace \(path)"))
        let records = try await db.reapRecords.list(repoPath: nil)
        #expect(records.isEmpty)
    }

    @Test func sweepReclaimsAStampedArchiveOnceTheGraceWindowHasPassed() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        let repoRow = try await db.repos.create(
            path: repo.path, displayName: "acme", defaultBranch: "main")
        let path = try await makeInterruptedArchive(
            db: db, repo: repo, repoID: repoRow.id, name: "stale",
            stampArchivedAt: true)

        // Same fixture as the grace test — only the sweep's clock differs, so
        // this pair isolates the gate rather than anything else about the row.
        // The default grace window is one hour (`Config.defaultGCGraceSeconds`).
        let later = Date().addingTimeInterval(Double(Config.defaultGCGraceSeconds) + 600)
        let result = await makeGC(db: db, now: { later }).sweep()

        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(result.planned.contains("REAP archived-worktree \(path)"))
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

    @Test func sweepPrunesARegistrationWhoseDirectoryIsGoneAndRevivesAfterwards() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        let repoRow = try await db.repos.create(
            path: repo.path, displayName: "acme", defaultBranch: "main")

        // The wreckage a failed prune leaves: the directory has left its pool
        // slot (renamed into the queue and drained, or removed by hand) while
        // `.git/worktrees/<id>` survives. Nothing else in the sweep recovers
        // it — step 1 only drains bytes, and step 2 only ever sees candidates
        // whose directory still exists — so without an explicit prune the
        // worktree is unrevivable forever.
        try await shell("mkdir -p .tbd/worktrees", at: repo)
        try await shell("git worktree add .tbd/worktrees/zombie -b zombie", at: repo)
        let path = repo.path + "/.tbd/worktrees/zombie"
        let wt = try await db.worktrees.create(
            repoID: repoRow.id, name: "zombie", branch: "zombie",
            path: path, tmuxServer: "tbd-test")
        try await db.worktrees.archive(id: wt.id)
        try FileManager.default.removeItem(atPath: path)

        let git = GitManager()
        let before = try await git.worktreeList(repoPath: repo.path)
        try #require(
            before.contains { $0.path == path },
            "fixture invalid: git must still register the path for this to test anything")

        // The stale registration is pruned even inside the grace window: the
        // directory is already gone, so there is nothing a running archive
        // could still be using.
        let result = await makeGC(db: db, git: git).sweep()

        #expect(result.planned.contains("PRUNE stale-registration \(path)"))
        let after = try await git.worktreeList(repoPath: repo.path)
        #expect(!after.contains { $0.path == path })

        // The point of pruning: revive's preflight throws
        // `worktreeAlreadyRegistered` while the registration survives.
        let lifecycle = WorktreeLifecycle(
            db: db, git: git, tmux: TmuxManager(dryRun: true), hooks: HookResolver())
        let revived = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: true)
        #expect(revived.status == .active)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func sweepDrainsAQueueBesideAnAdoptedWorktree() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        let repoRow = try await db.repos.create(
            path: repo.path, displayName: "acme", defaultBranch: "main")

        // An adopted worktree lives wherever the user put it, and
        // `WorktreeDeletionQueue.enqueue` derives the pool from the worktree's
        // own parent — so archiving one puts `.deleting/` in a directory no
        // layout prefix covers. An interrupted drain there would otherwise sit
        // in the user's own directory forever.
        let outside = tmp.appendingPathComponent("elsewhere").path
        try FileManager.default.createDirectory(
            atPath: outside, withIntermediateDirectories: true)
        let path = outside + "/adopted"
        try await shell("git worktree add \(path) -b adopted", at: repo)
        let wt = try await db.worktrees.create(
            repoID: repoRow.id, name: "adopted", branch: "adopted",
            path: path, tmuxServer: "tbd-test")
        try await db.worktrees.updateStatus(id: wt.id, status: .archived)

        let queueDir = WorktreeDeletionQueue().queueDir(forPool: outside)
        let entry = queueDir + "/" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: entry, withIntermediateDirectories: true)
        try "junk".write(toFile: entry + "/f.txt", atomically: true, encoding: .utf8)

        let result = await makeGC(db: db).sweep()

        #expect(!FileManager.default.fileExists(atPath: entry))
        #expect(result.planned.contains("REAP queued-deletion \(entry)"))
        // Draining that pool must not widen what may be RECLAIMED: the
        // adopted worktree itself is still outside every TBD prefix.
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(result.planned.contains("KEEP not-tbd-prefix \(path)"))
    }

    /// `forgetWorktree` hard-deletes the row and promises the directory stays
    /// where it is. The sweep snapshots archived rows once and acts on them
    /// later, so a forget landing in that window would otherwise still have
    /// its directory reaped. The pre-reap re-read closes it.
    @Test func sweepSkipsACandidateWhoseRowWasForgottenMidSweep() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        let repoRow = try await db.repos.create(
            path: repo.path, displayName: "acme", defaultBranch: "main")
        let path = try await makeInterruptedArchive(
            db: db, repo: repo, repoID: repoRow.id, name: "forgotten")
        let wtID = try #require(
            (try await db.worktrees.list(status: .archived)).first { $0.localPath == path }?.id)

        // Interleaved exactly where the race lives: after the candidate list
        // was built, before anything is reaped.
        let gc = makeGC(db: db, beforeInterruptedArchiveReap: {
            try? await db.worktrees.delete(id: wtID)
        })
        let result = await gc.sweep()

        #expect(FileManager.default.fileExists(atPath: path),
                "forget promises the directory stays put — the sweep must not reap it")
        #expect(result.planned.contains("KEEP row-changed \(path)"))
        let records = try await db.reapRecords.list(repoPath: nil)
        #expect(records.isEmpty)
    }

    /// The same window, entered through the other door: the row survives but
    /// is no longer `.archived` (a revive that landed mid-sweep). Reaping then
    /// would rename a live worktree's directory out from under it.
    @Test func sweepSkipsACandidateRevivedMidSweep() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        let repoRow = try await db.repos.create(
            path: repo.path, displayName: "acme", defaultBranch: "main")
        let path = try await makeInterruptedArchive(
            db: db, repo: repo, repoID: repoRow.id, name: "revived")
        let wtID = try #require(
            (try await db.worktrees.list(status: .archived)).first { $0.localPath == path }?.id)

        let gc = makeGC(db: db, beforeInterruptedArchiveReap: {
            try? await db.worktrees.updateStatus(id: wtID, status: .active)
        })
        let result = await gc.sweep()

        #expect(FileManager.default.fileExists(atPath: path))
        #expect(result.planned.contains("KEEP row-changed \(path)"))
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
