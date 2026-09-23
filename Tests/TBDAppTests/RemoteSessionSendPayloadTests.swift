import Foundation
import Testing
@testable import TBDApp

/// Tier 1: pure input-to-payload construction, with no process, filesystem,
/// network, or clock dependency.
@Suite("Remote session send payload")
struct RemoteSessionSendPayloadTests {
    @Test func preservesUserTextAndAppendsExactlyOneCarriageReturn() {
        let userText = "first line\nsecond line 🐒"
        let payload = RemoteSessionSendPayload.submitting(userText)

        #expect(payload.dropLast() == Substring(userText))
        #expect(payload.last == "\r")
        #expect(Data(payload.utf8) == Data(userText.utf8) + Data([0x0D]))
    }

    @Test func enterIsCarriageReturnNotLineFeed() {
        let payload = RemoteSessionSendPayload.submitting("continue")

        #expect(Array(payload.utf8).suffix(1) == [0x0D])
        #expect(Array(payload.utf8).suffix(1) != [0x0A])
    }
}
