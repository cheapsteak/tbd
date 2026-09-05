import Foundation
import TestSupport
import Testing

/// Tier 1. Pins the one unmeasured claim the `ShutdownLatch(executor:)` fix
/// rests on, so that the claim cannot quietly become false.
///
/// The rationale — written into `Tests/CLAUDE.md`, in the section
/// "Thread-blocking gates run off the cooperative pool" — is that **a
/// `Task.detached` runs at default priority, behind every higher-priority test
/// task the pass keeps runnable**. That is what explains CI measuring 0 of 8 detached callers
/// back after 90 s while the test's own polling task ran on time, and it is why
/// the remedy was to inject an executor into the callee rather than to raise a
/// bound. The claim was reasoned, not measured.
///
/// **A red here is a defect in that documentation, not in this test.** If the
/// observed relationship is not the documented one, the fix is to rewrite the
/// rationale there around the numbers this failure prints — and then to
/// re-examine whether executor injection was the right remedy — never to relax
/// the assertion until it passes.
///
/// **Why the probes report through a continuation rather than through
/// `await task.value`.** Awaiting a task is precisely the dependency the
/// runtime escalates on: a lower-priority task awaited by a higher-priority one
/// is boosted to the awaiter's priority, so a value read *inside* the awaited
/// body can never come back lower than the awaiter's — the assertion below
/// could not pass on any scheduler, and its red would prove nothing. So each
/// probe records `Task.currentPriority` as its **first** statement into a
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
/// The second test is here so the file is not one big hypothesis: it pins a
/// relationship that is certainly true (`Task { }` inherits its creator's
/// priority), measured through the same apparatus, so an apparatus that has
/// silently stopped measuring anything cannot look identical to a working one.
@Suite("Detached-task priority rationale", .fastPassBounded)
struct DetachedTaskPriorityRationaleTests {

    /// Every priority the probe observed, on the primary failure line.
    ///
    /// Thrown rather than `#expect`ed for the usual reason (`Tests/CLAUDE.md`
    /// assertion-hygiene rule 4): only `Issue.record(_: some Error)`, which a
    /// thrown error becomes, survives into a CI summary, and here the numbers
    /// *are* the finding — a bare `condition(value → false)` would tell us
    /// nothing about what the true relationship is.
    private struct DetachedPriorityNotBelowBody: Error, CustomStringConvertible {
        let body: TaskPriority
        let child: TaskPriority
        let detached: TaskPriority
        let gateHolding: TaskPriority

        var description: String {
            """
            a Task.detached did NOT run below the test body that created it. \
            Observed: test body \(renderPriority(body)); Task { } \(renderPriority(child)); \
            Task.detached { } \(renderPriority(detached)); \
            gateHoldingTask { } \(renderPriority(gateHolding)). \
            The rationale for ShutdownLatch(executor:) — in Tests/CLAUDE.md under \
            "Thread-blocking gates run off the cooperative pool" — asserts detached < body \
            and must be corrected around these numbers rather than this test being relaxed. \
            Each reading is the probe's first statement, reported over a continuation rather \
            than awaited, so none of them can be an escalated value.
            """
        }
    }

    /// The control measurement: a `Task { }` must run at its creator's priority.
    private struct ChildDidNotInheritBodyPriority: Error, CustomStringConvertible {
        let body: TaskPriority
        let child: TaskPriority

        var description: String {
            """
            a Task { } did NOT inherit the priority of the test body that created it. \
            Observed: test body \(renderPriority(body)); Task { } \(renderPriority(child)). \
            This is the control for the detached-priority measurement in this file: \
            unstructured child tasks inherit their creating task's priority, so a \
            mismatch here means the apparatus — a first-statement read reported over a \
            continuation — is measuring something other than creation priority, and the \
            detached reading next to it cannot be trusted either.
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

    @Test("a Task.detached runs below the test task that created it")
    func detachedRunsBelowTheCreatingTestTask() async throws {
        let body = Task.currentPriority
        let child = await observedPriority { report in Task { report() } }
        let detached = await observedPriority { report in Task.detached { report() } }
        let gateHolding = await observedPriority { report in _ = gateHoldingTask { report() } }

        guard detached.rawValue < body.rawValue else {
            throw DetachedPriorityNotBelowBody(
                body: body, child: child, detached: detached, gateHolding: gateHolding)
        }
    }

    @Test("a Task { } inherits the priority of the test task that created it")
    func childInheritsTheCreatingTestTaskPriority() async throws {
        let body = Task.currentPriority
        let child = await observedPriority { report in Task { report() } }

        guard child == body else {
            throw ChildDidNotInheritBodyPriority(body: body, child: child)
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
