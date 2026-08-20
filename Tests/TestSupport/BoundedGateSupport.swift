import Dispatch
import Foundation
import Testing

// Bounded waits for the `DispatchSemaphore` gates tests use to hold a piece of
// production work at a chosen instant while the test observes the world around
// it.
//
// WHY THE BOUND EXISTS — do not "simplify" `waitForGate` back to a bare
// `wait()`.
//
// A `DispatchSemaphore.wait()` with no deadline parks the *thread* it runs on.
// These gates are reached from inside async work — a date provider called
// under an `await`, a sink invoked from a receive loop, a teardown seam — so
// the parked thread is usually one of Swift's cooperative pool threads, and
// the pool is only as wide as the machine has cores. CI's `macos-26-arm64`
// runner has 3. The statement that would release the gate is itself async work
// needing a thread from that same pool, so once as many gates are parked as
// the pool is wide, nothing can reach a `signal()` and the whole test process
// wedges — permanently, and invisibly.
//
// That is not hypothetical: it turned `main` red. All ~4050 tests run in one
// process with no concurrency cap, seven suites held unbounded gates, and on
// the 3-vCPU runner all seven parked and none finished. The job died on its
// 30-minute `timeout-minutes` after ~23 minutes of total silence, with zero
// test failures reported. No per-test `.timeLimit` fired either: a blocked
// thread is exactly where cooperative cancellation cannot reach.
//
// A bounded wait cannot prevent the starvation, but it converts it from an
// anonymous job timeout into a named failing test — the same reason
// `test.yml`'s own `timeout-minutes` comment gives for existing. Every gate in
// this repo goes through here so there is one seam to find and one deadline to
// re-derive.

/// How long a bounded gate wait tolerates before it reports itself.
///
/// **Sized to dominate the longest legitimate hold, not to be snappy.** A gate
/// is held for as long as the test's own observation takes, and the outer
/// observations are themselves hang-catchers sized against a loaded runner:
/// the `TmuxControlSupervisor` teardown gates are held across a `waitUntil`
/// bounded by `ciSafeDeadline` (90 s). A gate deadline below that would go red
/// on a merely slow machine, and a spuriously red CI is worse than the bug
/// this bound exists to report. 120 s clears 90 s with margin while staying a
/// small fraction of the 30-minute step budget, so a wedge reports in minutes
/// instead of consuming the job.
///
/// It also stays inside `.clockDriven`'s `.timeLimit(.minutes(4))`, leaving
/// room for the rest of an ordinary test after one full gate timeout — the
/// same invariant `Tests/CLAUDE.md` derives for `ciSafeDeadline` and
/// `waitForSuspension`. Re-derive it together with those two when the test
/// population moves materially.
public enum TestGate {
    public static let deadline: Duration = .seconds(120)
}

/// Thrown-shaped diagnostic for an expired gate.
///
/// `Issue.record(_: some Error)` is the only form that puts this text on the
/// **primary** failure line; `Issue.record(String)` and `#expect(_, "…")`
/// demote it to a trailing `↳` line that CI summaries drop. See
/// `Tests/CLAUDE.md`, "Timeout errors must report observed state".
public struct TestGateTimeout: Error, CustomStringConvertible {
    public let gate: String
    public let after: Duration

    public init(gate: String, after: Duration) {
        self.gate = gate
        self.after = after
    }

    public var description: String {
        """
        test gate "\(gate)" was never signalled within \(after) — the releasing \
        statement never ran. On a narrow runner this is cooperative-pool \
        starvation: too many gates parked at once for any of them to be \
        released. See Tests/TestSupport/BoundedGateSupport.swift.
        """
    }
}

extension DispatchSemaphore {
    /// Waits for this gate, giving up after `timeout` and recording a named
    /// test issue instead of parking the thread forever.
    ///
    /// On a healthy machine the gate is signalled long before the deadline, so
    /// the ordering guarantee the gate provides is exactly what it was with a
    /// bare `wait()` — nothing this call does weakens it. The deadline is a
    /// hang-catcher: it asserts nothing and costs a passing run nothing.
    ///
    /// - Parameters:
    ///   - name: What is being held, in enough detail to identify the site
    ///     from a CI log alone.
    ///   - timeout: Defaults to ``TestGate/deadline``; override only with a
    ///     reason.
    /// - Returns: `true` if the gate was signalled, `false` if it expired.
    ///   Ignorable — the recorded issue is the report — but returned so a
    ///   caller that can act on the distinction may.
    ///
    /// Note: a gate reached from a plain dispatch queue or `Thread` has no
    /// task-local test context, so its issue may be reported against the run
    /// rather than attributed to one test. The process unwedging is the point;
    /// the test's own downstream assertions then fail with their own names.
    @discardableResult
    public func waitForGate(
        _ name: String,
        timeout: Duration = TestGate.deadline,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Bool {
        let seconds = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1e18
        guard wait(timeout: .now() + seconds) == .success else {
            Issue.record(
                TestGateTimeout(gate: name, after: timeout),
                sourceLocation: sourceLocation)
            return false
        }
        return true
    }
}
