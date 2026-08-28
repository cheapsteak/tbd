import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "supervision.supersession")

/// How a transcript is measured. Injected so tests drive fingerprints without
/// a filesystem, and so the daemon's one real measurement lives in one place.
public typealias TranscriptFingerprinter = @Sendable (String) -> TranscriptFingerprint?

public enum TranscriptFingerprinting {
    /// One `stat`: no open, no read, no parse. Cheap enough to run on every
    /// pass that reports a terminal, and it runs only for the rows holding a
    /// standing prompt.
    public static let live: TranscriptFingerprinter = { path in
        guard !path.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modifiedAt = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.int64Value
        else { return nil }
        return TranscriptFingerprint(path: path, modifiedAt: modifiedAt, size: size)
    }
}

/// What was appended to a transcript after a given byte offset.
///
/// A transcript that merely GREW does not say the session moved. A parallel
/// `Task` subagent writes its whole conversation into the parent's JSONL as
/// `isSidechain` records, and it keeps writing while the parent sits on a
/// permission prompt — so growth alone drops the hand on a human who is still
/// blocked. `SessionStateResolver` documents that exact failure and refuses the
/// inference for the same reason. Only the parent's own writing is evidence.
public enum TranscriptDelta: Sendable, Equatable {
    /// At least one non-sidechain record — the parent session itself wrote.
    case containsParentContent
    /// The file grew, but only with a nested agent's sidechain records. Also
    /// the answer when the delta holds no complete record at all: nothing the
    /// parent wrote has appeared.
    case sidechainOnly
}

/// Reads what a transcript gained after a byte offset. Injected beside
/// `TranscriptFingerprinter` so tests drive the judgment without a filesystem.
///
/// nil means the delta could not be read. Inability to look is never evidence.
public typealias TranscriptDeltaInspector = @Sendable (String, Int64) -> TranscriptDelta?

public enum TranscriptDeltaInspection {
    /// How much of a delta to read. The same order as
    /// `ClaudeDelegationTracker.tailByteLimit`, which reads the JSONL's tail on
    /// a far hotter path; a prompt's delta is normally a handful of records.
    /// A delta larger than this is read from its END — the newest records are
    /// the ones that describe what the session is doing now — and a window that
    /// shows only sidechain records leaves the hand up, which is the direction
    /// every edge on this rail fails toward.
    static let deltaByteLimit = 64 * 1024

    /// How far back to look for the record boundary at or before the offset.
    /// Transcript records are assistant messages and tool results, so this
    /// covers them with room to spare; past it the inspector declines to answer
    /// rather than parse a fragment.
    static let boundaryScanLimit = 1024 * 1024

    /// Read size for the backward scan. One of these usually settles it: the
    /// byte before a stat-captured size is a newline whenever the writer was
    /// between records.
    private static let boundaryChunkSize = 8 * 1024

    public static let live: TranscriptDeltaInspector = { path, offset in
        inspect(path: path, offset: offset)
    }

