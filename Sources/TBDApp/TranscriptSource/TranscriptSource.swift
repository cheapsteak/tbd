import Foundation
import os
import TBDShared

/// Owns the app's incremental view of every registered session's transcript
/// file: where it has read to, what it has built, and when to start over.
///
/// Paths are handed in, never resolved here. Both sources — a terminal's
/// `transcriptPath` and a `SessionSummary.filePath` — originate from the
/// daemon's own records, so this type needs no `TBD_HOME` or profile-directory
/// knowledge, and tests need no environment mutation to stay off the
/// developer's real `~/.claude`.
///
/// No clock is injected: this type performs no timed work. Every cadence
/// decision — when to tick, how often, and for which sessions — belongs to the
/// poll scheduler that drives it.
actor TranscriptSource {

    private static let log = Logger(subsystem: "com.tbd.app", category: "transcript-source")

    /// How many bytes of the already-consumed region are re-read and compared
    /// on each change, to prove the file was appended to rather than rewritten.
    /// Fixed size: the foreground tier polls at 100 ms, so the per-tick cost
    /// must not scale with the transcript.
    private static let verificationWindowBytes: UInt64 = 512

    private struct Entry {
        var path: String
        var offset: UInt64
        var lastSize: UInt64
        var lastModified: Date
        /// The last `verificationWindowBytes` bytes immediately BEFORE
        /// `offset`, as they read when this entry consumed them. nil only when
        /// nothing has been consumed yet, or when the window could not be
        /// captured — either way there is nothing to compare against.
        var consumedTail: Data?
        var transcript: IncrementalTranscript
    }

    private var entries: [String: Entry] = [:]

    init() {}

    func items(sessionID: String) -> [TranscriptItem] {
        entries[sessionID]?.transcript.items ?? []
    }

    /// How many sessions have a built transcript resident right now.
    ///
    /// Read-only, and here so the bound on this actor's retention is something
    /// a test can assert rather than something a comment claims. Nothing in the
    /// app reads it.
    var trackedSessionCount: Int { entries.count }

    /// Drops everything built for `sessionID`. The next `refresh` for that id
    /// starts over from byte zero.
    ///
    /// `TranscriptPollScheduler` is the only production caller, from two
    /// places: `deregister`, and `finishTick` for a poll whose refresh landed
    /// after its registration had already gone. Retention is scoped to
    /// registration either way, so no entry outlives the pane that asked for
    /// it.
    func forget(sessionID: String) {
        entries.removeValue(forKey: sessionID)
    }

    /// Bring `sessionID` up to date with `path`.
    ///
    /// Returns nil when the file could not be read at all — the caller must
    /// treat that as "no news", never as "the transcript is empty". Whatever
    /// was already built stays built. The daemon path gets this wrong today:
    /// `TranscriptParser.parse` returns `[]` for an unreadable file and the
    /// poll diff treats that as a change, so a transient failure blanks a pane.
    @discardableResult
    func refresh(sessionID: String, path: String) -> IncrementalTranscript.Change? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            Self.log.debug("stat failed, retaining prior items session=\(sessionID, privacy: .public)")
            return nil
        }

        var entry = entries[sessionID]
        if let existing = entry {
            // Cheap reset conditions, decided from the stat alone: a different
            // file, a file that shrank, a modification time that moved
            // backwards, or a file rewritten to the SAME byte size with a newer
            // mtime. These are the /clear, /compact and session-rollover cases;
            // none can be served by appending, because the earlier bytes are no
            // longer the same bytes.
            //
            // The same-size case is the subtle one, and it is NOT subsumed by
            // the byte verification below: that only proves the last window
            // before `offset` still matches, while a same-size rewrite can
            // differ only in bytes further back. Without this predicate such a
            // file is never re-read — the size guard below reports "no change"
            // — and once it later grows, the next read resumes from an offset
            // into content that no longer exists, splicing stale rows onto a
            // suffix of the new transcript.
            if existing.path != path || size < existing.lastSize || modified < existing.lastModified
                || (size == existing.lastSize && modified != existing.lastModified) {
                Self.log.debug("resetting session=\(sessionID, privacy: .public)")
                entry = nil
            } else if size > existing.lastSize {
                // The file grew. That is what an ordinary append looks like —
                // and also what a rewrite that happens to land larger looks
                // like, which size and mtime alone cannot tell apart. Re-read
                // the bounded window just before `offset` and compare: if those
                // bytes changed, the file is a different file and resuming from
                // `offset` would splice rows from the old transcript onto a
                // suffix of the new one.
                if let intact = Self.consumedTailIsIntact(path: path, entry: existing) {
                    if !intact {
                        Self.log.debug(
                            "consumed bytes changed, resetting session=\(sessionID, privacy: .public)")
                        entry = nil
                    }
                } else {
                    // The window could not be read. "No news" — never "empty".
                    Self.log.debug(
                        "verify read failed, retaining prior items session=\(sessionID, privacy: .public)")
                    return nil
                }
            }
        }

        let isFirstRead = entry == nil
        var working = entry ?? Entry(
            path: path, offset: 0, lastSize: 0,
            lastModified: Date(timeIntervalSince1970: 0),
            consumedTail: nil,
            transcript: IncrementalTranscript())

        guard isFirstRead || size != working.lastSize else {
            return IncrementalTranscript.Change(
                appended: working.transcript.items.count..<working.transcript.items.count,
                updated: [])
        }

        guard let read = TranscriptFileWindow.read(path: path, from: working.offset) else {
            Self.log.debug("read failed, retaining prior items session=\(sessionID, privacy: .public)")
            return nil
        }

        let change = working.transcript.ingest(lines: read.lines)
        working.offset = read.newOffset
        working.lastSize = size
        working.lastModified = modified
        working.path = path
        working.consumedTail = Self.tailWindow(path: path, endingAt: read.newOffset)
        entries[sessionID] = working
        return change
    }

    /// Whether the bytes `entry` has already consumed still read the same.
    ///
    /// Returns nil when the window could not be read at all, which the caller
    /// must report as "no news" rather than resetting: an unreadable file is
    /// not evidence that the file was rewritten.
    private static func consumedTailIsIntact(path: String, entry: Entry) -> Bool? {
        guard let expected = entry.consumedTail, !expected.isEmpty else { return true }
        guard let actual = tailWindow(path: path, endingAt: entry.offset) else { return nil }
        return actual == expected
    }

    /// The last `verificationWindowBytes` bytes before `offset` — fewer when
    /// the file is shorter than that, which is itself a mismatch worth seeing.
    /// nil on any read failure.
    private static func tailWindow(path: String, endingAt offset: UInt64) -> Data? {
        guard offset > 0 else { return Data() }
        let length = min(verificationWindowBytes, offset)
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset - length)
            return try handle.read(upToCount: Int(length)) ?? Data()
        } catch {
            return nil
        }
    }
}
