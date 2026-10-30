import Foundation
import Testing
@testable import TBDShared

/// Wire back-compat for the optional fields on `TerminalHibernationDelta`:
/// `suspendedSnapshot` / `hibernateReason`, which the parked view and
/// wake-on-focus need together with the `hibernated` flip rather than in the
/// later refetch, and `sessionIncarnationID`, which the app forwards Program
/// Status reports under.
@Suite("TerminalHibernationDelta coding")
struct TerminalHibernationDeltaCodingTests {

    /// A payload from an OLDER daemon that predates the optional fields must
    /// still decode — with each of them nil.
    @Test func decodesPayloadWithoutSnapshotAndReasonFields() throws {
        let json = """
        {
          "terminalHibernationChanged": {
            "_0": {
              "terminalID": "\(UUID().uuidString)",
              "worktreeID": "\(UUID().uuidString)",
              "hibernated": true,
              "keepWarm": false
            }
          }
        }
        """
        let decoded = try JSONDecoder().decode(StateDelta.self, from: Data(json.utf8))
        guard case .terminalHibernationChanged(let delta) = decoded else {
            Issue.record("expected terminalHibernationChanged, got \(decoded)")
            return
        }
        #expect(delta.hibernated == true)
        #expect(delta.suspendedSnapshot == nil)
        #expect(delta.hibernateReason == nil)
        #expect(delta.sessionIncarnationID == nil)
    }

    /// Round-trip: a delta carrying snapshot, reason and incarnation survives
    /// encode/decode.
    @Test func roundTripsSnapshotAndReason() throws {
        let incarnationID = UUID()
        let original = TerminalHibernationDelta(
            terminalID: UUID(), worktreeID: UUID(),
            hibernated: true, keepWarm: false,
            suspendedSnapshot: "FROZEN PANE", hibernateReason: .manual,
            sessionIncarnationID: incarnationID
        )
        let data = try JSONEncoder().encode(StateDelta.terminalHibernationChanged(original))
        let decoded = try JSONDecoder().decode(StateDelta.self, from: data)
        guard case .terminalHibernationChanged(let delta) = decoded else {
            Issue.record("expected terminalHibernationChanged, got \(decoded)")
            return
        }
        #expect(delta.suspendedSnapshot == "FROZEN PANE")
        #expect(delta.hibernateReason == .manual)
        #expect(delta.sessionIncarnationID == incarnationID)
    }
}
