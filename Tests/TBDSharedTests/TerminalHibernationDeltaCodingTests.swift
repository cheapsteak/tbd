import Foundation
import Testing
@testable import TBDShared

/// Wire back-compat for the `suspendedSnapshot` / `hibernateReason` fields on
/// `TerminalHibernationDelta` (added so the parked view and wake-on-focus see
/// them together with the `hibernated` flip, not in the later refetch).
@Suite("TerminalHibernationDelta coding")
struct TerminalHibernationDeltaCodingTests {

    /// A payload from an OLDER daemon that predates the snapshot/reason fields
    /// must still decode — with both nil.
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
    }

    /// Round-trip: a delta carrying snapshot + reason survives encode/decode.
    @Test func roundTripsSnapshotAndReason() throws {
        let original = TerminalHibernationDelta(
            terminalID: UUID(), worktreeID: UUID(),
            hibernated: true, keepWarm: false,
            suspendedSnapshot: "FROZEN PANE", hibernateReason: .manual
        )
        let data = try JSONEncoder().encode(StateDelta.terminalHibernationChanged(original))
        let decoded = try JSONDecoder().decode(StateDelta.self, from: data)
        guard case .terminalHibernationChanged(let delta) = decoded else {
            Issue.record("expected terminalHibernationChanged, got \(decoded)")
            return
        }
        #expect(delta.suspendedSnapshot == "FROZEN PANE")
        #expect(delta.hibernateReason == .manual)
    }
}
