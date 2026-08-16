import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Tier 1: pure decode, no I/O.
@Suite("SnapshotCompleteness")
struct SnapshotCompletenessTests {
    private func envelope(_ json: String) throws -> RemoteSessionListEnvelope {
        try JSONDecoder().decode(RemoteSessionListEnvelope.self, from: Data(json.utf8))
    }

    /// The contract's default: "Absent — MUST be read as `true`. A provider
    /// that always enumerates everything need never emit the field."
    @Test func anAbsentCompleteFieldReadsAsTrue() throws {
        let decoded = try envelope(#"{"sessions": [{"id": "a", "state": "running"}]}"#)
        #expect(decoded.complete)
        #expect(decoded.sessions.map(\.id) == ["a"])
    }

    @Test func anExplicitFalseSurvivesDecoding() throws {
        let decoded = try envelope(#"{"complete": false, "sessions": []}"#)
        #expect(decoded.complete == false)
    }

    @Test func anExplicitTrueSurvivesDecoding() throws {
        let decoded = try envelope(#"{"complete": true, "sessions": []}"#)
        #expect(decoded.complete)
    }

    /// The memberwise init keeps its old call shape for every existing fixture.
    @Test func theMemberwiseInitDefaultsToComplete() {
        #expect(RemoteSessionListEnvelope(sessions: []).complete)
        #expect(RemoteSessionListEnvelope(sessions: [], complete: false).complete == false)
    }
}
