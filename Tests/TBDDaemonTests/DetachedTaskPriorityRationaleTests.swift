import Foundation
import TestSupport
import Testing

/// Tier 1. Pins the one unmeasured claim the `ShutdownLatch(executor:)` fix
/// rests on, so that the claim cannot quietly become false.
///
/// The rationale — written into `Tests/CLAUDE.md` ("Thread-blocking gates run
/// off the cooperative pool") and into `gateHoldingTask`'s doc comment in
/// `Tests/TestSupport/BoundedGateSupport.swift` — is that **a `Task.detached`
/// runs at default priority, behind every higher-priority test task the pass
/// keeps runnable**. That is what explains CI measuring 0 of 8 detached callers
/// back after 90 s while the test's own polling task ran on time, and it is why
/// the remedy was to inject an executor into the callee rather than to raise a
/// bound. The claim was reasoned, not measured.
///
/// **A red here is a defect in that documentation, not in this test.** If the
/// observed relationship is not the documented one, the fix is to rewrite the
/// rationale in both places around the numbers this failure prints — and then
/// to re-examine whether executor injection was the right remedy — never to
/// relax the assertion until it passes.
///
/// No sleeps and no polls: each probe is one task creation and one `await` on
/// its value.
///
/// **One caveat the diagnostic names too, because it changes what a red
/// means.** Awaiting a lower-priority task escalates it, so the value read
/// inside a probe could in principle be an escalated one rather than the
/// priority the task was created at. That would make an equal-priority
/// observation an artefact of the measurement rather than a refutation of the
/// claim. It cannot make a *lower* observation spurious, which is the direction
/// the assertion runs in.
@Suite("Detached-task priority rationale")
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
            Observed: test body \(Self.render(body)); Task { } \(Self.render(child)); \
            Task.detached { } \(Self.render(detached)); \
            gateHoldingTask { } \(Self.render(gateHolding)). \
            The rationale for ShutdownLatch(executor:) — in Tests/CLAUDE.md under \
            "Thread-blocking gates run off the cooperative pool" and in gateHoldingTask's \
            doc comment in Tests/TestSupport/BoundedGateSupport.swift — asserts detached < body \
            and must be corrected around these numbers rather than this test being relaxed. \
            Note before concluding: awaiting a task escalates its priority, so an EQUAL \
            reading may be the measurement rather than the scheduler.
            """
        }

        static func render(_ priority: TaskPriority) -> String {
            "\(name(priority)) (rawValue \(priority.rawValue))"
        }

        /// `TaskPriority` prints as its raw value alone, which is unreadable in
        /// a failure line.
        static func name(_ priority: TaskPriority) -> String {
            switch priority {
            case .high: return "high/userInitiated"
            case .medium: return "medium"
            case .low: return "low/utility"
            case .background: return "background"
            default: return "unnamed"
            }
        }
    }

    @Test("a Task.detached runs below the test task that created it")
    func detachedRunsBelowTheCreatingTestTask() async throws {
        let body = Task.currentPriority
        let child = await Task { Task.currentPriority }.value
        let detached = await Task.detached { Task.currentPriority }.value
        let gateHolding = await gateHoldingTask { Task.currentPriority }.value

        guard detached.rawValue < body.rawValue else {
            throw DetachedPriorityNotBelowBody(
                body: body, child: child, detached: detached, gateHolding: gateHolding)
        }
    }
}
