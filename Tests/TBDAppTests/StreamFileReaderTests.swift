import Foundation
import Testing
@testable import TBDApp
@testable import TBDShared

/// The fold from tagged stream-file lines to the one message the app renders:
/// which message wins, how its text is assembled, and how it ends.
@Suite("StreamFileReader")
struct StreamFileReaderTests {

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let started = Date(timeIntervalSince1970: 1_699_999_999)

    // MARK: - Text assembly

    @Test("Deltas of one block concatenate in arrival order")
    func deltasConcatenateInArrivalOrder() {
        let folded = StreamFileReader.fold(
            lines: [
                .start(message: "msg_a", at: Self.started),
                .block(message: "msg_a", index: 0),
                .text(message: "msg_a", index: 0, text: "Hel"),
                .text(message: "msg_a", index: 0, text: "lo, "),
                .text(message: "msg_a", index: 0, text: "world"),
            ],
            now: Self.now
        )

        #expect(folded == ProvisionalMessage(messageID: "msg_a", text: "Hello, world", phase: .streaming))
    }

    /// The blocks arrive interleaved and out of order on purpose: the reader
    /// must order by block index, not by the order the deltas landed.
    @Test("Text blocks concatenate by ascending index, not arrival order")
    func blocksConcatenateByIndexOrder() {
        let folded = StreamFileReader.fold(
            lines: [
                .start(message: "msg_a", at: Self.started),
                .block(message: "msg_a", index: 2),
                .text(message: "msg_a", index: 2, text: "third"),
                .block(message: "msg_a", index: 0),
                .text(message: "msg_a", index: 0, text: "first"),
                .text(message: "msg_a", index: 2, text: "-tail"),
                .text(message: "msg_a", index: 1, text: "second"),
            ],
            now: Self.now
        )

        #expect(folded?.text == "firstsecondthird-tail")
    }

    // MARK: - Which message wins

    @Test("A later start supersedes the earlier message")
    func laterStartSupersedes() {
        let folded = StreamFileReader.fold(
            lines: [
                .start(message: "msg_old", at: Self.started),
                .text(message: "msg_old", index: 0, text: "stale"),
                .stop(message: "msg_old"),
                .start(message: "msg_new", at: Self.started),
                .text(message: "msg_new", index: 0, text: "fresh"),
            ],
            now: Self.now
        )

        #expect(folded == ProvisionalMessage(messageID: "msg_new", text: "fresh", phase: .streaming))
    }

    /// Two parents in flight against one route interleave their lines. The
    /// most recently started message that has text is the one to render.
    @Test("Interleaved two-message lines pick the most recent that has text")
    func interleavedLinesPickMostRecentWithText() {
        let folded = StreamFileReader.fold(
            lines: [
                .start(message: "msg_a", at: Self.started),
                .text(message: "msg_a", index: 0, text: "aaa"),
                .start(message: "msg_b", at: Self.started),
                .text(message: "msg_a", index: 0, text: "AAA"),
                .text(message: "msg_b", index: 0, text: "bbb"),
                .text(message: "msg_a", index: 0, text: "!"),
            ],
            now: Self.now
        )

        #expect(folded == ProvisionalMessage(messageID: "msg_b", text: "bbb", phase: .streaming))
    }

    @Test("A started message with no text yet wins only when nothing else has text")
    func startedWithoutTextWinsOnlyWhenAloneInHavingNone() {
        let onlyStarted = StreamFileReader.fold(
            lines: [.start(message: "msg_a", at: Self.started), .block(message: "msg_a", index: 0)],
            now: Self.now
        )
        #expect(onlyStarted == ProvisionalMessage(messageID: "msg_a", text: "", phase: .streaming))

        let alongsideText = StreamFileReader.fold(
            lines: [
                .start(message: "msg_a", at: Self.started),
                .text(message: "msg_a", index: 0, text: "has text"),
                .start(message: "msg_b", at: Self.started),
                .block(message: "msg_b", index: 0),
            ],
            now: Self.now
        )
        #expect(alongsideText == ProvisionalMessage(messageID: "msg_a", text: "has text", phase: .streaming))
    }

