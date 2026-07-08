import Foundation
import Testing
import TBDShared
@testable import TBDApp

/// Tab activation wake decision: when the user clicks a tab, wake only the
/// parked resumable terminals in THAT tab, never a cross-tab fan-out. Tests
/// the pure decision `terminalIDsToWakeOnTabActivation` to verify the spawn
/// storm fix is maintained and the scope is correctly limited.
@MainActor
@Suite("Wake on tab activation decision")
struct WakeOnTabActivationTests {
    private func terminal(_ id: UUID, parked: Bool, claudeSessionID: String? = UUID().uuidString, kind: TerminalKind? = nil, reason: HibernateReason? = nil) -> Terminal {
        var term = Terminal(id: id, worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
                            claudeSessionID: claudeSessionID, kind: kind, hibernatedAt: parked ? Date() : nil)
        term.hibernateReason = reason
        return term
    }

    /// Single parked terminal in activated tab (hibernated via hibernatedAt)
    /// → returned.
    @Test func wakesParkedTerminalInActivatedTab() {
        let state = AppState()
        let wt = UUID()
        let parked = UUID()
        let tabID = UUID()
        state.terminals[wt] = [terminal(parked, parked: true)]
        state.tabs[wt] = [Tab(id: tabID, content: .terminal(terminalID: parked), label: nil)]

        let toWake = state.terminalIDsToWakeOnTabActivation(worktreeID: wt, tabIndex: 0)
        #expect(toWake == [parked])
    }

    /// Parked terminal with legacy suspendedAt (hibernatedAt nil) → returned.
    @Test func wakesLegacySuspendedTerminalInActivatedTab() {
        let state = AppState()
        let wt = UUID()
        let parked = UUID()
        let tabID = UUID()
        // Manually construct a legacy row: hibernatedAt nil but isParked true via suspendedAt.
        var term = terminal(parked, parked: false) // hibernatedAt nil
        term.suspendedAt = Date() // But suspendedAt is set
        state.terminals[wt] = [term]
        state.tabs[wt] = [Tab(id: tabID, content: .terminal(terminalID: parked), label: nil)]

        let toWake = state.terminalIDsToWakeOnTabActivation(worktreeID: wt, tabIndex: 0)
        #expect(toWake == [parked])
    }

    /// Parked terminal that is NOT resumable (kind .shell, no claudeSessionID)
    /// → NOT returned.
    @Test func skipsUnresumableParkedTerminal() {
        let state = AppState()
        let wt = UUID()
        let unresumable = UUID()
        let tabID = UUID()
        // A shell-kind parked row with no claudeSessionID.
        state.terminals[wt] = [terminal(unresumable, parked: true, claudeSessionID: nil, kind: .shell)]
        state.tabs[wt] = [Tab(id: tabID, content: .terminal(terminalID: unresumable), label: nil)]

        let toWake = state.terminalIDsToWakeOnTabActivation(worktreeID: wt, tabIndex: 0)
        #expect(toWake.isEmpty)
    }

    /// Parked resumable terminal in a DIFFERENT (non-activated) tab
    /// → NOT returned (no cross-tab fan-out).
    @Test func doesNotWakeTerminalInInactiveTab() {
        let state = AppState()
        let wt = UUID()
        let parkedInTab0 = UUID()
        let parkedInTab1 = UUID()
        let tab0ID = UUID()
        let tab1ID = UUID()
        state.terminals[wt] = [
            terminal(parkedInTab0, parked: true),
            terminal(parkedInTab1, parked: true)
        ]
        state.tabs[wt] = [
            Tab(id: tab0ID, content: .terminal(terminalID: parkedInTab0), label: nil),
            Tab(id: tab1ID, content: .terminal(terminalID: parkedInTab1), label: nil)
        ]

        // Activate tab 1, expect only parkedInTab1 to be returned.
        let toWake = state.terminalIDsToWakeOnTabActivation(worktreeID: wt, tabIndex: 1)
        #expect(toWake == [parkedInTab1])
    }

    /// Non-parked terminal → not returned (nothing to wake).
    @Test func returnsEmptyForNonParkedTerminal() {
        let state = AppState()
        let wt = UUID()
        let awake = UUID()
        let tabID = UUID()
        state.terminals[wt] = [terminal(awake, parked: false)]
        state.tabs[wt] = [Tab(id: tabID, content: .terminal(terminalID: awake), label: nil)]

        let toWake = state.terminalIDsToWakeOnTabActivation(worktreeID: wt, tabIndex: 0)
        #expect(toWake.isEmpty)
    }

    /// Out-of-range tabIndex → returns [].
    @Test func returnsEmptyForOutOfRangeTabIndex() {
        let state = AppState()
        let wt = UUID()
        let term = UUID()
        let tabID = UUID()
        state.terminals[wt] = [terminal(term, parked: true)]
        state.tabs[wt] = [Tab(id: tabID, content: .terminal(terminalID: term), label: nil)]

        let toWake = state.terminalIDsToWakeOnTabActivation(worktreeID: wt, tabIndex: 5)
        #expect(toWake.isEmpty)
    }

