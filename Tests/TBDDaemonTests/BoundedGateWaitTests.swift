import Foundation
import TestSupport
import Testing

/// Harness for `waitForGate` (`Tests/TestSupport/BoundedGateSupport.swift`).
///
/// The expiry branch runs on no healthy machine, so without these it would be
/// code nobody ever executes — and the whole point of the bound is that it
/// behaves correctly on the one day it fires. Both halves are asserted: a
/// satisfied gate must still be a plain ordering primitive that records
/// nothing, and an unsatisfied one must return rather than park forever, with
/// a named issue.
@Suite("bounded gate waits")
struct BoundedGateWaitTests {

    @Test("a signalled gate succeeds and records nothing")
    func signalledGatePasses() {
        let gate = DispatchSemaphore(value: 0)
        gate.signal()
        #expect(gate.waitForGate("self-test: pre-signalled", timeout: .seconds(5)))
    }

    @Test("a gate signalled from another thread still orders the two sides")
    func gateOrdersConcurrentSignal() {
        let gate = DispatchSemaphore(value: 0)
        let released = NSLock()
        nonisolated(unsafe) var didRelease = false
        DispatchQueue.global().async {
            released.withLock { didRelease = true }
            gate.signal()
        }
        #expect(gate.waitForGate("self-test: cross-thread", timeout: .seconds(30)))
        #expect(released.withLock { didRelease }, "the wait must not return before the signal")
    }

    @Test("an unsignalled gate gives up and records a named issue")
    func unsignalledGateReportsItself() {
        let gate = DispatchSemaphore(value: 0)
        var gaveUp = false
        // The recorded issue IS the expected outcome here; `withKnownIssue`
        // also fails if no issue is recorded, so this pins that the expiry
        // branch reports rather than failing silently.
        withKnownIssue("the gate is deliberately never signalled") {
            gaveUp = gate.waitForGate("self-test: never signalled", timeout: .milliseconds(50))
                == false
        }
        #expect(gaveUp, "an expired gate must return false, not park the thread")
        // Leave the semaphore at its initial value: an expired `wait(timeout:)`
        // consumes nothing, so no balancing `signal()` is owed, and an extra
        // one would mask a regression here.
    }

    @Test("the timeout diagnostic names the gate and the deadline")
    func timeoutDescriptionCarriesTheDiagnostic() {
        let description = String(
            describing: TestGateTimeout(gate: "some gate", after: .seconds(3)))
        #expect(description.contains("some gate"))
        #expect(description.contains("3"))
    }
}
