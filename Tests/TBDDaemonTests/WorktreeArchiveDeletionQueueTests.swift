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

    @Test func theFallbackRemovalArmsItsOwnRaisedTimeout() async throws {
        let harness = try await ArchiveHarness.make()
        defer { harness.cleanUp() }

        // The entire bug was a removal killed by a deadline, so dropping the
        // `timeout:` argument at the fallback call site — or shrinking the
        // constant — must go red. This gives the archive a `GitManager` whose
        // INSTANCE deadline no real subprocess can meet: if the fallback leg
        // stopped passing its own raised timeout, `git worktree remove` would
        // be killed and the directory would survive.
        //
        // `runBoundedProcess` makes that discriminating rather than racy —
        // its completion path compares real elapsed time against the armed
        // deadline and reports `.timedOut` even when every armer was late, so
        // a 1 ms deadline cannot accidentally pass.
        let impatient = GitManager(subprocessTimeout: .milliseconds(1))

        // Control: prove that deadline really is fatal, on a throwaway
        // worktree of the same repo. Without this, a fallback that silently
        // did nothing would look identical to one that succeeded.
        let control = (harness.tempDir.path as NSString).appendingPathComponent("control-wt")
        try await shell(
            "git worktree add \(control) -b control-branch",
            at: URL(fileURLWithPath: harness.repoPath))
        await #expect(throws: GitTimeoutError.self) {
            try await impatient.worktreeRemove(
                repoPath: harness.repoPath, worktreePath: control)
        }
        #expect(FileManager.default.fileExists(atPath: control))

        // Force the archive onto the fallback leg: occupy the queue-dir name
        // with a regular file so `enqueue` cannot create `.deleting/`.
        let pool = (harness.worktreePath as NSString).deletingLastPathComponent
        let queueDir = WorktreeDeletionQueue().queueDir(forPool: pool)
        try "not a directory".write(toFile: queueDir, atomically: true, encoding: .utf8)

        let lifecycle = WorktreeLifecycle(
            db: harness.db, git: impatient,
            tmux: TmuxManager(dryRun: true), hooks: HookResolver())
        try await lifecycle.archiveWorktree(worktreeID: harness.worktreeID)

        #expect(!FileManager.default.fileExists(atPath: harness.worktreePath))
    }

    @Test func onWorktreeRemovedNeverFiresWhenBothEnqueueAndFallbackFail() async throws {
        // The headline guarantee — the callback fires only when the directory
        // is genuinely gone — has no coverage unless BOTH removal paths are
        // made to fail. Otherwise a regression back to an unconditional
        // `if let onWorktreeRemoved` would go undetected: every other test
        // here has one path succeed, so the callback firing looks correct
        // either way.
        let observed = ObservedRemoval()
        let harness = try await ArchiveHarness.make(onWorktreeRemoved: { path, _ in
            await observed.record(
                path: path,
                existedAtCallTime: FileManager.default.fileExists(atPath: path)
            )
        })
        defer { harness.cleanUp() }

        // Force `enqueue` to fail: occupy the queue-dir name with a regular
        // file, same technique as `enqueueFailureFallsBackToGitWorktreeRemove`.
        let pool = (harness.worktreePath as NSString).deletingLastPathComponent
        let queueDir = WorktreeDeletionQueue().queueDir(forPool: pool)
        try "not a directory".write(toFile: queueDir, atomically: true, encoding: .utf8)

        // Force the fallback `git worktree remove --force` to fail too: mark
        // a file inside the worktree user-immutable (`chflags uchg`), which
        // makes the recursive delete underneath `git worktree remove` return
        // "Operation not permitted" and leave the directory in place —
        // verified directly: exit code 255, directory and marker both
        // survive. `--force` bypasses git's own dirty/locked-worktree
        // refusals but has no effect on a filesystem-level EPERM.
        let markerPath = (harness.worktreePath as NSString).appendingPathComponent("immutable-marker")
        #expect(FileManager.default.createFile(atPath: markerPath, contents: Data("x".utf8)))
        try #require(chflags(markerPath, UInt32(UF_IMMUTABLE)) == 0, "chflags must succeed for this test to force a real removal failure")
        defer { chflags(markerPath, 0) } // clear before cleanUp()'s removeItem, else that fails too

        try await harness.lifecycle.archiveWorktree(worktreeID: harness.worktreeID)

        #expect(await observed.paths.isEmpty, "the callback must never fire when neither removal path succeeded")
        #expect(FileManager.default.fileExists(atPath: harness.worktreePath), "nothing removed the worktree — it must still be there")
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
    let db: TBDDatabase
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
            db: db,
            git: lifecycle.git,
            repoPath: repo.path,
            worktreePath: worktree.localPath,
            worktreeID: worktree.id,
            tempDir: tempDir
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: tempDir)
    }
}
