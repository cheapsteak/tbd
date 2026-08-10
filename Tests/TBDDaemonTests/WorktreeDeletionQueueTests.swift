import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared

@Suite("WorktreeDeletionQueue")
struct WorktreeDeletionQueueTests {

    /// Builds `<tmp>/pool/<name>/` holding one file, and returns (tmp, pool, worktreePath).
    private func makePool(name: String = "wt") throws -> (tmp: URL, pool: String, worktree: String) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dq-\(UUID().uuidString)")
        let pool = tmp.appendingPathComponent("pool")
        let wt = pool.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        try "hello".write(to: wt.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        return (tmp, pool.path, wt.path)
    }

    @Test func enqueueMovesWorktreeIntoQueueDirAndLeavesSlotEmpty() throws {
        let (tmp, pool, wt) = try makePool()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let queue = WorktreeDeletionQueue()
        let entry = try queue.enqueue(worktreePath: wt)

        #expect(!FileManager.default.fileExists(atPath: wt))
        #expect(FileManager.default.fileExists(atPath: entry.path))
        #expect(entry.path.hasPrefix(pool + "/" + WorktreeDeletionQueue.dirName + "/"))
        #expect(entry.originalPath == wt)
        // Contents moved intact, not copied and truncated.
        let moved = entry.path + "/file.txt"
        #expect(try String(contentsOfFile: moved, encoding: .utf8) == "hello")
    }

    @Test func enqueueGivesEachEntryADistinctDestination() throws {
        let (tmp, _, wtA) = try makePool(name: "a")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wtB = (wtA as NSString).deletingLastPathComponent + "/b"
        try FileManager.default.createDirectory(atPath: wtB, withIntermediateDirectories: true)

        let queue = WorktreeDeletionQueue()
        let a = try queue.enqueue(worktreePath: wtA)
        let b = try queue.enqueue(worktreePath: wtB)

        #expect(a.path != b.path)
    }

    @Test func enqueueThrowsRenameFailedWhenSourceMissing() throws {
        let (tmp, pool, _) = try makePool()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let queue = WorktreeDeletionQueue()
        #expect(throws: WorktreeDeletionQueueError.self) {
            try queue.enqueue(worktreePath: pool + "/does-not-exist")
        }
    }

    @Test func pendingEnumeratesEntriesLeftByAPreviousRun() throws {
        let (tmp, pool, wt) = try makePool()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let queue = WorktreeDeletionQueue()
        let entry = try queue.enqueue(worktreePath: wt)

        let found = queue.pending(pool: pool)
        #expect(found.map(\.path) == [entry.path])
    }

    @Test func pendingIsEmptyWhenQueueDirAbsent() throws {
        let (tmp, pool, _) = try makePool()
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(WorktreeDeletionQueue().pending(pool: pool).isEmpty)
    }

    @Test func drainRemovesEntryBytesAndReportsSuccess() throws {
        let (tmp, pool, wt) = try makePool()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let queue = WorktreeDeletionQueue()
        let entry = try queue.enqueue(worktreePath: wt)

        #expect(queue.drain(entry) == true)
        #expect(!FileManager.default.fileExists(atPath: entry.path))
        #expect(queue.pending(pool: pool).isEmpty)
    }

    @Test func drainIsIdempotentOnAnAlreadyDrainedEntry() throws {
        let (tmp, _, wt) = try makePool()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let queue = WorktreeDeletionQueue()
        let entry = try queue.enqueue(worktreePath: wt)
        #expect(queue.drain(entry) == true)
        // A second sweep must treat a vanished entry as done, not as failure.
        #expect(queue.drain(entry) == true)
    }

    @Test func drainResumesAfterAPartiallyDeletedEntry() throws {
        let (tmp, pool, wt) = try makePool()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let queue = WorktreeDeletionQueue()
        let entry = try queue.enqueue(worktreePath: wt)
        // Simulate an interrupted drain: some children already gone, dir remains.
        try FileManager.default.removeItem(atPath: entry.path + "/file.txt")

        #expect(queue.drain(entry) == true)
        #expect(queue.pending(pool: pool).isEmpty)
    }
}
