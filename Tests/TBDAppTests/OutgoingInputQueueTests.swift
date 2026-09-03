import Clocks
import Foundation
import SwiftTerm
import Testing

@testable import TBDApp
import TestSupport

/// Tier 1: every timed behaviour is driven by a `TestClock`; no real sleep
/// gates an assertion. The queue is `@MainActor` and synchronous on the user
/// side, so a keystroke, a paste marker and their writes are all observable in
/// the turn they happen in — the only real sleeping left is the bounded poll in
/// `waitForHeldInjections`, needed because `enqueueInjection` is `async` and a
/// test that wants to park one without blocking must start a `Task`, which only
/// SCHEDULES the call (Tests/CLAUDE.md's "Clock and date seams" — the
/// scheduling handshake may sleep in real time even though the behaviour under
/// test never does).
///
/// `.serialized` for cheap isolation between tests that each mint their own
/// `TestClock` + queue; not required for correctness, matches this
/// repo's convention for small clock-driven suites (`AppearanceDebounceTests`).
///
/// `.clockDriven` is at SUITE level on purpose: four of these tests `await` a
/// continuation that a broken implementation would never resume, so each needs
/// its own hang bound. The first depends on it explicitly — its `TestClock` is
/// deliberately never advanced, so the time limit is what turns "released on
/// the bound instead of on `endUserPaste`" from an eternal hang into a named
/// failure.
@MainActor
@Suite("OutgoingInputQueue", .clockDriven, .serialized)
struct OutgoingInputQueueTests {
    /// Records every chunk `OutgoingInputQueue` decided to write, in the order
    /// `write` was actually invoked (not the order it was enqueued — that
    /// distinction is exactly what these tests are checking), and stands in
    /// for the transport's own verdict via `result`.
    @MainActor
    private final class WriteRecorder {
        private(set) var writes: [Data] = []
        /// What the transport reports back. `false` models the panel shape H1
        /// is about: a holder-backed panel takes the `.localPTY` arm with a nil
        /// `localProcess`, so the bytes reach nothing.
        var result = true

        func write(_ data: Data) -> Bool {
            writes.append(data)
            return result
        }
    }

    /// A bounded wait that never saw its effect, on the primary failure line.
    ///
    /// Thrown-`Error` shape on purpose (Tests/CLAUDE.md assertion-hygiene rule
    /// 4): only `Issue.record(_: some Error)` survives into a CI summary, and
    /// for a bounded wait the message IS the whole finding. `observed` is the
    /// half that discriminates — zero says the `enqueueInjection` call never
    /// reached the queue at all, a nonzero-but-wrong count says the hold
    /// bookkeeping is off.
    private struct HeldInjectionCountTimeout: Error, CustomStringConvertible {
        let expected: Int
        let observed: Int
        let timeout: Duration

        var description: String {
            """
            OutgoingInputQueue: expected \(expected) held injection(s) — observed \(observed) \
            after polling up to \(timeout) of real time
            """
        }
    }

