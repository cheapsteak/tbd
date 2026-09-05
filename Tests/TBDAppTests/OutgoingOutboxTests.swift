import Clocks
import Foundation
import SwiftTerm
import Testing

@testable import TBDApp
import TestSupport

/// Tier 1. The transport is a fake with a byte capacity, which models a full
/// pty input queue exactly: it takes what fits, refuses the rest, and only
/// takes more when the test says the child drained. No pty, no timing, no
/// scheduling — every assertion is observable in the turn it happens in.
///
/// `.clockDriven` is at suite level because two tests below `await` a
/// continuation a broken implementation would never resume, and one drives the
/// backpressure timer on a `TestClock`; each needs its own hang bound.
///
// Two properties here are not testable and should not be faked:
//
// 1. That a keystroke acquires no scheduling hop. The queue is synchronous
//    and `@MainActor`, so any test of it would assert on the absence of a
//    suspension the compiler already forbids at these call sites.
// 2. That the outbox has no upper bound. "It holds an arbitrarily large
//    paste" is untestable in the useful direction — a test can hold 100 MB
//    and prove nothing about 101 MB — and the memory cost of trying is
//    itself a shared-box hazard.
@MainActor
@Suite("OutgoingInputQueue outbox", .clockDriven, .serialized)
struct OutgoingOutboxTests {

    /// A transport with a bounded input queue. `capacity` is what it will take
    /// before refusing; `drain(_:)` is the child reading.
    @MainActor
    final class FakeTransport {
        private(set) var accepted = Data()
        private(set) var attempts = 0
        var capacity: Int
        var isDead = false

        init(capacity: Int) { self.capacity = capacity }

        func attempt(_ data: Data) -> OutgoingInputQueue.WriteAttempt {
            attempts += 1
            if isDead { return .unwritable(written: 0) }
            let room = min(capacity, data.count)
            accepted.append(data.prefix(room))
            capacity -= room
            return room == data.count ? .accepted : .refused(written: room)
        }

        /// The child reading: makes room, nothing more.
        func drain(_ bytes: Int) { capacity += bytes }
    }

    /// Counts *transitions*, not calls, so a queue that armed or disarmed twice
    /// in a row is invisible in `arms`/`disarms` — which is why `isArmed` is
    /// asserted alongside them. The real notifier behind these edges is a
    /// counted `DispatchSource` suspend/resume pair that traps the process when
    /// unbalanced, so both halves matter.
    @MainActor
    final class NotifierSpy {
        private(set) var arms = 0
        private(set) var disarms = 0
        private(set) var isArmed = false
        func arm() { if !isArmed { arms += 1 }; isArmed = true }
        func disarm() { if isArmed { disarms += 1 }; isArmed = false }
    }

    /// Records what the panel-level backpressure indicator was told, including
    /// the `nil` that clears it.
    @MainActor
    final class BackpressureSpy {
        private(set) var published: [Int?] = []
        func record(_ pendingBytes: Int?) { published.append(pendingBytes) }
    }

    private func makeQueue(
        capacity: Int, clock: TestClock<Duration> = TestClock(),
        notifier: NotifierSpy? = nil, backpressure: BackpressureSpy? = nil
    ) -> (OutgoingInputQueue, FakeTransport, NotifierSpy) {
        let transport = FakeTransport(capacity: capacity)
        let spy = notifier ?? NotifierSpy()
        let queue = OutgoingInputQueue(
            clock: clock,
            armDrain: { spy.arm() },
            disarmDrain: { spy.disarm() },
            onBackpressureChange: { backpressure?.record($0) },
            attempt: { transport.attempt($0) })
        return (queue, transport, spy)
    }

    /// A bounded wait that never saw its effect, on the primary failure line.
    /// Copied rather than shared with `OutgoingInputQueueTests`: it is fifteen
    /// lines, and a test-support type for two suites costs more than the
    /// duplication.
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
    /// Needed because creating `Task { await queue.enqueueInjection(_:) }` only
    /// SCHEDULES that call — it does not run it. Nothing on the user side needs
    /// this: `enqueueUserBytes`, `beginUserPaste` and `endUserPaste` are
    /// synchronous.
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
            // Bounded scheduling-handshake poll, not the behaviour under test.
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - The remainder is kept

