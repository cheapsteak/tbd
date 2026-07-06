import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// State-level tests for the control-mode "input not being delivered"
/// indicator (#318 polish). The indicator's visibility is
/// `AppState.isInputDeliveryFailing(_:)`: it must be true ONLY for a pane
/// that is BOTH control-mode attached AND flagged failing by a daemon
/// health delta — never for unattached panes, whatever deltas arrive
/// (the CLAUDE.md gate rule: test each branch of the gate).
@MainActor
@Suite("Control-mode input-health indicator")
struct ControlModeInputHealthIndicatorTests {

    private func withState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.InputHealth.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AppState(userDefaults: defaults))
    }

    private func failingDelta(worktreeID: UUID, paneID: String) -> StateDelta {
        .controlModeInputHealthChanged(ControlModeInputHealthDelta(
            worktreeID: worktreeID, paneID: paneID, healthy: false))
    }

    private func healthyDelta(worktreeID: UUID, paneID: String) -> StateDelta {
        .controlModeInputHealthChanged(ControlModeInputHealthDelta(
            worktreeID: worktreeID, paneID: paneID, healthy: true))
    }

    @Test func attachedAndFailing_showsIndicator() {
        withState { state in
            let worktreeID = UUID()
            let key = ControlModePaneKey(worktreeID: worktreeID, paneID: "%3")
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%3")

            state.handleDelta(failingDelta(worktreeID: worktreeID, paneID: "%3"))

            #expect(state.isInputDeliveryFailing(key))
        }
    }

    @Test func notAttached_neverShowsIndicator_regardlessOfDeltas() {
        withState { state in
            let worktreeID = UUID()
            let key = ControlModePaneKey(worktreeID: worktreeID, paneID: "%3")

            // Failing delta for a pane that was never control-mode attached
            // (e.g. grouped-sessions fallback, or a stale delta): no indicator.
            state.handleDelta(failingDelta(worktreeID: worktreeID, paneID: "%3"))

            #expect(!state.isInputDeliveryFailing(key))
        }
    }

    @Test func attachedAndHealthy_showsNothing() {
        withState { state in
            let worktreeID = UUID()
            let key = ControlModePaneKey(worktreeID: worktreeID, paneID: "%3")
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%3")

            #expect(!state.isInputDeliveryFailing(key))
        }
    }

    @Test func recoveryDelta_clearsIndicator() {
        withState { state in
            let worktreeID = UUID()
            let key = ControlModePaneKey(worktreeID: worktreeID, paneID: "%3")
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%3")
            state.handleDelta(failingDelta(worktreeID: worktreeID, paneID: "%3"))
            #expect(state.isInputDeliveryFailing(key))

            state.handleDelta(healthyDelta(worktreeID: worktreeID, paneID: "%3"))

            #expect(!state.isInputDeliveryFailing(key))
        }
    }

    @Test func detach_clearsIndicator() {
        withState { state in
            let worktreeID = UUID()
            let key = ControlModePaneKey(worktreeID: worktreeID, paneID: "%3")
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%3")
            state.handleDelta(failingDelta(worktreeID: worktreeID, paneID: "%3"))
            #expect(state.isInputDeliveryFailing(key))

            state.controlModePaneDetached(worktreeID: worktreeID, paneID: "%3")

            #expect(!state.isInputDeliveryFailing(key))
            // A later re-attach must start healthy — the failing flag must
            // not survive the detach.
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%3")
            #expect(!state.isInputDeliveryFailing(key))
        }
    }

    @Test func deltasForOtherPanes_doNotLeakAcrossKeys() {
        withState { state in
            let worktreeID = UUID()
            let attached = ControlModePaneKey(worktreeID: worktreeID, paneID: "%3")
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%3")

            // Failing delta for a DIFFERENT pane in the same worktree.
            state.handleDelta(failingDelta(worktreeID: worktreeID, paneID: "%4"))

            #expect(!state.isInputDeliveryFailing(attached))
        }
    }
}
