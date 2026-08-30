import Foundation
import TestSupport
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
        let defaultsSuite = TestDefaultsSuite("InputHealth")
        defer { defaultsSuite.tearDown() }
        let defaults = defaultsSuite.defaults
        body(AppState(userDefaults: defaults))
    }

    private func failingDelta(worktreeID: UUID, paneID: String, generation: UInt64? = nil) -> StateDelta {
        .controlModeInputHealthChanged(ControlModeInputHealthDelta(
            worktreeID: worktreeID, paneID: paneID, healthy: false, generation: generation))
    }

    private func healthyDelta(worktreeID: UUID, paneID: String, generation: UInt64? = nil) -> StateDelta {
        .controlModeInputHealthChanged(ControlModeInputHealthDelta(
            worktreeID: worktreeID, paneID: paneID, healthy: true, generation: generation))
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

    @Test func reattach_clearsStaleFailingFlagFromPriorGeneration() {
        withState { state in
            let worktreeID = UUID()
            let key = ControlModePaneKey(worktreeID: worktreeID, paneID: "%3")
            // Gen 1 attaches and takes a REAL failure — the flag is set while
            // gen 1 is still the recorded attach.
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%3", generation: 1)
            state.handleDelta(failingDelta(worktreeID: worktreeID, paneID: "%3"))
            #expect(state.isInputDeliveryFailing(key))

            // The pane re-attaches (gen 2) BEFORE the stale gen-1 detach is
            // processed. A fresh attach starts healthy — the stale flag must
            // clear here, because nothing else ever will: the stale detach is
            // (correctly) generation-guarded, and the daemon's register-reset
            // is silent (no recovery delta arrives).
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%3", generation: 2)
            #expect(!state.isInputDeliveryFailing(key), "fresh attach must start from a healthy baseline")

            // The stale gen-1 detach then lands: attached state survives AND
            // the indicator stays clear.
            state.controlModePaneDetached(worktreeID: worktreeID, paneID: "%3", generation: 1)
            #expect(!state.isInputDeliveryFailing(key))
            state.handleDelta(failingDelta(worktreeID: worktreeID, paneID: "%3"))
            #expect(state.isInputDeliveryFailing(key), "gen-2 attach record must have survived the stale detach")
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

    // MARK: - Generation-scoped failing deltas (R6-M7)

    @Test func staleGenerationFailingDelta_doesNotFlagAFreshAttach() {
        withState { state in
            let worktreeID = UUID()
            let key = ControlModePaneKey(worktreeID: worktreeID, paneID: "%3")
            // The race: gen 1's keystrokes fail while its teardown is in
            // flight; the pane re-attaches as gen 2, and only THEN does the
            // gen-1 failure's delta arrive. The fresh attach must stay clear.
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%3", generation: 2)

            state.handleDelta(failingDelta(worktreeID: worktreeID, paneID: "%3", generation: 1))

            #expect(!state.isInputDeliveryFailing(key),
                    "a stale attach's failure must not flag its successor")
        }
    }

    @Test func matchingGenerationFailingDelta_applies() {
        withState { state in
            let worktreeID = UUID()
            let key = ControlModePaneKey(worktreeID: worktreeID, paneID: "%3")
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%3", generation: 2)

            state.handleDelta(failingDelta(worktreeID: worktreeID, paneID: "%3", generation: 2))

            #expect(state.isInputDeliveryFailing(key))
        }
    }

    @Test func nilGenerationFailingDelta_appliesForBackCompat() {
        withState { state in
            let worktreeID = UUID()
            let key = ControlModePaneKey(worktreeID: worktreeID, paneID: "%3")
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%3", generation: 2)

            // Older daemon stamps no generation: apply, as before R6-M7.
            state.handleDelta(failingDelta(worktreeID: worktreeID, paneID: "%3", generation: nil))

            #expect(state.isInputDeliveryFailing(key))
        }
    }

    @Test func generationDelta_againstRecordWithoutGeneration_applies() {
        withState { state in
            let worktreeID = UUID()
            let key = ControlModePaneKey(worktreeID: worktreeID, paneID: "%3")
            // The record can't be discriminated (older daemon vended no
            // generation at attach): a generation-stamped delta still applies.
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%3", generation: nil)

            state.handleDelta(failingDelta(worktreeID: worktreeID, paneID: "%3", generation: 4))

            #expect(state.isInputDeliveryFailing(key))
        }
    }

    @Test func recoveryDelta_clearsRegardlessOfGeneration() {
        withState { state in
            let worktreeID = UUID()
            let key = ControlModePaneKey(worktreeID: worktreeID, paneID: "%3")
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%3", generation: 2)
            state.handleDelta(failingDelta(worktreeID: worktreeID, paneID: "%3", generation: 2))
            #expect(state.isInputDeliveryFailing(key))

            // Even a stale-generation recovery clears: clearing is safe (the
            // worst case is an indicator that re-fires on the next failure).
            state.handleDelta(healthyDelta(worktreeID: worktreeID, paneID: "%3", generation: 1))

            #expect(!state.isInputDeliveryFailing(key))
        }
    }

    @Test func deltaJSONWithoutGeneration_decodes_wireBackCompat() throws {
        // An older daemon's delta payload has no `generation` key: the app
        // must decode it (nil) rather than drop the whole delta.
        let json = """
            {"worktreeID":"\(UUID().uuidString)","paneID":"%3","healthy":false}
            """
        let decoded = try JSONDecoder().decode(
            ControlModeInputHealthDelta.self, from: Data(json.utf8))
        #expect(decoded.generation == nil)
        #expect(decoded.healthy == false)
    }
}
