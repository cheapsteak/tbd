import Foundation
import TestSupport
import Testing

/// Tier 1. Pins the fact the fast pass's wait rules are derived from: **every
/// task in the pass runs at one priority**, so nothing in a test pass is ever
/// queued behind higher-priority work.
///
/// A test body, an unstructured `Task { }`, a `Task.detached { }` and a
/// `gateHoldingTask { }` all read the same `Task.currentPriority` — measured on
/// the 3-core CI runner, all four read medium (21).
///
/// **Why that fact is load-bearing.** With priorities equal, the cooperative
/// pool's queue is FIFO among everything the pass keeps runnable, and a
/// handshake that needs *k* suspension hops costs *k* × the per-hop latency of
/// a saturated pass — which is tens of seconds per hop, not milliseconds. That
/// is the mechanism `Tests/CLAUDE.md` derives its bounds from, in the sections
/// "Population is the scheduler, and it is a moving target" and
/// "Thread-blocking gates run off the cooperative pool": a bound cannot buy a
/// hop that never gets its turn, so the remedy for a starving handshake is to
/// take its hops off the shared queue (inject an executor into the callee,
/// `ShutdownLatch(executor:)`) rather than to raise a deadline or to reason
/// about priority at all.
///
/// **A red here means that derivation must be revisited, not that this test
/// should be relaxed.** If the four readings ever differ, priority ordering is
/// back in play in the pass, and the reasoning in `Tests/CLAUDE.md` — which
/// explains starvation purely by hop count × FIFO latency — has to be rewritten
/// around the numbers this failure prints before any bound is touched.
///
/// **Why the probes report through a continuation rather than through
/// `await task.value`.** Awaiting a task is precisely the dependency the
/// runtime escalates on: a lower-priority task awaited by a higher-priority one
/// is boosted to the awaiter's priority, so a value read *inside* the awaited
/// body can never come back lower than the awaiter's — an equality this
/// apparatus reported would be manufactured rather than observed. So each probe
/// records `Task.currentPriority` as its **first** statement into a
/// lock-guarded box and resumes a continuation the test is parked on. A
/// continuation is not a task dependency, so nothing is escalated, and the
/// reading is the priority the task was actually created at. The probe is
/// subject to the pass's scheduling latency like every other hop — the pool is
/// saturated by the other ~5,000 tests of the pass, not by this test, and a
/// starved probe would sit on the continuation for as long as that takes. That
/// is why the suite carries the shared hang guard: a wedge here reports as a
/// named suite rather than as the step's `timeout-minutes`.
///
/// No sleeps and no polls: each probe is one task creation and one continuation
/// resume.
///
/// The second test is the apparatus control, and it is the discriminating half:
/// an apparatus that had silently stopped measuring — reporting a constant, or
/// reporting the *caller's* priority instead of the probe's — would make the
/// parity above green for the wrong reason. So it reads a task created at an
/// explicitly higher priority and requires that reading to differ from the test
/// body's. Parity is a finding only if this apparatus can see a difference when
/// there is one.
@Suite("Task priority parity", .fastPassBounded)
struct TaskPriorityParityTests {

    /// Every priority the probe observed, on the primary failure line.
    ///
    /// Thrown rather than `#expect`ed for the usual reason (`Tests/CLAUDE.md`
    /// assertion-hygiene rule 4): only `Issue.record(_: some Error)`, which a
    /// thrown error becomes, survives into a CI summary, and here the numbers
    /// *are* the finding — a bare `condition(value → false)` would tell us
    /// nothing about which reading moved or where it moved to.
    private struct TaskPrioritiesDiffered: Error, CustomStringConvertible {
        let body: TaskPriority
        let child: TaskPriority
        let detached: TaskPriority
        let gateHolding: TaskPriority

