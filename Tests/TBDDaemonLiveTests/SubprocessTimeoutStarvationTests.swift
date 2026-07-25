import Clocks
import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib

/// Regression coverage for the dispatch-pool-starvation flake behind three CI
/// failures (SubprocessTimeoutTests, GitManagerTimeoutTests,
/// HibernationOrphanDetectionTests).
///
/// The bug: the subprocess watchdog used to fire its deadline via
/// `DispatchSource.makeTimerSource(queue: .global())`. That handler needs a
/// free thread from the shared default-QoS GCD pool. Under the full suite
/// (~3000 tests, every target in ONE process, suites run in parallel), many
/// pool threads park on subprocesses/pipes/waits; a saturated pool means the
/// 100ms timer handler never runs in time, the child (`/bin/sleep`) runs to
/// natural completion, and `terminationHandler` reports a clean success for a
/// call that blew its deadline by 300x.
///
/// These tests reproduce that deterministically by drowning the default-QoS
/// global pool in blocking work items, then asserting the bounded runner STILL
/// times out. On the pre-fix code they fail with "returned instead of timing
/// out"; the fix (dedicated watchdog Thread + authoritative deadline decision)
/// makes them pass.
///
/// BLAST RADIUS: all test targets compile into one process and Swift Testing
/// runs suites in parallel across targets, so a saturated global pool stalls
/// sibling suites for as long as the window is open. This suite is
/// `.serialized`, keeps the saturation window as short as possible, and ALWAYS
/// releases every parked work item in a path that runs regardless of the
/// call's outcome. Never leave the pool parked past the end of a test.
///
/// WHY THESE TESTS PASS A `TestClock` THEY NEVER ADVANCE — and it is the
/// opposite of virtualizing the deadline. `runBoundedProcess` arms its deadline
/// twice: on the `SubprocessWatchdog` thread and on the injected clock. The
/// clock armer sleeps on the *cooperative* executor, a different pool from the
/// libdispatch global queue this suite floods, so with a real clock it could
/// fire first and satisfy these assertions without the watchdog participating.
/// A never-advanced `TestClock` disables that armer, leaving the deadline REAL
/// and the satisfier set exactly as it was before the clock seam existed.
///
/// HOW THIS SUITE DISCRIMINATES THE WATCHDOG — `sleep 90` + `.clockDriven`, and
/// both halves are load-bearing. A THIRD mechanism can also report `.timedOut`:
/// the completion path's AUTHORITY check
/// (`ContinuousClock.now - start >= timeout`). With the watchdog deleted, the
/// child runs to natural completion and the authority check then reports
/// `.timedOut` on its own — so the assertion is satisfied without the watchdog
/// participating at all. Measured, against the previous `sleep 3`: deleting the
/// watchdog armer left both tests PASSING, in 8.03s instead of 5.15s (the extra
/// ~2.9s being the child running out).
///
/// That was true from the moment the authority check landed — it shipped in the
/// same fix as the watchdog, so this suite never discriminated between them, and
/// the "on the pre-fix code they fail" claim above held only against code that
/// had neither.
///
/// The fix is to make the authority path TOO SLOW to satisfy the test: a 90s
/// child outlives `.clockDriven`'s 60s limit, so a broken watchdog surfaces as a
/// time-limit failure, while a working one still SIGKILLs at ~100ms and the
/// suite costs exactly what it did before. A hang-catcher, not a wall-clock
/// tolerance — the distinction that keeps this out of hygiene rule 2.
///
/// **Both parts are required.** `sleep 90` alone changes nothing without the
/// time limit (the authority path would simply take 90s and pass), and the time
/// limit alone changes nothing with a 3s child. Verified by mutation: deleting
/// the watchdog armer turns both tests RED.
@Suite("Subprocess timeout under dispatch-pool starvation", .serialized, .clockDriven)
struct SubprocessTimeoutStarvationTests {

