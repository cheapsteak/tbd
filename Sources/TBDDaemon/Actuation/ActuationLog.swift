import Foundation
import os
import TBDShared

private let actuationLogger = Logger(subsystem: "com.tbd.daemon", category: "actuation-log")

/// A request-row append that failed twice — once outright, once after closing
/// and reopening the file. The actuation it was about to record does not
/// proceed, so this message is what the caller sees: it names the full path and
/// the recovery, not just an errno.
///
/// `CustomStringConvertible` as well as `LocalizedError` because the RPC router
/// surfaces failures with `"\(error)"`, which would otherwise print the struct.
struct ActuationLogUnwritable: LocalizedError, CustomStringConvertible, Equatable {
    let path: String
    let reason: String

    var description: String {
        "TBD could not record this action in its actuation log at \(path) (\(reason)). "
            + "Actions are refused until the log is writable again — check the file's "
            + "owner and mode, or move it aside; TBD will recreate it."
    }

    var errorDescription: String? { description }
}

/// The daemon's append-only record of every state-changing actuation it
/// performs on a session: one JSON object per line, request row first, then the
/// synchronous outcome row that confirms it.
///
/// The daemon is the only writer, and it writes at the moment it acts — nobody
/// is the reporter of their own acts. Actor isolation *is* the serialization:
/// one append runs at a time, whole-line, so interleaved partial lines are
/// impossible by construction.
///
/// Timestamps come through the `now` date seam, never a `Clock`: they are
/// persisted data, not behavior. The same seam decides the UTC day boundary, so
/// rotation is testable without wall time.
public actor ActuationLog {
    /// The active file. Rotated day segments land beside it.
    public let path: String

    private let now: @Sendable () -> Date
    private let encoder: JSONEncoder
    private let timestampFormatter: ISO8601DateFormatter
    private let dayFormatter: DateFormatter

    /// Open `O_APPEND` descriptor, or -1 when closed. Reopened on demand, and
    /// deliberately dropped on any write failure so the retry gets a fresh one.
    private var fd: Int32 = -1

    /// UTC day (`YYYY-MM-DD`) of the newest row in the active file, learned
    /// lazily on the first append and maintained from there. `nil` means "not
    /// determined yet"; an empty or absent file needs no rotation.
    private var segmentDay: String?

    public init(path: String, now: @Sendable @escaping () -> Date = { Date() }) {
        self.path = path
        self.now = now

        let encoder = JSONEncoder()
        // Sorted keys so a line is stable and diffable; no pretty-printing so
        // one row is one line. Encoding details are implementation, not contract.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder

        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestampFormatter = timestampFormatter

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        self.dayFormatter = dayFormatter
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    // MARK: - IDs

    /// A 12-character lowercase `[a-z0-9]` identifier from the system CSPRNG
    /// (`SystemRandomNumberGenerator`, which is `arc4random` on Darwin).
    ///
    /// One namespace, join-safe: ~2^62 of space, so a dispatch, its transcript
    /// envelope and its outcome can join on this string alone for the record's
    /// lifetime. Shell- and paste-safe too: no metacharacters and no hyphens,
    /// so a double-click selects the whole token.
    static func mintID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<12).map { _ in
            alphabet[Int.random(in: 0..<alphabet.count, using: &generator)]
        })
    }

    // MARK: - Appending

    /// Append a request row **before** the act it describes, and return its
    /// minted id so the outcome row can confirm it.
    ///
    /// Fail-closed: on failure the writer closes, reopens (recreating the file
    /// if it is missing) and retries exactly once. If that also fails it
    /// throws, and the caller must not proceed with the actuation — the whole
    /// reason the record exists is that no real act lacks a row.
    @discardableResult
    func appendRequest(_ row: ActuationRow) throws -> String {
        var row = row
        let id = Self.mintID()
        row.id = id
        try appendWithOneRetry(row, failClosed: true)
        return id
    }

    /// Append the synchronous outcome of an act that already ran.
    ///
    /// Best-effort-loud, never fail-closed: retroactively refusing a completed
    /// act is impossible, so a second failure is `.fault`-logged and swallowed.
    /// The record then shows a request with no outcome, which reads as
    /// unconfirmed — honest by construction.
    func appendOutcome(confirms: String, result: ActuationResult, error: String? = nil) {
        var row = ActuationRow(actor: .daemon(), kind: .outcome)
        row.id = Self.mintID()
        row.confirms = confirms
        row.result = result
        row.error = error
        try? appendWithOneRetry(row, failClosed: false)
    }

    private func appendWithOneRetry(_ row: ActuationRow, failClosed: Bool) throws {
        do {
            try appendOnce(row)
            return
        } catch {
            // A transient or single-bad-file condition self-heals: drop the
            // handle, reopen (recreating the file if it vanished), retry once.
            closeHandle()
            segmentDay = nil
        }
        do {
            try appendOnce(row)
        } catch {
            let failure = ActuationLogUnwritable(
                path: path, reason: (error as NSError).localizedDescription)
            actuationLogger.fault("\(failure.description, privacy: .public)")
            if failClosed { throw failure }
        }
    }

    private func appendOnce(_ row: ActuationRow) throws {
        var row = row
        let stampedAt = now()
        row.ts = timestampFormatter.string(from: stampedAt)

        // The row must land in the file that is at `path` NOW. An open
        // descriptor whose inode was unlinked or replaced under us — a cleanup
        // script, an external rotation, a `~/tbd` restored from backup — still
        // accepts writes, into a file nobody will ever read. That is exactly
        // the silent gap this record exists to forbid, so treat it as a failed
        // append and let the single reopen-retry recreate the file.
        if fd >= 0, !handleStillPointsAtPath() {
            throw Self.pathError("the log file was moved or removed")
        }

        let today = dayFormatter.string(from: stampedAt)
        try rotateIfNeeded(today: today)
        let descriptor = try openHandle()

        var line = try encoder.encode(row)
        line.append(0x0A)

        try line.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(
                    descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard written > 0 else { throw Self.posixError("write") }
                offset += written
            }
        }
        // fsync per row is affordable at actuation rates (human/agent scale,
        // not packet scale). `F_FULLFSYNC` is deliberately declined: the
        // residual power-loss window it would close also loses the actuation
        // itself, so the record stays truthful without it.
        guard fsync(descriptor) == 0 else { throw Self.posixError("fsync") }
        segmentDay = today
    }

    // MARK: - Handle and rotation

    private func openHandle() throws -> Int32 {
        if fd >= 0 { return fd }
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
        }
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { throw Self.posixError("open") }
        fd = descriptor
        return descriptor
    }

    /// Whether the open descriptor and `path` still name the same file.
    /// Cheap (two stats) and paid once per actuation, which is human/agent
    /// scale — not packet scale.
    private func handleStillPointsAtPath() -> Bool {
        var openFile = stat()
        var pathFile = stat()
        guard fstat(fd, &openFile) == 0, stat(path, &pathFile) == 0 else { return false }
        return openFile.st_dev == pathFile.st_dev && openFile.st_ino == pathFile.st_ino
    }

    private func closeHandle() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    /// Lazily, at the first append of a new UTC day, move the active file aside
    /// to `actuations-<YYYY-MM-DD>.jsonl` — stamped with the UTC date of the
    /// segment's **last** row, not today's — and start a fresh active file.
    ///
    /// No header, footer, or marker row is ever written: rotation is mechanical
    /// and implies no shift, session, or closed period. Readers reconstruct the
    /// record by concatenating segments in name order plus the active file.
    private func rotateIfNeeded(today: String) throws {
        if segmentDay == nil { segmentDay = try determineSegmentDay() }
        guard let day = segmentDay, day != today else { return }
        closeHandle()
        let destination = try rotationDestination(day: day)
        try FileManager.default.moveItem(atPath: path, toPath: destination)
        segmentDay = nil
    }

    /// A name collision can only come from a crash-window edge (two segments
    /// dated the same day). Take a numeric suffix rather than concatenating —
    /// concatenation would silently reorder somebody's record.
    private func rotationDestination(day: String) throws -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let base = "actuations-\(day)"
        let fileManager = FileManager.default
        for attempt in 0..<1000 {
            let name = attempt == 0 ? "\(base).jsonl" : "\(base)-\(attempt).jsonl"
            let candidate = (directory as NSString).appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate) { return candidate }
        }
        throw Self.posixError("rotate")
    }

    /// The UTC day of the newest row already in the active file, so a daemon
    /// that restarts mid-day rotates against the record rather than against its
    /// own uptime. Reads only the file's tail — a segment can be large.
    /// Returns `nil` when there is nothing to rotate.
    private func determineSegmentDay() throws -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { return nil }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return nil }

        let window: UInt64 = 64 * 1024
        try handle.seek(toOffset: size > window ? size - window : 0)
        let tail = (try? handle.readToEnd()) ?? Data()
        let lines = tail.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard let last = lines.last,
              let parsed = try? JSONDecoder().decode(TimestampProbe.self, from: Data(last)),
              parsed.ts.count >= 10
        else {
            // An unparseable tail (partial line from a crash, hand-editing)
            // must not wedge rotation. Fall back to the file's own mtime.
            let attributes = try? fileManager.attributesOfItem(atPath: path)
            guard let modified = attributes?[.modificationDate] as? Date else { return nil }
            return dayFormatter.string(from: modified)
        }
        return String(parsed.ts.prefix(10))
    }

    /// Just enough of a row to read its day back.
    private struct TimestampProbe: Decodable { let ts: String }

    private static func pathError(_ reason: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain, code: Int(ENOENT),
            userInfo: [NSLocalizedDescriptionKey: reason])
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain, code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey:
                "\(operation) failed: \(String(cString: strerror(errno)))"])
    }
}
