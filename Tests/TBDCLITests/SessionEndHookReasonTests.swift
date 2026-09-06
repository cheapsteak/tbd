import Foundation
import Testing
@testable import TBDCLI

/// `SessionEndCommand.hookReason(from:)` is the whole parse standing between
/// Claude Code's `SessionEnd` payload and the park stamp the daemon writes off
/// it. Static and pure so it is testable without a pipe.
///
/// Every way it can fail must answer nil — "we do not know" — never throw: a
/// hook bridge must not wedge or redden the agent it observes, and the daemon
/// reads a missing reason as "not a process exit" and leaves the row alone.
@Suite struct SessionEndHookReasonTests {
    private func payload(_ json: String) -> Data { Data(json.utf8) }

    @Test("a reason is lifted out of the payload, and unknown fields are ignored")
    func reasonPresent() {
        #expect(SessionEndCommand.hookReason(from: payload(#"{"reason":"clear"}"#)) == "clear")
        #expect(SessionEndCommand.hookReason(
            from: payload(#"{"session_id":"abc","reason":"other","cwd":"/tmp"}"#)) == "other")
    }

    @Test("a well-formed payload that names no reason knows nothing")
    func reasonAbsent() {
        #expect(SessionEndCommand.hookReason(from: payload("{}")) == nil)
        #expect(SessionEndCommand.hookReason(from: payload(#"{"session_id":"abc"}"#)) == nil)
        #expect(SessionEndCommand.hookReason(from: payload(#"{"reason":null}"#)) == nil)
    }

    @Test("an empty payload is a nil reason, not an error")
    func emptyData() {
        #expect(SessionEndCommand.hookReason(from: Data()) == nil)
    }

    /// The 1 MiB cap bounds PROCESSING, so it is judged on the byte count alone:
    /// a payload one byte over the line is refused even though it parses
    /// perfectly, and one exactly at the line is not.
    @Test("an oversized payload is refused on its size alone")
    func oversizedData() {
        let cap = 1 << 20
        func padded(to size: Int) -> Data {
            let prefix = #"{"reason":"clear","pad":""#
            let suffix = #""}"#
            return payload(
                prefix
                    + String(repeating: "x", count: size - prefix.utf8.count - suffix.utf8.count)
                    + suffix)
        }

        let atCap = padded(to: cap)
        #expect(atCap.count == cap)
        #expect(SessionEndCommand.hookReason(from: atCap) == "clear")

        let overCap = padded(to: cap + 1)
        #expect(overCap.count == cap + 1)
        #expect(SessionEndCommand.hookReason(from: overCap) == nil)
    }

    @Test("malformed JSON, and JSON that is not the expected object, answer nil")
    func malformedJSON() {
        #expect(SessionEndCommand.hookReason(from: payload("{not json")) == nil)
        #expect(SessionEndCommand.hookReason(from: payload("[]")) == nil)
        #expect(SessionEndCommand.hookReason(from: payload(#"{"reason":42}"#)) == nil)
    }
}