    static func inspect(path: String, offset: Int64) -> TranscriptDelta? {
        guard !path.isEmpty, offset >= 0,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            // The caller compares sizes before asking, so a file shorter than
            // the offset is a race rather than a state to interpret.
            guard UInt64(offset) <= end else { return nil }
            guard let boundary = try recordBoundary(handle: handle, at: UInt64(offset))
            else { return nil }
            let capped = end - boundary > UInt64(deltaByteLimit)
            let start = capped ? end - UInt64(deltaByteLimit) : boundary
            try handle.seek(toOffset: start)
            let window = try handle.read(upToCount: Int(end - start)) ?? Data()
            return classify(window: window, startsMidRecord: capped)
        } catch {
            logger.debug(
                "transcript delta read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The start of the record that `offset` falls inside.
    ///
    /// `offset` is a file SIZE captured by a stat, so it lands mid-record
    /// whenever the fingerprint was taken while a line was being written. The
    /// bytes of that fragment were already present, but its record was not
    /// complete — starting the window at the raw offset would hand the parser a
    /// tail fragment and silently lose the one real append. nil when no
    /// boundary sits within `boundaryScanLimit`: no answer beats a guessed one.
    private static func recordBoundary(handle: FileHandle, at offset: UInt64) throws -> UInt64? {
        guard offset > 0 else { return 0 }
        let floor = offset > UInt64(boundaryScanLimit) ? offset - UInt64(boundaryScanLimit) : 0
        var high = offset
        while high > floor {
            let chunk = min(high - floor, UInt64(boundaryChunkSize))
            let low = high - chunk
            try handle.seek(toOffset: low)
            let data = try handle.read(upToCount: Int(chunk)) ?? Data()
            if let index = data.lastIndex(of: 0x0A) {
                return low + UInt64(data.distance(from: data.startIndex, to: index)) + 1
            }
            high = low
        }
        return floor == 0 ? 0 : nil
    }

    /// A record the parent wrote is one that parses and does not carry
    /// `isSidechain: true` — the same partition `TranscriptParser` already makes
    /// when it drops a nested agent's conversation from the parent's transcript.
    /// A line this build cannot read as a record at all is not a parent record
    /// until it is read as one, so it decides nothing and is passed over.
    private static func classify(window: Data, startsMidRecord: Bool) -> TranscriptDelta {
        var lines = window.split(separator: 0x0A, omittingEmptySubsequences: false)
        // Whatever follows the final newline is a record still being written.
        // Incomplete is not yet evidence of anything.
        if !lines.isEmpty { lines.removeLast() }
        // The byte cap moved the window's start into a record whose beginning
        // was left behind; that fragment is not parseable as one.
        if startsMidRecord, !lines.isEmpty { lines.removeFirst() }
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let record = object as? [String: Any] else { continue }
            if record["isSidechain"] as? Bool != true { return .containsParentContent }
        }
        return .sidechainOnly
    }
}

/// The second superseder of an awaiting-input reason.
///
/// The activity rail retracts a reason when a hook reports the session moved.
/// This one retracts it when the session's TRANSCRIPT shows the session itself
/// moved, which is the only evidence available when no hook arrives — and none
/// does: Claude Code fires nothing when a human answers a permission prompt,
/// and a session whose hook rail has gone quiet produces no activity
/// observation at all.
///
/// A transcript that grew is not on its own that evidence. A nested agent's
/// sidechain records land in the parent's file while the parent is blocked, so
/// the delta is read and attributed before a hand comes down.
///
/// Every branch fails toward leaving the prompt raised. A lingering hand is the
/// defect this exists to fix; a hand dropped while a human is still being asked
/// hides the one row that needs attention.
///
/// See `docs/specs/2026-08-27-awaiting-input-transcript-supersession-design.md`.
struct AwaitingInputSupersession: Sendable {
    let db: TBDDatabase
    let fingerprint: TranscriptFingerprinter
    let delta: TranscriptDeltaInspector

    /// Reconcile one terminal against its transcript. Returns whether a
    /// standing prompt was retracted, so a caller entitled to announce the
    /// retraction can do so from what the write actually did.
    func reconcile(terminal: Terminal) async -> Bool {
        guard let reason = terminal.awaitingInputReason,
              reason.classification == .promptOnScreen else { return false }
        guard let path = terminal.transcriptPath, !path.isEmpty else { return false }
        // Inability to look is never evidence that a prompt was answered.
        guard let observed = fingerprint(path) else { return false }
        guard let stored = reason.transcriptFingerprint else {
            _ = try? await db.terminals.adoptTranscriptFingerprint(
                id: terminal.id, fingerprint: observed)
            return false
        }
        // The steady state: a session sitting on a prompt writes nothing, so an
        // unchanged file is the pending case and costs exactly one stat — no
        // open, no read, no parse.
        guard stored != observed else { return false }

        // A retargeted session (`/clear`, compaction, resume) or a truncated
        // file leaves the stored offset describing a file that no longer
        // exists in that shape. Neither can be read as a delta.
        if stored.path == observed.path, observed.size >= stored.size {
            switch delta(path, stored.size) {
            case .sidechainOnly:
                // A nested agent wrote; the parent did not. The hand stays up,
                // and the baseline moves forward so the next pass is a stat
                // again rather than a re-read of the same records.
                _ = try? await db.terminals.refreshTranscriptFingerprint(
                    id: terminal.id, expected: stored, fingerprint: observed)
                return false
            case nil:
                // Unreadable: change nothing, not even the baseline. Refreshing
                // here would move the offset past bytes nobody ever read.
                return false
            case .containsParentContent:
                break
            }
        }
        return (try? await db.terminals.clearAwaitingInputReasonIfFingerprintMatches(
            id: terminal.id, expected: stored)) ?? false
    }
}
