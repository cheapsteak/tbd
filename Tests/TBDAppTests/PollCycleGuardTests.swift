import Foundation
import Testing
@testable import TBDApp

/// Tests for the Layer A in-flight poll guard (`AppState.runPollCycleIfIdle`).
///
/// The 2s poll timer frees the main actor whenever its refresh awaits a slow
/// daemon RPC, so without a guard each subsequent tick would spawn another
/// overlapping refresh cycle — an RPC storm. `runPollCycleIfIdle` collapses any
/// tick that fires while a cycle is still running into a cheap skip.
///
/// Every test constructs `AppState(userDefaults:)` against a unique throwaway
/// suite — TBDApp ships as an unbundled SPM executable, so `UserDefaults.standard`
/// is the running developer's real `TBDApp.plist`. Using it from tests would
/// clobber live UI preferences.
@MainActor
@Suite("Poll cycle guard")
struct PollCycleGuardTests {

    private func makeState() -> (AppState, String, UserDefaults) {
        let suiteName = "TBDAppTests.PollCycleGuard.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (AppState(userDefaults: defaults), suiteName, defaults)
    }

    // Idle path: a fresh AppState runs the body and reports it ran; no skips.
    @Test func idleCycle_runsBody_andReturnsTrue() async {
        let (state, suiteName, defaults) = makeState()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var didRun = false
        let ran = await state.runPollCycleIfIdle {
            didRun = true
        }

        #expect(ran)
        #expect(didRun)
        #expect(state.skippedPollCycles == 0)
    }

    // In-flight path: while one cycle is suspended on a continuation we control,
    // a second concurrent call must return false WITHOUT running its body and
    // bump skippedPollCycles. After the first completes, a third call runs again
    // — proving the in-flight flag was cleared by the `defer`.
    @Test func overlappingCycle_isSkipped_thenFlagClears() async {
        let (state, suiteName, defaults) = makeState()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Coordinates handoff between the test and the first (suspended) cycle
        // without sleeps: the first cycle signals it has entered (so the flag is
        // set) and then parks until the test releases it.
        let gate = ContinuationGate()

        // Launch the first cycle; it enters the guard, signals, then awaits.
        async let firstRan: Bool = state.runPollCycleIfIdle {
            await gate.enterAndWait()
        }

        // Wait until the first cycle is provably inside the guarded body.
        await gate.waitUntilEntered()

        // Second call fires while the first is still in flight: must be skipped.
        var secondBodyRan = false
        let secondRan = await state.runPollCycleIfIdle {
            secondBodyRan = true
        }
        #expect(secondRan == false)
        #expect(secondBodyRan == false)
        #expect(state.skippedPollCycles == 1)

        // Release the first cycle and let it finish.
        await gate.release()
        let firstResult = await firstRan
        #expect(firstResult)

        // Flag cleared: a third call runs again.
        var thirdBodyRan = false
        let thirdRan = await state.runPollCycleIfIdle {
            thirdBodyRan = true
        }
        #expect(thirdRan)
        #expect(thirdBodyRan)
        // Still only the one skip from the overlapping call.
        #expect(state.skippedPollCycles == 1)
    }
}

/// Deterministic two-phase rendezvous used to hold one poll cycle "in flight"
/// while a second call races it. `enterAndWait()` signals entry then parks until
/// `release()`; `waitUntilEntered()` lets the test block until entry is observed.
/// No sleeps, no polling — every wait resumes off an explicit signal.
private actor ContinuationGate {
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    /// Called from inside the first guarded body: marks entry (waking any
    /// `waitUntilEntered()`) then suspends until `release()`.
    func enterAndWait() async {
        hasEntered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        if isReleased { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    /// Resumes once the first body has entered the guard.
    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    /// Releases the parked first body.
    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
