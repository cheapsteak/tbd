import Foundation

/// Where one reader of a growing JSONL has read to, and the rules that decide,
/// on each refresh, whether the file grew by an append or became a different
/// file.
///
/// Reading resumes from `offset`, which is either zero or one past a newline
/// `TranscriptFileWindow` returned, so every read is line-aligned. Resuming is
/// only correct while the bytes before `offset` are still the bytes this cursor
/// consumed. `step(path:)` checks that cheaply on every call: first from the
/// file's size and modification date, then, when the file grew, by re-reading
/// the last `verificationWindowBytes` bytes before `offset` and comparing them
/// with what was there when they were consumed.
///
/// The cursor holds no transcript. What the lines mean, and what to rebuild on
/// a reset, belongs to the caller.
public struct TranscriptAppendCursor: Sendable {

    /// What one `step(path:)` found.
    public enum Step: Sendable, Equatable {
        /// The file could not be stat'ed or read, or the window that proves an
        /// append could not be read back. No news, never "the transcript is
        /// empty": the cursor is unchanged, and whatever the caller built stays
        /// built.
        case unreadable
        /// The same size and modification date as at the last read. Nothing
        /// was read.
        case unchanged
        /// The file is no longer the one this cursor consumed: a different
        /// path, a file that shrank, a modification date that moved backwards,
        /// the same size with a new modification date, or bytes before
        /// `offset` that no longer match (or were never captured). Nothing was
        /// read and the cursor is unchanged; the caller starts over with a
        /// cursor at offset zero.
        case reset
        /// The complete lines past the previous `offset`, possibly none. The
        /// cursor has moved past them.
        case appended(lines: [String])
    }

    /// How many bytes of the already-consumed region are re-read and compared
    /// on each growth, to prove the file was appended to rather than
    /// rewritten. Fixed size: a caller can poll at 100 ms, so the per-step
    /// cost must not scale with the transcript.
    public static let verificationWindowBytes: UInt64 = 512

    /// How much `rebaseAfterPrepend(limit:)` reads at a time.
    static let rebaseStepBytes = 1 << 20

    /// What the cursor knows about the bytes it has already consumed: the
    /// input to the next step's rewrite-versus-append check.
    ///
    /// The two cases must stay distinguishable. Collapsing them into a nullable
    /// `Data` reads "nothing to verify" and "verification unavailable" the same
    /// way, and the second one silently licenses the splice this whole
    /// mechanism exists to prevent.
    private enum ConsumedTail: Sendable {
        /// The last `verificationWindowBytes` bytes immediately BEFORE
        /// `offset`, as they read when this cursor consumed them. Empty when
        /// nothing has been consumed yet (`offset == 0`), which is legitimately
        /// verifiable, because there is no earlier content a rewrite could
        /// have altered.
        case captured(Data)

        /// Bytes WERE consumed, but the window that would prove the next growth
        /// is an append could not be read back. Nothing exists to compare
        /// against, so the next growth must be re-read from byte zero rather
        /// than trusted.
        case unavailable
    }

    /// The size and modification date the last read saw.
    private struct Stamp: Sendable {
        let size: UInt64
        let modified: Date
    }

    /// The file the cursor last read, or was made for.
    public private(set) var path: String

    /// Where the next read starts: zero, or one past a newline.
    public private(set) var offset: UInt64

    /// Nil until the first read. A cursor that has never read takes no reset
    /// decision: its first step reads from `offset` unconditionally.
    private var stamp: Stamp?

    private var consumedTail: ConsumedTail

    /// Reads the verification window back off disk: the bytes that end at the
    /// given offset of the file at the given path, nil on a read failure.
    /// Injected so a test can make the capture fail without racing the
    /// filesystem. `diskTailWindow(path:endingAt:)` is the production reader.
    private let captureTail: @Sendable (String, UInt64) -> Data?

    /// A cursor for `path` that has consumed everything before `offset`.
    ///
    /// At offset zero nothing has been consumed and `captureTail` is not
    /// called. Above zero, the window before `offset` is captured now, so a
    /// `rebaseAfterPrepend(limit:)` before the first step has something to
    /// look for. The first `step(path:)` reads from `offset` whatever the file
    /// looks like: the caller vouches for an offset it hands in.
    public init(path: String, offset: UInt64, captureTail: @escaping @Sendable (String, UInt64) -> Data?) {
        self.path = path
        self.offset = offset
        self.captureTail = captureTail
        self.consumedTail = .captured(Data())
        if offset > 0 {
            recaptureTail()
        }
    }

    /// One refresh of the file at `path`.
    ///
    /// In order: a failed stat is `.unreadable`. For a cursor that has read
    /// before, a different path, a shrink, a modification date that moved
    /// backwards, or the same size with a new modification date is `.reset`;
    /// otherwise a file that grew has its consumed window re-read, which is
    /// `.unreadable` when it cannot be read and `.reset` when it differs; and a
    /// file that did not grow is `.unchanged`. Then the read from `offset`:
    /// `.unreadable` when it fails, else `.appended` with the complete lines,
    /// after which the window the next step verifies against is captured.
    public mutating func step(path: String) -> Step {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            return .unreadable
        }