    /// Truncation happens only when nothing is in flight, but a reader that
    /// resumed mid-file still sees a head whose `start` is gone. Such a message
    /// counts, keyed by the id its own lines carry.
    @Test("A message whose start was truncated away still counts")
    func tornHeadWithoutStartStillCounts() {
        let folded = StreamFileReader.fold(
            lines: [
                .text(message: "msg_torn", index: 0, text: "orphan text"),
                .stop(message: "msg_torn"),
            ],
            now: Self.now
        )

        #expect(folded == ProvisionalMessage(
            messageID: "msg_torn",
            text: "orphan text",
            phase: .complete(at: Self.now)
        ))
    }

    // MARK: - Phase

    @Test("stop completes the message at the fold's now")
    func stopCompletesAtNow() {
        let folded = StreamFileReader.fold(
            lines: [
                .start(message: "msg_a", at: Self.started),
                .text(message: "msg_a", index: 0, text: "done"),
                .stop(message: "msg_a"),
            ],
            now: Self.now
        )

        #expect(folded?.phase == .complete(at: Self.now))
    }

    @Test("aborted carries its reason")
    func abortedCarriesReason() {
        let folded = StreamFileReader.fold(
            lines: [
                .start(message: "msg_a", at: Self.started),
                .text(message: "msg_a", index: 0, text: "partial"),
                .aborted(message: "msg_a", reason: "upstream connection dropped"),
            ],
            now: Self.now
        )

        #expect(folded == ProvisionalMessage(
            messageID: "msg_a",
            text: "partial",
            phase: .aborted(reason: "upstream connection dropped")
        ))
    }

    @Test("The last terminal line for a message wins")
    func lastTerminalLineWins() {
        let folded = StreamFileReader.fold(
            lines: [
                .start(message: "msg_a", at: Self.started),
                .text(message: "msg_a", index: 0, text: "partial"),
                .aborted(message: "msg_a", reason: "tee gave up"),
                .stop(message: "msg_a"),
            ],
            now: Self.now
        )

        #expect(folded?.phase == .complete(at: Self.now))
    }

    /// A fold is stable in `now`: the caller records the instant it first saw
    /// the stop and passes the same value back, so the 60-second unconfirmed
    /// rule measures from first sight rather than from the latest poll.
    @Test("The same lines and the same now fold to the same completion instant")
    func foldIsStableInNow() {
        let lines: [ModelProxyStreamLine] = [
            .start(message: "msg_a", at: Self.started),
            .text(message: "msg_a", index: 0, text: "done"),
            .stop(message: "msg_a"),
        ]

        #expect(StreamFileReader.fold(lines: lines, now: Self.now)
            == StreamFileReader.fold(lines: lines, now: Self.now))
        #expect(StreamFileReader.fold(lines: lines, now: Self.now.addingTimeInterval(60))?.phase
            == .complete(at: Self.now.addingTimeInterval(60)))
    }

    /// The successor exists but has said nothing yet, and the message before
    /// it finished. Selection is "most recent *with text*", so the finished
    /// message keeps the row — and it must keep its `.complete` phase too, or a
    /// pane would show a settled answer as though it were still streaming and
    /// C4's retire rules would never start their clock.
    @Test("A completed message survives an empty successor, phase intact")
    func completedMessageOutlivesAnEmptySuccessor() {
        let folded = StreamFileReader.fold(
            lines: [
                .start(message: "msg_a", at: Self.started),
                .text(message: "msg_a", index: 0, text: "the answer"),
                .stop(message: "msg_a"),
                .start(message: "msg_b", at: Self.started.addingTimeInterval(1)),
            ],
            now: Self.now
        )

        #expect(folded == ProvisionalMessage(
            messageID: "msg_a",
            text: "the answer",
            phase: .complete(at: Self.now)
        ))
    }

    // MARK: - Degenerate input

    @Test("No lines folds to nil")
    func emptyFoldsToNil() {
        #expect(StreamFileReader.fold(lines: [], now: Self.now) == nil)
    }

    @Test("Lines that carry no message and no start fold to nil")
    func blocksWithoutTextOrStartFoldToNil() {
        #expect(StreamFileReader.fold(lines: [.block(message: "msg_a", index: 0)], now: Self.now) == nil)
    }

    /// Exercises the whole path a tailer takes: raw text lines through
    /// `decode`, one of them garbage, the survivors folded.
    @Test("A malformed line is skipped and the rest still fold")
    func malformedLinesAreSkipped() throws {
        let raw = try [
            ModelProxyStreamLine.start(message: "msg_a", at: Self.started).encodedLine(),
            ModelProxyStreamLine.text(message: "msg_a", index: 0, text: "before").encodedLine(),
            #"{"type":"text","message":"msg_a","index":0,"tex"#,  // a line caught mid-append
            ModelProxyStreamLine.text(message: "msg_a", index: 0, text: "-after").encodedLine(),
            ModelProxyStreamLine.stop(message: "msg_a").encodedLine(),
        ]

        let decoded = raw.compactMap(ModelProxyStreamLine.decode(line:))
        #expect(decoded.count == raw.count - 1)

        #expect(StreamFileReader.fold(lines: decoded, now: Self.now) == ProvisionalMessage(
            messageID: "msg_a",
            text: "before-after",
            phase: .complete(at: Self.now)
        ))
    }
}
