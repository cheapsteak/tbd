import Clocks
import Foundation
import Testing

@testable import TBDApp
import TestSupport

/// Tier 1: every timed behaviour is driven by a `TestClock`; no real sleep
/// gates an assertion. The only real sleeping is a short polling cadence used
/// to wait for scheduling to catch up (Tests/CLAUDE.md's "Clock and date
/// seams" — the scheduling handshake may sleep in real time even though the
/// behaviour under test never does).
///
/// `.serialized` for cheap isolation between tests that each mint their own
/// `TestClock` + queue; not required for correctness, matches this
/// repo's convention for small clock-driven suites (`AppearanceDebounceTests`).
@Suite("OutgoingInputQueue", .clockDriven, .serialized)
struct OutgoingInputQueueTests {
    /// Records every chunk `OutgoingInputQueue` decided to write, in the
    /// order `write` was actually invoked (not the order it was enqueued —
    /// that distinction is exactly what these tests are checking).
    private actor WriteRecorder {
        private(set) var writes: [Data] = []
        /// Optional per-payload delay, keyed by the payload's UTF-8 string.
        /// Used by the ordering test to prove the consumer is genuinely
        /// SEQUENTIAL: if events were dispatched concurrently instead, a
        /// later chunk with a shorter delay could finish (and record) before
        /// an earlier chunk with a longer one.
        private var delays: [String: Duration] = [:]

        func setDelay(_ delay: Duration, forKey key: String) {
            delays[key] = delay
        }

        func write(_ data: Data) async {
            if let key = String(data: data, encoding: .utf8), let delay = delays[key] {
                // Real (bounded, short) delay standing in for slow I/O in a
                // mutation-discriminating test; not the behaviour under
                // test's own timing, so a `TestClock` does not apply here
                // (see suite doc). `no_raw_task_sleep` does not cover
                // `Tests/` (Tests/CLAUDE.md, assertion-hygiene rule 3).
                try? await Task.sleep(for: delay)
            }
            writes.append(data)
        }
    }

    /// Bounded real-time poll for `queue.pendingInjectionCountForTesting`.
    /// Needed because creating `Task { await queue.enqueueInjection(_:) } }`
    /// only SCHEDULES that call — it does not run synchronously — so a test
    /// that wants to observe "the injection is now held" before proceeding
    /// must wait for the scheduler, not assume it already happened.
    private func waitForPendingInjectionCount(
        _ expected: Int, on queue: OutgoingInputQueue,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while await queue.pendingInjectionCountForTesting != expected {
            if ContinuousClock.now > deadline {
                Issue.record(
                    "timed out waiting for pendingInjectionCountForTesting == \(expected)",
                    sourceLocation: sourceLocation)
                return
            }
            // Bounded scheduling-handshake poll, not the behaviour under
            // test — see suite doc + Tests/CLAUDE.md assertion-hygiene rule 3.
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("An injection arriving mid-paste is held until the paste closes")
    func injectionHeldUntilPasteCloses() async {
        let recorder = WriteRecorder()
        // A long bound: this test proves the paste-close path releases the
        // injection, not the timeout — so the timeout must never fire. A
        // `TestClock` that is NEVER advanced makes that structural: if the
        // implementation were buggy and relied on the bound instead of
        // `endUserPaste()`, the awaited `enqueueInjection` call below would
        // simply hang, and the suite's `.clockDriven` time limit would fail
        // the test with a clear diagnostic rather than a false pass.
        let clock = TestClock()
        let queue = OutgoingInputQueue(pasteHoldBound: .seconds(999), clock: clock) { data in
            await recorder.write(data)
        }

        queue.beginUserPaste()
        let injection = Task { await queue.enqueueInjection(Data("INJECT".utf8)) }
        await waitForPendingInjectionCount(1, on: queue)

        // Nothing should have been written while the paste is still open.
        let writesWhileOpen = await recorder.writes
        #expect(writesWhileOpen.isEmpty)

        queue.endUserPaste()

        let wasWritten = await injection.value
        #expect(wasWritten == true)
        let writesAfterClose = await recorder.writes
        #expect(writesAfterClose == [Data("INJECT".utf8)])
    }

    @Test("An injection arriving outside a paste goes straight out")
    func injectionOutsidePasteGoesStraightOut() async {
        let recorder = WriteRecorder()
        let clock = TestClock()
        let queue = OutgoingInputQueue(pasteHoldBound: .seconds(2), clock: clock) { data in
            await recorder.write(data)
        }

        // No `beginUserPaste()` at all — the queue starts with no paste open.
        let wasWritten = await queue.enqueueInjection(Data("INJECT".utf8))

        #expect(wasWritten == true)
        let writes = await recorder.writes
        #expect(writes == [Data("INJECT".utf8)])
    }

    @Test("Ordering within each stream is preserved")
    func orderingWithinEachStreamPreserved() async {
        let recorder = WriteRecorder()
        // Reverse-order delays: chunk "0" waits longest, the last chunk waits
        // (almost) no time. If the consumer dispatched writes CONCURRENTLY
        // instead of one at a time, the short-delay late chunks would finish
        // — and record — before the long-delay early ones, and the recorded
        // order would come back reversed rather than input order.
        let chunkCount = 6
        for index in 0..<chunkCount {
            await recorder.setDelay(.milliseconds(Double(chunkCount - index) * 8), forKey: String(index))
        }
        let clock = TestClock()
        let queue = OutgoingInputQueue(pasteHoldBound: .seconds(2), clock: clock) { data in
            await recorder.write(data)
        }

        let expected = (0..<chunkCount).map { Data(String($0).utf8) }
        for chunk in expected {
            queue.enqueueUserBytes(chunk)
        }

        // Bounded real-time wait for all `chunkCount` writes to land — this
        // is the scheduling handshake, not the property under test (which is
        // the ORDER, asserted below).
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while await recorder.writes.count < chunkCount {
            if ContinuousClock.now > deadline {
                Issue.record("timed out waiting for all \(chunkCount) writes to land")
                break
            }
            try? await Task.sleep(for: .milliseconds(5))
        }

        let writes = await recorder.writes
        #expect(writes == expected)
    }

    @Test("A paste that never closes does not strand an injection forever")
    func unclosedPasteDoesNotStrandInjectionForever() async {
        let recorder = WriteRecorder()
        let bound = Duration.seconds(5)
        let clock = TestClock()
        let queue = OutgoingInputQueue(pasteHoldBound: bound, clock: clock) { data in
            await recorder.write(data)
        }

        queue.beginUserPaste()
        let injection = Task { await queue.enqueueInjection(Data("INJECT".utf8)) }
        await waitForPendingInjectionCount(1, on: queue)

        // The paste is deliberately NEVER closed — `endUserPaste()` is never
        // called in this test. Advancing virtual time past the bound is the
        // only thing that can release the injection.
        await clock.advanceWhenSuspended(by: bound)

        let wasWritten = await injection.value
        #expect(wasWritten == true)
        let writes = await recorder.writes
        #expect(writes == [Data("INJECT".utf8)])
    }
}
