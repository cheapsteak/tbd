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

    public var description: String {
        switch self {
        case .bodyTooLarge(let n): return "body too large: \(n) bytes (max 65536)"
        case .writeFailed(let p, let e): return "write(\(p)) failed: errno=\(e)"
        case .fsyncFailed(let p, let e): return "fsync(\(p)) failed: errno=\(e)"
        case .openFailed(let p, let e): return "open(\(p)) failed: errno=\(e)"
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

    // Protected by per-channel async locks (ChannelLockManager). Mutations
    // happen only inside `withLock`, so the Dictionary is never touched
    // concurrently for the same key. @unchecked is justified by that contract.
    private var seqCache: [String: Int] = [:]

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

        // Inside the per-channel lock: only synchronous file work.
        // No `await` inside the closure body means no actor reentrancy
        // and no parallel attempts to acquire the same flock.
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
            seqCache[normalized] = nextSeq
            return ChannelPostResult(seq: nextSeq, ts: ts)
        }

        // DB index update outside the per-channel lock (no serialization
        // requirement here; ChannelIndexStore already serializes via its
        // own writer queue, and ordering of `recordPost` calls only affects
        // `lastMessageAt` precedence — not correctness).
        try await index.recordPost(name: normalized, at: result.ts)
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
        if let cached = seqCache[name] { return cached }
        let highest = try recoverAndScanHighestSeq(name: name)
        seqCache[name] = highest
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
        }
        return highest
    }

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
