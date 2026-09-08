import Clocks
import Foundation
import Testing
@testable import TBDApp
@testable import TBDShared
import TestSupport

/// A deterministic generator, so a failing chunk split is reproducible from
/// the seed rather than being a coin flip in CI.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// `TranscriptSource`'s second file: the model-proxy stream file it tails
/// beside the transcript JSONL, and the provisional message it folds out of it.
///
/// Real files on disk throughout — the point of this layer is the tailing, the
/// offsets and the shrink rule, none of which a hand-built fixture exercises.
/// Every file lives under the run's fenced scratch root, never `~/tbd`.
@Suite("TranscriptSourceStream")
struct TranscriptSourceStreamTests {

    // MARK: - Fixtures

    /// A directory of this test's own, under the root `scripts/test.sh`
    /// reclaims even when the run is killed.
    private static func scratchDir() throws -> String {
        let dir = fencedScratchRoot(prefix: "tbdstream")
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func write(_ text: String, to path: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Appends without replacing the file, so the reader sees growth at one
    /// inode rather than a substitution.
    private static func append(_ text: String, to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private static func lines(_ lines: [ModelProxyStreamLine]) throws -> String {
        try lines.map { try $0.encodedLine() + "\n" }.joined()
    }

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let started = Date(timeIntervalSince1970: 1_699_999_999)

    // MARK: - Growth

    @Test("a growing stream file yields growing text across two refreshes")
    func growingFileYieldsGrowingText() async throws {
        let path = try Self.scratchDir() + "/stream.jsonl"
        try Self.write(try Self.lines([
            .start(message: "msg_a", at: Self.started),
            .text(message: "msg_a", index: 0, text: "Hello"),
        ]), to: path)

        let source = TranscriptSource()
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.t0))
        #expect(await source.provisional(sessionID: "s1")?.text == "Hello")

        try Self.append(try Self.lines([
            .text(message: "msg_a", index: 0, text: ", world"),
        ]), to: path)

        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.t0))
        #expect(await source.provisional(sessionID: "s1")?.text == "Hello, world")
    }

    /// A tick over a file nothing has written to is not news. Without this the
    /// pane would be told to re-render on every 100 ms foreground poll.
    @Test("a stream file that did not change reports no news")
    func unchangedFileIsNotNews() async throws {
        let path = try Self.scratchDir() + "/stream.jsonl"
        try Self.write(try Self.lines([
            .start(message: "msg_a", at: Self.started),
            .text(message: "msg_a", index: 0, text: "Hello"),
        ]), to: path)

        let source = TranscriptSource()
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.t0))
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.t0) == false)
        #expect(await source.provisional(sessionID: "s1")?.text == "Hello")
    }

    // MARK: - The shrink rule

    /// The proxy truncates the file in place when nothing is in flight, so the
    /// next turn starts at byte zero of the same path. Resuming from the old
    /// offset would splice the retired turn's lines onto the new one.
    @Test("a truncated stream file restarts and yields the new message")
    func truncatedFileRestarts() async throws {
        let path = try Self.scratchDir() + "/stream.jsonl"
        try Self.write(try Self.lines([
            .start(message: "msg_old", at: Self.started),
            .text(message: "msg_old", index: 0, text: "a long since finished answer"),
            .stop(message: "msg_old"),
        ]), to: path)

        let source = TranscriptSource()
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.t0))
        #expect(await source.provisional(sessionID: "s1")?.messageID == "msg_old")

        // Strictly shorter than what was consumed.
        try Self.write(try Self.lines([
            .start(message: "msg_new", at: Self.started),
            .text(message: "msg_new", index: 0, text: "new"),
        ]), to: path)

        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.t0))
        let provisional = await source.provisional(sessionID: "s1")
        #expect(provisional?.messageID == "msg_new")
        #expect(provisional?.text == "new", "the retired turn's deltas must not survive")
        #expect(provisional?.phase == .streaming)
    }

    /// The second leg of the shrink rule, and it is not reachable through the
    /// first. `offset` stops at the last newline, so a file whose tail is a
    /// half-written line has `offset < lastSize` — and a replacement landing
    /// between the two is shorter than the file we last saw while still being
    /// longer than the bytes we consumed. Without the `size < lastSize` test
    /// the reader resumes mid-line into content that no longer exists: the
    /// partial line fails to decode, is skipped, and the pane keeps rendering
    /// the previous message forever.
    @Test("a file shorter than the last size but longer than the offset still restarts")
    func fileShorterThanLastSizeRestarts() async throws {
        let path = try Self.scratchDir() + "/stream.jsonl"
        let head = try Self.lines([.text(message: "msg_old", index: 0, text: "old")])
        // A long half-written line: no trailing newline, so it is withheld and
        // the offset stays at the end of `head` while the size runs far past it.
        try Self.write(head + #"{"index":0,"message":"msg_old","text":""# + String(repeating: "x", count: 5_000),
                       to: path)

        let source = TranscriptSource()
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.t0))
        #expect(await source.provisional(sessionID: "s1")?.text == "old")

        let replacement = try Self.lines([
            .text(message: "msg_new", index: 0, text: String(repeating: "n", count: 200)),
        ])
        #expect(replacement.utf8.count > head.utf8.count,
                "the replacement must be longer than the consumed prefix, or this proves nothing")
        try Self.write(replacement, to: path)

        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.t0))
        #expect(await source.provisional(sessionID: "s1")?.messageID == "msg_new")
    }

    // MARK: - Failure handling

    /// An unreadable file is no news, never a blank row: it is written by
    /// another process that can be replacing it, and a pane must not lose the
    /// answer on screen because one `stat` lost a race.
    @Test("an unreadable stream file keeps the prior provisional and reports no news")
    func unreadableFileKeepsPriorProvisional() async throws {
        let dir = try Self.scratchDir()
        let path = dir + "/stream.jsonl"
        try Self.write(try Self.lines([
            .start(message: "msg_a", at: Self.started),
            .text(message: "msg_a", index: 0, text: "still here"),
        ]), to: path)

        let source = TranscriptSource()
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.t0))

        try FileManager.default.removeItem(atPath: path)
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.t0) == false)
        #expect(await source.provisional(sessionID: "s1")?.text == "still here")

        // A path that never existed reads the same way, including the branch
        // where the entry's recorded path differs from the one asked for.
        #expect(await source.refreshStream(
            sessionID: "s1", path: dir + "/never-written.jsonl", now: Self.t0) == false)
        #expect(await source.provisional(sessionID: "s1")?.text == "still here")
    }

    // MARK: - Completion instant

    /// `StreamFileReader.fold` stamps `.complete(at:)` with whatever `now` it
    /// is handed and leaves the stability of that value to its caller. This is
    /// the caller. If the instant moved with every poll, the deadline that
    /// retires an unconfirmed message would never come due.
    @Test("the completion instant is recorded once and reused on later refreshes")
    func completionInstantIsStable() async throws {
        let path = try Self.scratchDir() + "/stream.jsonl"
        try Self.write(try Self.lines([
            .start(message: "msg_a", at: Self.started),
            .text(message: "msg_a", index: 0, text: "the answer"),
            .stop(message: "msg_a"),
        ]), to: path)

        let source = TranscriptSource()
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.t0))
        #expect(await source.provisional(sessionID: "s1")?.phase == .complete(at: Self.t0))

        let later = Self.t0.addingTimeInterval(120)
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: later) == false)
        #expect(await source.provisional(sessionID: "s1")?.phase == .complete(at: Self.t0))

        // A successor that has started but said nothing does not take the row,
        // and must not restamp the finished message either.
        try Self.append(try Self.lines([
            .start(message: "msg_b", at: Self.started.addingTimeInterval(1)),
        ]), to: path)
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: later) == false)
        #expect(await source.provisional(sessionID: "s1")?.phase == .complete(at: Self.t0))
    }

    /// The reset half of the same rule: the recorded instant belongs to one
    /// message id, so the next message completes at its own time.
    @Test("a new message completing gets its own instant")
    func completionInstantResetsWithTheMessage() async throws {
        let path = try Self.scratchDir() + "/stream.jsonl"
        try Self.write(try Self.lines([
            .start(message: "msg_a", at: Self.started),
            .text(message: "msg_a", index: 0, text: "first"),
            .stop(message: "msg_a"),
        ]), to: path)

        let source = TranscriptSource()
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.t0))

        let later = Self.t0.addingTimeInterval(120)
        try Self.append(try Self.lines([
            .start(message: "msg_b", at: Self.started.addingTimeInterval(1)),
            .text(message: "msg_b", index: 0, text: "second"),
            .stop(message: "msg_b"),
        ]), to: path)

        #expect(await source.refreshStream(sessionID: "s1", path: path, now: later))
        let provisional = await source.provisional(sessionID: "s1")
        #expect(provisional?.messageID == "msg_b")
        #expect(provisional?.phase == .complete(at: later))
    }

    // MARK: - Retention

    @Test("forgetting a session drops its stream entry too")
    func forgetDropsTheStreamEntry() async throws {
        let path = try Self.scratchDir() + "/stream.jsonl"
        try Self.write(try Self.lines([
            .start(message: "msg_a", at: Self.started),
            .text(message: "msg_a", index: 0, text: "hello"),
        ]), to: path)

        let source = TranscriptSource()
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.t0))
        #expect(await source.trackedStreamSessionCount == 1)

        await source.forget(sessionID: "s1")

        #expect(await source.provisional(sessionID: "s1") == nil)
        #expect(await source.trackedStreamSessionCount == 0,
                "a deregistered session must leave no stream tail resident")
    }

    // MARK: - The defensive cap

    /// The ceiling exists for the case the proxy's own truncation does not
    /// cover, and it drops whole messages that have already ended rather than
    /// the head of whatever is in flight.
    ///
    /// The assertion is arranged so the cap is the only thing that can produce
    /// it: the finished message is the one with text, so while its lines are
    /// retained it wins the fold outright. Only once they are gone can the
    /// started-but-silent successor hold the row.
    @Test("passing the line ceiling drops the oldest message that has already ended")
    func theOldestEndedMessageIsDroppedAtTheCeiling() async throws {
        let path = try Self.scratchDir() + "/stream.jsonl"
        var lines: [ModelProxyStreamLine] = [.start(message: "msg_a", at: Self.started)]
        for _ in 0..<9_999 {
            lines.append(.text(message: "msg_a", index: 0, text: "x"))
        }
        lines.append(.stop(message: "msg_a"))
        lines.append(.start(message: "msg_b", at: Self.started.addingTimeInterval(1)))
        #expect(lines.count > 10_000, "the fixture must actually cross the ceiling")
        try Self.write(try Self.lines(lines), to: path)

        let source = TranscriptSource()
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.t0))

        let provisional = await source.provisional(sessionID: "s1")
        #expect(provisional?.messageID == "msg_b")
        #expect(provisional?.text.isEmpty == true)
    }

    /// The cap must never take the *newest* message, which is what makes it
    /// inert while a single turn is the only thing resident.
    ///
    /// A long answer crosses the ceiling and then ends on the same tick its
    /// `stop` lands. Dropping it there leaves nothing to fold, the fold's
    /// "found nothing keeps the prior provisional" rule takes over, and the row
    /// is stranded at `.streaming` holding a partial answer that nothing can
    /// ever complete. This test fails on exactly that path: without the
    /// exclusion the fold returns nil, `refreshStream` reports no news, and no
    /// provisional exists at all.
    @Test("a single message past the ceiling still completes with its full text")
    func aLoneMessagePastTheCeilingSurvivesItsOwnStop() async throws {
        let path = try Self.scratchDir() + "/stream.jsonl"
        var lines: [ModelProxyStreamLine] = [.start(message: "msg_a", at: Self.started)]
        for _ in 0..<10_001 {
            lines.append(.text(message: "msg_a", index: 0, text: "x"))
        }
        lines.append(.stop(message: "msg_a"))
        #expect(lines.count > 10_000, "the fixture must actually cross the ceiling")
        try Self.write(try Self.lines(lines), to: path)

        let source = TranscriptSource()
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.t0))

        let provisional = await source.provisional(sessionID: "s1")
        #expect(provisional?.messageID == "msg_a")
        #expect(provisional?.phase == .complete(at: Self.t0),
                "the stop arrived in the same tick that crossed the ceiling")
        #expect(provisional?.text.count == 10_001,
                "no part of the only message on screen may be dropped")
    }

    /// Two parent requests in flight: the *older* message owns the last line
    /// while a *newer* one holds the row.
    ///
    /// `msg_a` starts first and keeps appending; `msg_b` starts after it, says
    /// its piece and stops; then `msg_a` pushes the file past the ceiling. The
    /// fold renders `msg_b` — the most recent message with text, ranked by
    /// where its first line appears — so the cap must not evict it.
    ///
    /// What discriminates: under the old `kept.last?.message` rule the
    /// protected message is `msg_a`, the owner of the last line, which leaves
    /// the already-ended `msg_b` as the oldest evictable message. Every one of
    /// its lines is dropped and the fold falls back to `msg_a` — the row
    /// rewinds to the earlier turn. This test then reads `msg_a`, not `msg_b`.
    @Test("the cap keeps the newer of two interleaved messages, not the last line's owner")
    func aNewerInterleavedMessageSurvivesTheCeiling() async throws {
        let path = try Self.scratchDir() + "/stream.jsonl"
        var lines: [ModelProxyStreamLine] = [
            .start(message: "msg_a", at: Self.started),
            .text(message: "msg_a", index: 0, text: "the older answer"),
            .start(message: "msg_b", at: Self.started.addingTimeInterval(1)),
            .text(message: "msg_b", index: 0, text: "the newer answer"),
            .stop(message: "msg_b"),
        ]
        for _ in 0..<10_000 {
            lines.append(.text(message: "msg_a", index: 0, text: "x"))
        }
        #expect(lines.count > 10_000, "the fixture must actually cross the ceiling")
        try Self.write(try Self.lines(lines), to: path)

        let source = TranscriptSource()
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.t0))

        let provisional = await source.provisional(sessionID: "s1")
        #expect(provisional?.messageID == "msg_b",
                "the cap may not evict the message the fold renders")
        #expect(provisional?.text == "the newer answer",
                "every line of the newer message must survive the eviction")
        #expect(provisional?.phase == .complete(at: Self.t0))
    }

    /// The same interleaving with the names the other way round, and an
    /// `aborted` end rather than a `stop`: `msg_b` is the one that starts first
    /// and keeps appending, `msg_a` is the newer message that ends.
    ///
    /// What discriminates: as above, the old rule protects the last line's
    /// owner `msg_b` and evicts the newer `msg_a` wholesale, so this test reads
    /// `msg_b` and the older text. Ranking by first-line position protects
    /// `msg_a`, and with nothing else ended the cap drops nothing at all.
    @Test("the mirrored interleaving keeps the newer message too, aborted or not")
    func aNewerInterleavedAbortedMessageSurvivesTheCeiling() async throws {
        let path = try Self.scratchDir() + "/stream.jsonl"
        var lines: [ModelProxyStreamLine] = [
            .start(message: "msg_b", at: Self.started),
            .text(message: "msg_b", index: 0, text: "the older answer"),
            .start(message: "msg_a", at: Self.started.addingTimeInterval(1)),
            .text(message: "msg_a", index: 0, text: "the newer answer"),
            .aborted(message: "msg_a", reason: "the proxy died mid-turn"),
        ]
        for _ in 0..<10_000 {
            lines.append(.text(message: "msg_b", index: 0, text: "x"))
        }
        #expect(lines.count > 10_000, "the fixture must actually cross the ceiling")
        try Self.write(try Self.lines(lines), to: path)

        let source = TranscriptSource()
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.t0))

        let provisional = await source.provisional(sessionID: "s1")
        #expect(provisional?.messageID == "msg_a",
                "the cap may not evict the message the fold renders")
        #expect(provisional?.text == "the newer answer")
        #expect(provisional?.phase == .aborted(reason: "the proxy died mid-turn"),
                "an aborted message counts as ended, and is still the newest")
    }

    // MARK: - Chunk-split equivalence

    /// Three messages: two that finished and one that has only started, with
    /// deltas carrying multi-byte characters and a marker the split chooser
    /// aims at. The fold's answer is `msg_b` — the most recent message that has
    /// *text*, since `msg_c` has produced none — completed at the reader's
    /// `now`.
    private static let chunkSplitFixture: [ModelProxyStreamLine] = [
        .start(message: "msg_a", at: started),
        .block(message: "msg_a", index: 0),
        .text(message: "msg_a", index: 0, text: "Hello, "),
        .text(message: "msg_a", index: 0, text: "wörld 🌍 — and a newline\nin the delta"),
        .stop(message: "msg_a"),
        .start(message: "msg_b", at: started.addingTimeInterval(1)),
        .text(message: "msg_b", index: 0, text: "the second answer, SPLITME here, ✓"),
        .text(message: "msg_b", index: 1, text: " and a second block"),
        .stop(message: "msg_b"),
        .start(message: "msg_c", at: started.addingTimeInterval(2)),
    ]

    /// The property the whole tailing layer exists to hold: **how** the bytes
    /// arrive cannot change what a pane renders. The proxy's tee writes into
    /// this file from another process, so a poll can land at any byte offset —
    /// between two lines, inside a line's JSON, or inside a single multi-byte
    /// character — and the same file delivered in any chunking must fold to the
    /// same provisional message as the file read whole.
    ///
    /// Two of the splits are chosen rather than drawn, because they are the two
    /// a naive tailer gets wrong: one lands inside a `text` line's JSON string
    /// value, one inside the four bytes of an emoji. The rest are drawn from a
    /// seeded generator, so a failure names the exact byte offsets that produced
    /// it and can be replayed.
    @Test(
        "a file delivered in arbitrary chunks folds to what the whole file folds to",
        arguments: [UInt64(0x5EED), 0x7A11, 0xC0FF_EE00, 0xD15E_A5E0])
    func arbitraryChunkSplitsFoldToTheWholeFile(seed: UInt64) async throws {
        let path = try Self.scratchDir() + "/stream.jsonl"
        let lines = Self.chunkSplitFixture
        let data = Data(try Self.lines(lines).utf8)

        // Inside a `text` line's JSON string value, and inside the four bytes
        // of "🌍". `#require`, not `if let`: a fixture that stopped containing
        // either would leave this test drawing only ordinary offsets and still
        // passing.
        let insideJSONString = try #require(data.range(of: Data("SPLITME".utf8))).lowerBound + 3
        let insideMultiByte = try #require(data.range(of: Data("🌍".utf8))).lowerBound + 2

        var generator = SplitMix64(state: seed)
        var offsets: Set<Int> = [insideJSONString, insideMultiByte]
        for _ in 0..<12 {
            offsets.insert(Int(generator.next() % UInt64(data.count - 1)) + 1)
        }
        let splits = offsets.filter { $0 > 0 && $0 < data.count }.sorted()
        let replay = "seed=0x\(String(seed, radix: 16)) splits=\(splits) of \(data.count) bytes"

        try Self.write("", to: path)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let source = TranscriptSource()
        var start = 0
        for end in splits + [data.count] {
            try handle.seekToEnd()
            try handle.write(contentsOf: data.subdata(in: start..<end))
            start = end
            _ = await source.refreshStream(sessionID: "s1", path: path, now: Self.t0)
        }

        let whole = StreamFileReader.fold(lines: lines, now: Self.t0)
        #expect(whole?.messageID == "msg_b",
                "the fixture must fold to a completed message, or this proves nothing")
        #expect(whole?.phase == .complete(at: Self.t0))
        #expect(await source.provisional(sessionID: "s1") == whole,
                "chunked delivery must land on the whole-file fold — \(replay)")
    }

    // MARK: - Transcript confirmation

    private static let assistantLine = #"{"type":"assistant","uuid":"a1","timestamp":"2026-08-26T10:00:00.000Z","message":{"role":"assistant","id":"msg_a","content":[{"type":"text","text":"hi"}]}}"#

    /// The confirmation signal C4's retire rule reads. Delegation, but to the
    /// *session's own* transcript: a message another session carries must not
    /// retire this one's row.
    @Test("assistant message confirmation is scoped to the session's own transcript")
    func assistantMessageConfirmationIsPerSession() async throws {
        let path = try Self.scratchDir() + "/transcript.jsonl"
        try Self.write(Self.assistantLine + "\n", to: path)

        let source = TranscriptSource()
        #expect(await source.hasAssistantMessage(sessionID: "s1", id: "msg_a") == false,
                "nothing has been read, so nothing confirms anything")

        await source.refresh(sessionID: "s1", path: path)

        #expect(await source.hasAssistantMessage(sessionID: "s1", id: "msg_a"))
        #expect(await source.hasAssistantMessage(sessionID: "s1", id: "msg_absent") == false)
        #expect(await source.hasAssistantMessage(sessionID: "s2", id: "msg_a") == false)
    }
}

