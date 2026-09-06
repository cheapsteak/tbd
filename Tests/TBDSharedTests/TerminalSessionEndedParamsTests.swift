import Foundation
import Testing
@testable import TBDShared

/// `terminal.sessionEnded` gains the hook payload's `reason`. The wire contract
/// is that an OLDER `~/.local/bin/tbd` — which is routinely stale relative to a
/// running daemon — keeps decoding, and a newer one adds a field the daemon may
/// or may not read.
@Suite("TerminalSessionEndedParams")
struct TerminalSessionEndedParamsTests {
    private let terminalID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    @Test func aPayloadWithoutTheReasonStillDecodes() throws {
        let json = """
            {"terminalID":"\(terminalID.uuidString)"}
            """
        let params = try JSONDecoder().decode(
            TerminalSessionEndedParams.self, from: Data(json.utf8))
        #expect(params.terminalID == terminalID)
        #expect(params.reason == nil)
    }

    @Test func aPayloadWithTheReasonCarriesItVerbatim() throws {
        let json = """
            {"terminalID":"\(terminalID.uuidString)","reason":"logout"}
            """
        let params = try JSONDecoder().decode(
            TerminalSessionEndedParams.self, from: Data(json.utf8))
        #expect(params.reason == "logout")
    }

    @Test func itRoundTrips() throws {
        let params = TerminalSessionEndedParams(
            terminalID: terminalID, sessionIncarnationID: UUID(), reason: "clear")
        let decoded = try JSONDecoder().decode(
            TerminalSessionEndedParams.self, from: JSONEncoder().encode(params))
        #expect(decoded == params)
    }
}
