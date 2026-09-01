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
// Gates reached from a dedicated `Thread` never had the problem and need
// nothing: `FDVendingServer` delivers to its sinks from a dedicated receive
// thread. `WorktreeDeletionQueue` and `TmuxControlSupervisor` reach their gates
// from dispatch queues, which keeps them off the cooperative pool but does NOT
// give them dedicated threads. Their small fixed counts keep a plain bounded
// `waitForGate`; the executor below cannot share libdispatch workers with them,
// because many simultaneous gate tasks can consume every such worker.
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
/// Every enqueued task job gets a real `Thread`, not a concurrent dispatch
/// queue. Dispatch queues do not own threads; enough blocking jobs on one can
/// consume libdispatch's workers and starve unrelated queue work. A task job is
/// one synchronous continuation: its thread exits when that continuation
/// completes or suspends, and the next continuation gets another thread. Gate
/// tasks follow finite test-only RPC paths, so this bounded resumption churn is
/// preferable to sharing either of the process-wide worker pools they test.
public final class GateExecutor: TaskExecutor, @unchecked Sendable {
    /// One per process. The executor holds no state; the shared instance
    /// exists so `gateHoldingTask` does not mint a queue per call site.
    public static let shared = GateExecutor()

    private init() {}

    public func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        let thread = Thread {
            job.runSynchronously(on: executor)
        }
        thread.name = "com.tbd.tests.gate-executor"
        thread.qualityOfService = .userInitiated
        thread.start()
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

/// The handshake budget a bounded wait gets in a saturated pass.
///
/// One literal, two typed accessors, because the value is consumed as a
/// `Duration` by the poll-loop helpers and as a `TimeInterval` by the
/// `Date`-arithmetic ones. It lives here, next to ``TestGate/deadline``, for
/// two reasons: it is the value that deadline must dominate — so a change to
/// either that is not checked against the other is a bug, and adjacency is
/// what makes that checkable — and it is reachable from both
/// `Tests/TBDDaemonTests` and `Tests/TBDDaemonLiveTests`, which is what keeps
/// `ciSafeDeadline`, `TmuxControlSupervisorTeardownTests.teardownWaitDeadline`
/// and `ProviderEventsSupervisorTests.saturatedWaitDeadline` one constant
/// rather than three that can drift apart unnoticed.
///
/// The derivation itself — why 90 s, and what re-derives it — stays with
/// `ciSafeDeadline` in `Tests/TBDDaemonTests/ControlModeTestSupport.swift`,
/// which is where the reasoning about population and contention lives.
public enum TestDeadlines {
    /// 90 s, as a `TimeInterval` for `Date`-based waits.
    public static let saturatedPassSeconds: TimeInterval = 90

    /// The same 90 s, as a `Duration` for poll-loop waits.
    public static let saturatedPass: Duration = .seconds(saturatedPassSeconds)
}

/// Carries a bounded wait's OBSERVED state on the primary failure line
/// (assertion-hygiene rule 4: `#expect(cond, "…")` and `Issue.record(String)`
/// both demote the message to a trailing `↳` line that CI summaries drop; only
/// `Issue.record(_: some Error)` survives). `observed` is nil when the caller
/// supplied no reporter — the text then matches the no-reporter wording exactly.
public struct BoundedWaitTimeout: Error, CustomStringConvertible {
    public let what: String
    public let observed: String?
    public let deadline: Duration

    public init(what: String, observed: String?, deadline: Duration) {
        self.what = what
        self.observed = observed
        self.deadline = deadline
    }

    public var description: String {
        let seen = observed.map { " — observed \($0)" } ?? ""
        return "timed out waiting for \(what)\(seen) after polling up to \(deadline)"
    }
}

/// Poll every 10 ms until `condition`, recording an Issue at the caller's
/// source location after `deadline`. A final post-deadline re-check absorbs
/// sleep slices that overshoot the deadline AFTER the condition became true
/// (observed live as `timedOut(got: N, want: N)` at loadavg ~40).
///
/// It lives here, beside ``TestDeadlines`` whose value it defaults to, for the
/// same reason that constant does: `Tests/TBDDaemonTests` and
/// `Tests/TBDDaemonLiveTests` both need it, and neither can import the other.
///
/// `observed` renders what the waiter actually saw at the moment it gave up; it
/// is evaluated only on the failing path. Supply it for any wait whose
/// condition is uninformative on its own ("2 health events" says nothing about
/// how many arrived).
///
/// **The diagnostic reports the state that decided the failure, not the state
/// at report time** (assertion-hygiene rule 4 — the
/// `fileBytesMismatch(expected: 6150, actual: 6150)` shape). `observed` and
/// `condition` are two closures over the same growing state, so reading
/// `observed` *after* the last `condition()` lets an event that lands in the
/// gap print the self-contradictory `timed out waiting for 2 health events —
/// observed 2`. The order below closes that: `observed` is captured first, and
/// the condition is then re-checked once more, so anything that arrived while
/// the diagnostic was being composed makes this a PASS rather than a
/// contradictory failure. The counters these waits watch are monotone, so a
/// condition that is false after the capture was false at the capture too —
/// the reported state and the verdict are consistent by construction.
///
/// Returns whether the condition was met (false on timeout) so callers that
/// index into results afterwards can abort via `#require` instead of trapping
/// out of range; count/equality-checking callers may ignore the result.
@discardableResult
public func waitFor(
    _ what: String, deadline: Duration = TestDeadlines.saturatedPass,
    observed: (@Sendable () async -> String)? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () async -> Bool
) async throws -> Bool {
    let end = ContinuousClock.now + deadline
    while ContinuousClock.now < end {
        if await condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    if await condition() { return true }
    // Capture BEFORE deciding to fail, then re-check: see the doc comment.
    let seen = await observed?()
    if await condition() { return true }
    Issue.record(
        BoundedWaitTimeout(what: what, observed: seen, deadline: deadline),
        sourceLocation: sourceLocation)
    return false
}

/// How long a bounded gate wait tolerates before it reports itself.
///
/// **Sized to dominate the longest legitimate hold, not to be snappy.** A gate
/// is held for as long as the test's own observation takes, and the outer
/// observations are themselves hang-catchers sized against a loaded runner:
/// the `TmuxControlSupervisor` teardown gates are held across a `waitUntil`
/// bounded by that suite's own `teardownWaitDeadline` (90 s, the value
/// `ciSafeDeadline` carries). A gate deadline below that would go red
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
