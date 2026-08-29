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
        let releaseThread = Thread {
            released.withLock { didRelease = true }
            gate.signal()
        }
        releaseThread.name = "com.tbd.tests.gate-release"
        releaseThread.start()
        // Default deadline, not a snappier number of its own: this is a
        // hang-catcher on a dedicated thread hop. A dispatch queue is not a
        // dedicated thread and cannot be the reference here: saturated gate
        // work used to starve the queue for the entire deadline.
        #expect(gate.waitForGate("self-test: cross-thread"))
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

    @Test("gate holders block their own threads, leaving the cooperative pool free")
    func gateHoldersDoNotStarveTheCooperativePool() async throws {
        // More simultaneous holders than Swift's cooperative pool is wide, so
        // the count reproduces CI's 3-thread runner on any machine. Started
        // with a plain `Task` these park every pool thread; the `await` below
        // then cannot get one until a holder gives up, and the giving-up is
        // what reds this test. Enqueueing them needs no thread, so all of them
        // are pending before the first suspension point.
        let holders = ProcessInfo.processInfo.activeProcessorCount + 2
        let gate = DispatchSemaphore(value: 0)
        let parked = Counter()
        let tasks = (0..<holders).map { index in
            gateHoldingTask {
                parked.increment()
                return gate.waitForGate("self-test: pool-starvation holder \(index)")
            }
        }
        defer { for _ in 0..<holders { gate.signal() } }

        // Ordinary cooperative work still gets a thread while every gate is
        // held. Deliberately not timed: scheduling latency in the parallel
        // pass is tens of seconds under load, so a wall-clock bound here would
        // go red on a merely busy machine. The default gate deadline clears
        // that latency with room to spare, which is what keeps the discrimination
        // one-sided — a healthy run always releases first.
        #expect(await Task { true }.value)

        for _ in 0..<holders { gate.signal() }
        var released = 0
        for task in tasks where await task.value { released += 1 }
        #expect(released == holders, "every holder must be released, not expire")
        #expect(parked.value == holders, "every holder must have reached its gate")
    }

    @Test("gate holders leave the dispatch worker pool free")
    func gateHoldersDoNotStarveDispatchWorkers() async throws {
        // 64 is the smallest stress count that reproduced the old executor's
        // dispatch-worker ceiling on the development host, and it exceeds the
        // 25 gate holders added by this PR when the 3-core CI runner starved.
        // The count is deliberately fixed: this stresses a shared worker limit,
        // which is not the same as active CPU width.
        let holders = 64
        let gate = DispatchSemaphore(value: 0)
        let parked = Counter()
        let tasks = (0..<holders).map { index in
            gateHoldingTask {
                parked.increment()
                return gate.waitForGate("self-test: dispatch-starvation holder \(index)")
            }
        }
        defer { for _ in 0..<holders { gate.signal() } }

        guard await waitUntil({ parked.value == holders }, timeout: ciSafeDeadline) else {
            for _ in 0..<holders { gate.signal() }
            for task in tasks { _ = await task.value }
            Issue.record("every stress holder must reach its gate")
            return
        }

        let dispatched = Counter()
        DispatchQueue.global(qos: .userInitiated).async { dispatched.increment() }
        let dispatchRan = await waitUntil(
            { dispatched.value == 1 }, timeout: ciSafeDeadline)

        for _ in 0..<holders { gate.signal() }
        for task in tasks { _ = await task.value }
        #expect(dispatchRan, "gate holders must not consume the workers needed by unrelated dispatch work")
    }

    @Test("the timeout diagnostic names the gate and the deadline")
    func timeoutDescriptionCarriesTheDiagnostic() {
        let description = String(
            describing: TestGateTimeout(gate: "some gate", after: .seconds(3)))
        #expect(description.contains("some gate"))
        #expect(description.contains("3"))
    }
}


/// Minimal thread-safe counter — the holders increment from threads that are
/// about to block, so this cannot be an actor.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
