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
        let source = pool + "/does-not-exist"
        #expect {
            try queue.enqueue(worktreePath: source)
        } throws: { error in
            guard case let .renameFailed(from, to, code) = error as? WorktreeDeletionQueueError else {
                return false
            }
            return from == source
                && to.hasPrefix(pool + "/" + WorktreeDeletionQueue.dirName + "/")
                && code == ENOENT
        }
    }

    /// Proves `enqueue` really calls the `rename(2)` syscall and not
    /// `FileManager.moveItem`, which would silently succeed across
    /// filesystems via copy-then-delete instead of surfacing `EXDEV`. The
    /// injected stub simulates the destination being on a different
    /// filesystem; a regression to `moveItem` would not exercise this seam at
    /// all, since `moveItem` never calls it.
    @Test func enqueueSurfacesEXDEVFromTheInjectedRenameSeam() throws {
        let (tmp, pool, wt) = try makePool()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let queue = WorktreeDeletionQueue(renameItem: { _, _ in
            errno = EXDEV
            return -1
        })

        #expect {
            try queue.enqueue(worktreePath: wt)
        } throws: { error in
            guard case let .renameFailed(from, to, code) = error as? WorktreeDeletionQueueError else {
                return false
            }
            return from == wt
                && to.hasPrefix(pool + "/" + WorktreeDeletionQueue.dirName + "/")
                && code == EXDEV
        }
        // The stub never actually moved anything.
        #expect(FileManager.default.fileExists(atPath: wt))
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

    @Test func drainRemovesEntryBytesAndReportsSuccess() async throws {
        let (tmp, pool, wt) = try makePool()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let queue = WorktreeDeletionQueue()
        let entry = try queue.enqueue(worktreePath: wt)

        #expect(await queue.drain(entry) == true)
        #expect(!FileManager.default.fileExists(atPath: entry.path))
        #expect(queue.pending(pool: pool).isEmpty)
    }

    @Test func drainIsIdempotentOnAnAlreadyDrainedEntry() async throws {
        let (tmp, _, wt) = try makePool()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let queue = WorktreeDeletionQueue()
        let entry = try queue.enqueue(worktreePath: wt)
        #expect(await queue.drain(entry) == true)
        // A second sweep must treat a vanished entry as done, not as failure.
        #expect(await queue.drain(entry) == true)
    }

    @Test func drainResumesAfterAPartiallyDeletedEntry() async throws {
        let (tmp, pool, wt) = try makePool()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let queue = WorktreeDeletionQueue()
        let entry = try queue.enqueue(worktreePath: wt)
        // Simulate an interrupted drain: some children already gone, dir remains.
        try FileManager.default.removeItem(atPath: entry.path + "/file.txt")

        #expect(await queue.drain(entry) == true)
        #expect(queue.pending(pool: pool).isEmpty)
    }

    @Test func drainRefusesAPathOutsideAQueueDirectory() async throws {
        let (tmp, _, wt) = try makePool()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // `QueuedDeletion.init` is public and `drain` is a recursive delete of
        // whatever path it is handed, so it carries an anchor check the same
        // way `ScratchpadCollector.cleanUp` does before its own `removeItem`.
        // Here the "entry" names a live worktree directory rather than
        // anything TBD renamed into `.deleting/`.
        let queue = WorktreeDeletionQueue()
        #expect(await queue.drain(QueuedDeletion(path: wt, originalPath: wt)) == false)
        #expect(FileManager.default.fileExists(atPath: wt + "/file.txt"))
    }

    /// Tier 2. The unlink must run on the type's serial drain queue, not on
    /// the caller's thread: `drain` is reached from detached tasks on the
    /// cooperative pool, and removing a dependency-heavy worktree takes
    /// minutes, so an inline `removeItem` parks a pool thread for that long —
    /// one per concurrent archive.
    ///
    /// Occupies the drain queue with a gated work item, then starts a drain
    /// and shows the bytes are still there while the queue is busy, and gone
    /// once it is released. An inline implementation — including an `async`
    /// one that simply never hops — deletes the entry while the gate is still
    /// held and fails the middle assertion.
    @Test func drainQueuesTheUnlinkBehindTheSerialDrainQueue() async throws {
        let (tmp, pool, wt) = try makePool()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let queue = WorktreeDeletionQueue()
        let entry = try queue.enqueue(worktreePath: wt)

        // Signalled in a `defer` so a failure anywhere below cannot leave the
        // process-wide drain queue blocked for other suites.
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let occupied = Flag()
        WorktreeDeletionQueue.drainQueue.async {
            occupied.set()
            gate.wait()
        }
        try await waitUntil(occupied.isSet, "drain queue never picked up the gate item")

        let entered = Flag()
        let drained = Task { () -> Bool in
            entered.set()
            return await queue.drain(entry)
        }
        try await waitUntil(entered.isSet, "drain task never started")
        // Room for an inline implementation to have finished: the entry is one
        // small file, so its removal would land in microseconds once the task
        // is running.
        try await Task.sleep(for: .milliseconds(200))
        #expect(FileManager.default.fileExists(atPath: entry.path))

        gate.signal()
        #expect(await drained.value == true)
        #expect(!FileManager.default.fileExists(atPath: entry.path))
        #expect(queue.pending(pool: pool).isEmpty)
    }

    /// Bounded poll (no wall-clock assertion): fails with a named diagnostic
    /// rather than hanging if the condition never becomes true.
    private func waitUntil(
        _ condition: @autoclosure () -> Bool, _ what: String,
        timeout: Duration = .seconds(10)
    ) async throws {
        let step = Duration.milliseconds(10)
        var waited = Duration.zero
        while !condition() {
            if waited >= timeout { throw WaitTimeout(what: what, after: timeout) }
            try await Task.sleep(for: step)
            waited += step
        }
    }

    private struct WaitTimeout: Error, CustomStringConvertible {
        let what: String
        let after: Duration
        var description: String { "timed out after \(after): \(what)" }
    }

    /// Minimal lock-guarded boolean; the drain queue sets it from a dispatch
    /// thread while the test task reads it.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
}
