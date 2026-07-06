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
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%3", generation: 1)

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
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%3", generation: 1)

            #expect(!state.isInputDeliveryFailing(key))
        }
    }

    @Test func recoveryDelta_clearsIndicator() {
        withState { state in
            let worktreeID = UUID()
            let key = ControlModePaneKey(worktreeID: worktreeID, paneID: "%3")
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%3", generation: 1)
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
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%3", generation: 1)
            state.handleDelta(failingDelta(worktreeID: worktreeID, paneID: "%3"))
            #expect(state.isInputDeliveryFailing(key))

            state.controlModePaneDetached(worktreeID: worktreeID, paneID: "%3", generation: 1)

            #expect(!state.isInputDeliveryFailing(key))
            // A later re-attach must start healthy — the failing flag must
            // not survive the detach.
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%3", generation: 2)
            #expect(!state.isInputDeliveryFailing(key))
        }
    }

    @Test func deltasForOtherPanes_doNotLeakAcrossKeys() {
        withState { state in
            let worktreeID = UUID()
            let attached = ControlModePaneKey(worktreeID: worktreeID, paneID: "%3")
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%3", generation: 1)

            // Failing delta for a DIFFERENT pane in the same worktree.
            state.handleDelta(failingDelta(worktreeID: worktreeID, paneID: "%4"))

            #expect(!state.isInputDeliveryFailing(attached))
        }
    }

    // MARK: - Generation-scoped detach (M3 review fix)

    @Test func staleDetach_olderGeneration_doesNotClearFreshAttach() {
        withState { state in
            let worktreeID = UUID()
            let key = ControlModePaneKey(worktreeID: worktreeID, paneID: "%3")
            // The race: a closing pane's cleanup (attach gen 1) lands AFTER a
            // fresh view's attach (gen 2) for the same pane.
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%3", generation: 2)
            state.controlModePaneDetached(worktreeID: worktreeID, paneID: "%3", generation: 1)

            // The fresh attach's record survives: a failing delta still
            // gates open (the indicator can show), exactly as if the stale
            // clear never happened.
            state.handleDelta(failingDelta(worktreeID: worktreeID, paneID: "%3"))
            #expect(state.isInputDeliveryFailing(key))

            // The stale detach must not have dropped the failing flag either:
            // a recovery delta (not the stale detach) is what clears it.
            state.handleDelta(healthyDelta(worktreeID: worktreeID, paneID: "%3"))
            #expect(!state.isInputDeliveryFailing(key))

            // The fresh attach's OWN detach (matching generation) clears.
            state.controlModePaneDetached(worktreeID: worktreeID, paneID: "%3", generation: 2)
            state.handleDelta(failingDelta(worktreeID: worktreeID, paneID: "%3"))
            #expect(!state.isInputDeliveryFailing(key), "detached pane never shows the indicator")
        }
    }

    @Test func detachWithoutGeneration_clearsUnconditionally() {
        withState { state in
            let worktreeID = UUID()
            let key = ControlModePaneKey(worktreeID: worktreeID, paneID: "%3")
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%3", generation: 7)
            state.handleDelta(failingDelta(worktreeID: worktreeID, paneID: "%3"))
            #expect(state.isInputDeliveryFailing(key))

            // Back-compat fallback path: no generation → unconditional clear.
            state.controlModePaneDetached(worktreeID: worktreeID, paneID: "%3")

            #expect(!state.isInputDeliveryFailing(key))
        }
    }

    @Test func attachWithoutGeneration_anyDetachClears() {
        withState { state in
            let worktreeID = UUID()
            let key = ControlModePaneKey(worktreeID: worktreeID, paneID: "%3")
            // Older daemon vended no generation: the record cannot be
            // discriminated, so a generation-carrying detach clears it
            // (today's behavior, accepted).
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%3", generation: nil)
            state.controlModePaneDetached(worktreeID: worktreeID, paneID: "%3", generation: 5)

            state.handleDelta(failingDelta(worktreeID: worktreeID, paneID: "%3"))
            #expect(!state.isInputDeliveryFailing(key))
        }
    }
}
