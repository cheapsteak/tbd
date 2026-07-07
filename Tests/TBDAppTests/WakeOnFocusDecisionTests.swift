import Foundation
import Testing
import TBDShared
@testable import TBDApp

/// The spawn-storm fix: on focus, wake EXACTLY ONE parked terminal, never fan
/// out to all N (which queued respawns past the 300s ceiling and hung the
/// daemon). Tests the pure decision `terminalIDToWakeOnFocus` across its three
/// branches without needing a live `DaemonClient`.
@MainActor
@Suite("Wake-on-focus decision (spawn-storm fix)")
struct WakeOnFocusDecisionTests {
    private func terminal(_ id: UUID, parked: Bool) -> Terminal {
        Terminal(id: id, worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
                 hibernatedAt: parked ? Date() : nil)
    }

    /// Branch 1: the focused terminal is itself parked → wake exactly it (not
    /// merely the first parked row).
    @Test func wakesTheFocusedParkedTerminal() {
        let state = AppState()
        let wt = UUID()
        let other = UUID()
        let focused = UUID()
        // `focused` is SECOND so a naive "first parked" would wrongly pick `other`.
        state.terminals[wt] = [terminal(other, parked: true), terminal(focused, parked: true)]
        let tabID = UUID()
        state.tabs[wt] = [Tab(id: tabID, content: .terminal(terminalID: focused), label: nil)]
        state.activeTabIndices[wt] = 0

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == focused)
    }

    /// Branch 2: no resolvable focused terminal (history view active) → fall back
    /// to the FIRST parked terminal — one, not a fan-out.
    @Test func fallsBackToFirstParkedWhenNoFocusResolvable() {
        let state = AppState()
        let wt = UUID()
        let firstParked = UUID()
        let secondParked = UUID()
        state.terminals[wt] = [terminal(firstParked, parked: true), terminal(secondParked, parked: true)]
        let tabID = UUID()
        state.tabs[wt] = [Tab(id: tabID, content: .terminal(terminalID: firstParked), label: nil)]
        // History view active → terminalIDForAutofocus returns nil.
        state.historyActiveWorktrees.insert(wt)

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == firstParked)
    }

    /// Branch 3: nothing parked → nil (nothing to wake).
    @Test func returnsNilWhenNoParkedTerminals() {
        let state = AppState()
        let wt = UUID()
        state.terminals[wt] = [terminal(UUID(), parked: false), terminal(UUID(), parked: false)]

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == nil)
    }

    // MARK: - Wake-failure alert coalescing (modal-spam fix)
    //
    // After a reboot kills every tmux server, each wake failure used to fire
    // its own modal — alert spam. `wakeTerminal` no longer alerts at all; it
    // RETURNS the failure message. The automatic focus path ignores it
    // (silent — its "no alert" branch is structural), and the explicit Wake
    // menu action folds its batch of failures through this pure function
    // into at most ONE modal per user action. All three branches covered.

    /// No failures → nil → no alert shown.
    @Test func noWakeFailuresProducesNoAlert() {
        #expect(AppState.coalescedWakeFailureMessage(failures: []) == nil)
    }

    /// A single failure → the bare message, no count prefix.
    @Test func singleWakeFailureShowsBareMessage() {
        #expect(AppState.coalescedWakeFailureMessage(failures: ["tmux window @1 is gone"])
                == "Couldn't wake session: tmux window @1 is gone")
    }

    /// Multiple failures → ONE message carrying the count and the first
    /// failure — never one modal per terminal.
    @Test func multipleWakeFailuresCoalesceIntoOneMessage() {
        let message = AppState.coalescedWakeFailureMessage(
            failures: ["window @1 gone", "window @2 gone", "window @3 gone"]
        )
        #expect(message == "Couldn't wake 3 sessions: window @1 gone")
    }
}
