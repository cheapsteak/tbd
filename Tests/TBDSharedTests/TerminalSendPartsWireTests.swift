import Foundation
import Testing
@testable import TBDShared

/// `terminal.send` grows three optional fields. The contract that matters is
/// what an OLD caller's payload means: `{terminalID, text, submit}` must decode
/// and behave byte-identically, because `~/.local/bin/tbd` is routinely stale
/// relative to a running daemon and every agent in the fleet uses that verb.
@Suite("terminal.send parts on the wire")
struct TerminalSendPartsWireTests {
    private let terminalID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    @Test func anOldPayloadDecodesUnchanged() throws {
        let json = """
            {"terminalID":"\(terminalID.uuidString)","text":"hello","submit":true}
            """
        let params = try JSONDecoder().decode(
            TerminalSendParams.self, from: Data(json.utf8))
        #expect(params.text == "hello")
        #expect(params.submit == true)
        #expect(params.parts == nil)
        #expect(params.envelope == nil)
        #expect(params.gateOnAwaitingInput == nil)
    }

    @Test func partsDecodeInOrderAndKeepTheirKinds() throws {
        let json = """
            {"terminalID":"\(terminalID.uuidString)","submit":true,"parts":[
              {"kind":"text","value":"look at "},
              {"kind":"imagePath","value":"/tmp/a.png"},
              {"kind":"text","value":" and tell me"}
            ]}
            """
        let params = try JSONDecoder().decode(
            TerminalSendParams.self, from: Data(json.utf8))
        #expect(params.parts == [
            .text("look at "),
            .imagePath("/tmp/a.png"),
            .text(" and tell me"),
        ])
    }

    /// A tagged object, not a bare string: a reader must be able to tell an
    /// image path from a sentence that happens to look like one, and a third
    /// kind must be addable without changing an existing field's JSON type.
    @Test func aPartEncodesAsATaggedObject() throws {
        let json = try #require(String(
            data: try JSONEncoder().encode(SendPart.imagePath("/tmp/a.png")),
            encoding: .utf8))
        #expect(json.contains(#""kind":"imagePath""#))
        #expect(json.contains(#""value":"\/tmp\/a.png""#) || json.contains(#""value":"/tmp/a.png""#))
    }

    @Test func theEnvelopeAndGateFieldsRoundTrip() throws {
        let explicit = TerminalSendParams(
            terminalID: terminalID, submit: true,
            parts: [.text("hi")], envelope: .suppressed, gateOnAwaitingInput: true)
        let decoded = try JSONDecoder().decode(
            TerminalSendParams.self, from: JSONEncoder().encode(explicit))
        #expect(decoded.envelope == .suppressed)
        #expect(decoded.gateOnAwaitingInput == true)
        #expect(decoded.parts == [.text("hi")])
    }

    /// An envelope value this build does not know must not fail the whole
    /// decode and lose the payload with it — the same reading `HibernateReason`
    /// and `UpdateMode` already take.
    @Test func anUnknownEnvelopeValueFallsBackToAttached() throws {
        let json = """
            {"terminalID":"\(terminalID.uuidString)","text":"hi","envelope":"redacted"}
            """
        let params = try JSONDecoder().decode(
            TerminalSendParams.self, from: Data(json.utf8))
        #expect(params.text == "hi")
        #expect(params.envelope == .attached)
    }
}
