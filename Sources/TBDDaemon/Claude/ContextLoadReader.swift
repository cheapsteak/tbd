import Foundation
import TBDShared

/// Reads one session's `ContextLoad` — how full its context window is — from
/// the two machine sources that can speak to it.
///
/// **There is no compiled model→window table here, and there must never be
/// one.** The effective window is a session fact, not a model fact: Claude Code
/// resolves it per session from the model id, a long-context suffix, a beta
/// header, environment overrides and a remote feature flag, so the same model
/// id can be a 200k session or a 1M session. A table — compiled, downloaded, or
/// sniffed out of a model id or a `[1m]` suffix — reports *capability*, and
/// capability errs in the dangerous direction: claiming 1M for a session
/// actually running at 200k reads one-fifth full at the boundary, which is
/// exactly where being wrong costs a session. Where nothing observed the
/// window, this reader says `unknown` and says why.
///
/// Two paths, in preference order:
///
/// 1. **The statusline tee fired.** Prefer the captured JSON's own paired
///    reading — Claude Code computed numerator, denominator and percentage at
///    one instant from one source, and taking both halves from it is the only
///    way to report a fraction that was ever simultaneously true.
/// 2. **It did not** — every non-desk session, and a desk whose statusline has
///    not run yet. The numerator comes from the transcript tail; the
///    denominator is `unknown`, with a `why` naming which case it is.
struct ContextLoadReader {
    /// Whether this session has a statusline tee — and when it does not, why
    /// not. Three shapes, because the `why` of an unknown window has to tell
    /// them apart and two of them are easy to conflate.
    enum TeeStatus: Sendable, Equatable {
        /// A Claude desk session: the tee is installed and may simply not have
        /// fired yet.
        case installed
        /// A desk session whose agent is not the one the tee installs on. The
        /// tee lives in the Claude spawn path, so a desk created on a
        /// Codex-preferring install is branded a desk and runs without one —
        /// reporting "installed but has not fired yet" for it would be false.
        case deskWithoutTee
        /// An ordinary session. The tee installs on desk sessions only.
        case notADesk
    }

    /// How much of the transcript's tail to read. The same 64 KiB window
    /// `DeliveryVerifier` tails with: large enough to span several assistant
    /// records, small enough that a multi-megabyte transcript costs one seek.
    static let defaultTailWindowBytes = 64 * 1024

    var tailWindowBytes: Int = ContextLoadReader.defaultTailWindowBytes
    /// The date seam. Only reached when a transcript record carries no
    /// parseable `timestamp` of its own — a persisted/compared timestamp, so
    /// the date seam rather than a clock.
    var now: @Sendable () -> Date = { Date() }

    /// Read the load for a session.
    ///
    /// - Parameters:
    ///   - capturePath: the statusline tee's capture file for this session.
    ///     Passed explicitly rather than derived so the reader is hermetic.
    ///   - transcriptPath: the session's transcript JSONL, when TBD knows one.
    ///   - tee: whether the statusline tee was installed for this session, and
    ///     if not, why not. Only used to word the `why` of an unknown window —
    ///     a desk whose statusline has not run yet is a different situation
    ///     from a desk that will never have one and from a fleet session that
    ///     was never going to, and a reader deserves to be told which.
    func read(
        capturePath: String,
        transcriptPath: String?,
        tee: TeeStatus
    ) -> ContextLoad {
        guard let capture = readCapture(atPath: capturePath) else {
            return ContextLoad(
                used: transcriptUsed(transcriptPath: transcriptPath),
                window: .unknown(why: unknownWindowReason(tee))
            )
        }
        guard let size = capture.contextWindowSize else {
            // The tee fired but this Claude Code build reported no
            // `context_window_size`. Nothing observed the denominator, so it is
            // unknown — the numerator the payload does carry is still better
            // than nothing, and still labeled with where it came from.
            return ContextLoad(
                used: capture.usedTokens.map {
                    ObservedFact(value: $0, source: .statuslineTee, observedAt: capture.observedAt)
                } ?? transcriptUsed(transcriptPath: transcriptPath),
                window: .unknown(
                    why: "the statusline tee fired for this session but its payload carried no "
                        + "context_window.context_window_size")
            )
        }
        let window = ContextWindow.observed(
            ObservedFact(value: size, source: .statuslineTee, observedAt: capture.observedAt))
        if let used = capture.usedTokens {
            return ContextLoad(
                used: ObservedFact(value: used, source: .statuslineTee, observedAt: capture.observedAt),
                window: window
            )
        }
        // `current_usage` is null before the session's first API call and again
        // after a `/compact` until the next one, and `used_percentage` can be
        // null early for the same reason. The denominator is still good, so the
        // numerator falls back to the transcript tail.
        //
        // A numerator and a denominator observed at different moments must not
        // be silently presented as one coherent fraction. Nothing here hides
        // that: the two halves carry their own sources and observed-ats, and
        // `ContextLoad.isPairedReading` is false for exactly this result, so a
        // consumer composing a percentage can say so.
        return ContextLoad(used: transcriptUsed(transcriptPath: transcriptPath), window: window)
    }

