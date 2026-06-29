import Foundation
import Testing
import TBDShared
@testable import TBDDaemonLib

/// Counts how many times `compute` actually ran.
private actor CallCounter {
    private(set) var count = 0
    @discardableResult
    func increment() -> Int { count += 1; return count }
}

/// A one-shot gate the test opens to release a parked `compute`.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for cont in pending { cont.resume() }
    }
}

struct PRListCoordinatorTests {

    private func sentinel(_ marker: Int) -> PRListResult {
        // Encode the marker in a deterministic UUID so callers can prove they
        // received the SAME snapshot.
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", marker))")!
        return PRListResult(statuses: [uuid: PRStatus(number: marker, url: "u", state: .mergeable)])
    }

    @Test func concurrentCallsCollapseIntoSingleComputation() async {
        let coordinator = PRListCoordinator()
        let counter = CallCounter()
        let started = CallCounter()
        let gate = Gate()
        let result = sentinel(1)

        let n = 24
        async let collected: [PRListResult] = await withTaskGroup(of: PRListResult.self) { group in
            for _ in 0..<n {
                group.addTask {
                    await started.increment()
                    // `run` is throwing now; these computes never throw, so a
                    // `try?` keeps the harness simple while still exercising the
                    // single-flight collapse.
                    return (try? await coordinator.run {
                        await counter.increment()
                        await gate.wait()   // park every compute that actually runs
                        return result
                    }) ?? self.sentinel(-1)
                }
            }
            var out: [PRListResult] = []
            for await r in group { out.append(r) }
            return out
        }

        // Wait until every caller's body has begun, then drain the scheduler so
        // all run() calls have collapsed onto the single in-flight task.
        while await started.count < n { await Task.yield() }
        for _ in 0..<200 { await Task.yield() }

        // Gate is still closed: only ONE compute could have run its increment.
        // A failed collapse would have started a second compute, whose own
        // increment would push the counter to 2 BEFORE we open the gate.
        #expect(await counter.count == 1)

        await gate.open()
        let results = await collected

        #expect(results.count == n)
        #expect(results.allSatisfy { $0.statuses == result.statuses })
        // Still exactly one compute after everyone resolved.
        #expect(await counter.count == 1)
    }

    @Test func secondWaveAfterResolutionRunsComputeAgain() async throws {
        let coordinator = PRListCoordinator()
        let counter = CallCounter()

        // First wave: no gating, resolves immediately.
        let first = try await coordinator.run {
            await counter.increment()
            return self.sentinel(1)
        }
        #expect(first.statuses == sentinel(1).statuses)
        #expect(await counter.count == 1)

        // Second wave after the first cleared: compute runs again.
        let second = try await coordinator.run {
            await counter.increment()
            return self.sentinel(2)
        }
        #expect(second.statuses == sentinel(2).statuses)
        #expect(await counter.count == 2)
    }

    private struct ComputeError: Error {}

    @Test func thrownErrorPropagatesToAllCallersAndClearsInFlight() async throws {
        let coordinator = PRListCoordinator()
        let counter = CallCounter()
        let started = CallCounter()
        let gate = Gate()

        // First wave: many concurrent callers collapse onto one compute that
        // throws. Every caller must observe the SAME thrown error.
        let n = 12
        async let outcomes: [Bool] = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<n {
                group.addTask {
                    await started.increment()
                    do {
                        _ = try await coordinator.run {
                            await counter.increment()
                            await gate.wait()      // hold the in-flight task open
                            throw ComputeError()
                        }
                        return false               // unexpected success
                    } catch is ComputeError {
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var out: [Bool] = []
            for await r in group { out.append(r) }
            return out
        }

        while await started.count < n { await Task.yield() }
        for _ in 0..<200 { await Task.yield() }
        // Single-flight collapse: only one compute ran despite the throw.
        #expect(await counter.count == 1)

        await gate.open()
        let results = await outcomes
        #expect(results.count == n)
        #expect(results.allSatisfy { $0 })   // every caller saw ComputeError

        // The slot was cleared on throw (defer), so a fresh wave runs a NEW
        // compute that can succeed — a transient failure didn't poison the slot.
        let recovered = try await coordinator.run {
            await counter.increment()
            return self.sentinel(7)
        }
        #expect(recovered.statuses == sentinel(7).statuses)
        #expect(await counter.count == 2)   // the first throwing compute + this one
    }
}
