import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Tier 2 — real files in a temp directory, because the reader's contract
/// includes the capture file's modification time and a byte-bounded tail read,
/// neither of which survives being mocked away. No `TBD_HOME` involved: every
/// path is passed in.
@Suite struct ContextLoadReaderTests {

    private struct Scratch {
        let root: URL
        let capturePath: String
        let transcriptPath: String

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("tbd-ctx-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            capturePath = root.appendingPathComponent("capture.json").path
            transcriptPath = root.appendingPathComponent("transcript.jsonl").path
        }

        func writeCapture(_ json: String, modified: Date) throws {
            try Data(json.utf8).write(to: URL(fileURLWithPath: capturePath))
            try FileManager.default.setAttributes(
                [.modificationDate: modified], ofItemAtPath: capturePath)
        }

        /// Two assistant records; the later one is what the reader must use.
        func writeTranscript(tokens: Int, timestamp: String) throws {
            let earlier = #"{"type":"assistant","timestamp":"2026-08-10T00:00:00Z","message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
            let latest = """
            {"type":"assistant","timestamp":"\(timestamp)","message":{"usage":\
            {"input_tokens":\(tokens - 30),"output_tokens":9999,\
            "cache_creation_input_tokens":20,"cache_read_input_tokens":10}}}
            """
            try Data(([earlier, latest].joined(separator: "\n") + "\n").utf8)
                .write(to: URL(fileURLWithPath: transcriptPath))
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private static let captureModified = Date(timeIntervalSince1970: 1_770_000_000)
    private static let transcriptStamp = "2026-08-10T12:00:00Z"
    private static var transcriptDate: Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: transcriptStamp)!
    }

    private static func fullCapture(size: Int = 1_000_000, used: Int = 250_000) -> String {
        """
        {"session_id":"s","context_window":{"total_input_tokens":1,"total_output_tokens":2,
        "context_window_size":\(size),"used_percentage":25.0,"remaining_percentage":75.0,
        "current_usage":{"input_tokens":\(used - 30),"output_tokens":5000,
        "cache_creation_input_tokens":20,"cache_read_input_tokens":10}}}
        """
    }

    // MARK: - Tee absent

    @Test func nonDeskSessionReportsAnUnknownWindowNamingTheCase() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try scratch.writeTranscript(tokens: 120_000, timestamp: Self.transcriptStamp)

        let load = ContextLoadReader().read(
            capturePath: scratch.capturePath, transcriptPath: scratch.transcriptPath,
            tee: .notADesk)