    @Test("a refused remainder is kept, not dropped")
    func refusedRemainderIsKept() {
        let (queue, transport, notifier) = makeQueue(capacity: 1_022)

        queue.enqueueUserBytes(Data(repeating: 0x61, count: 4_096))

        #expect(transport.accepted.count == 1_022)
        #expect(queue.pendingByteCountForTesting == 4_096 - 1_022)
        #expect(notifier.isArmed, "a non-empty outbox must arm the drain")
    }

    @Test("everything enqueued behind a remainder is held, in order, and never written early")
    func laterChunksAreHeldBehindTheRemainder() {
        let (queue, transport, _) = makeQueue(capacity: 1_022)
        let payload = Data(repeating: 0x61, count: 4_096)

        queue.enqueueUserBytes(payload)
        queue.enqueueUserBytes(Data("Z".utf8))

        #expect(transport.accepted == payload.prefix(1_022),
                "a keystroke behind a remainder must not overtake it")
        // Two chunks, not one: the FIFO appends whole chunks rather than
        // coalescing them into a buffer it would have to copy on every append.
        #expect(queue.outboxChunkCountForTesting == 2)

        // The half that actually discriminates. Above, the transport had no
        // room either, so a queue with no hold at all would have had the
        // keystroke refused and appended anyway and passed. Here the child has
        // read: the transport WOULD take this keystroke this instant, and it
        // must still not get it, because 3,074 bytes of the paste are ahead of
        // it and `drain()` is the only thing allowed to move them.
        transport.drain(1_000_000)
        queue.enqueueUserBytes(Data("Y".utf8))

