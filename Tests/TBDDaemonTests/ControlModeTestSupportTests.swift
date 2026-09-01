import Foundation
import TestSupport
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
    /// **The backlog is built by real commands, not by hand-fed reply blocks.**
    /// `TmuxControlCommandClient.complete` pops `pending.removeFirst()`, so a
    /// reply arriving against an EMPTY queue is a protocol violation: it takes
    /// the teardown branch (`closed = true`, `onFatalError()`, one `logger.error`
    /// each) and never correlates with anything. Enqueuing 20,000 bare
    /// `.commandSucceeded` blocks would exercise only that desync path — a drain
    /// assertion still, but with the correlator's actual job never once
    /// performed, and 20,000 error-level log entries emitted per run. Writing
    /// the commands first is what makes the sentence above true: each reply pops
    /// its own command, in order, and every completion fires with `.success`.
    ///
    /// One `sendList` is deliberate rather than 20,000 `send(…)` calls: it
    /// appends all 20,000 to `pending` and writes them as ONE stream write, and
    /// `makeRespondingClient`'s `writeLine` splits that write back into 20,000
    /// ordered replies — so the whole backlog is yielded inside a single actor
    /// hop that `handle` cannot interleave with. That is what guarantees a real
    /// backlog at the `finish()` call rather than a hoped-for one, and it shows
    /// in the measurement: all 20,000 blocks are still queued at the call, on
    /// every run (3/3 measured), where hand-fed blocks left an
    /// already-partly-drained 2,395–5,312. Completions are plain closures, so
    /// nothing here depends on a continuation resuming. The whole test takes
    /// ~0.2 s.
    @Test("ReplyFeed.finish() delivers every enqueued reply, backlog and all")
    func finishDeliversBufferedReplies() async throws {
        let (client, _, feed) = makeRespondingClient()
        let blocks = 20_000
        let succeeded = SuccessCounter()
        await client.sendList((0..<blocks).map { index in
            TmuxCommand(text: "display-message -p drain-\(index)") { result in
                if case .success = result { succeeded.increment() }
            }
        })

        // Measured before the drain gets a turn: this is the backlog the
        // assertion below is actually about. Zero would make `delivered ==
        // blocks` true by arithmetic rather than by draining, and the
        // delete-`await drain.value` mutation would stop reddening.
        let queuedAtFinish = blocks - feed.delivered
        await feed.finish()

        #expect(queuedAtFinish > 0,
                "no backlog at the call — this test would pass without draining anything")
        #expect(feed.delivered == blocks,
                "finish() must not return before the buffer is drained (delivered \(feed.delivered) of \(blocks), backlog at the call \(queuedAtFinish))")
        // Every reply popped its own pending command and completed it: had they
        // hit `complete`'s empty-queue teardown branch instead, no completion
        // would have fired at all.
        #expect(succeeded.count == blocks,
                "replies must correlate to commands in order (\(succeeded.count) of \(blocks) completed with success)")
        // The feed holds the client weakly; keeping it alive here is what makes
        // the deliveries above go through a real correlator.
        withExtendedLifetime(client) {}
    }

    /// Thread-safe tally of command completions that resolved successfully.
    private final class SuccessCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        func increment() { lock.lock(); _count += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    }
}
