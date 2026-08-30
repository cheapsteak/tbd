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

    private struct Entry {
        var path: String
        var offset: UInt64
        var lastSize: UInt64
        var lastModified: Date
        var transcript: IncrementalTranscript
    }

    private var entries: [String: Entry] = [:]

    init() {}

    func items(sessionID: String) -> [TranscriptItem] {
        entries[sessionID]?.transcript.items ?? []
    }

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
        // Reset conditions: a different file, a file that shrank, a
        // modification time that moved backwards, or a file rewritten to the
        // SAME byte size with a newer mtime. These are the /clear, /compact and
        // session-rollover cases; none can be served by appending, because the
        // earlier bytes are no longer the same bytes.
        //
        // The same-size case is the subtle one. Without it the file is never
        // re-read — the size guard below reports "no change" — and once it
        // later grows, the next read resumes from an offset into content that
        // no longer exists, splicing stale rows onto a suffix of the new
        // transcript. Re-parsing costs a full pass only when the mtime moved
        // while the size did not, which an ordinary append cannot do, so the
        // common path is untouched.
        if let existing = entry,
           existing.path != path || size < existing.lastSize || modified < existing.lastModified
            || (size == existing.lastSize && modified != existing.lastModified) {
            Self.log.debug("resetting session=\(sessionID, privacy: .public)")
            entry = nil
        }

        let isFirstRead = entry == nil
        var working = entry ?? Entry(
            path: path, offset: 0, lastSize: 0,
            lastModified: Date(timeIntervalSince1970: 0),
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
        entries[sessionID] = working
        return change
    }
}