/// The scheduler's half: a registered stream path is refreshed on the same tick
/// as the transcript, at the same tier cadence, and a change to it alone is
/// news.
///
/// `.clockDriven` is the hang guard for the virtual-time failure mode (a sleep
/// nobody advances waits forever); `.serialized` because `TestClock.advance`
/// megayields and clock-driven tests starve each other in parallel.
@Suite("TranscriptStreamPollScheduling", .clockDriven, .serialized)
struct TranscriptStreamPollSchedulingTests {

    /// Records which sessions the scheduler announced as changed.
    private actor NewsLog {
        private(set) var sessions: [String] = []
        func record(_ sessionID: String) { sessions.append(sessionID) }
        var count: Int { sessions.count }
    }

    private static let userLine = #"{"type":"user","uuid":"a","timestamp":"2026-08-26T10:00:00.000Z","message":{"role":"user","content":"hello"}}"#

    @Test("a registered stream file is polled at the tier cadence, and its change alone is news")
    func streamChangeAloneIsNews() async throws {
        let dir = fencedScratchRoot(prefix: "tbdstrsch")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let transcriptPath = dir + "/transcript.jsonl"
        let streamPath = dir + "/stream.jsonl"
        try (Self.userLine + "\n").write(toFile: transcriptPath, atomically: true, encoding: .utf8)
        // Present but empty: the terminal was routed through the proxy and no
        // turn has run yet.
        try "".write(toFile: streamPath, atomically: true, encoding: .utf8)

        let source = TranscriptSource()
        let clock = TestClock()
        let scheduler = TranscriptPollScheduler(source: source, clock: clock)
        let news = NewsLog()
        await scheduler.setOnChange { sessionID in await news.record(sessionID) }

        // Consume the transcript up front, so nothing there can move and the
        // stream file is the only thing left that can produce news.
        await source.refresh(sessionID: "s1", path: transcriptPath)

        await scheduler.register(
            sessionID: "s1", path: transcriptPath, streamPath: streamPath,
            tier: .background, token: TranscriptPaneToken())

        // Exactly one line, written whole: a window is truncated at its last
        // newline, so a partial append is withheld rather than folded, and the
        // count below stays a real assertion.
        let line = try ModelProxyStreamLine
            .text(message: "msg_a", index: 0, text: "hi from the proxy").encodedLine()
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: streamPath))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()

        let sawNews = await clock.advanceUntil(
            "the scheduler to report the stream file's change",
            by: TranscriptPollPolicy.background
        ) { await news.count > 0 }
        #expect(sawNews)

        #expect(await news.sessions == ["s1"],
                "only the stream file moved, and it moved once")
        #expect(await source.provisional(sessionID: "s1")?.text == "hi from the proxy",
                "the tick must have driven refreshStream, not only refresh")
    }

    /// The off branch: a registration with no stream path touches no second
    /// file and builds no provisional, however long it polls.
    @Test("a registration with no stream path never builds a provisional")
    func noStreamPathBuildsNoProvisional() async throws {
        let dir = fencedScratchRoot(prefix: "tbdstrsch")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let transcriptPath = dir + "/transcript.jsonl"
        try (Self.userLine + "\n").write(toFile: transcriptPath, atomically: true, encoding: .utf8)

        let source = TranscriptSource()
        let clock = TestClock()
        let scheduler = TranscriptPollScheduler(source: source, clock: clock)
        let news = NewsLog()
        await scheduler.setOnChange { sessionID in await news.record(sessionID) }

        await scheduler.register(
            sessionID: "s1", path: transcriptPath, tier: .background,
            token: TranscriptPaneToken())

        let sawNews = await clock.advanceUntil(
            "the scheduler to report the transcript's first read",
            by: TranscriptPollPolicy.background
        ) { await news.count > 0 }
        #expect(sawNews, "the transcript itself must still be polled")
        #expect(await source.provisional(sessionID: "s1") == nil)
        #expect(await source.trackedStreamSessionCount == 0)
    }

    /// A changed stream path is a different file, so whatever a tick in flight
    /// read describes something this registration no longer names — the same
    /// reason a changed transcript path mints one.
    @Test("changing the stream path mints a new generation")
    func changedStreamPathMintsAGeneration() async {
        let scheduler = TranscriptPollScheduler(source: TranscriptSource())
        let pane = TranscriptPaneToken()

        await scheduler.register(
            sessionID: "s1", path: "/a", streamPath: "/stream-a",
            tier: .background, token: pane)
        let first = await scheduler.registeredGeneration(sessionID: "s1")

        await scheduler.register(
            sessionID: "s1", path: "/a", streamPath: "/stream-a",
            tier: .foreground, token: pane)
        #expect(await scheduler.registeredGeneration(sessionID: "s1") == first,
                "re-declaring a tier is the same entry")

        await scheduler.register(
            sessionID: "s1", path: "/a", streamPath: "/stream-b",
            tier: .foreground, token: pane)
        #expect(await scheduler.registeredGeneration(sessionID: "s1") != first)

        await scheduler.deregister(sessionID: "s1", token: pane)
    }
}
