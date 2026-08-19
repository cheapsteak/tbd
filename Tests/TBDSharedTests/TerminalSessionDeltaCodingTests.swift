import Foundation
import Testing
@testable import TBDShared

@Suite("TerminalSessionDelta coding")
struct TerminalSessionDeltaCodingTests {
    @Test("legacy payload without an order generation still decodes")
    func legacyPayloadDecodes() throws {
        let terminalID = UUID()
        let worktreeID = UUID()
        let json = """
        {"terminalID":"\(terminalID.uuidString)","worktreeID":"\(worktreeID.uuidString)","sessionID":"session","transcriptPath":null}
        """

        let delta = try JSONDecoder().decode(
            TerminalSessionDelta.self,
            from: Data(json.utf8))

        #expect(delta.terminalID == terminalID)
        #expect(delta.sessionOrderObservedAt == nil)
    }

    @Test("the session order generation round trips")
    func orderGenerationRoundTrips() throws {
        let observedAt = Date(timeIntervalSinceReferenceDate: 123)
        let original = TerminalSessionDelta(
            terminalID: UUID(),
            worktreeID: UUID(),
            sessionID: "session",
            transcriptPath: "/tmp/session.jsonl",
            sessionOrderObservedAt: observedAt)

        let decoded = try JSONDecoder().decode(
            TerminalSessionDelta.self,
            from: JSONEncoder().encode(original))

        #expect(decoded.sessionOrderObservedAt == observedAt)
    }
}
