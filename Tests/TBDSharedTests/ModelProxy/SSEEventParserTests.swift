import Testing
import Foundation
@testable import TBDShared

@Suite struct SSEEventParserTests {
    // MARK: - Chunk boundaries

    @Test func oneEventSplitAcrossThreeFeedsIncludingInsideAMultiByteSequence() {
        // The globe is four UTF-8 bytes; both feed boundaries land inside it,
        // so a decoder that ran per-chunk would see two truncated sequences.
        let head = Array("event: message_start\ndata: {\"greeting\":\"h\u{00E9}llo ".utf8)
        let globe = Array("🌍".utf8)
        let tail = Array("\"}\n\n".utf8)
        #expect(globe.count == 4)
        let bytes = head + globe + tail

        var parser = SSEEventParser()
        let firstCut = head.count + 2
        let secondCut = head.count + 3

        #expect(parser.feed(bytes[0..<firstCut]).isEmpty)
        #expect(parser.pendingByteCount == firstCut)
        #expect(parser.feed(bytes[firstCut..<secondCut]).isEmpty)
        #expect(parser.pendingByteCount == secondCut)

        let events = parser.feed(bytes[secondCut...])
        #expect(events.count == 1)
        #expect(events.first?.name == "message_start")
        #expect(events.first?.data == "{\"greeting\":\"héllo 🌍\"}")
        #expect(events.first?.isComment == false)
        #expect(parser.pendingByteCount == 0)
    }

