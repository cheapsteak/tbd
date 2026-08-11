import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "deletionQueue")

/// Thread-safe rendering of an errno value. `strerror(3)` returns a pointer
/// into a shared static buffer and is not safe to call concurrently;
/// `strerror_r(3)` fills a caller-owned buffer instead.
private func describeErrno(_ code: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    if strerror_r(code, &buffer, buffer.count) == 0 {
        return String(cString: buffer)
    }
    return "errno \(code)"
}

/// A worktree directory that has been renamed out of its pool slot and is
/// waiting for its bytes to be reclaimed.
public struct QueuedDeletion: Sendable, Equatable {
    /// Where the directory lives now: `<pool>/.deleting/<uuid>`.
    public let path: String
    /// The pool slot it was renamed out of. Retained for logging and reap
    /// records; nothing reads it back off disk.
    public let originalPath: String

    public init(path: String, originalPath: String) {
        self.path = path
        self.originalPath = originalPath
    }
}

public enum WorktreeDeletionQueueError: Error, CustomStringConvertible, Equatable {
    /// `rename(2)` refused. `errno` is `EXDEV` when the queue directory landed
    /// on a different filesystem than the worktree — the case the archive
    /// path's fallback exists for.
    case renameFailed(from: String, to: String, errno: Int32)

    public var description: String {
        switch self {
        case let .renameFailed(from, to, code):
            return "rename(\(from) -> \(to)) failed: \(describeErrno(code)) (errno \(code))"
        }
    }
}

/// Owns the hand-off point between "this worktree is archived" and "its bytes
/// are gone".
///
/// Removing a worktree means unlinking every file in it, which for a
/// dependency-heavy repo is 200,000+ entries and minutes of wall clock — far
/// past any subprocess deadline. Renaming it is one syscall and takes
/// milliseconds regardless of size. So archiving renames the directory into
/// `<pool>/.deleting/<uuid>` and treats that as the commit point: once the
/// rename lands and git's registration is pruned, the worktree is gone as far
/// as TBD and git are concerned, and reclaiming the bytes can take as long as
/// it needs. An interrupted drain leaves an entry that is unambiguously
/// garbage, which the GC sweep finishes later.
///
/// The queue directory is a sibling of the worktree directories rather than one
/// global location because `rename(2)` cannot cross filesystems and pools may
/// live outside `TBD_HOME`.
public struct WorktreeDeletionQueue: Sendable {
    /// Leading dot so pool-listing loops skip it the way they already skip
    /// other dotfiles.
    public static let dirName = ".deleting"

    /// Where `drain`'s unlink loop actually runs.
    ///
    /// Serial, and `static` so every drain in the process shares it — an
    /// archive's inline drain, a concurrent archive's, and the GC sweep's all
    /// queue behind one another even though each holds its own
    /// `WorktreeDeletionQueue` value. That is the design's stated position
    /// (spec, "`WorktreeDeletionQueue`"): draining one entry at a time costs
    /// nothing, because nothing waits on the queue emptying, while parallel
    /// drains saturate the disk against whatever the developer is doing and
    /// give each removal a quarter of the throughput anyway.
    ///
    /// It is also what keeps a minutes-long `removeItem` off the cooperative
    /// pool. `drain` is called from detached tasks, so running the unlink
    /// inline would park a pool thread for the whole removal — 70 s to several
    /// minutes for a dependency-heavy worktree — and concurrent archives would
    /// park one each.
    ///
    /// Internal rather than private so a test can occupy it and prove `drain`
    /// really queues behind it instead of unlinking inline.
    static let drainQueue = DispatchQueue(
        label: "com.tbd.daemon.deletion-queue.drain", qos: .utility
    )

    /// The rename primitive `enqueue` calls. Defaults to the real `rename(2)`
    /// syscall; tests substitute a stub to force specific `errno` values
    /// (e.g. `EXDEV`) without needing two real filesystems, and to prove that
    /// production really goes through the syscall rather than
    /// `FileManager.moveItem`'s cross-filesystem copy-then-delete fallback.
    private let renameItem: @Sendable (String, String) -> Int32