    /// Bounded real-time poll for `queue.pendingInjectionCountForTesting`.
    /// Needed because creating `Task { await queue.enqueueInjection(_:) }`
    /// only SCHEDULES that call — it does not run it — so a test that wants to
    /// observe "the injection is now held" before proceeding must wait for the
    /// scheduler rather than assume it already happened. Nothing on the user
    /// side needs this: `enqueueUserBytes`, `beginUserPaste` and
    /// `endUserPaste` are synchronous.
    private func waitForHeldInjections(
        _ expected: Int, on queue: OutgoingInputQueue,
        timeout: Duration = .seconds(8),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while queue.pendingInjectionCountForTesting != expected {
            if ContinuousClock.now > deadline {
                Issue.record(
                    HeldInjectionCountTimeout(
                        expected: expected,
                        observed: queue.pendingInjectionCountForTesting,
                        timeout: timeout),
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
            recorder.write(data)
        }

        queue.beginUserPaste()
        let injection = Task { await queue.enqueueInjection(Data("INJECT".utf8)) }
        await waitForHeldInjections(1, on: queue)

        // Nothing should have been written while the paste is still open.
        #expect(recorder.writes.isEmpty)

        queue.endUserPaste()

        let wasWritten = await injection.value
        #expect(wasWritten == true)
        #expect(recorder.writes == [Data("INJECT".utf8)])
    }

    @Test("An injection arriving outside a paste goes straight out")
    func injectionOutsidePasteGoesStraightOut() async {
        let recorder = WriteRecorder()
        let clock = TestClock()
        let queue = OutgoingInputQueue(pasteHoldBound: .seconds(2), clock: clock) { data in
            recorder.write(data)
        }

        // No `beginUserPaste()` at all — the queue starts with no paste open.
        let wasWritten = await queue.enqueueInjection(Data("INJECT".utf8))

        #expect(wasWritten == true)
        #expect(recorder.writes == [Data("INJECT".utf8)])
    }

    @Test("An injection the transport never took is not acked as written")
    func injectionThatReachedNothingIsNotAckedAsWritten() async {
        let recorder = WriteRecorder()
        // The holder-backed panel shape: `performOutgoingWrite` takes the
        // `.localPTY` arm, finds no `localProcess`, and hands the bytes to
        // nobody. Acking `true` here would stop the daemon falling back and
        // lose the prompt invisibly — the failure H1 named.
        recorder.result = false
        let clock = TestClock()
        let queue = OutgoingInputQueue(pasteHoldBound: .seconds(999), clock: clock) { data in
            recorder.write(data)
        }

        // Both routes to a write must report it: straight out...
        #expect(await queue.enqueueInjection(Data("STRAIGHT".utf8)) == false)

        // ...and released from a hold.
        queue.beginUserPaste()
        let held = Task { await queue.enqueueInjection(Data("HELD".utf8)) }
        await waitForHeldInjections(1, on: queue)
        queue.endUserPaste()
        #expect(await held.value == false)

        // And the force-delivery path on an unclosed paste.
        queue.beginUserPaste()
        let forced = Task { await queue.enqueueInjection(Data("FORCED".utf8)) }
        await waitForHeldInjections(1, on: queue)
        await clock.advanceWhenSuspended(by: .seconds(999))
        #expect(await forced.value == false)
    }

    @Test("Ordering within each stream is preserved")
    func orderingWithinEachStreamPreserved() async {
        let recorder = WriteRecorder()
        let clock = TestClock()
        // Never advanced: the two holds below must be released by
        // `endUserPaste()`, not by their bound.
        let queue = OutgoingInputQueue(pasteHoldBound: .seconds(999), clock: clock) { data in
            recorder.write(data)
        }

        // Both streams at once, interleaved, with each injection confirmed
        // held before the next is started — otherwise the order two
        // back-to-back `Task`s reach the queue in would itself be undefined
        // and there would be no injection order to assert.
        queue.beginUserPaste()
        queue.enqueueUserBytes(Data("u0".utf8))
        let first = Task { await queue.enqueueInjection(Data("i0".utf8)) }
        await waitForHeldInjections(1, on: queue)
        queue.enqueueUserBytes(Data("u1".utf8))
        let second = Task { await queue.enqueueInjection(Data("i1".utf8)) }
        await waitForHeldInjections(2, on: queue)
        queue.enqueueUserBytes(Data("u2".utf8))

        // The user's stream is the paste itself, so it must NOT be held: its
        // chunks go out in arrival order while the paste is open.
        #expect(recorder.writes == ["u0", "u1", "u2"].map { Data($0.utf8) })

        queue.endUserPaste()
        #expect(await first.value == true)
        #expect(await second.value == true)
        // The injection stream follows, in the order it was enqueued — a flush
        // that reversed or reordered the held injections reddens here.
        #expect(recorder.writes == ["u0", "u1", "u2", "i0", "i1"].map { Data($0.utf8) })
    }

    @Test("A paste that never closes does not strand an injection forever")
    func unclosedPasteDoesNotStrandInjectionForever() async {
        let recorder = WriteRecorder()
        let bound = Duration.seconds(5)
        let clock = TestClock()
        let queue = OutgoingInputQueue(pasteHoldBound: bound, clock: clock) { data in
            recorder.write(data)
        }

        queue.beginUserPaste()
        let injection = Task { await queue.enqueueInjection(Data("INJECT".utf8)) }
        await waitForHeldInjections(1, on: queue)

        // The paste is deliberately NEVER closed — `endUserPaste()` is never
        // called in this test. Advancing virtual time past the bound is the
        // only thing that can release the injection.
        //
        // Short of the bound first, and that half matters as much: the bound
        // is required to be strictly shorter than the daemon's `injectionAck`
        // deadline, so an implementation that released early would let the
        // hold expire inside a paste it was supposed to outlast. Without this
        // assertion a mutation that shortened the wait passed the suite.
        await clock.advanceWhenSuspended(by: bound - .milliseconds(1))
        #expect(queue.pendingInjectionCountForTesting == 1)
        #expect(recorder.writes.isEmpty)

        await clock.advanceWhenSuspended(by: .milliseconds(1))

        let wasWritten = await injection.value
        #expect(wasWritten == true)
        #expect(recorder.writes == [Data("INJECT".utf8)])
    }

    @Test("Teardown releases a held injection as unwritten")
    func shutdownReleasesHeldInjectionAsUnwritten() async {
        let recorder = WriteRecorder()
        let clock = TestClock()
        let queue = OutgoingInputQueue(pasteHoldBound: .seconds(999), clock: clock) { data in
            recorder.write(data)
        }

        queue.beginUserPaste()
        let injection = Task { await queue.enqueueInjection(Data("INJECT".utf8)) }
        await waitForHeldInjections(1, on: queue)

        // The panel goes away mid-paste. The spec's fail-open rule rests on
        // this answer: `false` sends the daemon to its own direct write, while
        // a `true` here would ack a byte nothing ever carried.
        queue.shutdown()

        #expect(await injection.value == false)
        #expect(recorder.writes.isEmpty)
        #expect(queue.pendingInjectionCountForTesting == 0)
    }
}

/// The production trigger for the hold, driven end to end.
///
/// The four tests above call `beginUserPaste()`/`endUserPaste()` directly and
/// so never exercise what actually decides a paste is open: a whole-payload
/// equality test against SwiftTerm's bracketed-paste markers, inside
/// `Coordinator.send(source:data:)`. That decision depends on a vendored
/// fork's chunking behaviour, so it gets its own coverage on the real path —
/// `makeCoordinatorHarness()` builds a `Coordinator` on production wiring with
/// a real pty child.
///
/// Scope, stated plainly: the chunks are handed to the delegate directly, the
/// way `QuietIngestTests` does, so this pins the CLASSIFICATION rather than
/// SwiftTerm's chunking. Driving the fork's own chunking would mean going
/// through `paste(_:)`, which reads `NSPasteboard.general` — the developer's
/// real clipboard. The coalesced case below is therefore a record of what
/// happens if that chunking ever changes, not a guard against it changing.
@MainActor
@Suite("OutgoingInputQueue paste-marker detection", .serialized)
struct OutgoingInputQueuePasteMarkerTests {
    private static let start = ArraySlice(EscapeSequences.bracketedPasteStart)
    private static let end = ArraySlice(EscapeSequences.bracketedPasteEnd)

    @Test("The start marker opens a paste and the end marker closes it")
    func markersOpenAndCloseThePaste() {
        let harness = makeCoordinatorHarness()
        defer { harness.tearDown() }
        let queue = harness.coordinator.outgoingQueueForTesting
        #expect(queue.isPasteOpenForTesting == false)

        harness.coordinator.send(source: harness.terminalView, data: Self.start)
        #expect(queue.isPasteOpenForTesting == true)

        // The payload between the markers must not close the paste.
        harness.coordinator.send(source: harness.terminalView, data: ArraySlice("hello".utf8))
        #expect(queue.isPasteOpenForTesting == true)

        harness.coordinator.send(source: harness.terminalView, data: Self.end)
        #expect(queue.isPasteOpenForTesting == false)
    }

    @Test("Ordinary typing never opens a paste")
    func payloadOnlyDoesNotOpenAPaste() {
        let harness = makeCoordinatorHarness()
        defer { harness.tearDown() }
        let queue = harness.coordinator.outgoingQueueForTesting

        for chunk in ["h", "i", "\r"] {
            harness.coordinator.send(source: harness.terminalView, data: ArraySlice(chunk.utf8))
            #expect(queue.isPasteOpenForTesting == false)
        }
    }

    @Test("A marker coalesced with its payload is not recognized")
    func coalescedMarkerAndPayloadIsNotRecognized() {
        let harness = makeCoordinatorHarness()
        defer { harness.tearDown() }
        let queue = harness.coordinator.outgoingQueueForTesting

        // Whole-payload equality, so a chunk carrying the marker AND the
        // payload is not a marker. Recorded rather than desired: today
        // `MacTerminalView` makes three separate `send` calls and the
        // main-actor delivery buffer preserves each boundary, so this shape
        // does not arise. If a fork bump ever produced it, no paste would be
        // detected — harmless, because one `enqueueUserBytes` call is one
        // atomic write that an injection lands wholly before or after, but the
        // hold would stop happening and this test is where to notice.
        harness.coordinator.send(
            source: harness.terminalView,
            data: ArraySlice(EscapeSequences.bracketedPasteStart + Array("hello".utf8)))
        #expect(queue.isPasteOpenForTesting == false)
    }
}