    /// Why no denominator was observed, in the caller's own terms.
    private func unknownWindowReason(_ tee: TeeStatus) -> String {
        switch tee {
        case .installed:
            return "the statusline tee is installed for this desk session but has not fired yet"
        case .deskWithoutTee:
            return "this desk session does not run the agent the statusline tee installs on, so "
                + "nothing will report its resolved context window"
        case .notADesk:
            return "the statusline tee installs on desk sessions only, so nothing has reported "
                + "this session's resolved context window"
        }
    }

    // MARK: - The transcript tail

    /// Tokens in the window, from the last assistant record carrying a `usage`
    /// block in the transcript's tail.
    ///
    /// **A known-fragile dependency, named rather than hidden.** Claude Code
    /// documents the transcript JSONL as an internal, version-unstable format;
    /// this read is coupled to its record shape and will break silently on a
    /// change to it. It is accepted because no better machine source for the
    /// numerator exists today, and it is written down here — and in the design
    /// spec — so the coupling is a stated cost rather than a surprise.
    private func transcriptUsed(transcriptPath: String?) -> ObservedFact<Int>? {
        guard let transcriptPath, !transcriptPath.isEmpty,
              let tail = readTail(atPath: transcriptPath) else {
            return nil
        }
        guard let (tokens, observedAt) = Self.lastUsage(inTail: tail, fallbackDate: now()) else {
            return nil
        }
        return ObservedFact(value: tokens, source: .transcriptTail, observedAt: observedAt)
    }

    /// Byte-bounded tail read, the shape `DeliveryVerifier.transcriptTail`
    /// uses: seek to `size - window`, read to the end, and let an unreadable
    /// file be nil rather than empty — "could not read" and "read nothing" are
    /// different facts and collapsing them is how an absence becomes a zero.
    private func readTail(atPath path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let window = UInt64(max(tailWindowBytes, 0))
        do {
            try handle.seek(toOffset: size > window ? size - window : 0)
            return try handle.readToEnd() ?? Data()
        } catch {
            return nil
        }
    }

