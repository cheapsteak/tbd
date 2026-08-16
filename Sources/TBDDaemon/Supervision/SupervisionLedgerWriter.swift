import Foundation
import os
import TBDShared

private let ledgerLogger = Logger(subsystem: "com.tbd.daemon", category: "supervision.ledger")

/// The append-only supervision record at `~/tbd/supervision/ledger.jsonl`
/// (design §6, §7): one JSON object per line, written by the daemon at the
/// moment a coverage decision takes effect.
///
/// Shaped after `ActuationLog`, and for the same reasons: actor isolation *is*
/// the serialization, so one whole-line append runs at a time and interleaved
/// partial lines are impossible within this process; the handle is `O_APPEND`
/// and every row is `fsync`ed, so a crash costs at most the row in flight; the
/// open descriptor's `(device, inode)` is checked against the path before each
/// append, so a file moved or replaced under the daemon is a failed append
/// rather than a silent write into a file nobody will read. Timestamps arrive
/// as `SupervisionInstant` on the line itself, minted by the caller's date
/// seam — this writer never reaches for `Date()`.
///
/// **Appends are best-effort-loud, never fail-closed.** That is the opposite of
/// `ActuationLog.appendRequest`, and deliberately: an actuation row is written
/// *before* its act, so refusing to write is refusing to act, while a lifecycle
/// line is written *after* a decision has already taken effect in
/// `supervision.json` or the config column. Retroactively refusing a mark that
/// already stands is impossible, so a failed append is `.fault`-logged and the
/// gesture still succeeds. What the record then shows is a project whose span
/// has no opening line — which reads as "start unknown" through
/// `SupervisionCoverageSummary(spanStartedAt: nil, …)`, honest by construction.
///
/// **This writer does not rotate.** `ActuationLog` rotates daily because it
/// carries every actuation the daemon performs; this file carries coverage
/// decisions, at a rate of a few lines per operator gesture. When rotation
/// arrives it must land together with a `spanStarts()` that reads the rotated
/// segments in name order before the active file — otherwise a span opened
/// yesterday would read as unknown after the first rotation.
public actor SupervisionLedgerWriter {
    /// The active file.
    public let path: String

    private let encoder: JSONEncoder

    /// Open `O_APPEND` descriptor, or -1 when closed. Dropped on any write
    /// failure so the single retry gets a fresh one.
    private var fd: Int32 = -1

    /// Set when a read of the file found it ending mid-line, and consumed by
    /// the next append: the row goes out behind a newline so the dangling bytes
    /// terminate as their own junk line instead of fusing with it.
    private var fragmentPendingIsolation = false

    public init(path: String) {
        self.path = path
        let encoder = JSONEncoder()
        // Sorted keys so a line is stable and diffable; no pretty-printing so
        // one row is one line.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    // MARK: - Appending

    /// Append one line, retrying once through a fresh descriptor.
    ///
    /// Never throws: see the type's note on best-effort-loud. The return value
    /// says whether the line reached the file, for the callers that want to log
    /// about it; nothing branches on it.
    ///
    /// The retry opens with a newline, so a half-written first attempt
    /// terminates as its own junk line rather than fusing with this one. It can
    /// therefore duplicate a line whose bytes landed but whose `fsync` failed,
    /// and that is the accepted trade rather than an oversight: `ActuationLog`
    /// carries the three-phase resume-from-offset machinery because a
    /// duplicated actuation row would claim an act happened twice, while a
    /// duplicated lifecycle line carries the same `id` and the same `ts` and
    /// therefore claims the same decision once. Span recovery reads it
    /// idempotently, and the repeated id is what makes the duplicate visible.
    @discardableResult
    public func append(_ line: SupervisionLedgerLine) -> Bool {
        do {
            try appendOnce(line)
            return true
        } catch {
            closeHandle()
            do {
                try appendOnce(line, isolatingFragment: true)
                return true
            } catch {
                ledgerLogger.fault(
                    """
                    Could not append a supervision lifecycle line to \
                    \(self.path, privacy: .public): \
                    \((error as NSError).localizedDescription, privacy: .public). \
                    The decision itself took effect; only the record of it is missing, \
                    so the span it opens or closes will read as start-unknown.
                    """)
                return false
            }
        }
    }

    private func appendOnce(_ line: SupervisionLedgerLine, isolatingFragment: Bool = false) throws {
        // The row must land in the file that is at `path` NOW. An open
        // descriptor whose inode was replaced under us still accepts writes,
        // into a file nobody will ever read.
        if fd >= 0, !handleStillPointsAtPath() {
            throw Self.pathError("the supervision ledger was moved or removed")
        }
        let descriptor = try openHandle()

        var bytes = Data()
        if isolatingFragment || fragmentPendingIsolation { bytes.append(0x0A) }
        bytes.append(try encoder.encode(line))
        bytes.append(0x0A)

        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(
                    descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard count > 0 else { throw Self.posixError("write") }
                offset += count
            }
        }
        // One `fsync` per row is affordable at coverage-gesture rates.
        guard fsync(descriptor) == 0 else { throw Self.posixError("fsync") }
        // Cleared here and nowhere earlier: the flag is a debt owed to bytes
        // still on disk, and only a write that actually landed pays it. Clearing
        // it up front loses the isolating newline whenever both the attempt and
        // its retry fail — the fragment survives, the flag does not, and the
        // *next* append fuses a valid object onto it, turning a junk line into a
        // permanently unreadable one.
        fragmentPendingIsolation = false
    }

    // MARK: - Reading the record back

    /// The open coverage span for each project: the timestamp of its most
    /// recent `projectOn` with no `projectOff` after it (design §9).
    ///
    /// **A span's start is recovered from the record, never stored as a field**
    /// — which is what makes "a restart resumes coverage from two files"
    /// literally true. Reading is not deciding: this walks the file and returns
    /// values, and writes, sends, and starts nothing.
    ///
    /// A line that does not decode is skipped rather than fatal. A hand-edit or
    /// a crash fragment must not take the whole record's memory offline, and
    /// the count is logged so the damage is visible.
    ///
    /// **That count means corruption, and only corruption.** A line of a kind
    /// this build does not know — a `delivery` or `enrollment` line from a later
    /// slice, or a lifecycle event added after this one — decodes into
    /// `.unrecognized` rather than failing, so it passes through here as a line
    /// that opens and closes nothing. Without that, the first slice to write a
    /// new kind would have made every restart log its whole record as damaged,
    /// which is the shape of alarm an operator learns to ignore.
    public func spanStarts() -> [String: SupervisionInstant] {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
            return [:]
        }
        if data.last != 0x0A { fragmentPendingIsolation = true }

        let decoder = JSONDecoder()
        var open: [String: SupervisionInstant] = [:]
        var skipped = 0
        for raw in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let line = try? decoder.decode(SupervisionLedgerLine.self, from: Data(raw)) else {
                skipped += 1
                continue
            }
            guard let project = line.project else { continue }
            switch line.payload {
            case .projectOn: open[project] = line.ts
            case .projectOff: open.removeValue(forKey: project)
            // A line of a kind this build does not recognize neither opens a
            // span nor closes one. It is somebody else's record, read past.
            case .brakeEngaged, .brakeReleased, .modeChanged, .deskSpawned, .deskReplaced,
                 .unrecognized: break
            }
        }
        if skipped > 0 {
            ledgerLogger.warning(
                """
                Skipped \(skipped, privacy: .public) corrupt line(s) in \
                \(self.path, privacy: .public) while recovering coverage spans — \
                lines of an unrecognized kind are read past and are not counted here.
                """)
        }
        return open
    }

    // MARK: - Handle

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

    private func closeHandle() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    /// Whether the open descriptor and `path` still name the same file.
    private func handleStillPointsAtPath() -> Bool {
        var openFile = stat()
        var pathFile = stat()
        guard fstat(fd, &openFile) == 0, stat(path, &pathFile) == 0 else { return false }
        return openFile.st_dev == pathFile.st_dev && openFile.st_ino == pathFile.st_ino
    }

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
