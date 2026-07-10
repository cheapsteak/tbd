import Testing
import Foundation
@testable import TBDDaemonLib

/// Tests for the InputActivityTracker: timestamp recording, query, forget, and
/// pruning. Pure: no DB, no tmux, no actor. One test per method/path.
@Suite("InputActivityTracker")
struct InputActivityTrackerTests {
    private let pane1 = "pane-1"
    private let pane2 = "pane-2"
    private let pane3 = "pane-3"

    @Test func recordInputThenLastInputReturnsTimestamp() {
        let tracker = InputActivityTracker()

        tracker.recordInput(paneID: pane1)
        // Capture the first recorded time
        let recorded = tracker.lastInput(paneID: pane1)
        #expect(recorded != nil)

        // Record again after a small delay
        usleep(100)
        tracker.recordInput(paneID: pane1)
        let recorded2 = tracker.lastInput(paneID: pane1)
        #expect(recorded2 != nil)
        // Second time should be >= first (likely strictly greater due to delay)
        #expect(recorded2! >= recorded!)
    }

    @Test func recordInputRecordsCurrentTime() {
        let tracker = InputActivityTracker()
        let beforeRecord = Date()

        tracker.recordInput(paneID: pane1)

        let recorded = tracker.lastInput(paneID: pane1)
        let afterRecord = Date()

        #expect(recorded != nil)
        #expect(recorded! >= beforeRecord)
        #expect(recorded! <= afterRecord)
    }

    @Test func lastInputReturnsNilForUnknownPane() {
        let tracker = InputActivityTracker()
        #expect(tracker.lastInput(paneID: pane1) == nil)
    }

    @Test func forgetClearsRecordedTimestamp() {
        let tracker = InputActivityTracker()
        tracker.recordInput(paneID: pane1)
        #expect(tracker.lastInput(paneID: pane1) != nil)

        tracker.forget(paneID: pane1)
        #expect(tracker.lastInput(paneID: pane1) == nil)
    }

    @Test func forgetOnUnknownPaneIsIdempotent() {
        let tracker = InputActivityTracker()
        // Should not crash
        tracker.forget(paneID: pane1)
        #expect(tracker.lastInput(paneID: pane1) == nil)
    }

    @Test func pruneDropsAbsentPanes() {
        let tracker = InputActivityTracker()
        tracker.recordInput(paneID: pane1)
        tracker.recordInput(paneID: pane2)
        tracker.recordInput(paneID: pane3)

        #expect(tracker.lastInput(paneID: pane1) != nil)
        #expect(tracker.lastInput(paneID: pane2) != nil)
        #expect(tracker.lastInput(paneID: pane3) != nil)

        // Prune: keep only pane1 and pane2
        tracker.prune(keeping: Set([pane1, pane2]))

        #expect(tracker.lastInput(paneID: pane1) != nil)
        #expect(tracker.lastInput(paneID: pane2) != nil)
        #expect(tracker.lastInput(paneID: pane3) == nil)
    }

    @Test func pruneWithEmptySetClearsAll() {
        let tracker = InputActivityTracker()
        tracker.recordInput(paneID: pane1)
        tracker.recordInput(paneID: pane2)

        tracker.prune(keeping: Set())

        #expect(tracker.lastInput(paneID: pane1) == nil)
        #expect(tracker.lastInput(paneID: pane2) == nil)
    }

    @Test func pruneIsIdempotent() {
        let tracker = InputActivityTracker()
        tracker.recordInput(paneID: pane1)

        tracker.prune(keeping: Set([pane1]))
        let after1 = tracker.lastInput(paneID: pane1)

        tracker.prune(keeping: Set([pane1]))
        let after2 = tracker.lastInput(paneID: pane1)

        #expect(after1 == after2)
    }

    @Test func multiplepanesTrackedIndependently() {
        let tracker = InputActivityTracker()

        tracker.recordInput(paneID: pane1)
        let time1 = tracker.lastInput(paneID: pane1)!

        // Small delay to ensure time advances
        usleep(100)

        tracker.recordInput(paneID: pane2)
        let time2 = tracker.lastInput(paneID: pane2)!

        #expect(time2 >= time1)
        // pane1's time should not have changed
        #expect(tracker.lastInput(paneID: pane1) == time1)
    }
}