        // Never a guess. The numerator is real and labeled with where it came
        // from; the denominator says it does not know, and why.
        let used = try #require(load.used)
        #expect(used.value == 120_000)
        #expect(used.source == .transcriptTail)
        #expect(used.observedAt == Self.transcriptDate)
        guard case .unknown(let why) = load.window else {
            Issue.record("expected an unknown window, got \(load.window)")
            return
        }
        #expect(why.contains("desk sessions only"))
        #expect(!load.isPairedReading)
    }

    @Test func deskWhoseTeeHasNotFiredSaysSoRatherThanBlamingTheFleetRule() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try scratch.writeTranscript(tokens: 50_000, timestamp: Self.transcriptStamp)

        let load = ContextLoadReader().read(
            capturePath: scratch.capturePath, transcriptPath: scratch.transcriptPath,
            tee: .installed)

        guard case .unknown(let why) = load.window else {
            Issue.record("expected an unknown window, got \(load.window)")
            return
        }
        #expect(why.contains("has not fired yet"))
    }

    @Test func noTranscriptAndNoCaptureLeavesBothHalvesHonestlyEmpty() {
        let load = ContextLoadReader().read(
            capturePath: "/nonexistent/capture.json", transcriptPath: nil, tee: .notADesk)
        #expect(load.used == nil)
        #expect(load.percentUsed() == nil)
    }

    @Test func theTwoHundredKFallbackIsLabelledEverywhereItIsUsed() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try scratch.writeTranscript(tokens: 100_000, timestamp: Self.transcriptStamp)

        let load = ContextLoadReader().read(
            capturePath: scratch.capturePath, transcriptPath: scratch.transcriptPath,
            tee: .notADesk)

        let percent = try #require(load.percentUsed())
        #expect(percent.percent == 50.0)
        // The flag rides with the number: a caller cannot receive the
        // percentage without also receiving "this denominator was assumed".
        #expect(percent.assumedWindow)
        #expect(load.window.effectiveTokens() == (ContextWindow.assumedTokens, true))
    }

    // MARK: - Tee present

    @Test func fullCaptureGivesThePairedReadingWithTheCapturesMtime() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        // A transcript exists and disagrees — the paired reading must win.
        try scratch.writeTranscript(tokens: 999_999, timestamp: Self.transcriptStamp)
        try scratch.writeCapture(Self.fullCapture(), modified: Self.captureModified)

        let load = ContextLoadReader().read(
            capturePath: scratch.capturePath, transcriptPath: scratch.transcriptPath,
            tee: .installed)

        guard case .observed(let window) = load.window else {
            Issue.record("expected an observed window, got \(load.window)")
            return
        }
        #expect(window.value == 1_000_000)
        #expect(window.source == .statuslineTee)
        // The capture's mtime is when Claude Code observed it, not when TBD
        // read the file — aging by the read makes a stale fact look fresh.
        #expect(window.observedAt == Self.captureModified)
        let used = try #require(load.used)
        // input + both cache buckets, output excluded — one formula, the same
        // one the transcript path uses.
        #expect(used.value == 250_000)
        #expect(used.source == .statuslineTee)
        #expect(used.observedAt == Self.captureModified)
        #expect(load.isPairedReading)
        let percent = try #require(load.percentUsed())
        #expect(percent.percent == 25.0)
        #expect(!percent.assumedWindow)
    }

    @Test func nullCurrentUsageFallsBackToTheTranscriptAndSaysItIsNotPaired() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try scratch.writeTranscript(tokens: 77_000, timestamp: Self.transcriptStamp)
        // The documented shape right after a `/compact`, before the next call.
        try scratch.writeCapture(
            #"{"context_window":{"context_window_size":200000,"used_percentage":null,"current_usage":null}}"#,
            modified: Self.captureModified)

        let load = ContextLoadReader().read(
            capturePath: scratch.capturePath, transcriptPath: scratch.transcriptPath,
            tee: .installed)

        guard case .observed(let window) = load.window else {
            Issue.record("expected an observed window, got \(load.window)")
            return
        }
        #expect(window.value == 200_000)
        let used = try #require(load.used)
        #expect(used.value == 77_000)
        #expect(used.source == .transcriptTail)
        // Two moments, two sources — so the pair is NOT presented as one
        // coherent reading, and a consumer composing a percentage can say so.
        #expect(used.observedAt != window.observedAt)
        #expect(!load.isPairedReading)
    }

    @Test func captureWithoutAWindowSizeStillRefusesToGuessOne() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try scratch.writeCapture(
            #"{"model":{"id":"claude-opus-4-1[1m]"},"context_window":{"current_usage":{"input_tokens":5}}}"#,
            modified: Self.captureModified)

        let load = ContextLoadReader().read(
            capturePath: scratch.capturePath, transcriptPath: nil, tee: .installed)

        // A `[1m]` in the model id is exactly the sniff this design refuses:
        // it reports capability, not the window in force.
        guard case .unknown(let why) = load.window else {
            Issue.record("expected an unknown window, got \(load.window)")
            return
        }
        #expect(why.contains("context_window_size"))
        #expect(load.used?.value == 5)
    }

    /// A malformed `context_window_size` is "no denominator", not a denominator.
    ///
    /// `as? Int` alone is not that test, and the boolean case is the one that
    /// bites: JSON `true` arrives from `JSONSerialization` as an `NSNumber` that
    /// casts cleanly to `1`, so the session would be reported as running in a
    /// one-token window with every percentage built on it absurd. The Nightwatch
    /// reader rejects the same set (`isinstance(size, bool) or not
    /// isinstance(size, int) or size <= 0`); the two read one file and must not
    /// disagree about whether it carries a window.
    @Test(arguments: ["true", "false", "0", "-1", "1.5", #""200000""#, "null", "[]", "{}"])
    func aMalformedWindowSizeIsNoWindowRatherThanAWrongOne(literal: String) throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try scratch.writeCapture(
            """
            {"context_window":{"context_window_size":\(literal),
            "current_usage":{"input_tokens":5}}}
            """,
            modified: Self.captureModified)

        let load = ContextLoadReader().read(
            capturePath: scratch.capturePath, transcriptPath: nil, tee: .installed)

        guard case .unknown(let why) = load.window else {
            Issue.record("a \(literal) context_window_size was reported as a window: \(load.window)")
            return
        }
        #expect(why.contains("context_window_size"))
        // The numerator the payload does carry is still better than nothing.
        #expect(load.used?.value == 5)
        #expect(!load.isPairedReading)
    }

    /// The guard's own OFF branch: an ordinary positive integer still reads.
    @Test func anOrdinaryWindowSizeStillReads() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try scratch.writeCapture(
            #"{"context_window":{"context_window_size":1,"current_usage":{"input_tokens":5}}}"#,
            modified: Self.captureModified)

        let load = ContextLoadReader().read(
            capturePath: scratch.capturePath, transcriptPath: nil, tee: .installed)

        guard case .observed(let window) = load.window else {
            Issue.record("expected an observed window, got \(load.window)")
            return
        }
        #expect(window.value == 1)
    }

    /// A desk on an agent the tee does not install on is neither "installed but
    /// not fired" nor "not a desk", and saying either would be false.
    /// `spawnPrimaryTerminals` resolves the primary agent from
    /// `primaryAgentPreference`, so a desk on a Codex-preferring install is
    /// branded a desk and runs with no tee at all.
    @Test func aDeskWithoutATeeIsNotDescribedAsOneWaitingToFire() {
        let load = ContextLoadReader().read(
            capturePath: "/nonexistent/capture.json", transcriptPath: nil,
            tee: .deskWithoutTee)

        guard case .unknown(let why) = load.window else {
            Issue.record("expected an unknown window, got \(load.window)")
            return
        }
        #expect(!why.contains("has not fired yet"))
        #expect(why.contains("does not run the agent the statusline tee installs on"))
    }

    @Test func malformedCaptureFallsBackToTheTranscriptRatherThanFailing() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try scratch.writeTranscript(tokens: 33_000, timestamp: Self.transcriptStamp)
        try scratch.writeCapture("{ half a payl", modified: Self.captureModified)

        let load = ContextLoadReader().read(
            capturePath: scratch.capturePath, transcriptPath: scratch.transcriptPath,
            tee: .installed)

        #expect(load.used?.value == 33_000)
        #expect(load.used?.source == .transcriptTail)
    }

    // MARK: - The tail read

    @Test func tailReadIsByteBoundedAndTolerantOfATruncatedFirstLine() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        var lines: [String] = []
        for index in 1...500 {
            lines.append(
                #"{"type":"assistant","message":{"usage":{"input_tokens":\#(index),"#
                + #""cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: URL(fileURLWithPath: scratch.transcriptPath))

        var reader = ContextLoadReader()
        reader.tailWindowBytes = 512

        let load = reader.read(
            capturePath: "/nonexistent", transcriptPath: scratch.transcriptPath, tee: .notADesk)

        // The window lands mid-record, so the first line in it is a fragment.
        // It is skipped, and the last complete record still wins.
        #expect(load.used?.value == 500)
    }

    @Test func recordWithoutATimestampFallsBackToTheInjectedDate() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let line = #"{"message":{"usage":{"input_tokens":42}}}"# + "\n"
        try Data(line.utf8).write(to: URL(fileURLWithPath: scratch.transcriptPath))
        let fixed = Date(timeIntervalSince1970: 1_234_567)

        var reader = ContextLoadReader()
        reader.now = { fixed }

        let load = reader.read(
            capturePath: "/nonexistent", transcriptPath: scratch.transcriptPath, tee: .notADesk)

        #expect(load.used?.observedAt == fixed)
        // Cache buckets absent entirely — defaulted to zero, not treated as a
        // parse failure, since sessions without prompt caching omit them.
        #expect(load.used?.value == 42)
    }

    /// The ASCII cut above is the easy case. A real transcript is full of
    /// emoji, box drawing and curly quotes, so a byte-offset tail routinely
    /// starts **inside** a multi-byte sequence — and strict UTF-8 decoding
    /// answers nil for the whole tail when it does, erasing a numerator that
    /// was sitting there in plain ASCII a few hundred bytes later. The failure
    /// is indistinguishable from a missing transcript, which is what makes it
    /// worth a test of its own.
    @Test func aTailCutInsideAMultiByteSequenceStillReportsTheNumerator() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        // 4-byte emoji as the padding — ordinary agent output.
        let padding = String(repeating: "🙂", count: 200)
        let filler = #"{"type":"user","message":{"content":"\#(padding)"}}"#
        let record = #"{"type":"assistant","message":{"usage":{"input_tokens":777,"#
            + #""cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        let bytes = Data((filler + "\n" + record + "\n").utf8)
        try bytes.write(to: URL(fileURLWithPath: scratch.transcriptPath))

        // Pin the cut **inside** the filler's last emoji rather than hoping for
        // it: the tail then opens on a UTF-8 continuation byte, which is the
        // exact shape that used to erase the whole read.
        let lastEmojiStart = try #require(
            bytes.range(of: Data("🙂".utf8), options: .backwards)?.lowerBound)
        let cut = lastEmojiStart + 1
        #expect(bytes[cut] & 0xC0 == 0x80, "the cut must land on a continuation byte")
        #expect(String(data: bytes[cut...], encoding: .utf8) == nil,
                "if this tail decodes strictly, the test is not exercising the defect")

        var reader = ContextLoadReader()
        reader.tailWindowBytes = bytes.count - cut

        let load = reader.read(
            capturePath: "/nonexistent", transcriptPath: scratch.transcriptPath,
            tee: .notADesk)

        #expect(load.used?.value == 777,
                "a tail cut mid-codepoint erased a numerator that was plainly there")
    }

    // MARK: - The stamp belongs to the payload

    /// `contents(atPath:)` then `attributesOfItem(atPath:)` are two lookups of
    /// the same *name*, and the two can answer about different files — the tee
    /// publishes by `mv -f`, and `attributesOfItem` does not even follow a
    /// symlink, so the pair can hand back one file's bytes with another's
    /// modification time. That produces an `ObservedFact` whose observed-at is
    /// newer than the value it labels, which is the one thing this file's
    /// opening comment forbids. One open, one inode, both halves.
    @Test func theCaptureStampComesFromTheFileTheBytesCameFrom() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let target = scratch.root.appendingPathComponent("real-capture.json").path
        let published = Date(timeIntervalSince1970: 1_700_000_000)
        try Data(#"{"context_window":{"context_window_size":123456}}"#.utf8)
            .write(to: URL(fileURLWithPath: target))
        try FileManager.default.setAttributes(
            [.modificationDate: published], ofItemAtPath: target)

        // The name the reader is given resolves to that file, but is itself a
        // different filesystem object with its own, much newer stamp.
        let link = scratch.root.appendingPathComponent("capture-link.json").path
        try FileManager.default.createSymbolicLink(
            atPath: link, withDestinationPath: target)

        let capture = try #require(ContextLoadReader().readCapture(atPath: link))
        #expect(capture.contextWindowSize == 123456)
        #expect(capture.observedAt == published,
                "the payload was stamped with a different file's modification time")
    }

    @Test func unreadableTranscriptIsAbsenceNotZero() {
        let load = ContextLoadReader().read(
            capturePath: "/nonexistent", transcriptPath: "/nonexistent/transcript.jsonl",
            tee: .notADesk)
        #expect(load.used == nil)
    }
}
