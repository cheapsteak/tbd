import Dispatch
import Foundation
import Testing

// Thread-blocking gates in tests, and the two things they need to be safe.
//
// Several suites hold a piece of production work still at a chosen instant —
// freeze a date provider on its first call, hold a receive loop mid-loop, hold
// a teardown mid-stop — while the test observes the world around it. The seam
// they reach is a *synchronous* closure, so the only way to hold it is to
// block the thread running it: `DispatchSemaphore.wait()`, released by the
// test.
//
// WHICH THREAD gets blocked is the whole safety question, and it is decided by
// the caller, not by the gate.
//
// ## 1. Never block a cooperative-pool thread — `gateHoldingTask`
//
// A blocked thread is gone until the gate is released. When that thread
// belongs to Swift's cooperative pool the loss is shared: the pool is only as
// wide as the machine has cores (CI's `macos-26-arm64` runner has 3), every
// suspended task in the process needs a thread from it, and the statement that
// would release the gate is itself async work needing one. Park as many gates
// as the pool is wide and no thread can reach any `signal()`; the process
// stops making progress permanently.
//
// That is not hypothetical: it turned `main` red. All ~4050 tests run in one
// process with no concurrency cap, and on the 3-thread runner the pass went
// silent for ~23 minutes and died on the step's 30-minute `timeout-minutes`
// having reported zero test failures. No per-test `.timeLimit` fired either —
// a blocked thread is exactly where cooperative cancellation cannot reach.
//
// Bounding the wait does not fix that. A bounded wait still owns its thread
// for the whole deadline, so the gates stop wedging the process and instead
// starve it: on the first bounded run the four date-seam suites held pool
// threads for their full 120 s while ~43 innocent tests in suites with no gate
// of their own blew their own 90 s and 120 s hang-catchers. The cure is to
// keep the blocking OFF the pool entirely — start the task that will hold a
// gate with `gateHoldingTask`, which pins it (and every default-actor hop it
// makes) to threads these tests own.
//
// Gates reached from a dedicated `Thread` or a `DispatchQueue` never had the
// problem and need nothing: `FDVendingServer` delivers to its sinks from a
// dedicated receive `Thread`, `WorktreeDeletionQueue`'s gate sits on its own
// `drainQueue`, and `TmuxControlSupervisor` runs `stopConnection` on
// `DispatchQueue.global(qos:.utility)` precisely so a blocking stop stays off
// the actor. Those three keep a plain bounded `waitForGate` and no executor.
//
// ## 2. Bound every wait anyway — `waitForGate`
//
// The bound is the safety net under the rule above, not a substitute for it.
// An author who adds a gate and starts it with a plain `Task` gets a named
// failing test naming the gate instead of an anonymous 30-minute job timeout —
// the same reason `test.yml`'s own `timeout-minutes` comment gives for
// existing. Every gate in this repo goes through `waitForGate` so there is one
// seam to find and one deadline to re-derive.

/// Runs jobs on threads the test process owns rather than on Swift's
/// cooperative pool, so a task that blocks inside a gate cannot starve
/// unrelated tests.
///
/// Task executor preference is inherited by child tasks and — per SE-0417 —
/// also carries into *default* actors, so a handler that hops through
/// `RPCRouter`, a store actor and `CodexTranscriptActivityTracker` keeps
/// running here for the whole call. TBD declares no custom `unownedExecutor`
/// anywhere in `Sources/`, so there is no actor along these paths that would
/// pull the job back onto the pool.
///
/// The queue is concurrent: gates are held one per task, and a blocked worker
/// must not stall an unrelated job that happens to be queued behind it.
public final class GateExecutor: TaskExecutor, @unchecked Sendable {
    /// One per process. The executor holds no state; the shared instance
    /// exists so `gateHoldingTask` does not mint a queue per call site.
    public static let shared = GateExecutor()

    private let queue = DispatchQueue(
        label: "com.tbd.tests.gate-executor",
        qos: .userInitiated,
        attributes: .concurrent)

    private init() {}

    public func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}

/// Starts a task that is expected to block on a `waitForGate`, on threads that
/// are not Swift's cooperative pool.
///
/// Use this for the ONE side that gets held. The other side — the work the
/// test runs while the gate is closed, and the `signal()` that releases it —
/// stays on the pool, which is the point: it needs a thread, and this call is
/// what guarantees one is left.
public func gateHoldingTask<Success: Sendable>(
    _ operation: @escaping @Sendable () async -> Success
) -> Task<Success, Never> {
    Task(executorPreference: GateExecutor.shared) { await operation() }
}

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
        statement never ran. If the holding side was started with a plain \
        `Task` rather than `gateHoldingTask`, it blocked a cooperative-pool \
        thread and starved the work that would have released it. See \
        Tests/TestSupport/BoundedGateSupport.swift.
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
