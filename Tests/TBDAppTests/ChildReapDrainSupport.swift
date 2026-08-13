import Darwin
import Foundation

@testable import TBDApp

// Shared by the two suites that observe background reaps —
// `ChildReaperTests` and `TerminalTeardownReapTests`.

/// How long a barrier wait may take before it is reported as a stuck reap.
///
/// The honest cost of the barrier is the longest-lived child in the process:
/// every child these suites spawn is either `/bin/sleep 0`–`0.4` or a `sleep
/// 120` that teardown SIGTERMs, so a healthy drain returns in well under a
/// second. 30 s is ~30x that, and it must land inside the two suites' shared
/// `.timeLimit(.minutes(1))` with room for the disposal and assertions that
/// follow it — which it does with 2x to spare. It is a hang guard, not a timing
/// assertion: a passing run never spends any of it.
let reapDrainHangGuard: Duration = .seconds(30)

/// How a bounded wait for `ChildReaper`'s queue barrier ended.
enum ReapDrainOutcome {
    /// The barrier fired: every reap enqueued before the wait has run to
    /// completion, so a child that still exists is a reap that did not reap.
    case drained(waited: Duration)
    /// The barrier did not fire inside the hang guard. Some reap is parked in
    /// `waitpid` on a child that has not exited.
    case stalled(waited: Duration)
    /// The surrounding task was cancelled — the suite time limit fired, or the
    /// run is tearing down.
    case cancelled(waited: Duration)

    /// The diagnostic for a barrier that did not fire — `nil` when it did.
    /// `observedState` is a closure so the caller's `waitid`/`kill` probe runs
    /// only on the failing path.
    func diagnostic(pid: pid_t, observedState: () -> String) -> (any Error)? {
        switch self {
        case .drained:
            return nil
        case .stalled(let waited):
            return ReapDrainStalled(pid: pid, observedState: observedState(), waited: waited)
        case .cancelled(let waited):
            return ReapDrainWaitCancelled(pid: pid, observedState: observedState(), waited: waited)
        }
    }
}

struct ReapDrainStalled: Error, CustomStringConvertible {
    let pid: pid_t
    let observedState: String
    let waited: Duration

    var description: String {
        "ChildReaper's queue barrier did not fire within \(waited) — a reap is parked in waitpid "
            + "on a child that has not exited (the unbounded wait ChildReaper's doc comment "
            + "declares). pid \(pid) was observed \(observedState); this test ended and reaped it "
            + "before failing. Nothing here says teardown is broken — it says a reap is stuck."
    }
}

struct ReapDrainWaitCancelled: Error, CustomStringConvertible {
    let pid: pid_t
    let observedState: String
    let waited: Duration

    var description: String {
        "waiting for ChildReaper's queue barrier was CANCELLED after \(waited) — the suite time "
            + "limit fired, or the run is tearing down. pid \(pid) was observed \(observedState); "
            + "this test ended and reaped it before failing. This says nothing about whether "
            + "teardown reaps."
    }
}

/// Suspends until every reap `ChildReaper` had already enqueued has run to
/// completion — or until `budget` elapses, or the task is cancelled.
///
/// **The fast path is the point, and it is an event, not a window.**
/// `ChildReaper.drainPendingReaps` puts a barrier on the reaper's own concurrent
/// queue, so when it fires every reap enqueued before this call has *finished*.
/// A child that still exists after that is a contract failure, not a scheduling
/// delay — which is the distinction polling cannot make (it can only ever report
/// "still there after N tries"). Suspending rather than blocking also keeps the
/// main queue draining, which the teardown suite needs.
///
/// **Why the wait is nevertheless bounded.** The barrier is ordered behind
/// `waitpid` calls that `ChildReaper` itself documents as unbounded: a child
/// that ignores `SIGHUP` never exits and its reaper thread parks forever. No
/// suite `.timeLimit` can rescue that — a `withCheckedContinuation` awaiting a
/// callback that never runs is not cancellable, and Swift Testing cannot cancel
/// a thread parked in a synchronous `waitpid` either — so an unbounded barrier
/// wait would wedge the whole run instead of reddening one test. The hang guard
/// converts that back into a red test with a named diagnostic, and the caller
/// SIGKILLs its own child on that path so the stall cannot poison siblings.
///
/// **Two properties of the barrier the caller has to know.** It is *process-
/// wide*, so it also waits on reaps enqueued by any concurrently running test.
/// And a barrier on a *concurrent* queue also blocks every block submitted
/// after it, which is precisely the serialization
/// `ChildReaper.queue`'s `.concurrent` attribute exists to avoid: while one reap
/// is parked, later reaps still run (they were submitted before this barrier),
/// but every *subsequent* barrier queues behind this one. So a single stuck reap
/// costs each later test one bounded `budget` and a named failure — degraded,
/// attributable, and finite — instead of a wedge.
///
/// The guard task is cancelled on the fast path, and cancellation of the caller
/// resolves the wait immediately rather than waiting the budget out.
func drainPendingReaps(within budget: Duration = reapDrainHangGuard) async -> ReapDrainOutcome {
    let started = ContinuousClock.now
    let signal = DrainSignal()
    ChildReaper.drainPendingReaps { signal.resolve(.drained) }
    let hangGuard = Task {
        // A cancelled sleep means the barrier already won — say nothing.
        do { try await Task.sleep(for: budget) } catch { return }
        signal.resolve(.stalled)
    }
    defer { hangGuard.cancel() }

    let reason = await withTaskCancellationHandler {
        await signal.wait()
    } onCancel: {
        signal.resolve(.cancelled)
    }
    let waited = ContinuousClock.now - started
    switch reason {
    case .drained: return .drained(waited: waited)
    case .stalled: return .stalled(waited: waited)
    case .cancelled: return .cancelled(waited: waited)
    }
}

/// One-shot resolution box: whoever gets there first decides, and the losers —
/// including the barrier callback that fires minutes later — are no-ops.
///
/// It exists because the three racers cannot be raced with a task group: the
/// barrier arm is exactly the one that may never complete, and a task group
/// awaits *every* child at scope exit, so `cancelAll()` would not release it.
/// The two losing arms here are a cancellable `Task.sleep` and a callback that
/// simply lands in an already-settled box, so nothing is left to wait on.
private final class DrainSignal: @unchecked Sendable {
    enum Reason: Sendable { case drained, stalled, cancelled }

    private let lock = NSLock()
    private var settled: Reason?
    private var waiter: CheckedContinuation<Reason, Never>?

    func resolve(_ reason: Reason) {
        lock.lock()
        guard settled == nil else { lock.unlock(); return }
        settled = reason
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: reason)
    }

    /// Single-consumer by construction: one call per `drainPendingReaps`.
    func wait() async -> Reason {
        await withCheckedContinuation { (continuation: CheckedContinuation<Reason, Never>) in
            lock.lock()
            if let settled {
                lock.unlock()
                continuation.resume(returning: settled)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}
