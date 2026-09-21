import Foundation
import Testing
@testable import TBDShared

/// Wire shape of `.remoteSessionReconnectRequested`, the daemon's relay of
/// `tbd remote reconnect` to the app.
@Suite("RemoteSessionReconnectDelta coding")
struct RemoteSessionReconnectDeltaCodingTests {
    @Test func roundTripsProviderAndSessionID() throws {
        let original = RemoteSessionReconnectDelta(provider: "acme", sessionID: "sess/1")
        let data = try JSONEncoder().encode(StateDelta.remoteSessionReconnectRequested(original))
        let decoded = try JSONDecoder().decode(StateDelta.self, from: data)
        guard case .remoteSessionReconnectRequested(let delta) = decoded else {
            Issue.record("expected remoteSessionReconnectRequested, got \(decoded)")
            return
        }
        #expect(delta == original)
    }

    /// Pins the case name on the wire: an app decodes by that key, and one
    /// built before this case drops the line rather than misreading it as
    /// another delta.
    @Test func decodesTheDocumentedWireShape() throws {
        let json = #"{"remoteSessionReconnectRequested": {"_0": {"provider": "acme", "sessionID": "s1"}}}"#
        let decoded = try JSONDecoder().decode(StateDelta.self, from: Data(json.utf8))
        guard case .remoteSessionReconnectRequested(let delta) = decoded else {
            Issue.record("expected remoteSessionReconnectRequested, got \(decoded)")
            return
        }
        #expect(delta == RemoteSessionReconnectDelta(provider: "acme", sessionID: "s1"))
    }
}
