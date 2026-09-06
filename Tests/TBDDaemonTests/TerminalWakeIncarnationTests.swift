import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// `terminal.wake` reports the incarnation its respawn minted, and reports none
/// when it did not respawn.
///
/// The negative rows are the load-bearing ones: an id on a no-op path would let
/// the app's sending hold release on somebody else's `SessionStart`, which is
/// the exact failure the id exists to prevent.
@Suite("terminal.wake reports its incarnation")
struct TerminalWakeIncarnationTests {

    @Test func theWokenPathCarriesTheMintedID() throws {
        let minted = UUID()
        let result = try #require(
            RPCRouter.wakeResultPayload(for: .ok(sessionIncarnationID: minted)))
        #expect(result.woken)
        #expect(result.sessionIncarnationID == minted)
    }

    /// `woken: false` means the prompt was never delivered anywhere, so there is
    /// no spawn to name and nothing for a hold to wait on.
    @Test func theNoOpPathsCarryNoID() throws {
        for result in [WakeResult.notHibernated, WakeResult.inFlight] {
            let payload = try #require(RPCRouter.wakeResultPayload(for: result))
            #expect(!payload.woken)
            #expect(payload.sessionIncarnationID == nil)
        }
    }

    /// `sessionIncarnationID` is nil here for wire compatibility rather than
    /// because the daemon can actually produce this shape — `liveIncarnationID`
    /// is non-optional on the respawn path, so a nil id never comes from this
    /// process today. The optional exists so an older daemon's `{"woken":true}`
    /// (no field at all) still decodes; this test pins that the decoder
    /// tolerates it and that the app must not hold forever waiting on an id
    /// that will never arrive.
    @Test func aWokenPathWithNoIDIsStillWoken() throws {
        let payload = try #require(
            RPCRouter.wakeResultPayload(for: .ok(sessionIncarnationID: nil)))
        #expect(payload.woken)
        #expect(payload.sessionIncarnationID == nil)
    }

    /// Wire compatibility both ways: an older client's payload still decodes,
    /// and an older daemon's response still decodes here.
    @Test func theFieldIsAdditiveOnTheWire() throws {
        let decoded = try JSONDecoder().decode(
            TerminalWakeResult.self, from: Data(#"{"woken":true}"#.utf8))
        #expect(decoded.woken)
        #expect(decoded.sessionIncarnationID == nil)
    }
}
