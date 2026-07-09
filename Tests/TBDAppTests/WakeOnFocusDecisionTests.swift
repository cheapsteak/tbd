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

    private func parkedTerminal(_ id: UUID, reason: HibernateReason?) -> Terminal {
        Terminal(id: id, worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
                 hibernatedAt: Date(), hibernateReason: reason)
    }

    /// Focus `terminalID`'s tab in `wt` so `terminalIDForAutofocus` resolves it.
    private func focus(_ state: AppState, worktreeID wt: UUID, terminalID: UUID) {
        state.tabs[wt] = [Tab(id: UUID(), content: .terminal(terminalID: terminalID), label: nil)]
        state.activeTabIndices[wt] = 0
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

    // MARK: - Manual-park exclusion (hibernateReason)
    //
    // An explicit "Hibernate now" (`hibernateReason == .manual`) must NOT be
    // silently undone by navigating back to the worktree: focus-wake skips it
    // at BOTH decision points (the focused-terminal match and the `.first`
    // fallback). Auto, recovery, and legacy nil-reason parks keep the old
    // behavior and still wake on focus.

    /// A manually-parked session is skipped even when it is the FOCUSED
    /// terminal — and with nothing else parked, nothing is woken at all.
    @Test func skipsManuallyParkedTerminalEvenWhenFocused() {
        let state = AppState()
        let wt = UUID()
        let manual = UUID()
        state.terminals[wt] = [parkedTerminal(manual, reason: .manual)]
        focus(state, worktreeID: wt, terminalID: manual)

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == nil)
    }

    /// An auto-parked (idle-sweep) session still wakes on focus.
    @Test func wakesAutoParkedTerminalOnFocus() {
        let state = AppState()
        let wt = UUID()
        let auto = UUID()
        state.terminals[wt] = [parkedTerminal(auto, reason: .auto)]
        focus(state, worktreeID: wt, terminalID: auto)

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == auto)
    }

    /// A recovery-parked (crash-recovery reconcile) session still wakes on focus.
    @Test func wakesRecoveryParkedTerminalOnFocus() {
        let state = AppState()
        let wt = UUID()
        let recovery = UUID()
        state.terminals[wt] = [parkedTerminal(recovery, reason: .recovery)]
        focus(state, worktreeID: wt, terminalID: recovery)

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == recovery)
    }

    /// A merge-parked session (`hibernateReason == .merged`) still wakes on
    /// focus: auto-hibernate-on-merge is system-initiated, not an explicit
    /// user "Hibernate now", so navigating back to the worktree wakes it —
    /// unlike a `.manual` park. Pins the design decision.
    @Test func wakesMergedReasonParkedTerminalOnFocus() {
        let state = AppState()
        let wt = UUID()
        let merged = UUID()
        state.terminals[wt] = [parkedTerminal(merged, reason: .merged)]
        focus(state, worktreeID: wt, terminalID: merged)

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == merged)
    }

    /// A legacy parked row with NO reason (pre-v46) still wakes on focus —
    /// the old behavior is preserved for rows the migration can't attribute.
    @Test func wakesLegacyNilReasonParkedTerminalOnFocus() {
        let state = AppState()
        let wt = UUID()
        let legacy = UUID()
        state.terminals[wt] = [parkedTerminal(legacy, reason: nil)]
        focus(state, worktreeID: wt, terminalID: legacy)

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == legacy)
    }

    /// Mixed worktree: a manual park and an auto park coexist. The manual one
    /// is FIRST in the list (a naive `.first` fallback would pick it) and also
    /// FOCUSED (a naive focused-match would pick it) — the auto one must be
    /// chosen anyway, proving the exclusion applies at both decision points.
    @Test func mixedManualAndAutoParkedChoosesTheAutoOne() {
        let state = AppState()
        let wt = UUID()
        let manual = UUID()
        let auto = UUID()
        state.terminals[wt] = [
            parkedTerminal(manual, reason: .manual),
            parkedTerminal(auto, reason: .auto),
        ]
        focus(state, worktreeID: wt, terminalID: manual)

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == auto)
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
