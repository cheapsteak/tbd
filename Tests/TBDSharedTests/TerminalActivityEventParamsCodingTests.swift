import Foundation
import Testing
@testable import TBDShared

@Suite struct TerminalActivityEventParamsCodingTests {
    @Test("legacy activity payload without session identity still decodes")
    func legacyPayloadStillDecodes() throws {
        let terminalID = UUID()
        let data = Data(
            #"{"terminalID":"\#(terminalID.uuidString)","activityState":"working"}"#.utf8)

        let decoded = try JSONDecoder().decode(TerminalActivityEventParams.self, from: data)

        #expect(decoded.terminalID == terminalID)
        #expect(decoded.activityState == .working)
        #expect(decoded.sessionID == nil)
    }

    @Test("activity payload carries optional Codex session identity")
    func sessionIdentityRoundTrips() throws {
        let params = TerminalActivityEventParams(
            terminalID: UUID(),
            activityState: .waitingForUser,
            sessionID: "session-current")

        let decoded = try JSONDecoder().decode(
            TerminalActivityEventParams.self,
            from: JSONEncoder().encode(params))

        #expect(decoded.sessionID == "session-current")
    }
}