        if let last = stamp {
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
            // file is never re-read (the size check below reports "no
            // change"), and once it later grows, the next read resumes from an
            // offset into content that no longer exists, splicing stale rows
            // onto a suffix of the new transcript.
            if self.path != path || size < last.size || modified < last.modified
                || (size == last.size && modified != last.modified) {
                return .reset
            } else if size > last.size {
                // The file grew. That is what an ordinary append looks like,
                // and also what a rewrite that happens to land larger looks
                // like, which size and mtime alone cannot tell apart. Re-read
                // the bounded window just before `offset` and compare: if those
                // bytes changed, the file is a different file and resuming from
                // `offset` would splice rows from the old transcript onto a
                // suffix of the new one.
                guard let intact = consumedTailIsIntact(path: path) else {
                    // The window could not be read. "No news", never "empty".
                    return .unreadable
                }
                if !intact {
                    return .reset
                }
            } else {
                return .unchanged
            }
        }

        guard let read = TranscriptFileWindow.read(path: path, from: offset) else {
            return .unreadable
        }
        self.offset = read.newOffset
        self.stamp = Stamp(size: size, modified: modified)
        self.path = path
        // Capture the window the NEXT step will verify against. A failure here
        // is not "nothing to verify": the file was replaced or removed in the
        // instant since the read above, and the bytes just consumed can no
        // longer be proven to be a prefix of what is on disk. Record that, so
        // the next growth resets instead of being trusted as an append.
        recaptureTail()
        return .appended(lines: read.lines)
    }

    /// After a known prepend (the remote cache's `head` moved), finds the
    /// consumed window again within `limit` bytes past `offset`, and moves
    /// `offset` to just past it. False means the caller resets.
    ///
    /// A prepend of `k` bytes moves the consumed window from ending at
    /// `offset` to ending at `offset + k`. So the scan reads from the window's
    /// length before `offset` (where the window starts when `k` is zero) up to
    /// `offset + limit`, in steps of `rebaseStepBytes`, carrying the last
    /// window-length-minus-one bytes of each step into the next so a match that
    /// spans two steps is still found. A match ends at `p`, at most `limit`
    /// bytes past `offset`; when `p` is at a line start, `offset` becomes `p`
    /// and the window is captured again there.
    ///
    /// When the window's bytes occur more than once in the scanned range, the
    /// first match wins: the earliest `p`. A prepend that itself contains a
    /// copy of the window therefore lands the cursor inside the prepended
    /// bytes, and the next step delivers the rest of them again. A line-aligned
    /// 512-byte window repeated verbatim is rare in a transcript, whose rows
    /// carry unique ids and timestamps.
    ///
    /// False, with the cursor unchanged, when the window was never captured,
    /// when it is empty above offset zero (there is nothing to look for), when
    /// the file cannot be read, or when no match ends at a line start within
    /// the limit. An empty window at offset zero means nothing was consumed, so
    /// there is nothing to move: true, with the cursor unchanged.
    public mutating func rebaseAfterPrepend(limit: Int) -> Bool {
        guard case .captured(let tail) = consumedTail else { return false }
        guard !tail.isEmpty else { return offset == 0 }
        guard limit >= 0, let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }

        let tailLength = UInt64(tail.count)
        let scanStart = offset >= tailLength ? offset - tailLength : 0
        let scanEnd = offset + UInt64(limit)
        guard (try? handle.seek(toOffset: scanStart)) != nil else { return false }
        // Keep only what could still begin a match that ends in the next
        // step: one byte fewer than the window.
        let keep = tail.count - 1

        // `buffer` holds the file's bytes from `bufferStart` on.
        var buffer = Data()
        var bufferStart = scanStart
        var readTo = scanStart
        while readTo < scanEnd {
            let count = Int(min(UInt64(Self.rebaseStepBytes), scanEnd - readTo))
            guard let chunk = try? handle.read(upToCount: count), !chunk.isEmpty else { break }
            readTo += UInt64(chunk.count)
            buffer.append(chunk)

            if let match = buffer.range(of: tail) {
                // The byte before `p` is the window's last byte, so every match
                // of the same window agrees on whether it ends at a line start:
                // when the first does not, none does.
                guard buffer[buffer.index(before: match.upperBound)] == UInt8(ascii: "\n") else {
                    return false
                }
                offset = bufferStart + UInt64(match.upperBound - buffer.startIndex)
                recaptureTail()
                return true
            }

            if buffer.count > keep {
                bufferStart += UInt64(buffer.count - keep)
                buffer = Data(buffer.suffix(keep))
            }
        }
        return false
    }

    /// The last `verificationWindowBytes` bytes before `offset`, fewer when
    /// the file is shorter than that, which is itself a mismatch worth seeing.
    /// Empty, not nil, when nothing has been consumed yet; nil on a read
    /// failure, which the cursor records as "unavailable".
    public static func diskTailWindow(path: String, endingAt offset: UInt64) -> Data? {
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

    /// Whether the bytes this cursor has already consumed still read the same.
    ///
    /// Returns false when they do not, and also when the cursor never captured
    /// them: both mean this growth cannot be served by appending, and the
    /// caller must re-read from byte zero. Returns nil when the window cannot
    /// be read right now, which the caller must report as "no news" rather than
    /// resetting: an unreadable file is not evidence that the file was
    /// rewritten.
    private func consumedTailIsIntact(path: String) -> Bool? {
        guard case .captured(let expected) = consumedTail else { return false }
        guard !expected.isEmpty else { return true }
        guard let actual = captureTail(path, offset) else { return nil }
        return actual == expected
    }

    private mutating func recaptureTail() {
        if let tail = captureTail(path, offset) {
            consumedTail = .captured(tail)
        } else {
            consumedTail = .unavailable
        }
    }
}
