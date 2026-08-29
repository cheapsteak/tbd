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
        #expect(decoded.sessionIncarnationID == nil)
    }

    @Test("activity payload carries optional Codex session and process identity")
    func sessionAndProcessIdentityRoundTrips() throws {
        let incarnationID = UUID()
        let params = TerminalActivityEventParams(
            terminalID: UUID(),
            activityState: .waitingForUser,
            sessionID: "session-current",
            sessionIncarnationID: incarnationID)

        let decoded = try JSONDecoder().decode(
            TerminalActivityEventParams.self,
            from: JSONEncoder().encode(params))

        #expect(decoded.sessionID == "session-current")
        #expect(decoded.sessionIncarnationID == incarnationID)
    }
}

@Suite struct TerminalSessionEventParamsCodingTests {
    @Test("legacy session payload without process incarnation still decodes")
    func legacyPayloadStillDecodes() throws {
        let terminalID = UUID()
        let data = Data(
            #"{"terminalID":"\#(terminalID.uuidString)","sessionID":"session-current","transcriptPath":null,"source":"startup"}"#.utf8)

        let decoded = try JSONDecoder().decode(TerminalSessionEventParams.self, from: data)

        #expect(decoded.terminalID == terminalID)
        #expect(decoded.sessionID == "session-current")
        #expect(decoded.sessionIncarnationID == nil)
    }

    @Test("session payload carries optional process incarnation")
    func processIncarnationRoundTrips() throws {
        let incarnationID = UUID()
        let params = TerminalSessionEventParams(
            terminalID: UUID(),
            sessionID: "session-current",
            transcriptPath: "/tmp/session-current.jsonl",
            source: "startup",
            sessionIncarnationID: incarnationID)

        let decoded = try JSONDecoder().decode(
            TerminalSessionEventParams.self,
            from: JSONEncoder().encode(params))

        #expect(decoded.sessionIncarnationID == incarnationID)
    }
}

@Suite struct TerminalSessionEndedParamsCodingTests {
    @Test("legacy SessionEnd payload without process incarnation still decodes")
    func legacyPayloadStillDecodes() throws {
        let terminalID = UUID()
        let data = Data(#"{"terminalID":"\#(terminalID.uuidString)"}"#.utf8)

        let decoded = try JSONDecoder().decode(TerminalSessionEndedParams.self, from: data)

        #expect(decoded.terminalID == terminalID)
        #expect(decoded.sessionIncarnationID == nil)
    }

    @Test("SessionEnd payload carries optional process incarnation")
    func processIncarnationRoundTrips() throws {
        let incarnationID = UUID()
        let params = TerminalSessionEndedParams(
            terminalID: UUID(),
            sessionIncarnationID: incarnationID)

        let decoded = try JSONDecoder().decode(
            TerminalSessionEndedParams.self,
            from: JSONEncoder().encode(params))

        #expect(decoded.sessionIncarnationID == incarnationID)
    }
}