    @Test func feedingOneByteAtATimeYieldsTheSameEvents() {
        let text = "event: a\ndata: 1\n\n: ping\n\nevent: b\ndata: 2\ndata: 3\n\n"
        var parser = SSEEventParser()
        var events: [SSEEvent] = []
        for byte in Array(text.utf8) {
            events += parser.feed([byte])
        }
        #expect(events == [
            SSEEvent(name: "a", data: "1", isComment: false),
            SSEEvent(name: nil, data: "", isComment: true),
            SSEEvent(name: "b", data: "2\n3", isComment: false),
        ])
        #expect(parser.pendingByteCount == 0)
    }

    @Test func pendingBytesAreRetainedUntilTheBlankLineArrives() {
        var parser = SSEEventParser()
        #expect(parser.pendingByteCount == 0)
        #expect(parser.feed(Array("data: partial\n".utf8)).isEmpty)
        #expect(parser.pendingByteCount == 14)
        #expect(parser.feed([UInt8]()).isEmpty)
        #expect(parser.pendingByteCount == 14)
        let events = parser.feed(Array("\n".utf8))
        #expect(events == [SSEEvent(name: nil, data: "partial", isComment: false)])
        #expect(parser.pendingByteCount == 0)
    }

    // MARK: - Field handling

    @Test func multipleDataLinesJoinWithNewlines() {
        var parser = SSEEventParser()
        let events = parser.feed(Array("data: a\ndata: b\n\n".utf8))
        #expect(events == [SSEEvent(name: nil, data: "a\nb", isComment: false)])
    }

    @Test func eventFieldSetsTheName() {
        var parser = SSEEventParser()
        let events = parser.feed(Array("event: message_start\ndata: {\"type\":\"message_start\"}\n\n".utf8))
        #expect(events.count == 1)
        #expect(events.first?.name == "message_start")
        #expect(events.first?.data == "{\"type\":\"message_start\"}")
        #expect(events.first?.isComment == false)
    }

    @Test func atMostOneSpaceIsStrippedAfterTheColon() {
        var parser = SSEEventParser()
        let events = parser.feed(Array("data:none\n\ndata: one\n\ndata:  two\n\ndata:\n\n".utf8))
        #expect(events.map(\.data) == ["none", "one", " two", ""])
        #expect(events.allSatisfy { !$0.isComment })
    }

    @Test func idAndRetryFieldsAreIgnored() {
        var parser = SSEEventParser()
        let events = parser.feed(Array("id: 42\nretry: 3000\nevent: ping\ndata: x\n\n".utf8))
        #expect(events == [SSEEvent(name: "ping", data: "x", isComment: false)])
    }

    @Test func unknownFieldsAndBareFieldNamesAreIgnored() {
        var parser = SSEEventParser()
        let events = parser.feed(Array("nonsense: value\nbare\ndata: kept\n\n".utf8))
        #expect(events == [SSEEvent(name: nil, data: "kept", isComment: false)])
    }

    // MARK: - Comments

    @Test func commentOnlyEventIsEmittedAsAComment() {
        var parser = SSEEventParser()
        let events = parser.feed(Array(": ping\n\n".utf8))
        #expect(events == [SSEEvent(name: nil, data: "", isComment: true)])
    }

    @Test func bareColonIsAComment() {
        var parser = SSEEventParser()
        let events = parser.feed(Array(":\n\n".utf8))
        #expect(events == [SSEEvent(name: nil, data: "", isComment: true)])
    }

    @Test func anEventCarryingBothACommentAndFieldsIsNotAComment() {
        var parser = SSEEventParser()
        let events = parser.feed(Array(": ping\ndata: x\n\n".utf8))
        #expect(events == [SSEEvent(name: nil, data: "x", isComment: false)])
    }

    // MARK: - Line terminators

    @Test func crlfLineEndingsAreAccepted() {
        var parser = SSEEventParser()
        let events = parser.feed(Array("event: ping\r\ndata: a\r\ndata: b\r\n\r\n".utf8))
        #expect(events == [SSEEvent(name: "ping", data: "a\nb", isComment: false)])
        #expect(parser.pendingByteCount == 0)
    }

    @Test func crlfSplitAcrossFeedsStillTerminatesTheEvent() {
        var parser = SSEEventParser()
        #expect(parser.feed(Array("data: a\r\n\r".utf8)).isEmpty)
        let events = parser.feed(Array("\n".utf8))
        #expect(events == [SSEEvent(name: nil, data: "a", isComment: false)])
    }

    @Test func mixedLineEndingsWithinOneEventAreAccepted() {
        var parser = SSEEventParser()
        let events = parser.feed(Array("event: ping\r\ndata: a\n\n".utf8))
        #expect(events == [SSEEvent(name: "ping", data: "a", isComment: false)])
    }

    // MARK: - Framing

    @Test func severalEventsInOneFeedComeBackInOrder() {
        var parser = SSEEventParser()
        let events = parser.feed(Array("event: one\ndata: 1\n\nevent: two\ndata: 2\n\n".utf8))
        #expect(events == [
            SSEEvent(name: "one", data: "1", isComment: false),
            SSEEvent(name: "two", data: "2", isComment: false),
        ])
    }

    @Test func extraBlankLinesDoNotProduceEmptyEvents() {
        var parser = SSEEventParser()
        let events = parser.feed(Array("\n\r\n\ndata: a\n\n\n\n".utf8))
        #expect(events == [SSEEvent(name: nil, data: "a", isComment: false)])
        #expect(parser.pendingByteCount == 0)
    }

    @Test func anUnterminatedTrailingEventIsNotEmitted() {
        var parser = SSEEventParser()
        let events = parser.feed(Array("data: a\n\ndata: b\n".utf8))
        #expect(events == [SSEEvent(name: nil, data: "a", isComment: false)])
        #expect(parser.pendingByteCount == 8)
    }

    @Test func anEmptyFeedYieldsNothing() {
        var parser = SSEEventParser()
        #expect(parser.feed([UInt8]()).isEmpty)
        #expect(parser.pendingByteCount == 0)
    }

    @Test func parsersAreIndependentValues() {
        var first = SSEEventParser()
        #expect(first.feed(Array("data: a\n".utf8)).isEmpty)
        var copy = first
        #expect(copy.feed(Array("\n".utf8)) == [SSEEvent(name: nil, data: "a", isComment: false)])
        #expect(copy.pendingByteCount == 0)
        // The copy consuming the event must not have drained the original.
        #expect(first.pendingByteCount == 8)
        #expect(first.feed(Array("data: b\n\n".utf8)) == [SSEEvent(name: nil, data: "a\nb", isComment: false)])
    }
}
