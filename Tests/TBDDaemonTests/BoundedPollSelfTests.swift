import Foundation
import TestSupport
import Testing

/// Tier 1 — the contract of `TestSupport/BoundedPoll.swift`, which is now the
/// only bounded-poll loop in the suite. Six helpers had written that loop
/// independently and between them carried two defects: a verdict taken from the
/// loop's exit rather than from a fresh read, and a `try?` that turned
/// cancellation into a busy-spin. Consolidating them means those defects can
/// only be reintroduced here, so this is where they are pinned.
///
/// In-process state only: no filesystem, no subprocess, no `~/tbd`, and no
/// wall-clock assertions — every test below is deterministic in *ordering*
/// rather than in timing, which is the property the helpers it backs exist to
/// restore.
@Suite("Bounded poll self-tests")
struct BoundedPollSelfTests {
    /// Counts condition evaluations, so a test can assert on **effort** instead
    /// of elapsed time. A "returns promptly" assertion would itself be the kind
    /// of wall-clock deadline this file exists to stop trusting.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0

        func bump() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    /// The defect, in its limiting and only deterministic form: a zero budget
    /// means the loop body never runs, so a verdict taken from the loop's exit
    /// has looked at nothing at all. In the field the gap was the same shape and
    /// merely larger — one sample at the top, then a resumption that landed
    /// after a 30 s deadline.
    @Test("a condition that already holds is satisfied even on an expired budget")
    func alreadyTrueIsSatisfiedOnAnExpiredBudget() async {
        let outcome = await pollUntilTrue(timeout: .zero) { true }
        #expect(outcome == .satisfied)
    }

    /// The mutation check the test above needs: a poll that always reported
    /// `.satisfied` would pass it and silently delete every hang guard built on
    /// this primitive.
    @Test("a condition that never holds times out")
    func neverTrueTimesOut() async {
        let outcome = await pollUntilTrue(timeout: .zero) { false }
        #expect(outcome == .timedOut)
    }

    /// The condition is read at least once even when the budget is already
    /// gone — otherwise the case above would pass for the wrong reason, by
    /// never consulting the caller at all.
    @Test("the condition is read even when the budget is already spent")
    func conditionIsReadOnAnExpiredBudget() async {
        let reads = Counter()
        _ = await pollUntilTrue(timeout: .zero) {
            reads.bump()
            return false
        }
        #expect(reads.count >= 1, "an unread condition cannot support any verdict")
    }

    /// Cancellation is not expiry, and `try?` around the poll sleep cannot tell
    /// them apart: a cancelled `Task.sleep` throws instantly, so an unguarded
    /// loop stops suspending and spins on `ContinuousClock.now` for the rest of
    /// its budget — pinning a cooperative thread in a process where thousands of
    /// tests are queued behind it. Measured against the unguarded loop:
    /// 33,754,162 evaluations in 30 s. Guarded: two.
    @Test("a cancelled poll stops spinning and reports cancellation, not expiry")
    func cancelledPollStopsSpinning() async {
        let reads = Counter()
        let task = Task { () -> PollOutcome in
            // Enter already cancelled, so the loop cannot race the `cancel()`.
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
            // A budget long enough that expiry cannot be what ends this.
            return await pollUntilTrue(timeout: .seconds(30)) {
                reads.bump()
                return false
            }
        }
        task.cancel()
        let outcome = await task.value

        #expect(outcome == .cancelled,
                "a cancelled wait must not be reported as a missed deadline")
        #expect(reads.count <= 2,
                """
                a cancelled poll must stop yielding rather than busy-spin its \
                budget away — evaluated \(reads.count) time(s)
                """)
    }

    /// Evaluation order, and it is load-bearing rather than incidental: the
    /// condition is read **before** cancellation is consulted, so work that
    /// completed at the same moment the task was cancelled is still honoured.
    /// Reversing the two would discard a real success and report `.cancelled`.
    @Test("a condition true at cancellation time still wins")
    func conditionBeatsCancellation() async {
        let task = Task { () -> PollOutcome in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
            return await pollUntilTrue(timeout: .seconds(30)) { true }
        }
        task.cancel()
        #expect(await task.value == .satisfied)
    }
}
