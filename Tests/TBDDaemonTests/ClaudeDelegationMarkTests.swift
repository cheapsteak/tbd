import Foundation
import Testing
@testable import TBDDaemonLib

@Suite struct ClaudeDelegationMarkTests {
    /// The trap this guards: `handleTerminalActivityEvent` returns early when
    /// the reported state equals the stored one, and a background-agent wake
    /// produces a second `idle` with no `working` between. A mark placed below
    /// that guard is dropped, and the rail latches the previous turn's count.
    @Test func aRepeatedIdleReportStillMarksTheTerminal() async {
        let tracker = ClaudeDelegationTracker()
        let id = UUID()

        await tracker.mark(terminalID: id)
        _ = await tracker.sample(
            targets: [ClaudeDelegationTarget(terminalID: id, transcriptPath: nil)])

        // Second idle for an already-idle terminal: still a turn boundary.
        await tracker.mark(terminalID: id)
        #expect(await tracker.isMarked(terminalID: id))
    }
}