        var description: String {
            """
            the tasks of a test pass did NOT all run at one priority. \
            Observed: test body \(renderPriority(body)); Task { } \(renderPriority(child)); \
            Task.detached { } \(renderPriority(detached)); \
            gateHoldingTask { } \(renderPriority(gateHolding)). \
            The wait rules in Tests/CLAUDE.md — "Population is the scheduler" and \
            "Thread-blocking gates run off the cooperative pool" — explain a starving \
            handshake as hop count times FIFO latency, which holds only while these are \
            equal; that derivation must be revisited around these numbers before any \
            bound is changed. Each reading is the probe's first statement, reported over \
            a continuation rather than awaited, so none of them can be an escalated value.
            """
        }
    }

    /// The control measurement: the apparatus must be able to see a difference.
    private struct ProbeCannotDistinguishPriorities: Error, CustomStringConvertible {
        let body: TaskPriority
        let elevated: TaskPriority

        var description: String {
            """
            a Task created at an explicitly higher priority did NOT read higher than the \
            test body that created it. Observed: test body \(renderPriority(body)); \
            Task(priority: .high) { } \(renderPriority(elevated)). \
            This is the control for the parity measurement in this file: the apparatus — a \
            first-statement read reported over a continuation — must report the probe's own \
            priority. If it cannot see a requested difference, it is reporting a constant \
            or the caller's value, and the parity next to it is an artefact rather than a \
            finding. The one other way to read this line: the pass itself now runs above \
            medium, in which case the parity test's four numbers are the ones to read.
            """
        }
    }

    // MARK: - Apparatus

    /// A one-shot rendezvous between a probe task and the parked test body.
    ///
    /// Deliberately a lock-guarded class rather than an actor: the probe must
    /// report from its *first* statement, with no suspension between entering
    /// the task and reading `Task.currentPriority`.
    private final class PriorityProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<TaskPriority, Never>?

        /// Hand over the continuation before the probe task exists, so the
        /// probe can never find the box empty.
        func park(_ continuation: CheckedContinuation<TaskPriority, Never>) {
            lock.lock()
            defer { lock.unlock() }
            self.continuation = continuation
        }

        /// Resume the parked test exactly once; a second call is a no-op.
        func report(_ priority: TaskPriority) {
            lock.lock()
            let parked = continuation
            continuation = nil
            lock.unlock()
            parked?.resume(returning: priority)
        }
    }

    /// The priority observed by a task created by `start`, which is handed the
    /// reporting closure its task body must call as its first statement.
    private func observedPriority(
        startingProbe start: (@escaping @Sendable () -> Void) -> Void
    ) async -> TaskPriority {
        let probe = PriorityProbe()
        return await withCheckedContinuation { continuation in
            probe.park(continuation)
            start { probe.report(Task.currentPriority) }
        }
    }

    // MARK: - Tests

    @Test("a test body, Task { }, Task.detached { } and gateHoldingTask { } all run at one priority")
    func everyTaskOfAPassRunsAtOnePriority() async throws {
        let body = Task.currentPriority
        let child = await observedPriority { report in Task { report() } }
        let detached = await observedPriority { report in Task.detached { report() } }
        let gateHolding = await observedPriority { report in _ = gateHoldingTask { report() } }

        guard child == body, detached == body, gateHolding == body else {
            throw TaskPrioritiesDiffered(
                body: body, child: child, detached: detached, gateHolding: gateHolding)
        }
    }

    @Test("the probe reads the priority a task was created at, so it can tell two apart")
    func probeDistinguishesAnExplicitlyElevatedTask() async throws {
        let body = Task.currentPriority
        let elevated = await observedPriority { report in
            Task(priority: .high) { report() }
        }

        guard elevated.rawValue > body.rawValue else {
            throw ProbeCannotDistinguishPriorities(body: body, elevated: elevated)
        }
    }
}

/// `TaskPriority` prints as its raw value alone, which is unreadable in a
/// failure line.
private func renderPriority(_ priority: TaskPriority) -> String {
    let name: String
    switch priority {
    case .high: name = "high/userInitiated"
    case .medium: name = "medium"
    case .low: name = "low/utility"
    case .background: name = "background"
    default: name = "unnamed"
    }
    return "\(name) (rawValue \(priority.rawValue))"
}
