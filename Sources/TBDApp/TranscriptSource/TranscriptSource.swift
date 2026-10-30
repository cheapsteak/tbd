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

    /// What an entry knows about the bytes it has already consumed — the input
    /// to the next tick's rewrite-versus-append check.
    ///
    /// The two cases must stay distinguishable. Collapsing them into a nullable
    /// `Data` reads "nothing to verify" and "verification unavailable" the same
    /// way, and the second one silently licenses the splice this whole
    /// mechanism exists to prevent.
    private enum ConsumedTail {
        /// The last `verificationWindowBytes` bytes immediately BEFORE
        /// `offset`, as they read when this entry consumed them. Empty when
        /// nothing has been consumed yet (`offset == 0`) — legitimately
        /// verifiable, because there is no earlier content a rewrite could
        /// have altered.
        case captured(Data)

        /// Bytes WERE consumed, but the window that would prove the next growth
        /// is an append could not be read back. Nothing exists to compare
        /// against, so the next growth must be re-read from byte zero rather
        /// than trusted.
        case unavailable
    }

    private struct Entry {
        var path: String
        var offset: UInt64
        var lastSize: UInt64
        var lastModified: Date
        var consumedTail: ConsumedTail
        var transcript: IncrementalTranscript
    }

    private var entries: [String: Entry] = [:]

    /// What an entry knows about one session's `transcript-stream.json`, the
    /// session mod's live view of the answer being written.
    ///
    /// Deliberately separate from `Entry`: the two files have different
    /// writers and lifetimes, and a session can have one, both or neither.
    /// Nothing here resets the other.
    private struct StreamEntry {
        var path: String
        /// The last snapshot that decoded, or nil when the file is missing.
        var snapshot: TranscriptStreamSnapshot?
        /// The size and modification date `snapshot` was read at, so a tick
        /// that finds the file unchanged reads nothing.
        var stamp: FileStamp?
        /// Whether the mod's heartbeat was older than the stale bound at the
        /// last tick. Read only while the snapshot has blocks to show.
        var heartbeatStale: Bool
    }

    private struct FileStamp: Equatable {
        let size: UInt64
        let modified: Date
    }

    private var streamEntries: [String: StreamEntry] = [:]

    /// Reads the verification window back off disk. Injected so a test can make
    /// the capture fail without racing the filesystem: in production the window
    /// is lost only when the file is replaced or removed in the instant between
    /// the main read and this one.
    private let captureTail: @Sendable (String, UInt64) -> Data?

    init() {
        self.captureTail = { path, offset in
            TranscriptSource.diskTailWindow(path: path, endingAt: offset)
        }
    }

    init(captureTail: @escaping @Sendable (String, UInt64) -> Data?) {
        self.captureTail = captureTail
    }

    func items(sessionID: String) -> [TranscriptItem] {
        entries[sessionID]?.transcript.items ?? []
    }

    /// How many sessions have a built transcript resident right now.
    ///
    /// Read-only, and here so the bound on this actor's retention is something
    /// a test can assert rather than something a comment claims. Nothing in the
    /// app reads it.
    var trackedSessionCount: Int { entries.count }

    /// How many sessions have a stream-file tail resident right now. Read-only,
    /// and here for the same reason as `trackedSessionCount`: so a test can
    /// assert the bound rather than trust a comment. Nothing in the app reads
    /// it.
    var trackedStreamSessionCount: Int { streamEntries.count }

    /// Drops everything built for `sessionID` — the transcript AND the
    /// stream snapshot read for it. The next `refresh` or
    /// `refreshStream` for that id starts over from byte zero.
    ///
    /// `TranscriptPollScheduler` is the only production caller, from two
    /// places: `deregister`, and `finishTick` for a poll whose refresh landed
    /// after its registration had already gone. Retention is scoped to
    /// registration either way, so no entry outlives the pane that asked for
    /// it.
    func forget(sessionID: String) {
        entries.removeValue(forKey: sessionID)
        streamEntries.removeValue(forKey: sessionID)
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
                if let intact = consumedTailIsIntact(path: path, entry: existing) {
                    if !intact {
                        Self.log.debug(
                            "consumed bytes unverified, resetting session=\(sessionID, privacy: .public)")
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
            consumedTail: .captured(Data()),
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
        // Capture the window the NEXT tick will verify against. A failure here
        // is not "nothing to verify": the file was replaced or removed in the
        // instant since the read above, and the bytes just consumed can no
        // longer be proven to be a prefix of what is on disk. Record that, so
        // the next growth resets instead of being trusted as an append.
        if let tail = captureTail(path, read.newOffset) {
            working.consumedTail = .captured(tail)
        } else {
            working.consumedTail = .unavailable
        }
        entries[sessionID] = working
        return change
    }

    // MARK: - Session mod stream file

    /// What one publish needs about `sessionID`, read in a single hop onto this
    /// actor.
    ///
    /// The items, the stream snapshot and which of its blocks the JSONL has
    /// confirmed are facts about one instant. Gathered with separate awaits, a
    /// `refresh` could land between them: a publish could then read the
    /// transcript from *before* a block's row arrived and the confirmation from
    /// *after* it, and show neither the provisional block nor its settled row.
    /// Nothing suspends inside this method, so the answers agree.
    ///
    /// `confirmedUUIDs` holds the snapshot's block `uuid`s that the
    /// transcript already has a row for, and no others.
    func snapshot(sessionID: String) -> StreamPublishSnapshot {
        let entry = entries[sessionID]
        let stream = streamEntries[sessionID]
        let confirmed = (stream?.snapshot?.blockUUIDs ?? []).filter {
            entry?.transcript.hasRow(uuid: $0) ?? false
        }
        return StreamPublishSnapshot(
            items: entry?.transcript.items ?? [],
            stream: stream?.snapshot,
            confirmedUUIDs: confirmed,
            heartbeatStale: stream?.heartbeatStale ?? false)
    }

    /// The stream snapshot last read for `sessionID`, or nil when none has
    /// been read or the file is missing.
    func streamSnapshot(sessionID: String) -> TranscriptStreamSnapshot? {
        streamEntries[sessionID]?.snapshot
    }

    /// Bring `sessionID`'s stream snapshot up to date with the file at `path`,
    /// and its heartbeat with the clock. Returns whether anything a publish
    /// shows changed.
    ///
    /// - **A missing file** means there is no stream: the snapshot is dropped.
    /// - **A file that does not parse, or has an unknown version,** is no
    ///   news: the last good snapshot stays. A cut-off read of a write in
    ///   progress is the expected cause, so nothing is recorded about the file
    ///   and the next tick reads it again.
    /// - **An unchanged file** — the same size and modification date as the
    ///   snapshot was read at — is not read again.
    ///
    /// The heartbeat (`alive.json`, beside the stream file) is read only while
    /// the snapshot has blocks: it can retire a provisional block and has
    /// nothing else to do. `now` is the instant it is measured against.
    @discardableResult
    func refreshStream(sessionID: String, path: String, now: Date) -> Bool {
        var working = streamEntries[sessionID]
        if let existing = working, existing.path != path {
            // A different file under the same session id: nothing read from the
            // old one describes the new one.
            working = nil
        }
        var entry = working ?? StreamEntry(path: path, snapshot: nil, stamp: nil, heartbeatStale: false)
        let previousSnapshot = working?.snapshot
        let previousStale = working?.heartbeatStale ?? false

        let stamp = Self.stamp(path: path)
        if stamp == nil || stamp != entry.stamp {
            switch StreamFileReader.read(path: path) {
            case .missing:
                entry.snapshot = nil
                entry.stamp = nil
            case .noNews:
                Self.log.debug(
                    "stream file unreadable, keeping the last snapshot session=\(sessionID, privacy: .public)")
            case .snapshot(let snapshot):
                entry.snapshot = snapshot
                entry.stamp = stamp
            }
        }

        let hasBlocks = entry.snapshot?.steps.contains { !$0.blocks.isEmpty } ?? false
        entry.heartbeatStale = hasBlocks
            && StreamFileReader.heartbeatIsStale(streamPath: path, now: now)

        streamEntries[sessionID] = entry
        return entry.snapshot != previousSnapshot || entry.heartbeatStale != previousStale
    }

    private static func stamp(path: String) -> FileStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return FileStamp(size: size, modified: modified)
    }

    /// Whether the bytes `entry` has already consumed still read the same.
    ///
    /// Returns false when they do not, and also when the entry never captured
    /// them — both mean this growth cannot be served by appending, and the
    /// caller must re-read from byte zero. Returns nil when the window cannot
    /// be read right now, which the caller must report as "no news" rather than
    /// resetting: an unreadable file is not evidence that the file was
    /// rewritten.
    private func consumedTailIsIntact(path: String, entry: Entry) -> Bool? {
        guard case .captured(let expected) = entry.consumedTail else { return false }
        guard !expected.isEmpty else { return true }
        guard let actual = captureTail(path, entry.offset) else { return nil }
        return actual == expected
    }

    /// The last `verificationWindowBytes` bytes before `offset` — fewer when
    /// the file is shorter than that, which is itself a mismatch worth seeing.
    /// Empty — not nil — when nothing has been consumed yet; nil on a read
    /// failure, which the caller records as `.unavailable`.
    private static func diskTailWindow(path: String, endingAt offset: UInt64) -> Data? {
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

/// What `TranscriptSource.snapshot(sessionID:)` hands one publish: the JSONL
/// items, the stream snapshot, and the two retire facts the source can know —
/// which of the snapshot's block `uuid`s the JSONL already holds, and whether
/// the mod's heartbeat has gone stale.
struct StreamPublishSnapshot: Sendable, Equatable {
    let items: [TranscriptItem]
    let stream: TranscriptStreamSnapshot?
    let confirmedUUIDs: Set<String>
    let heartbeatStale: Bool
}
