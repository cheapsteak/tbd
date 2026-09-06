import Foundation
import Testing
@testable import TBDShared

/// `HibernateReason.exited` is the machine-readable "the Claude process left on
/// its own" fact the send path refuses on. It rides the same TEXT column and the
/// same wire field as the other reasons, so the only new risks are the raw value
/// and the lenient decoder that protects older app binaries.
@Suite("HibernateReason.exited")
struct HibernateReasonExitedTests {

    @Test func theRawValueIsStableOnTheWire() throws {
        #expect(HibernateReason.exited.rawValue == "exited")
        let encoded = try JSONEncoder().encode(HibernateReason.exited)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"exited\"")
    }

    @Test func itRoundTripsThroughATerminal() throws {
        var terminal = Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude)
        terminal.hibernatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        terminal.hibernateReason = .exited
        let decoded = try JSONDecoder().decode(
            Terminal.self, from: JSONEncoder().encode(terminal))
        #expect(decoded.hibernateReason == .exited)
        #expect(decoded.isExitStamped)
    }

    /// The lenient decoder stays lenient: a reason a FUTURE daemon invents must
    /// still not fail the whole `Terminal` decode on this build.
    @Test func anUnknownReasonStillFallsBackToAuto() throws {
        let json = Data(#""quiesced""#.utf8)
        #expect(try JSONDecoder().decode(HibernateReason.self, from: json) == .auto)
    }

    /// `isExitStamped` is about BOTH columns: a row parked by the idle sweep is
    /// hibernated but not exit-stamped, and a reason with no stamp is not a park.
    @Test func isExitStampedNeedsBothColumns() {
        var terminal = Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude)
        #expect(!terminal.isExitStamped)

        terminal.hibernatedAt = Date(timeIntervalSince1970: 1)
        terminal.hibernateReason = .auto
        #expect(!terminal.isExitStamped)

        terminal.hibernateReason = .exited
        #expect(terminal.isExitStamped)

        terminal.hibernatedAt = nil
        #expect(!terminal.isExitStamped)
    }
}
