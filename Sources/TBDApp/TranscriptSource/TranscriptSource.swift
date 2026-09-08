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

    /// What an entry knows about one terminal's model-proxy stream file.
    ///
    /// Deliberately separate from `Entry`: the two files are different files
    /// with different lifetimes — the transcript JSONL belongs to the Claude
    /// session and the stream file to the terminal — and a session can have
    /// one, both or neither. Nothing here resets the other.
    private struct StreamEntry {
        var path: String
        var offset: UInt64
        var lastSize: UInt64
        /// Every line decoded so far, in file order. Bounded by the proxy's
        /// own per-message truncation, and defensively by `maxStreamLines`.
        var lines: [ModelProxyStreamLine]
        var provisional: ProvisionalMessage?
        /// The `now` this reader recorded the FIRST time a fold reported
        /// `.complete` for the message `provisional` names, reused on every
        /// later fold of the same message.
        ///
        /// `StreamFileReader.fold` stamps `.complete(at:)` with whatever `now`
        /// it is handed and says the stability of that value is the caller's
        /// to keep. This is where it is kept: without it every poll would
        /// re-stamp the completion instant with a fresh `Date()`, and the
        /// 60-second unconfirmed rule — which measures from when the reader
        /// first saw the stop — would never come due. Reset when the message
        /// id changes, because the new message has not completed yet.
        var completedAt: Date?
        /// The `now` at which this reader last saw a line arrive for the
        /// message `provisional` names.
        ///
        /// The ten-minute silent-stream rule measures from here, so it must
        /// move when a line lands and stay put when a poll finds nothing —
        /// stamping it with a fresh `Date()` every tick would push that
        /// deadline forward forever, exactly as re-stamping `completedAt`
        /// would push the 60-second one. Reset when the message id changes,
        /// because the deadline belongs to the message, not to the session.
        var lastLineAt: Date?
    }

    private var streamEntries: [String: StreamEntry] = [:]

    /// Defensive ceiling on one session's retained stream lines.
    ///
    /// The proxy truncates the file when nothing is in flight, so in practice
    /// the retained set is one turn's deltas. This bounds the pathological case
    /// — a proxy that never truncates, or a reader that never sees it happen —
    /// by dropping the oldest message that has already ended, which is the only
    /// content nothing can still be appended to.
    private static let maxStreamLines = 10_000

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
    /// provisional message tailed from the stream file. The next `refresh` or
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

    // MARK: - Model proxy stream file

    /// The message currently worth rendering from `sessionID`'s stream file, or
    /// nil when nothing has been tailed for it.
    func provisional(sessionID: String) -> ProvisionalMessage? {
        streamEntries[sessionID]?.provisional
    }

    /// Whether the session's own transcript has caught up with the assistant
    /// message `id` — the signal that retires a provisional row in favour of
    /// the real transcript item.
    ///
    /// False for a session with no transcript entry at all, which is the
    /// conservative reading: nothing has been read, so nothing confirms
    /// anything.
    func hasAssistantMessage(sessionID: String, id: String) -> Bool {
        entries[sessionID]?.transcript.hasAssistantMessage(id: id) ?? false
    }

    /// Everything one publish needs about `sessionID`, read in a single hop
    /// onto this actor.
    ///
    /// `items`, `provisional` and the provisional's confirmation are three
    /// facts about one instant, and gathering them with three separate awaits
    /// let a `refresh` land between them: a publish could then read the
    /// transcript from *before* the settled assistant message arrived and the
    /// confirmation from *after* it, and show neither the provisional row nor
    /// the settled one. Nothing suspends inside this method, so the three
    /// answers are necessarily consistent with each other.
    ///
    /// `confirmed` is `hasAssistantMessage` for the provisional's own id, and
    /// false when there is no provisional — no other message id is ever a
    /// candidate for a row, so the caller needs no other lookup.
    func snapshot(
        sessionID: String
    ) -> (items: [TranscriptItem], provisional: ProvisionalMessage?, confirmed: Bool) {
        let entry = entries[sessionID]
        let provisional = streamEntries[sessionID]?.provisional
        let confirmed = provisional.map {
            entry?.transcript.hasAssistantMessage(id: $0.messageID) ?? false
        } ?? false
        return (entry?.transcript.items ?? [], provisional, confirmed)
    }

    /// Bring `sessionID`'s provisional message up to date with the stream file
    /// at `path`. Returns whether the provisional actually changed.
    ///
    /// **An unreadable file is no news, never a blank row.** A failed stat or a
    /// failed read returns false and leaves the prior provisional exactly as it
    /// was — the file is written by a separate process that can be replacing,
    /// truncating or not-yet-creating it, and none of that is evidence the
    /// message on screen is gone.
    ///
    /// **A fold that finds nothing is no news either.** The proxy truncates the
    /// file when nothing is in flight, so an empty file means "no turn running"
    /// — not "the answer you are showing was withdrawn". The provisional row is
    /// retired by confirmation from the transcript or by the unconfirmed
    /// deadline, never by the stream file going quiet.
    ///
    /// `now` is the instant this poll happened. It is handed to
    /// `StreamFileReader.fold` only for a message that has just completed;
    /// a message already recorded as complete keeps the instant it was first
    /// seen to complete (`StreamEntry.completedAt`).
    @discardableResult
    func refreshStream(sessionID: String, path: String, now: Date) -> Bool {
        var entry = streamEntries[sessionID]
        if let existing = entry, existing.path != path {
            // A different file under the same session id, so the *working* copy
            // starts empty: nothing read from the old one describes the new one.
            //
            // The stored entry is deliberately not cleared here. If the new file
            // cannot be stat'd or read below, this returns without writing
            // anything back and the old path's provisional keeps the row — an
            // unreadable file is no news, never "the answer was withdrawn". The
            // switch takes effect on the first tick the new file can be read.
            entry = nil
        }
        var working = entry ?? StreamEntry(
            path: path, offset: 0, lastSize: 0, lines: [], provisional: nil, completedAt: nil)

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            Self.log.debug(
                "stream stat failed, retaining prior provisional session=\(sessionID, privacy: .public)")
            return false
        }

        // The shrink rule: the proxy truncates this file in place, so a file
        // shorter than what we have consumed — or shorter than we last saw it —
        // is a new file's worth of content at the same path. Resume from zero
        // and drop the lines the old content produced, or the fold would splice
        // a retired turn onto the new one.
        if size < working.offset || size < working.lastSize {
            Self.log.debug(
                "stream file shrank, restarting session=\(sessionID, privacy: .public)")
            working.offset = 0
            working.lines = []
        }

        // A file that is exactly the size we last saw has had nothing appended,
        // and the fold is a pure function of the lines — so there is nothing to
        // read and nothing that could have changed. Skips one open-and-read per
        // tick per visible pane, which at the 100 ms foreground cadence is the
        // difference worth having.
        if entry != nil, size == working.lastSize { return false }

        guard let read = TranscriptFileWindow.read(path: path, from: working.offset) else {
            Self.log.debug(
                "stream read failed, retaining prior provisional session=\(sessionID, privacy: .public)")
            return false
        }

        working.offset = read.newOffset
        working.lastSize = size
        working.path = path
        // A line that will not decode is skipped, not fatal: the tailer can
        // catch a partial append, and a newer proxy can write a `type` this
        // build does not know.
        let decoded = read.lines.compactMap(ModelProxyStreamLine.decode(line:))
        working.lines.append(contentsOf: decoded)
        working.lines = Self.capped(working.lines)

        let previous = working.provisional
        guard let folded = StreamFileReader.fold(lines: working.lines, now: now) else {
            streamEntries[sessionID] = working
            return false
        }

        if previous?.messageID != folded.messageID {
            // A different message now holds the row, and it has neither been
            // seen to complete nor been timed from before this fold.
            working.completedAt = nil
            working.lastLineAt = nil
        }
        // Only a line that actually arrived for *this* message restarts its
        // silence. Lines that belong to another in-flight message do not, and
        // a tick that decoded nothing at all leaves the deadline where it was.
        if working.lastLineAt == nil
            || decoded.contains(where: { $0.message == folded.messageID }) {
            working.lastLineAt = now
        }

        var phase = folded.phase
        if case .complete = folded.phase {
            if let firstSeen = working.completedAt {
                phase = .complete(at: firstSeen)
            } else {
                working.completedAt = now
            }
        }
        let stabilized = ProvisionalMessage(
            messageID: folded.messageID, text: folded.text, phase: phase,
            lastLineAt: working.lastLineAt ?? now)

        working.provisional = stabilized
        streamEntries[sessionID] = working
        return previous != working.provisional
    }

    /// Drops whole messages from the head until the retained lines are back
    /// under `maxStreamLines`, oldest ended message first.
    ///
    /// Only a message that has already ended is dropped: an in-flight one is
    /// still being appended to, and removing its head would leave the fold
    /// rendering a torn suffix of the very turn on screen.
    ///
    /// The **most recent** message is never dropped either, ended or not — which
    /// is also what keeps the cap inert while a single message is the only one
    /// resident. A long turn crosses the ceiling and then ends on the same tick
    /// its `stop` lands; dropping it there would fold to nothing, and the stored
    /// provisional would be stranded at `.streaming` holding a partial answer
    /// that nothing can ever complete. So a single pathologically long turn is
    /// allowed past the ceiling rather than be mangled or lost — the ceiling is
    /// a defence against accumulation *across* turns, which is the shape that
    /// actually grows without bound.
    ///
    /// "Most recent" is `StreamFileReader.mostRecentMessageID` — the message
    /// whose first line appears latest, the same ranking the fold picks with —
    /// and not the owner of the last retained line. Those diverge exactly when
    /// two parent requests interleave: an older message that keeps appending
    /// after a newer one has started and stopped owns the last line, so ranking
    /// by it protects the *older* turn and evicts every line of the newer one,
    /// which is the message the fold is rendering. Ranking by first-line
    /// position instead means eviction can only ever move the row forward to a
    /// later turn, never rewind it to an earlier one.
    private static func capped(_ lines: [ModelProxyStreamLine]) -> [ModelProxyStreamLine] {
        guard lines.count > maxStreamLines else { return lines }
        var kept = lines
        while kept.count > maxStreamLines,
              let newest = StreamFileReader.mostRecentMessageID(in: kept),
              let oldest = oldestEndedMessage(in: kept, excluding: newest) {
            kept.removeAll { $0.message == oldest }
        }
        return kept
    }

    /// The id of the earliest-appearing message that has a terminal line,
    /// ignoring `newest` — the most recent message by first-line position,
    /// which the caller must keep whether or not it has ended.
    private static func oldestEndedMessage(
        in lines: [ModelProxyStreamLine], excluding newest: String
    ) -> String? {
        var ended: Set<String> = []
        for line in lines {
            switch line {
            case let .stop(message): ended.insert(message)
            case let .aborted(message, _): ended.insert(message)
            case .start, .block, .text: break
            }
        }
        ended.remove(newest)
        guard !ended.isEmpty else { return nil }
        return lines.first { ended.contains($0.message) }?.message
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
