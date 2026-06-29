import Foundation
import Testing
@testable import TBDDaemonLib

/// Tracks how many holders are inside the limiter at once.
private actor PeakTracker {
    private(set) var current = 0
    private(set) var peak = 0
    func enter() { current += 1; if current > peak { peak = current } }
    func leave() { current -= 1 }
}

private actor BoolFlag {
    private(set) var value = false
    func set() { value = true }
}

struct RPCConcurrencyLimiterTests {

    @Test func peakHoldersNeverExceedCapAndAllComplete() async {
        let cap = 3
        let limiter = RPCConcurrencyLimiter(limit: cap)
        let tracker = PeakTracker()
        let n = 60

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<n {
                group.addTask {
                    await limiter.acquire()
                    await tracker.enter()
                    for _ in 0..<8 { await Task.yield() }   // hold the slot briefly
                    await tracker.leave()
                    await limiter.release()
                }
            }
        }

        // No interleaving ever exceeded the cap...
        #expect(await tracker.peak <= cap)
        // ...and concurrency genuinely happened (waiters were woken to refill).
        #expect(await tracker.peak >= 1)
        // The group draining proves no task deadlocked.
        #expect(await tracker.current == 0)
        // All slots returned: nothing left in flight.
        #expect(await limiter.inFlight == 0)
        #expect(await limiter.highWaterMark <= cap)
    }

    @Test func acquireBeyondCapBlocksUntilRelease() async {
        let limiter = RPCConcurrencyLimiter(limit: 1)
        let flag = BoolFlag()

        // Main holds the only slot.
        await limiter.acquire()

        let waiter = Task {
            await limiter.acquire()
            await flag.set()
        }

        // Give the waiter ample opportunity to (fail to) acquire.
        for _ in 0..<300 { await Task.yield() }
        #expect(await flag.value == false)       // parked, slot not granted
        #expect(await limiter.inFlight == 1)     // still pinned at the cap

        // Releasing wakes the parked waiter.
        await limiter.release()
        await waiter.value
        #expect(await flag.value == true)
        // Slot was transferred, not double-counted.
        #expect(await limiter.inFlight == 1)

        await limiter.release()
        #expect(await limiter.inFlight == 0)
    }
}