    /// No tabs for worktree → returns [].
    @Test func returnsEmptyWhenNoTabsForWorktree() {
        let state = AppState()
        let wt = UUID()
        let term = UUID()
        state.terminals[wt] = [terminal(term, parked: true)]
        // No tabs entry

        let toWake = state.terminalIDsToWakeOnTabActivation(worktreeID: wt, tabIndex: 0)
        #expect(toWake.isEmpty)
    }

    /// Parked resumable terminal with hibernateReason == .manual
    /// → NOT returned (manually-hibernated sessions don't auto-wake on tab activation).
    @Test func skipsManuallyParkedTerminal() {
        let state = AppState()
        let wt = UUID()
        let manual = UUID()
        let tabID = UUID()
        state.terminals[wt] = [terminal(manual, parked: true, reason: .manual)]
        state.tabs[wt] = [Tab(id: tabID, content: .terminal(terminalID: manual), label: nil)]

        let toWake = state.terminalIDsToWakeOnTabActivation(worktreeID: wt, tabIndex: 0)
        #expect(toWake.isEmpty)
    }

    /// Parked resumable with .auto reason in activated tab → included.
    @Test func wakesAutoParkedInActivatedTab() {
        let state = AppState()
        let wt = UUID()
        let auto = UUID()
        let tabID = UUID()
        state.terminals[wt] = [terminal(auto, parked: true, reason: .auto)]
        state.tabs[wt] = [Tab(id: tabID, content: .terminal(terminalID: auto), label: nil)]

        let toWake = state.terminalIDsToWakeOnTabActivation(worktreeID: wt, tabIndex: 0)
        #expect(toWake == [auto])
    }

    /// Parked resumable with .recovery reason in activated tab → included.
    @Test func wakesRecoveryParkedInActivatedTab() {
        let state = AppState()
        let wt = UUID()
        let recovery = UUID()
        let tabID = UUID()
        state.terminals[wt] = [terminal(recovery, parked: true, reason: .recovery)]
        state.tabs[wt] = [Tab(id: tabID, content: .terminal(terminalID: recovery), label: nil)]

        let toWake = state.terminalIDsToWakeOnTabActivation(worktreeID: wt, tabIndex: 0)
        #expect(toWake == [recovery])
    }

    /// Parked resumable with nil reason (legacy) in activated tab → included.
    @Test func wakesLegacyParkedInActivatedTab() {
        let state = AppState()
        let wt = UUID()
        let legacy = UUID()
        let tabID = UUID()
        state.terminals[wt] = [terminal(legacy, parked: true, reason: nil)]
        state.tabs[wt] = [Tab(id: tabID, content: .terminal(terminalID: legacy), label: nil)]

        let toWake = state.terminalIDsToWakeOnTabActivation(worktreeID: wt, tabIndex: 0)
        #expect(toWake == [legacy])
    }
}

/// Updated terminalIDToWakeOnFocus decision: must filter to resumable rows
/// only, skipping unresumable (e.g. legacy parked shell-kind rows with no
/// claudeSessionID).
@MainActor
@Suite("Wake-on-focus decision (resumability filter)")
struct WakeOnFocusResumabilityTests {
    private func terminal(_ id: UUID, parked: Bool, claudeSessionID: String? = UUID().uuidString, kind: TerminalKind? = nil, reason: HibernateReason? = nil) -> Terminal {
        var term = Terminal(id: id, worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
                            claudeSessionID: claudeSessionID, kind: kind, hibernatedAt: parked ? Date() : nil)
        term.hibernateReason = reason
        return term
    }

