import Darwin
import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "channels.store")

public enum ChannelStoreError: Error, CustomStringConvertible {
    case bodyTooLarge(bytes: Int)
    case writeFailed(path: String, errno: Int32)
    case fsyncFailed(path: String, errno: Int32)
    case openFailed(path: String, errno: Int32)
    case channelNotFound(name: String)

    public var description: String {
        switch self {
        case .bodyTooLarge(let n): return "body too large: \(n) bytes (max 65536)"
        case .writeFailed(let p, let e): return "write(\(p)) failed: errno=\(e)"
        case .fsyncFailed(let p, let e): return "fsync(\(p)) failed: errno=\(e)"
        case .openFailed(let p, let e): return "open(\(p)) failed: errno=\(e)"
        case .channelNotFound(let n): return "channel not found: \(n)"
        }
    }
}

public struct ChannelPostResult: Sendable {
    public let seq: Int
    public let ts: Date
}

/// Orchestrates per-channel JSONL writes. Owns the per-channel lock
/// manager, the in-memory `seq` cache, and the `channel_index` updates.
public final class ChannelStore: @unchecked Sendable {
    private static let bodyByteLimit = 64 * 1024

    private let channelsDir: URL
    private let archiveDir: URL
    private let index: ChannelIndexStore
    private let lockManager = ChannelLockManager()

