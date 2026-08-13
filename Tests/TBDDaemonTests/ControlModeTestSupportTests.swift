import Foundation
import Testing

@testable import TBDDaemonLib

/// Tier 1: the control-mode suites' own harness, driven directly.
///
/// Two properties that every suite consuming `ControlModeTestSupport` depends
/// on, and that nothing else would notice regressing — a harness defect shows
/// up as a *sibling* suite flaking under load, weeks later and attributed to
/// production. Both tests below are deterministic and take milliseconds.
@Suite("Control-mode test support")
struct ControlModeTestSupportTests {

    /// A state box whose "event" lands the moment the diagnostic reads it —
    /// the exact race that produced `timed out waiting for 2 health events —
    /// observed 2`, made deterministic.
    private final class ArrivesWhenObserved: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var reads = 0

        /// Reading the observed state IS the arrival, so the value the
        /// diagnostic would print always disagrees with the verdict that was
        /// taken before it.
        func read() -> Int {
            lock.lock()
            defer { lock.unlock() }
            reads += 1
            count = 1
            return count
        }

        var current: Int { lock.lock(); defer { lock.unlock() }; return count }
        var observedReads: Int { lock.lock(); defer { lock.unlock() }; return reads }
    }

    @Test("waitFor's diagnostic can never contradict the verdict that produced it")
    func waitForDiagnosticIsConsistentWithItsVerdict() async throws {
        let state = ArrivesWhenObserved()

        // Deadline in the past by construction: the loop body never runs, so
        // this exercises exactly the post-deadline decision path.
        let met = try await waitFor("1 event", deadline: .zero,
                                    observed: { "\(state.read())" }) {
            state.current >= 1
        }

        // The event arrived while the diagnostic was being composed, so this is
        // a PASS. Under the pre-fix ordering the timeout was already recorded by
        // then and the run carried the self-contradictory "timed out waiting for
        // 1 event — observed 1" (assertion-hygiene rule 4's
        // `expected: 6150, actual: 6150` shape).
        #expect(met, "an event that landed during the diagnostic must be a pass, not a contradiction")
        #expect(state.observedReads == 1, "the observed state must be read exactly once, on the failing path")
    }

    /// `finish()` is a happens-before, not a best effort: when it returns, every
    /// block enqueued before it has reached the correlator. Callers depend on
    /// that because they routinely reach `finish()` with replies in flight — a
    /// wait that returns on a stream WRITE returns before that write's reply is
    /// handled — and a `send(…)`-shaped command whose reply is never handed over
    /// leaves a `withCheckedThrowingContinuation` suspended for the rest of the
    /// run.
    ///
    /// The count is large enough to guarantee a real backlog at the call
    /// (measured: 2,395–5,312 blocks still queued), so this is a drain
    /// assertion rather than a formality.
    @Test("ReplyFeed.finish() delivers every enqueued reply, backlog and all")
    func finishDeliversBufferedReplies() async throws {
        let (client, _, feed) = makeRespondingClient()
        let blocks = 20_000
        for _ in 0..<blocks {
            feed.enqueue(.commandSucceeded(number: 0, fromClient: true, lines: []))
        }

        await feed.finish()

        #expect(feed.delivered == blocks,
                "finish() must not return before the buffer is drained (delivered \(feed.delivered) of \(blocks))")
        // The feed holds the client weakly; keeping it alive here is what makes
        // the deliveries above go through a real correlator.
        withExtendedLifetime(client) {}
    }
}
