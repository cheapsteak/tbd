import Darwin
import Foundation

@testable import TBDApp

// Shared by the two suites that observe background reaps —
// `ChildReaperTests` and `TerminalTeardownReapTests`.

/// How long a drain wait may take before it is reported as a stuck reap.
///
/// The honest cost of the drain is the longest-lived child in the process:
/// every child these suites spawn is either `/bin/sleep 0`–`0.4` or a `sleep
/// 120` that teardown SIGTERMs, so a healthy drain returns in well under a
/// second. 30 s is ~30x that. It must also land inside the two suites' shared
/// suite limit with room for the disposal and assertions that follow it, so
/// that a stuck reap is reported by *this* guard, with its observed state,
/// rather than truncated into a bare "Time limit was exceeded". That limit is
/// `.fastPassBounded` (`Tests/TestSupport/ClockTestSupport.swift`) — 240 s, one
/// dial derived from the fast pass's measured latency — which leaves this
/// guard 8x of room instead of the 2x the hand-written one minute left it. It
/// is a hang guard, not a timing assertion: a passing run never spends any
/// of it.
let reapDrainHangGuard: Duration = .seconds(30)

/// How a bounded wait for `ChildReaper`'s drain ended.
enum ReapDrainOutcome {
    /// The drain fired: every reap started before the wait has run to
    /// completion, so a child that still exists is a reap that did not reap.
    case drained(waited: Duration)
    /// The drain did not fire inside the hang guard. Some reap is parked in
    /// `waitpid` on a child that has not exited.
    case stalled(waited: Duration)
    /// The surrounding task was cancelled — the suite time limit fired, or the
    /// run is tearing down.
    case cancelled(waited: Duration)

    /// The diagnostic for a drain that did not fire — `nil` when it did.
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
        "ChildReaper's drain did not fire within \(waited) — a reap is parked in waitpid "
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
        "waiting for ChildReaper's drain was CANCELLED after \(waited) — the suite time "
            + "limit fired, or the run is tearing down. pid \(pid) was observed \(observedState); "
            + "this test ended and reaped it before failing. This says nothing about whether "
            + "teardown reaps."
    }
}

/// Suspends until every reap `ChildReaper` had already started has run to
/// completion — or until `budget` elapses, or the task is cancelled.
///
/// **The fast path is the point, and it is an event, not a window.**
/// `ChildReaper.drainPendingReaps` fires once every reap started before this
/// call has *finished* — the reaper keeps a ledger of the reaps in flight, and
/// the thread that completes the last one this drain covers is the one that
/// calls back. A child that still exists after that is a contract failure, not
/// a scheduling delay — which is the distinction polling cannot make (it can
/// only ever report "still there after N tries"). Suspending rather than
/// blocking also keeps the main queue draining, which the teardown suite needs.
///
/// **Why the wait is nevertheless bounded.** The drain waits on `waitpid`
/// calls that `ChildReaper` itself documents as unbounded: a child that ignores
/// `SIGHUP` never exits and its reaper thread parks forever. No suite
/// `.timeLimit` can rescue that — a `withCheckedContinuation` awaiting a
/// callback that never runs is not cancellable, and Swift Testing cannot cancel
/// a thread parked in a synchronous `waitpid` either — so an unbounded drain
/// wait would wedge the whole run instead of reddening one test. The hang guard
/// converts that back into a red test with a named diagnostic, and the caller
/// SIGKILLs its own child on that path so the stall cannot poison siblings.
///
/// **Two properties of the drain the caller has to know.** It is *process-
/// wide*, so it also waits on reaps started by any concurrently running test.
/// And a stuck reap holds up only the drains that cover it, never later reaps:
/// each reap runs on a thread of its own, so a parked one costs each later test
/// one bounded `budget` and a named failure — degraded, attributable, and
/// finite — instead of a wedge. Nothing on this path touches a libdispatch
/// worker, deliberately: the previous shape, a barrier on a private concurrent
/// queue, shared the process's ~64 constrained workers with every global-queue
/// block in the fast pass, and once those were all parked neither the reaps nor
/// the barrier could start — this guard then fired for every drain-awaiting
/// test in both suites at once, which is what the nightly ledger recorded.
///
/// The guard task is cancelled on the fast path, and cancellation of the caller
/// resolves the wait immediately rather than waiting the budget out.
func drainPendingReaps(within budget: Duration = reapDrainHangGuard) async -> ReapDrainOutcome {
    let started = ContinuousClock.now
    let signal = DrainSignal()
    ChildReaper.drainPendingReaps { signal.resolve(.drained) }
    let hangGuard = Task {
        // A cancelled sleep means the drain already won — say nothing.
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
/// including the drain callback that fires minutes later — are no-ops.
///
/// It exists because the three racers cannot be raced with a task group: the
/// drain arm is exactly the one that may never complete, and a task group
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