    public init() {
        self.renameItem = { rename($0, $1) }
    }

    /// Test seam: inject a stand-in for `rename(2)`.
    init(renameItem: @escaping @Sendable (String, String) -> Int32) {
        self.renameItem = renameItem
    }

    public func queueDir(forPool pool: String) -> String {
        (pool as NSString).appendingPathComponent(Self.dirName)
    }

    /// Renames `worktreePath` into its pool's queue directory.
    ///
    /// Uses `rename(2)` rather than `FileManager.moveItem`, which silently
    /// degrades to a recursive copy-then-delete across filesystems — turning a
    /// millisecond operation into a multi-minute one that also doubles peak
    /// disk usage. Failing fast with `EXDEV` is the correct outcome; the caller
    /// falls back to an in-place removal.
    public func enqueue(worktreePath: String) throws -> QueuedDeletion {
        let pool = (worktreePath as NSString).deletingLastPathComponent
        let dir = queueDir(forPool: pool)
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        let destination = (dir as NSString).appendingPathComponent(UUID().uuidString)

        if renameItem(worktreePath, destination) != 0 {
            let code = errno
            throw WorktreeDeletionQueueError.renameFailed(
                from: worktreePath, to: destination, errno: code
            )
        }
        logger.debug("""
        deletionQueue: enqueued \(worktreePath, privacy: .public) \
        as \(destination, privacy: .public)
        """)
        return QueuedDeletion(path: destination, originalPath: worktreePath)
    }

    /// Entries awaiting reclamation in this pool, including ones a previous
    /// daemon run left behind. `originalPath` is unknown for those, so it is
    /// reported as the entry path itself.
    public func pending(pool: String) -> [QueuedDeletion] {
        let dir = queueDir(forPool: pool)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return []
        }
        return names.sorted().map { name in
            let path = (dir as NSString).appendingPathComponent(name)
            return QueuedDeletion(path: path, originalPath: path)
        }
    }

    /// Reclaims one entry's bytes. Returns `true` when the entry is gone —
    /// including when it was already gone, so a repeated sweep is a no-op
    /// rather than a reported failure. A partially deleted entry is resumed on
    /// the next call.
    ///
    /// Refuses any path that is not inside a `.deleting/` directory. Entries
    /// normally come from `enqueue` or `pending`, both of which can only
    /// produce queue paths — but `QueuedDeletion.init` is public, so this is a
    /// recursive delete of a caller-supplied path, and the anchor check is the
    /// same defense `ScratchpadCollector.cleanUp` puts in front of its own
    /// `removeItem`. Returning `false` (not `true`) keeps the failure visible:
    /// nothing was reclaimed.
    ///
    /// The two guards are cheap `stat`-level checks and stay on the caller's
    /// thread; only the unlink loop hops to `drainQueue` (see its comment for
    /// why that queue is serial and process-wide).
    @discardableResult
    public func drain(_ entry: QueuedDeletion) async -> Bool {
        guard (entry.path as NSString).pathComponents.contains(Self.dirName) else {
            logger.error("""
            deletionQueue: refusing to drain \(entry.path, privacy: .public) — \
            not inside a \(Self.dirName, privacy: .public) queue directory
            """)
            return false
        }
        guard FileManager.default.fileExists(atPath: entry.path) else { return true }
        let path = entry.path
        return await withCheckedContinuation { continuation in
            Self.drainQueue.async {
                do {
                    try FileManager.default.removeItem(atPath: path)
                    logger.debug("deletionQueue: drained \(path, privacy: .public)")
                    continuation.resume(returning: true)
                } catch {
                    logger.error("""
                    deletionQueue: drain of \(path, privacy: .public) failed, \
                    will resume next sweep: \(error, privacy: .public)
                    """)
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