    /// Number of blocking work items to flood the default-QoS pool with. The
    /// default-QoS worker-thread ceiling is ~64/process; 128 comfortably
    /// exhausts it on this 12-core box and on 2-core CI runners.
    private static let floodCount = 128

    /// Lock-guarded counter — `DispatchSemaphore.wait` is unavailable from an
    /// async context, so we track flood-item progress with a counter polled via
    /// `Task.sleep` (which runs on Swift's cooperative executor, a pool distinct
    /// from the libdispatch global queue we are deliberately starving).
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Saturates the default-QoS global pool with `floodCount` items each
    /// blocked on `gate`, runs `body` while the pool is starved, then ALWAYS
    /// releases every item (signals `gate` floodCount times) before returning —
    /// on success, on thrown error, on assertion failure. Polls until the
    /// flooded items observe the release so the pool is genuinely drained before
    /// the next serialized test starts.
    private func withSaturatedGlobalPool(_ body: () async -> Void) async {
        let gate = DispatchSemaphore(value: 0)
        let started = Counter()
        let drained = Counter()
        for _ in 0..<Self.floodCount {
            DispatchQueue.global().async {
                started.increment()
                gate.wait()      // park a pool thread
                drained.increment()
            }
        }
        // Best-effort: wait until the pool has spun up workers and parked them.
        // Once every item is parked no free default-QoS thread remains to
        // service a `DispatchSource(queue: .global())` timer handler — the
        // pre-fix watchdog's scheduling dependency.
        let startDeadline = ContinuousClock.now + .seconds(5)
        while started.current < Self.floodCount, ContinuousClock.now < startDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        await body()

        // ALWAYS release, on every exit path. `signal` (unlike `wait`) is
        // allowed from async. Then poll until every item drains so the pool is
        // fully free before the next serialized test (or sibling suite) runs.
        // Keep signalling each pass rather than exactly `floodCount` times: a
        // `DispatchSemaphore` hard-crashes on dealloc only when its value is
        // BELOW its initial value (a waiter still parked), so over-signalling is
        // harmless while under-signalling on a slow-drain deadline would crash.
        for _ in 0..<Self.floodCount { gate.signal() }
        let drainDeadline = ContinuousClock.now + .seconds(10)
        while drained.current < Self.floodCount, ContinuousClock.now < drainDeadline {
            gate.signal()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func tmuxRunExternalCommandTimesOutEvenWhenPoolSaturated() async {
        // `sleep 3` (not 30) so the pre-fix broken behavior — child runs to
        // natural completion, terminationHandler resumes a clean success — is
        // observed in bounded time. With the fix the 100ms deadline fires on
        // the dedicated watchdog thread regardless of pool state.
        await withSaturatedGlobalPool {
            do {
                _ = try await TmuxManager.runExternalCommand(
                    executable: "/bin/sleep",
                    arguments: ["90"],
                    label: "starvation-test",
                    timeout: .milliseconds(100),
                    clock: TestClock()  // never advanced — isolates the watchdog; see suite doc
                )
                Issue.record("expected runExternalCommand to time out under pool saturation, but it returned")
            } catch let error as TmuxError {
                guard case .timedOut = error else {
                    Issue.record("expected TmuxError.timedOut, got \(error)")
                    return
                }
            } catch {
                Issue.record("expected TmuxError.timedOut, got \(error)")
            }
        }
    }

    @Test func gitRunTimesOutEvenWhenPoolSaturated() async {
        // TestClock never advanced — disables the clock armer; see suite doc.
        let git = GitManager(subprocessTimeout: .milliseconds(100), clock: TestClock())
        await withSaturatedGlobalPool {
            do {
                _ = try await git.runForTimeoutTesting(
                    executable: "/bin/sleep",
                    arguments: ["90"],
                    at: FileManager.default.temporaryDirectory.path
                )
                Issue.record("expected runForTimeoutTesting to time out under pool saturation, but it returned")
            } catch is GitTimeoutError {
                // expected
            } catch {
                Issue.record("expected GitTimeoutError, got \(error)")
            }
        }
    }
}