    /// The last assistant `usage` block in the tail, and the record's own
    /// timestamp when it carried a parseable one.
    ///
    /// The token figure is **input + cache_creation + cache_read, excluding
    /// output** — the same formula `TranscriptParser.extractUsage` feeds into
    /// `TokenUsage.contextTotal` and the one `docs/transcript-context-usage.md`
    /// documents. There is deliberately no second formula in this codebase.
    ///
    /// The first line of a tail read is usually a fragment of a record, so a
    /// line that does not parse is skipped rather than treated as a failure.
    static func lastUsage(inTail tail: Data, fallbackDate: Date) -> (tokens: Int, observedAt: Date)? {
        guard let text = Self.decodeTail(tail) else { return nil }
        var result: (tokens: Int, observedAt: Date)?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let record = object as? [String: Any],
                  let message = record["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let input = usage["input_tokens"] as? Int else {
                continue
            }
            let tokens = input
                + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                + (usage["cache_read_input_tokens"] as? Int ?? 0)
            let observedAt = (record["timestamp"] as? String).flatMap(Self.parseTimestamp) ?? fallbackDate
            result = (tokens, observedAt)
        }
        return result
    }

    /// Decode a byte-offset tail as text.
    ///
    /// A tail begins wherever `size - window` lands, so it routinely begins
    /// **inside** a multi-byte sequence — agent output is full of emoji, box
    /// drawing and curly quotes. Strict decoding answers nil for the *entire*
    /// tail when it does, so a perfectly readable transcript reports
    /// "numerator unreadable", indistinguishable from a missing one.
    ///
    /// The repair resumes at the first newline. That is the right boundary
    /// rather than a convenient one: a record is a line, which is the single
    /// property of this file format that holds across its revisions, and the
    /// first line of a tail read is a fragment that the caller discards anyway.
    /// So nothing whole is lost — only the partial record that was never going
    /// to parse.
    static func decodeTail(_ tail: Data) -> String? {
        if let text = String(data: tail, encoding: .utf8) { return text }
        guard let newline = tail.firstIndex(of: 0x0A) else { return nil }
        return String(data: tail[tail.index(after: newline)...], encoding: .utf8)
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // MARK: - The statusline capture

    /// What one captured statusline payload says about context.
    struct Capture: Equatable {
        /// `context_window.context_window_size`, when present.
        let contextWindowSize: Int?
        /// Tokens in the window from `context_window.current_usage`, when that
        /// object is present. Null before the first API call and again after a
        /// `/compact`, which is why it is optional here.
        let usedTokens: Int?
        /// The capture file's modification time — when the tee published this
        /// payload, which is when Claude Code observed it. Not the time TBD
        /// read the file: aging a fact by the read would make a stale reading
        /// look fresh on every poll.
        let observedAt: Date
    }

    /// Read one capture, payload and stamp from the **same open file**.
    ///
    /// `contents(atPath:)` followed by `attributesOfItem(atPath:)` is two
    /// lookups of the same name, and the tee publishes by `mv -f` — an atomic
    /// rename that can land between them. The pair would then stamp one
    /// payload with a different file's modification time, producing an
    /// `ObservedFact` whose observed-at is newer than the value it labels,
    /// which is the one thing this file's opening comment forbids. Opening once
    /// and asking the descriptor pins both halves to one inode: a rename can
    /// still swap the name, but never what this handle is holding.
    func readCapture(atPath path: String) -> Capture? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd() ?? Data(),
              let modified = handle.modificationDate() else {
            return nil
        }
        return Self.parseCapture(data: data, observedAt: modified)
    }

    /// Parse a captured payload. Every field is treated as absent-able —
    /// `current_usage`, `used_percentage` and `remaining_percentage` are all
    /// documented as nullable, and a payload TBD cannot read at all is nil
    /// rather than a zero.
    static func parseCapture(data: Data, observedAt: Date) -> Capture? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let contextWindow = root["context_window"] as? [String: Any] else {
            return nil
        }
        let size = positiveInt(contextWindow["context_window_size"])
        var used: Int?
        if let current = contextWindow["current_usage"] as? [String: Any],
           let input = current["input_tokens"] as? Int {
            // Same formula as the transcript tail, for the same reason: output
            // tokens are not in the next request's window.
            used = input
                + (current["cache_creation_input_tokens"] as? Int ?? 0)
                + (current["cache_read_input_tokens"] as? Int ?? 0)
        }
        return Capture(contextWindowSize: size, usedTokens: used, observedAt: observedAt)
    }

    /// A strictly-positive integer out of a JSON value, or nil.
    ///
    /// `as? Int` alone is not that test, and the gap is not theoretical: JSON
    /// `true` arrives from `JSONSerialization` as an `NSNumber` that casts
    /// cleanly to `1`, which would be reported as a one-token context window and
    /// turn every percentage built on it into an absurdity. Zero and negatives
    /// are refused for the same reason — a denominator that cannot divide is not
    /// an observation, and `unknown` with a reason is the honest answer.
    ///
    /// This mirrors, field for field, the guard the Nightwatch reader applies to
    /// the same payload (`isinstance(size, bool) or not isinstance(size, int) or
    /// size <= 0`). The two read one file and must not disagree about whether it
    /// carries a window.
    private static func positiveInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        // `NSNumber as? Int` is exact: a fractional or out-of-range value is nil
        // rather than a truncation.
        guard let intValue = number as? Int, intValue > 0 else { return nil }
        return intValue
    }
}

// MARK: - Stamping a payload with its own file's time

extension FileHandle {
    /// The modification time of the file this handle already has open.
    ///
    /// `fstat` on the descriptor, deliberately, rather than a second lookup by
    /// path: a path can be re-pointed by a rename between two calls — which is
    /// precisely how the statusline tee publishes — and a stamp taken from the
    /// new file would label the old file's bytes. A descriptor names an inode,
    /// so the answer belongs to the payload the caller is holding.
    func modificationDate() -> Date? {
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else { return nil }
        let time = info.st_mtimespec
        return Date(timeIntervalSince1970:
            Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
    }
}