        #expect(transport.accepted == payload.prefix(1_022),
                "a keystroke must not overtake a remainder just because there is room for it")
        #expect(queue.pendingByteCountForTesting == (4_096 - 1_022) + 2)
        #expect(queue.outboxChunkCountForTesting == 3)
    }

    @Test("draining delivers every byte exactly once, in arrival order")
    func drainDeliversEverythingInOrder() {
        let (queue, transport, notifier) = makeQueue(capacity: 1_022)
        let payload = Data(repeating: 0x61, count: 4_096)
        let keystroke = Data("Z".utf8)

        queue.enqueueUserBytes(payload)
        queue.enqueueUserBytes(keystroke)
        // The child reads in three bites; the notifier fires once per bite.
        for _ in 0..<3 {
            transport.drain(2_000)
            queue.drain()
        }

        #expect(transport.accepted == payload + keystroke)
        #expect(queue.pendingByteCountForTesting == 0)
        #expect(!notifier.isArmed, "an empty outbox must disarm")
        #expect(notifier.disarms == 1)
    }

    /// The measured hazard, pinned: an armed notifier over an empty outbox is
    /// 44k–182k main-queue callbacks per second, so a path that empties the
    /// outbox without disarming is the main queue at 100% until the panel
    /// closes. Every path that can empty the outbox is walked here, because the
    /// one that forgets to disarm is the one that ships.
    @Test("the notifier is never left armed over an empty outbox, by any path")
    func notifierIsNeverArmedOverAnEmptyOutbox() {
        // Path 1: nothing was ever refused.
        let (quiet, _, quietNotifier) = makeQueue(capacity: 1_000_000)
        quiet.enqueueUserBytes(Data("Z".utf8))
        #expect(quietNotifier.arms == 0, "a write that fits must not arm anything")

        // Path 2: drained to empty.
        let (drained, transport, drainedNotifier) = makeQueue(capacity: 1_022)
        drained.enqueueUserBytes(Data(repeating: 0x61, count: 4_096))
        #expect(drainedNotifier.isArmed, "positive control: the episode really started")
        transport.drain(1_000_000)
        drained.drain()
        #expect(!drainedNotifier.isArmed)

        // Path 3: the transport died with bytes outstanding.
        let (died, deadTransport, deadNotifier) = makeQueue(capacity: 1_022)
        died.enqueueUserBytes(Data(repeating: 0x61, count: 4_096))
        #expect(deadNotifier.isArmed, "positive control: the episode really started")
        deadTransport.isDead = true
        died.drain()
        #expect(!deadNotifier.isArmed)

        // Path 4: teardown with bytes outstanding.
        let (torn, _, tornNotifier) = makeQueue(capacity: 1_022)
        torn.enqueueUserBytes(Data(repeating: 0x61, count: 4_096))
        #expect(tornNotifier.isArmed, "positive control: the episode really started")
        torn.shutdown()
        #expect(!tornNotifier.isArmed)
    }

    /// The other half of the same invariant: the edges are idempotent, so a
    /// second disarm cannot unbalance the counted suspend/resume pair behind
    /// them. `NotifierSpy` counts transitions, not calls, so a queue that
    /// disarmed twice would show `disarms == 1` here and a real notifier would
    /// have trapped — which is why the spy also asserts on its own state.
    @Test("the arm and disarm edges fire once per episode")
    func armAndDisarmAreEdges() {
        let (queue, transport, notifier) = makeQueue(capacity: 1_022)

        queue.enqueueUserBytes(Data(repeating: 0x61, count: 4_096))
        queue.enqueueUserBytes(Data("Z".utf8))       // still refusing; no second arm
        transport.drain(1_000_000)
        queue.drain()
        queue.drain()                                 // a spurious readiness fire
        queue.shutdown()                              // and a teardown after that

        #expect(notifier.arms == 1)
        #expect(notifier.disarms == 1)
        #expect(!notifier.isArmed)
    }

    // MARK: - The paste shape

    @Test("a paste's end marker is delivered after its payload, and a later keystroke after that")
    func pasteMarkersAndKeystrokeKeepTheirOrder() {
        let (queue, transport, _) = makeQueue(capacity: 1_022)
        let start = Data(EscapeSequences.bracketedPasteStart)
        let body = Data(repeating: 0x61, count: 4_096)
        let end = Data(EscapeSequences.bracketedPasteEnd)

        queue.beginUserPaste()
        queue.enqueueUserBytes(start)
        queue.enqueueUserBytes(body)
        queue.enqueueUserBytes(end)
        queue.endUserPaste()
        queue.enqueueUserBytes(Data("Z".utf8))
        transport.drain(1_000_000)
        queue.drain()

        // Built up statement by statement: a four-term `Data` concatenation
        // inside `#expect` blows the type-checker's budget.
        var expected = start
        expected.append(body)
        expected.append(end)
        expected.append(Data("Z".utf8))
        #expect(transport.accepted == expected, """
            the end marker must reach the child, and after the payload — a lost \
            or reordered ESC[201~ leaves the child in bracketed-paste mode
            """)
    }

    /// The refinement this work carries into the single-typist lease: with an
    /// outbox, "the paste is closed" and "the end marker has reached the
    /// child" are different moments — and the FIFO is what keeps an injection
    /// released at the first from landing before the second.
    @Test("an injection released by endUserPaste lands after an end marker still in the outbox")
    func releasedInjectionLandsAfterTheStillQueuedEndMarker() async throws {
        let (queue, transport, _) = makeQueue(capacity: 1_022)
        let body = Data(repeating: 0x61, count: 4_096)
        let end = Data(EscapeSequences.bracketedPasteEnd)

        queue.beginUserPaste()
        queue.enqueueUserBytes(body)
        queue.enqueueUserBytes(end)
        let injected = Task { await queue.enqueueInjection(Data("INJECTED\r".utf8)) }
        await waitForHeldInjections(1, on: queue)
        // The child reads BEFORE the paste closes, so the transport would take
        // the injection the instant `endUserPaste` releases it. That is the
        // whole hazard: the paste is closed, but its end marker is still in the
        // outbox, and only the FIFO keeps the injection behind it.
        transport.drain(1_000_000)
        queue.endUserPaste()
        queue.drain()

        #expect(await injected.value == true)
        let text = transport.accepted
        let markerAt = try #require(text.range(of: end))
        let injectionAt = try #require(text.range(of: Data("INJECTED\r".utf8)))
        #expect(markerAt.upperBound <= injectionAt.lowerBound,
                "an injection must never precede a paste's end marker")
    }

    // MARK: - The ack, and the drop

    @Test("an injection appended behind a remainder is accepted, not refused")
    func injectionBehindARemainderIsAccepted() async {
        let (queue, _, _) = makeQueue(capacity: 1_022)
        queue.enqueueUserBytes(Data(repeating: 0x61, count: 4_096))

        #expect(await queue.enqueueInjection(Data("hi\r".utf8)) == true, """
            `true` means accepted by a writer that will complete — the same \
            meaning the localProcess and sidecar arms carry
            """)
    }

    @Test("a dead transport drops the outbox, reports unwritten, and logs once")
    func deadTransportDropsTheOutbox() async {
        let (queue, transport, notifier) = makeQueue(capacity: 1_022)
        queue.enqueueUserBytes(Data(repeating: 0x61, count: 4_096))
        transport.isDead = true

        queue.drain()

        #expect(queue.pendingByteCountForTesting == 0)
        #expect(!notifier.isArmed)
        #expect(queue.outboxDropLogsForTesting == 1)
        #expect(await queue.enqueueInjection(Data("hi\r".utf8)) == false,
                "nothing will land through a dead transport, and the ack must say so")
        // Still one: the drop line belongs to the episode that lost bytes, not
        // to every later chunk offered to a transport that is still gone.
        #expect(queue.outboxDropLogsForTesting == 1)
    }

    @Test("a short write is not a transport failure and never logs one")
    func shortWriteIsNotATransportFailure() {
        let (queue, _, _) = makeQueue(capacity: 1_022)

        queue.enqueueUserBytes(Data(repeating: 0x61, count: 4_096))

        #expect(queue.userWriteOutcomeTransitionsForTesting == 0, """
            "keystrokes are being dropped" is false for a held remainder; only \
            a genuinely absent transport may log it
            """)
    }

    // MARK: - The backpressure edge

    @Test("the indicator appears only after the threshold, and clears on drain")
    func backpressureAppearsAfterTheThresholdAndClears() async {
        let clock = TestClock<Duration>()
        let backpressure = BackpressureSpy()
        let (queue, transport, _) = makeQueue(
            capacity: 1_022, clock: clock, backpressure: backpressure)

        queue.enqueueUserBytes(Data(repeating: 0x61, count: 4_096))
        await clock.advanceWhenSuspended(by: .milliseconds(900))
        #expect(backpressure.published.isEmpty,
                "a stall shorter than the threshold is not worth a banner")

        await clock.advanceWhenSuspended(by: .milliseconds(200))
        #expect(backpressure.published == [4_096 - 1_022])

        transport.drain(1_000_000)
        queue.drain()
        // Exactly two publications, and the second is the clear: the indicator
        // is an edge, not a per-chunk readout, so a queue that republished on
        // every accepted chunk of a 3 KB remainder would redden here.
        #expect(backpressure.published == [4_096 - 1_022, nil],
                "the banner clears when the outbox empties")
    }

    /// The other half of the threshold, and the one the timer test cannot
    /// reach: `drain()`'s `.refused` exit is the only path that can publish
    /// without the timer having fired, so it is the only place an
    /// unconditional publish would hide.
    @Test("a partial drain before the threshold draws no banner")
    func partialDrainBeforeTheThresholdDrawsNoBanner() {
        let backpressure = BackpressureSpy()
        let (queue, transport, _) = makeQueue(capacity: 1_022, backpressure: backpressure)

        queue.enqueueUserBytes(Data(repeating: 0x61, count: 4_096))
        // The child reads a little, twice — each `drain()` takes the `.refused`
        // exit with bytes still owed. Virtual time never moves, so the
        // threshold has provably not elapsed.
        for _ in 0..<2 {
            transport.drain(500)
            queue.drain()
        }

        #expect(queue.pendingByteCountForTesting > 0,
                "positive control: the episode is still open, so a banner was possible")
        #expect(backpressure.published.isEmpty, """
            a stall the person never noticed must not flash a banner on its way \
            out: the indicator is drawn by the threshold timer, and a partial \
            drain only refreshes one that is already showing
            """)
    }
}
