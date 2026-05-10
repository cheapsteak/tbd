import Foundation
import Testing
@testable import TBDShared

@Suite struct ChannelMessageTests {

    @Test func roundtrips() throws {
        let msg = ChannelMessage(
            seq: 42,
            ts: Date(timeIntervalSince1970: 1_715_354_581),
            fromSession: "abc-123",
            fromLabel: "tbd-known-smelt",
            body: "anyone seen the launchctl crash?"
        )
        let line = try msg.encodeLine()
        let decoded = try ChannelMessage.decodeLine(line)
        #expect(decoded == msg)
    }

    @Test func encodedLineEndsWithNewline() throws {
        let msg = ChannelMessage(seq: 1, ts: Date(), fromSession: "s", fromLabel: "l", body: "x")
        let line = try msg.encodeLine()
        #expect(line.last == 0x0A)  // '\n'
    }

    @Test func encodedLineHasNoInternalNewline() throws {
        let msg = ChannelMessage(seq: 1, ts: Date(), fromSession: "s", fromLabel: "l",
                                 body: "line one\nline two\nline three")
        let line = try msg.encodeLine()
        // Exactly one newline — at the end.
        let count = line.filter { $0 == 0x0A }.count
        #expect(count == 1)
        let decoded = try ChannelMessage.decodeLine(line)
        #expect(decoded.body == "line one\nline two\nline three")
    }

    @Test func decodeRejectsMalformedLine() {
        let bogus = Data("{not json\n".utf8)
        #expect(throws: (any Error).self) {
            try ChannelMessage.decodeLine(bogus)
        }
    }
}
