import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// `terminalHibernationChanged` delta application to the cached terminal row.
///
/// The parked `TerminalPanelView` materializes the instant `isParked` flips
/// (identity `id-tmuxWindowID-isParked`) and reads `initialSnapshot` from the
/// cached row ONCE at creation, and wake-on-focus filters on the cached row's
/// `hibernateReason` — so BOTH must land on the row together with the
/// `hibernated` flip, not in the later `refreshTerminals` refetch.
@MainActor
@Suite("Hibernation delta handling")
struct TerminalHibernationDeltaAppStateTests {

    private func withState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.HibernationDelta.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AppState(userDefaults: defaults))
    }

    @Test func hibernateDelta_populatesSnapshotAndReasonOnCachedRow() {
        withState { state in
            let worktreeID = UUID()
            let terminalID = UUID()
            state.terminals = [worktreeID: [
                Terminal(id: terminalID, worktreeID: worktreeID,
                         tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude)
            ]]

            state.handleDelta(.terminalHibernationChanged(TerminalHibernationDelta(
                terminalID: terminalID, worktreeID: worktreeID,
                hibernated: true, keepWarm: false,
                suspendedSnapshot: "FROZEN PANE", hibernateReason: .manual
            )))

            let row = state.terminals[worktreeID]?[0]
            #expect(row?.hibernatedAt != nil)
            #expect(row?.suspendedSnapshot == "FROZEN PANE",
                    "the parked view reads the cached row's snapshot at creation — it must arrive with the flip")
            #expect(row?.hibernateReason == .manual,
                    "wake-on-focus filters on the cached reason — it must arrive with the flip")
        }
    }

    @Test func wakeDelta_clearsReasonAndParkFlag_keepsSnapshot() {
        withState { state in
            let worktreeID = UUID()
            let terminalID = UUID()
            state.terminals = [worktreeID: [
                Terminal(id: terminalID, worktreeID: worktreeID,
                         tmuxWindowID: "@1", tmuxPaneID: "%1",
                         suspendedSnapshot: "FROZEN PANE", kind: .claude,
                         hibernatedAt: Date(), hibernateReason: .manual)
            ]]

            state.handleDelta(.terminalHibernationChanged(TerminalHibernationDelta(
                terminalID: terminalID, worktreeID: worktreeID,
                hibernated: false, keepWarm: false
            )))

            let row = state.terminals[worktreeID]?[0]
            #expect(row?.hibernatedAt == nil)
            #expect(row?.hibernateReason == nil,
                    "wake clears the reason, matching the daemon's clearHibernated")
            // clearHibernated deliberately KEEPS suspendedSnapshot in the DB so
            // the woken view can show the frozen pane while the live tmux
            // client reconnects — the cached row must match.
            #expect(row?.suspendedSnapshot == "FROZEN PANE")
        }
    }
}
