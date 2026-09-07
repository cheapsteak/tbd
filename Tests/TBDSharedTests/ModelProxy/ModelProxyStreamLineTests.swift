import Testing
import Foundation
@testable import TBDShared

@Suite struct ModelProxyStreamLineTests {
    @Test func everyCaseRoundTrips() throws {
        let cases: [ModelProxyStreamLine] = [
            .start(message: "msg_1", at: Date(timeIntervalSince1970: 1_700_000_000)),
            .block(message: "msg_1", index: 0),
            .text(message: "msg_1", index: 0, text: "The sea\nis"),
            .stop(message: "msg_1"),
            .aborted(message: "msg_1", reason: "overloaded_error"),
        ]
        for c in cases {
            let line = try c.encodedLine()
            #expect(!line.contains("\n"))
            #expect(ModelProxyStreamLine.decode(line: line) == c)
        }
    }

    @Test func malformedLineDecodesToNil() {
        #expect(ModelProxyStreamLine.decode(line: "{\"type\":\"bogus\"}") == nil)
        #expect(ModelProxyStreamLine.decode(line: "not json") == nil)
    }
}
