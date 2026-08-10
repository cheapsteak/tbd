import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared
import TestSupport

@Suite("Worktree archive uses the deletion queue")
struct WorktreeArchiveDeletionQueueTests {

    @Test func archiveClearsThePoolSlotAndDropsTheGitRegistration() async throws {
        let harness = try await ArchiveHarness.make()
        defer { harness.cleanUp() }

        try await harness.lifecycle.archiveWorktree(worktreeID: harness.worktreeID)

        #expect(!FileManager.default.fileExists(atPath: harness.worktreePath))
        let registered = try await harness.git.worktreeList(repoPath: harness.repoPath)
        #expect(!registered.contains { $0.path == harness.worktreePath })
    }

    @Test func archiveDrainsTheQueueSoNoBytesRemain() async throws {
        let harness = try await ArchiveHarness.make()
        defer { harness.cleanUp() }

        try await harness.lifecycle.archiveWorktree(worktreeID: harness.worktreeID)

        let pool = (harness.worktreePath as NSString).deletingLastPathComponent
        #expect(WorktreeDeletionQueue().pending(pool: pool).isEmpty)
        let queueDir = WorktreeDeletionQueue().queueDir(forPool: pool)
        // Assert existence explicitly rather than swallowing the lookup error
        // with `try?` — a queue dir that was never created and one that was
        // created-then-emptied both read as "no leftovers" under `try? … ?? []`,
        // which made the old form pass whether or not the queue was ever used.
        // Existence proves `enqueue` ran (only `enqueue` creates `.deleting/`);
        // emptiness proves `drain` ran.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: queueDir, isDirectory: &isDirectory)
        #expect(exists, "the queue directory must exist — its absence means archive never went through the queue")
        #expect(isDirectory.boolValue)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: queueDir)
        #expect(leftovers.isEmpty, "drain must have removed the queued entry")
    }

    @Test func onWorktreeRemovedFiresOnceThePathIsGone() async throws {
        // `WorktreeLifecycle` is a struct, so the callback is supplied at
        // construction rather than assigned onto a stored instance.
        let observed = ObservedRemoval()
        let harness = try await ArchiveHarness.make(onWorktreeRemoved: { path, _ in
            await observed.record(
                path: path,
                existedAtCallTime: FileManager.default.fileExists(atPath: path)
            )
        })
        defer { harness.cleanUp() }

        try await harness.lifecycle.archiveWorktree(worktreeID: harness.worktreeID)

        #expect(await observed.paths == [harness.worktreePath])
        // The whole point of moving the callback after a verified removal.
        #expect(await observed.everSawSurvivingPath == false)
    }

    @Test func enqueueFailureFallsBackToGitWorktreeRemove() async throws {
        let harness = try await ArchiveHarness.make()
        defer { harness.cleanUp() }

        // Make the queue directory un-creatable so `enqueue` throws: occupy its
        // name with a regular file.
        let pool = (harness.worktreePath as NSString).deletingLastPathComponent
        let queueDir = WorktreeDeletionQueue().queueDir(forPool: pool)
        try "not a directory".write(toFile: queueDir, atomically: true, encoding: .utf8)

        try await harness.lifecycle.archiveWorktree(worktreeID: harness.worktreeID)

        // The planted file is still there and still a plain file — proves
        // `enqueue`'s `createDirectory` genuinely failed to turn `.deleting/`
        // into a usable directory, i.e. the archive really took the fallback
        // leg rather than the queue succeeding some other way.
        var isDirectory: ObjCBool = false
        let stillExists = FileManager.default.fileExists(atPath: queueDir, isDirectory: &isDirectory)
        #expect(stillExists, "the planted file must still occupy the queue-dir path")
        #expect(!isDirectory.boolValue, "the queue dir must never have become usable — proves enqueue failed")

        // Fallback still removed the worktree and its registration.
        #expect(!FileManager.default.fileExists(atPath: harness.worktreePath))
        let registered = try await harness.git.worktreeList(repoPath: harness.repoPath)
        #expect(!registered.contains { $0.path == harness.worktreePath })
    }
}

/// Records `onWorktreeRemoved` invocations and whether the path still existed
/// when the callback ran.
private actor ObservedRemoval {
    private(set) var paths: [String] = []
    private(set) var everSawSurvivingPath = false

    func record(path: String, existedAtCallTime: Bool) {
        paths.append(path)
        if existedAtCallTime { everSawSurvivingPath = true }
    }
}

/// Shared setup for the archive-through-the-queue tests, modeled on
/// `ArchiveScratchpadCleanupTests`'s database/repo/worktree construction.
struct ArchiveHarness {
    let lifecycle: WorktreeLifecycle
    let git: GitManager
    let repoPath: String
    let worktreePath: String
    let worktreeID: UUID
    let tempDir: URL

    static func make(
        onWorktreeRemoved: (@Sendable (_ worktreePath: String, _ repoPath: String) async -> Void)? = nil
    ) async throws -> ArchiveHarness {
        let (tempDir, repoDir) = try await createTestRepo()
        let db = try TBDDatabase(inMemory: true)
        var lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(dryRun: true),
            hooks: HookResolver()
        )
        lifecycle.onWorktreeRemoved = onWorktreeRemoved

        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let worktree = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

        return ArchiveHarness(
            lifecycle: lifecycle,
            git: lifecycle.git,
            repoPath: repo.path,
            worktreePath: worktree.path,
            worktreeID: worktree.id,
            tempDir: tempDir
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: tempDir)
    }
}