    // Per-channel async locks (ChannelLockManager) serialize work for a
    // single channel name, but `post`/`archive` against *different* names
    // run on different actors and can mutate this Dictionary in parallel.
    // Swift Dictionary is COW: concurrent structural mutations from
    // different threads can corrupt the buffer or crash on resize even
    // when the keys differ. Hold an unfair lock around every read/write.
    // The lock is taken only for in-memory dictionary access — never
    // across file I/O or `await` boundaries — so contention is minimal.
    private let seqCache = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])

    public init(channelsDir: URL, index: ChannelIndexStore) {
        self.channelsDir = channelsDir
        self.archiveDir = channelsDir.appendingPathComponent("_archive")
        self.index = index
    }

    /// Append one message to a channel. Returns the assigned `seq` and `ts`.
    public func post(
        name: String,
        body: String,
        fromSession: String,
        fromLabel: String
    ) async throws -> ChannelPostResult {
        let normalized = try validateChannelName(name)

        let bodyBytes = body.utf8.count
        if bodyBytes > Self.bodyByteLimit {
            throw ChannelStoreError.bodyTooLarge(bytes: bodyBytes)
        }

        // Inside the per-channel lock: only synchronous work. No `await`
        // inside the closure body means no actor reentrancy and no
        // parallel attempts to acquire the same flock. The DB index
        // update uses the *synchronous* GRDB write so it sits inside
        // this lock too — that's what guarantees `archive` can't race
        // an in-flight `post` and resurrect the index row after delete.
        let result: ChannelPostResult = try await lockManager.withLock(normalized) { [self] in
            try ensureDir(channelsDir)
            let lock = try FileLock.acquire(path: lockPath(for: normalized))
            defer { try? lock.release() }

            let nextSeq = try ensureSeqCachePopulated(for: normalized) + 1
            let ts = Date()
            let msg = ChannelMessage(seq: nextSeq, ts: ts,
                                     fromSession: fromSession,
                                     fromLabel: fromLabel,
                                     body: body)
            let line = try msg.encodeLine()
            try appendLine(channel: normalized, line: line)
            seqCache.withLock { $0[normalized] = nextSeq }

            // DB write inside the per-channel lock; synchronous so we
            // don't reintroduce the actor-reentrancy hazard, and so
            // post/archive can't interleave at the index layer.
            try index.recordPostSync(name: normalized, at: ts)

            return ChannelPostResult(seq: nextSeq, ts: ts)
        }

        return result
    }

    // MARK: - File paths

    func filePath(for name: String) -> String {
        channelsDir.appendingPathComponent("\(name).jsonl").path
    }

    func lockPath(for name: String) -> String {
        channelsDir.appendingPathComponent("\(name).lock").path
    }

    // MARK: - Helpers

    private func ensureDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Populate the in-memory seq cache by scanning the file tail (and
    /// running torn-line recovery as a side effect). Returns the highest
    /// known seq, or 0 if the channel has no file yet.
    func ensureSeqCachePopulated(for name: String) throws -> Int {
        if let cached = seqCache.withLock({ $0[name] }) { return cached }
        let highest = try recoverAndScanHighestSeq(name: name)
        seqCache.withLock { $0[name] = highest }
        return highest
    }

    /// Stream-scan the channel file. If the trailing line is malformed,
    /// truncate the file back to the last good newline. Returns the highest
    /// successfully parsed seq (or 0 if no file).
    func recoverAndScanHighestSeq(name: String) throws -> Int {
        let path = filePath(for: name)
        guard FileManager.default.fileExists(atPath: path) else { return 0 }

        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return 0 }

        var highest = 0
        var lastGoodEnd = 0  // byte offset of (one-past) last good newline
        var lineStart = 0
        for (idx, byte) in data.enumerated() {
            if byte == 0x0A {
                let line = data.subdata(in: lineStart..<idx)
                if let msg = try? ChannelMessage.decodeLine(line) {
                    highest = max(highest, msg.seq)
                    lastGoodEnd = idx + 1
                }
                lineStart = idx + 1
            }
        }
        // Anything after the last newline (or after position 0 if no newline)
        // is an unfinished line. Truncate.
        if lastGoodEnd < data.count {
            logger.notice("Truncating torn-line tail of \(name, privacy: .public): \(data.count - lastGoodEnd) bytes dropped")
            let fd = open(path, O_WRONLY)
            if fd < 0 {
                throw ChannelStoreError.openFailed(path: path, errno: errno)
            }
            defer { close(fd) }
            if ftruncate(fd, off_t(lastGoodEnd)) != 0 {
                throw ChannelStoreError.writeFailed(path: path, errno: errno)
            }
            // Make the truncate durable so a crash before the OS flushes
            // doesn't leave the torn line on disk for the next start to
            // recover again. Recovery is idempotent, so this is correctness
            // polish rather than a fix for a known bug.
            if fsync(fd) != 0 {
                throw ChannelStoreError.fsyncFailed(path: path, errno: errno)
            }
        }
        return highest
    }

    /// Move the channel file to `_archive/<name>-<YYYYMMDD-HHMMSS>.jsonl`,
    /// remove the lock sidecar, and delete the index row. Returns the
    /// archived path.
    public func archive(name: String) async throws -> String {
        let normalized = try validateChannelName(name)

        // Synchronous file work under the per-channel lock; DB cleanup outside.
        // (Same actor-reentrancy lesson as `post`: no `await` inside withLock.)
        let archivedPath: String = try await lockManager.withLock(normalized) { [self] in
            let activePath = filePath(for: normalized)
            guard FileManager.default.fileExists(atPath: activePath) else {
                throw ChannelStoreError.channelNotFound(name: normalized)
            }

            // Hold the cross-process lock for the rename.
            let lock = try FileLock.acquire(path: lockPath(for: normalized))
            defer { try? lock.release() }

            try ensureDir(archiveDir)
            let stamp = Self.timestampFormatter.string(from: Date())
            let archivedPath = archiveDir
                .appendingPathComponent("\(normalized)-\(stamp).jsonl")
                .path
            try FileManager.default.moveItem(atPath: activePath, toPath: archivedPath)

            // Remove the lock sidecar (best-effort; lock FD is already closed
            // by `defer` above, but unlink can race with that).
            try? FileManager.default.removeItem(atPath: lockPath(for: normalized))

            seqCache.withLock { _ = $0.removeValue(forKey: normalized) }

            // DB delete inside the per-channel lock; synchronous to
            // match `post` and prevent the post/archive race that would
            // otherwise let an in-flight `recordPost` resurrect the row
            // after we deleted it.
            try index.deleteSync(name: normalized)

            return archivedPath
        }

        // Eviction happens *after* the per-channel lock body returns. The
        // ChannelSerial actor for this name has no remaining work (we just
        // archived the file and deleted the index row), so dropping it
        // prevents `locks` from accumulating stale entries over the
        // daemon's lifetime as channels are created and archived.
        await lockManager.evict(normalized)

        return archivedPath
    }

    /// `YYYYMMDD-HHMMSS` in UTC, for archive filenames.
    static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func appendLine(channel: String, line: Data) throws {
        let path = filePath(for: channel)
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        if fd < 0 {
            throw ChannelStoreError.openFailed(path: path, errno: errno)
        }
        defer { close(fd) }

        try line.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
            guard let base = rawBuf.baseAddress else { return }
            var written = 0
            while written < rawBuf.count {
                let r = Darwin.write(fd, base.advanced(by: written), rawBuf.count - written)
                if r < 0 {
                    if errno == EINTR { continue }
                    throw ChannelStoreError.writeFailed(path: path, errno: errno)
                }
                written += r
            }
        }

        if fsync(fd) != 0 {
            throw ChannelStoreError.fsyncFailed(path: path, errno: errno)
        }
    }
}
