import Foundation
import Testing
@testable import TBDCLI
@testable import TBDShared

/// The report `tbd terminal migrate` prints is the product of a fleet run: a
/// person needs to know what did not move and why.
@Suite("terminal migrate report")
struct TerminalMigrateReportTests {
    @Test("one line per session, each non-moves naming its reason")
    func oneLinePerSession() {
        let moved = UUID(), there = UUID(), busy = UUID(), blocked = UUID()
        let stalled = UUID()
        let lines = TerminalMigrate.reportLines(TerminalMigrateTransportResult(
            migrated: [moved],
            movedNotResumed: [TerminalMigrationSkip(
                terminalID: stalled, reason: "focus the tab to start it there")],
            skipped: [TerminalMigrationSkip(terminalID: busy, reason: "Session is actively running")],
            refused: [TerminalMigrationSkip(terminalID: blocked, reason: "no holder")],
            alreadyHolder: [there]))
        #expect(lines.count == 5)
        #expect(lines.contains("\(moved.uuidString)  migrated"))
        #expect(lines.contains("\(there.uuidString)  already on the holder"))
        #expect(lines.contains("\(busy.uuidString)  skipped: Session is actively running"))
        #expect(lines.contains("\(blocked.uuidString)  refused: no holder"))
        // Kept apart from `refused`: this session is on the holder, and a
        // reader acting on a "refused" line would look for it on tmux.
        #expect(lines.contains(
            "\(stalled.uuidString)  moved, not restarted: focus the tab to start it there"))
    }

    @Test("an empty run says so")
    func emptyRun() {
        #expect(TerminalMigrate.reportLines(TerminalMigrateTransportResult(
            migrated: [], skipped: [], refused: [])) == ["No sessions."])
    }
}
