import Foundation
import Testing
import TBDShared

@testable import TBDCLI

/// The `STATE` column `tbd terminal list` prints. Before this, a row parked by
/// `stampSessionExited` (or any other hibernation path) looked identical to a
/// live one in the human table — same ID, WINDOW, PANE, LABEL — even once its
/// pane id no longer resolved to anything. `--json` always carried
/// `hibernatedAt`/`hibernateReason`; this is what brings that fact to the
/// table a human actually reads.
@Suite("tbd terminal list parked-state column")
struct ParkedStateMarkerTests {
    private static func terminal(
        hibernatedAt: Date? = nil, hibernateReason: HibernateReason? = nil
    ) -> Terminal {
        Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .claude, hibernatedAt: hibernatedAt, hibernateReason: hibernateReason)
    }

    @Test func liveRowShowsNoMarker() {
        #expect(parkedStateMarker(for: Self.terminal()) == "-")
    }

    @Test func exitStampedRowNamesTheReason() {
        let row = Self.terminal(hibernatedAt: Date(), hibernateReason: .exited)
        #expect(parkedStateMarker(for: row) == "parked (exited)")
    }

    @Test func manuallyHibernatedRowNamesItsReasonToo() {
        let row = Self.terminal(hibernatedAt: Date(), hibernateReason: .manual)
        #expect(parkedStateMarker(for: row) == "parked (manual)")
    }

    /// Defensive: a parked row with no reason recorded still reads as parked
    /// rather than silently rendering the live-row marker.
    @Test func parkedWithNoReasonStillReadsAsParked() {
        let row = Self.terminal(hibernatedAt: Date(), hibernateReason: nil)
        #expect(parkedStateMarker(for: row) == "parked")
    }
}
