import Foundation
import TBDShared

/// Reads one session's `ContextLoad` — how full its context window is — from
/// the machine sources that can speak to it.
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
/// Claude Code tells a third party the window it resolved through
/// `$.session.usage()` and `session.measure`, which the session mod's `usage`
/// feature records to `usage.json`. Whether a session has that file is decided
/// at spawn, so the reader asks the spawn:
///
/// 1. **Spawned with `usage`, and the mod is confirmed running.** Take the
///    file's window, and its tokens when it carries them — measured together,
///    so the reading is paired. The file must name the live incarnation: the
///    new process's heartbeat can land before its first usage write, and a
///    file an earlier process left behind describes that process.
/// 2. **Spawned with `usage`, but the mod is not confirmed — a stale
///    heartbeat included — or its file is missing, torn, another
///    incarnation's or carries no valid window.** The numerator comes from the
///    transcript tail and the window is `unknown`.
/// 3. **Parked, and its last spawn ran `usage`** (`readParked`). Parking
///    replaces the agent with an inert shell, so no process is reporting a
///    window, and the session's shared `spawn.json` cannot say which earlier
///    process a usage file on disk belongs to. The window is `unknown` and
///    the numerator comes from the transcript tail.
/// 4. **Spawned without `usage`.** Nothing reports the session's window. The
///    numerator comes from the transcript tail and the window is `unknown`,
///    with a `why` that says so.
struct ContextLoadReader {
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
    ///   - usagePath: the session mod's `usage.json` for this session, when the
    ///     session has a directory. Read only when `usageLiveness` is
    ///     `.confirmed`.
    ///   - usageIncarnationID: the session's live incarnation. When given, a
    ///     usage file naming any other incarnation — or none — was written by
    ///     an earlier process of the same Claude session and is not read. A nil
    ///     live incarnation is unknown, so no file is accepted.
    ///   - usageLiveness: `SessionModLiveness` for the `usage` feature. `.legacy`
    ///     — a spawn made without the feature, and the default — means nothing
    ///     reports the window; any other answer means the spawn chose to record
    ///     it through the mod's file.
    ///   - transcriptPath: the session's transcript JSONL, when TBD knows one.
    func read(
        usagePath: String? = nil,
        usageIncarnationID: UUID? = nil,
        usageLiveness: SessionModLiveness = .legacy,
        transcriptPath: String?
    ) -> ContextLoad {
        switch usageLiveness {
        case .legacy:
            return ContextLoad(
                used: transcriptUsed(transcriptPath: transcriptPath),
                window: .unknown(
                    why: "this session was spawned without the session mod's usage feature, so "
                        + "nothing reports its resolved context window"))
        case .unknown(let reason):
            return ContextLoad(
                used: transcriptUsed(transcriptPath: transcriptPath),
                window: .unknown(
                    why: "this session was spawned to record its usage through the session mod, "
                        + "but the mod is not confirmed running in it (\(reason.rawValue)), so "
                        + "nothing has reported its resolved context window"))
        case .confirmed:
            return readFromUsage(
                usagePath: usagePath, liveIncarnationID: usageIncarnationID,
                transcriptPath: transcriptPath)
        }
    }

    /// A parked session whose last spawn ran `usage` — case 3 above. No
    /// process is reporting its window, so the window is `unknown` and the
    /// numerator comes from the transcript tail; the usage file is not read.
    func readParked(transcriptPath: String?) -> ContextLoad {
        ContextLoad(
            used: transcriptUsed(transcriptPath: transcriptPath),
            window: .unknown(
                why: "this session is parked, so no process is reporting its context window"))
    }

    // MARK: - The session mod's usage file

    /// A confirmed session's `usage.json`. Every way the file can fail to
    /// carry a window — missing, torn mid-write (`$.fs` has no rename),
    /// malformed, or a window that is zero, negative or a boolean — reads as
    /// "not observed", never as zero: the window is `unknown` with a `why`
    /// naming the file, and the numerator falls back to the transcript tail.
    /// So does a file from another incarnation: liveness confirms the mod is
    /// running in this process, not that this process has written yet.
    private func readFromUsage(
        usagePath: String?, liveIncarnationID: UUID?, transcriptPath: String?
    ) -> ContextLoad {
        func unobserved(_ why: String) -> ContextLoad {
            ContextLoad(used: transcriptUsed(transcriptPath: transcriptPath), window: .unknown(why: why))
        }
        guard let usagePath, !usagePath.isEmpty else {
            return unobserved("the session mod is recording this session's usage, but TBD has no "
                + "session directory to read its usage file from")
        }
        let record: SessionModFiles.UsageRecord
        switch SessionModFiles.read(SessionModFiles.UsageRecord.self, at: URL(fileURLWithPath: usagePath)) {
        case .missing:
            return unobserved("the session mod is recording this session's usage, but its usage "
                + "file has not been written yet")
        case .unreadable:
            return unobserved("the session mod's usage file for this session is unreadable — torn "
                + "mid-write or malformed — so it reports no context window")
        case .record(let decoded):
            record = decoded
        }
        // Compared as `SessionModLiveness.sameIncarnation` does: parsed, so
        // the UUID's case does not matter.
        // A missing live incarnation reads as unknown, never as a match.
        guard let live = liveIncarnationID,
              record.incarnationID.flatMap(UUID.init(uuidString:)) == live else {
            return unobserved("the session mod's usage file for this session is from an earlier "
                + "process of it, and this process has not written its own yet")
        }
        guard let size = record.validWindow else {
            return unobserved("the session mod's usage file for this session carries no valid "
                + "context.window")
        }
        let observedAt = Date(timeIntervalSince1970: Double(record.measuredAt) / 1000)
        let window = ContextWindow.observed(
            ObservedFact(value: size, source: .sessionMod, observedAt: observedAt))
        // `tokens` is absent at the `session.start` baseline, before any
        // response reported a fill. The window is still good, so the numerator
        // falls back to the transcript tail — an unpaired reading, which
        // `ContextLoad.isPairedReading` reports as such.
        guard let tokens = record.context.tokens, tokens >= 0 else {
            return ContextLoad(used: transcriptUsed(transcriptPath: transcriptPath), window: window)
        }
        return ContextLoad(
            used: ObservedFact(value: tokens, source: .sessionMod, observedAt: observedAt),
            window: window)
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
}

// MARK: - Stamping a payload with its own file's time

extension FileHandle {
    /// The modification time of the file this handle already has open.
    ///
    /// `fstat` on the descriptor, deliberately, rather than a second lookup by
    /// path: a path can be re-pointed by a rename between two calls, and a
    /// stamp taken from the new file would label the old file's bytes. A
    /// descriptor names an inode, so the answer belongs to the payload the
    /// caller is holding.
    func modificationDate() -> Date? {
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else { return nil }
        let time = info.st_mtimespec
        return Date(timeIntervalSince1970:
            Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
    }
}