    /// Branch 1 (existing): the focused terminal is itself parked AND resumable
    /// → wake exactly it.
    @Test func wakesTheFocusedParkedResumableTerminal() {
        let state = AppState()
        let wt = UUID()
        let other = UUID()
        let focused = UUID()
        state.terminals[wt] = [terminal(other, parked: true), terminal(focused, parked: true)]
        let tabID = UUID()
        state.tabs[wt] = [Tab(id: tabID, content: .terminal(terminalID: focused), label: nil)]
        state.activeTabIndices[wt] = 0

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == focused)
    }

    /// New branch: parked but unresumable (shell-kind, no claudeSessionID) is
    /// skipped; a later resumable parked row is chosen instead.
    @Test func skipsUnresumableParkedAndChoosesResumable() {
        let state = AppState()
        let wt = UUID()
        let unresumable = UUID()
        let resumable = UUID()
        // Unresumable first, resumable second — naive "first parked" would wrongly pick unresumable.
        state.terminals[wt] = [
            terminal(unresumable, parked: true, claudeSessionID: nil, kind: .shell),
            terminal(resumable, parked: true)
        ]
        let tabID = UUID()
        state.tabs[wt] = [Tab(id: tabID, content: .terminal(terminalID: resumable), label: nil)]
        state.activeTabIndices[wt] = 0

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == resumable)
    }

    /// Parked via legacy suspendedAt (hibernatedAt nil, but isParked true) and
    /// resumable → still selected.
    @Test func selectsLegacySuspendedResumableTerminal() {
        let state = AppState()
        let wt = UUID()
        let legacyParked = UUID()
        var term = terminal(legacyParked, parked: false) // hibernatedAt nil
        term.suspendedAt = Date() // Legacy parked
        state.terminals[wt] = [term]
        let tabID = UUID()
        state.tabs[wt] = [Tab(id: tabID, content: .terminal(terminalID: legacyParked), label: nil)]
        state.activeTabIndices[wt] = 0

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == legacyParked)
    }

    /// All parked terminals are unresumable → nil (nothing wakeable).
    @Test func returnsNilWhenAllParkedAreUnresumable() {
        let state = AppState()
        let wt = UUID()
        let unresumable1 = UUID()
        let unresumable2 = UUID()
        state.terminals[wt] = [
            terminal(unresumable1, parked: true, claudeSessionID: nil, kind: .shell),
            terminal(unresumable2, parked: true, claudeSessionID: nil, kind: .shell)
        ]

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == nil)
    }


    /// Parked resumable terminal with hibernateReason == .manual
    /// → NOT selected (manually-hibernated sessions don't auto-wake on focus).
    @Test func skipsManuallyParkedOnFocus() {
        let state = AppState()
        let wt = UUID()
        let manual = UUID()
        let tabID = UUID()
        state.terminals[wt] = [terminal(manual, parked: true, reason: .manual)]
        state.tabs[wt] = [Tab(id: tabID, content: .terminal(terminalID: manual), label: nil)]
        state.activeTabIndices[wt] = 0

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == nil)
    }

    /// Parked resumable with .auto reason → selected (auto parks auto-wake).
    @Test func wakesAutoParkedOnFocus() {
        let state = AppState()
        let wt = UUID()
        let auto = UUID()
        let tabID = UUID()
        state.terminals[wt] = [terminal(auto, parked: true, reason: .auto)]
        state.tabs[wt] = [Tab(id: tabID, content: .terminal(terminalID: auto), label: nil)]
        state.activeTabIndices[wt] = 0

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == auto)
    }

    /// Parked resumable with .recovery reason → selected (recovery parks auto-wake).
    @Test func wakesRecoveryParkedOnFocus() {
        let state = AppState()
        let wt = UUID()
        let recovery = UUID()
        let tabID = UUID()
        state.terminals[wt] = [terminal(recovery, parked: true, reason: .recovery)]
        state.tabs[wt] = [Tab(id: tabID, content: .terminal(terminalID: recovery), label: nil)]
        state.activeTabIndices[wt] = 0

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == recovery)
    }
}

/// Delta handler: clearing legacy suspendedAt on wake.
@MainActor
@Suite("Hibernation delta: legacy column cleanup")
struct HibernationDeltaLegacyCleanupTests {
    /// Wake delta (hibernated: false) on a row with BOTH suspendedAt and
    /// hibernatedAt set → both nil afterward, isParked == false.
    @Test func wakeClearsLegacySuspendedAtColumn() {
        let state = AppState()
        let wt = UUID()
        let termID = UUID()

        // Construct a legacy row: both hibernatedAt and suspendedAt set.
        var term = Terminal(id: termID, worktreeID: wt, tmuxWindowID: "@1", tmuxPaneID: "%1")
        term.hibernatedAt = Date()
        term.suspendedAt = Date(timeIntervalSinceNow: -3600)
        state.terminals[wt] = [term]

        let delta = TerminalHibernationDelta(
            terminalID: termID,
            worktreeID: wt,
            hibernated: false,
            keepWarm: false
        )
        state.applyTerminalHibernationDelta(delta)

        guard let updated = state.terminals[wt]?.first else {
            Issue.record("Terminal not found after delta")
            return
        }
        #expect(updated.hibernatedAt == nil)
        #expect(updated.suspendedAt == nil)
        #expect(!updated.isParked)
    }

    /// Hibernate delta (hibernated: true) → hibernatedAt set, suspendedAt
    /// untouched (already nil if new row, or preserved if legacy).
    @Test func hibernateLeavesLegacySuspendedAtUntouched() {
        let state = AppState()
        let wt = UUID()
        let termID = UUID()

        // Construct a legacy row with suspendedAt set.
        var term = Terminal(id: termID, worktreeID: wt, tmuxWindowID: "@1", tmuxPaneID: "%1")
        term.suspendedAt = Date(timeIntervalSinceNow: -3600)
        let originalSuspendedAt = term.suspendedAt
        state.terminals[wt] = [term]

        let delta = TerminalHibernationDelta(
            terminalID: termID,
            worktreeID: wt,
            hibernated: true,
            keepWarm: false
        )
        state.applyTerminalHibernationDelta(delta)

        guard let updated = state.terminals[wt]?.first else {
            Issue.record("Terminal not found after delta")
            return
        }
        #expect(updated.hibernatedAt != nil)
        #expect(updated.suspendedAt == originalSuspendedAt)
        #expect(updated.isParked)
    }
}
