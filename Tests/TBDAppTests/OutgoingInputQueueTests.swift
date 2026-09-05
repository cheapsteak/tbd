import Clocks
import Foundation
import SwiftTerm
import TBDShared
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
/// `.clockDriven` is at SUITE level on purpose: five of these tests `await` a
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
    ///
    /// This suite's transport is all-or-nothing on purpose: it never reports
    /// `.refused`, so the outbox stays empty throughout and every assertion
    /// below is about the paste hold alone. The short-write behaviour has its
    /// own suite (`OutgoingInputQueue outbox`), and keeping the two apart is
    /// what makes a failure here mean the hold broke rather than the queue.
    @MainActor
    private final class WriteRecorder {
        private(set) var writes: [Data] = []
        /// What the transport reports back. `false` models the panel shape H1
        /// is about: a holder-backed panel takes the `.localPTY` arm with a nil
        /// `localProcess`, so the bytes reach nothing.
        var result = true

        func write(_ data: Data) -> OutgoingInputQueue.WriteAttempt {
            writes.append(data)
            return result ? .accepted : .unwritable(written: 0)
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
    /// The deadline is the shared saturated-pass budget, not a literal: the
    /// `Task { await queue.enqueueInjection(_:) }` this waits on is
    /// unstructured, so SE-0417 carries no executor preference into it and it
    /// runs on the cooperative pool behind the whole fast pass — see
    /// `gateHoldingTask` in `Tests/TestSupport/BoundedGateSupport.swift`.
    private func waitForHeldInjections(
        _ expected: Int, on queue: OutgoingInputQueue,
        timeout: Duration = TestDeadlines.saturatedPass,
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

        // Composed output, not three `== false`s: `false` is the fail-open
        // answer, so an implementation that resolved `false` INSTEAD of
        // attempting the write — stranding the injection while telling the
        // daemon exactly what it wanted to hear — passes every assertion
        // above unchanged. All three payloads must have been offered to the
        // transport, in order; it is the transport that refused them.
        #expect(recorder.writes == ["STRAIGHT", "HELD", "FORCED"].map { Data($0.utf8) })
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

    /// Two jobs, and the second is why this test omits `pasteHoldBound`
    /// instead of supplying one.
    ///
    /// The first is the behaviour in the name: an unclosed paste must not
    /// strand an injection forever.
    ///
    /// The second is to **pin the production default to
    /// `HolderInputTiming.pasteHoldBound`**, from both sides. That constant is
    /// required to stay strictly shorter than the daemon's
    /// `injectionAckDeadline` (see `HolderInputTiming`, and
    /// `HolderInputTimingTests` for the ordering itself), and sharing the
    /// constant only removes the chance of two literals drifting — it does not
    /// stop this call site from going back to a literal of its own. So the
    /// queue below is **default-constructed**, and the clock is advanced by the
    /// shared constant:
    ///
    /// - a default longer than the constant leaves the injection held after the
    ///   full advance, and the awaited `enqueueInjection` hangs out to the
    ///   suite's `.clockDriven` bound — which is the unsafe direction, the one
    ///   that pushes the hold past the daemon's deadline;
    /// - a default shorter than the constant releases it during the first,
    ///   short-of-the-bound advance, and the two assertions there fail.
    ///
    /// Every other test in this suite supplies its own bound, because each is
    /// isolating a different mechanism; this one is the seam's own coverage.
    @Test("A paste that never closes does not strand an injection forever")
    func unclosedPasteDoesNotStrandInjectionForever() async {
        let recorder = WriteRecorder()
        let bound = HolderInputTiming.pasteHoldBound
        let clock = TestClock()
        let queue = OutgoingInputQueue(clock: clock) { data in
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

    @Test("A keystroke that reaches no transport is reported once per episode")
    func unwrittenUserBytesReportOncePerEpisode() {
        let recorder = WriteRecorder()
        let queue = OutgoingInputQueue(pasteHoldBound: .seconds(999), clock: TestClock()) { data in
            recorder.write(data)
        }

        // A working panel says nothing at all — the whole point of an
        // edge-triggered diagnostic on a path this hot.
        queue.enqueueUserBytes(Data("h".utf8))
        queue.enqueueUserBytes(Data("i".utf8))
        #expect(queue.userWriteOutcomeTransitionsForTesting == 0)

        // The transport goes away (a holder-backed panel: every keystroke
        // reaches nothing). The FIRST failed keystroke reports; the second
        // must not — an unconditional log here would be one line per
        // keystroke on the path `TerminalPanelView.swift:750` warns about,
        // and this count is what discriminates the two implementations.
        recorder.result = false
        queue.enqueueUserBytes(Data("x".utf8))
        #expect(queue.userWriteOutcomeTransitionsForTesting == 1)
        queue.enqueueUserBytes(Data("y".utf8))
        #expect(queue.userWriteOutcomeTransitionsForTesting == 1)

        // The other edge: recovery reports exactly once too, so the episode
        // has a visible end and not just a beginning.
        recorder.result = true
        queue.enqueueUserBytes(Data("z".utf8))
        #expect(queue.userWriteOutcomeTransitionsForTesting == 2)
        queue.enqueueUserBytes(Data("!".utf8))
        #expect(queue.userWriteOutcomeTransitionsForTesting == 2)

        // Reporting must not swallow the bytes: every keystroke was still
        // offered to the transport, in order.
        #expect(recorder.writes == ["h", "i", "x", "y", "z", "!"].map { Data($0.utf8) })
    }
}

/// The production trigger for the hold, driven end to end.
///
/// Five of the seven tests above call `beginUserPaste()`/`endUserPaste()`
/// directly and so never exercise what actually decides a paste is open: a
/// whole-payload equality test against SwiftTerm's bracketed-paste markers,
/// inside `Coordinator.send(source:data:)`. That decision depends on a
/// vendored fork's chunking behaviour, so it gets its own coverage on the real
/// path — `makeCoordinatorHarness()` builds a `Coordinator` on production
/// wiring with a real pty child.
///
/// Scope, stated plainly: the chunks are handed to the delegate directly, the
/// way `QuietIngestTests` does, so this pins the CLASSIFICATION rather than
/// SwiftTerm's chunking. Driving the fork's own chunking would mean going
/// through `paste(_:)`, which reads `NSPasteboard.general` — the developer's
/// real clipboard. What happens if that chunking ever coalesces a marker with
/// its payload is therefore recorded where it can be acted on — the comment
/// in `Coordinator.send(source:data:)` — and not as a test: no assertion here
/// could tell a coalescing fork from a chunking one, since the classifier
/// behaves the same either way.
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

        // Positive control on the SAME path, before the absence is asserted
        // (`QuietIngestTests`, which owns this harness, states the discipline
        // in its own suite doc): `false` is also the constructor's initial
        // value, so without a send that provably drives the getter to `true`
        // and back this test would pass identically if `send` early-returned
        // and never reached the queue at all.
        harness.coordinator.send(source: harness.terminalView, data: Self.start)
        #expect(queue.isPasteOpenForTesting == true)
        harness.coordinator.send(source: harness.terminalView, data: Self.end)
        #expect(queue.isPasteOpenForTesting == false)

        for chunk in ["h", "i", "\r"] {
            harness.coordinator.send(source: harness.terminalView, data: ArraySlice(chunk.utf8))
            #expect(queue.isPasteOpenForTesting == false)
        }
    }
}
