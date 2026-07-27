import Clocks
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib

// Tier 1 (docs/specs/2026-07-24-test-hardening-design.md §3): in-process,
// deterministic, driven entirely by virtual time. The only real sleeping is the
// scheduling handshake inside `advanceWhenSuspended`/`waitForSuspension`, which
// `Tests/CLAUDE.md` ("Clock and date seams") explicitly rules not a tier
// violation.
//
// DEFECT UNDER TEST: the gated interval stops being re-evaluated, so a
// foreground/background transition no longer shortens an in-flight wait.
// `Daemon.sleepThroughGatedInterval`'s doc comment — and `AppForegroundState`'s,
// which cites it — claim that per-tick re-evaluation is what *replaces*
// sleep-cancellation plumbing. Before this suite, nothing proved it: an
// implementation that sampled `interval()` once and slept it out whole would
// have passed the entire test suite while silently pinning the daemon to the
// 5-minute background cadence for five minutes after the app came forward.
//
// Two failure shapes are covered, because they are distinguishable:
//   - the closure stops being *called* → the call-count assertions catch it;
//   - the closure is called but its new value ignored (a cached `due`) → the
//     "no sleeper remains on the clock" assertions catch it.

/// Records how many times the gated-interval closure was evaluated, and lets a
/// test change the value it returns mid-wait. An actor because the closure is
/// `@Sendable` and `async`; no lock ceremony needed.
private actor GatedIntervalProbe {
    private(set) var callCount = 0
    private(set) var didReturn = false
    private var interval: Duration

    init(interval: Duration) {
        self.interval = interval
    }

    /// The gated-interval closure body.
    func next() -> Duration {
        callCount += 1
        return interval
    }

    func set(interval: Duration) {
        self.interval = interval
    }

    func markReturned() {
        didReturn = true
    }
}

@Suite(.clockDriven)
struct GatedIntervalSleepTests {
    /// Injected pacing, not production values: `Tests/CLAUDE.md` requires
    /// advance chains to stay in single digits, so the thresholds below are
    /// crossed in two or three advances instead of thirty.
    private static let tick: Duration = .seconds(10)

    @Test("returns after exactly the number of polls the interval implies")
    func returnsAfterExpectedPollCount() async {
        let clock = TestClock<Duration>()
        let probe = GatedIntervalProbe(interval: .seconds(30))  // 3 ticks

        let waiter = Task {
            await Daemon.sleepThroughGatedInterval(
                { await probe.next() }, tick: Self.tick, clock: clock)
            await probe.markReturned()
        }

        // Tick 1 and 2 re-evaluate and keep waiting; each advance sits next to
        // the re-park it produces rather than being batched at the top.
        await clock.advanceWhenSuspended(by: Self.tick)
        await clock.waitForSuspension()
        #expect(await probe.callCount == 1)

        await clock.advanceWhenSuspended(by: Self.tick)
        await clock.waitForSuspension()
        #expect(await probe.callCount == 2)

        // Tick 3 crosses the threshold.
        await clock.advanceWhenSuspended(by: Self.tick)

        // `checkSuspension()` throws while a sleeper IS registered, so "no
        // error" is the assertion that the wait ended rather than re-parking.
        // Its opening `megaYield()` is what gives the resumed task its turn.
        await #expect(throws: Never.self) { try await clock.checkSuspension() }

        // Deterministic join. `cancel()` is a no-op on a task that already
        // returned; on a defective loop still parked on the clock it resumes
        // the sleeper so the loop head exits, which keeps this suite reporting
        // the assertions above instead of wedging on `await waiter.value`.
        waiter.cancel()
        await waiter.value
        let observedCalls = await probe.callCount
        #expect(observedCalls == 3, "expected 3 interval evaluations, observed \(observedCalls)")
        #expect(await probe.didReturn)
    }

    @Test("one tick short of the threshold has not returned; the next tick returns")
    func boundaryIsExact() async {
        let clock = TestClock<Duration>()
        let probe = GatedIntervalProbe(interval: .seconds(30))  // 3 ticks

        let waiter = Task {
            await Daemon.sleepThroughGatedInterval(
                { await probe.next() }, tick: Self.tick, clock: clock)
            await probe.markReturned()
        }

        await clock.advanceWhenSuspended(by: Self.tick)
        await clock.advanceWhenSuspended(by: Self.tick)

        // 20s waited against a 30s gate. The re-park is the happens-before for
        // the flag read: reaching a suspension means the loop chose to keep
        // waiting rather than return.
        await clock.waitForSuspension()
        let returnedEarly = await probe.didReturn
        let callsAtBoundary = await probe.callCount
        #expect(
            !returnedEarly,
            """
            returned after \(callsAtBoundary) tick(s) — 20s waited against a 30s \
            gate should still be waiting
            """
        )

        // The final tick, and only it, ends the wait.
        await clock.advanceWhenSuspended(by: Self.tick)
        await #expect(throws: Never.self) { try await clock.checkSuspension() }

        waiter.cancel()
        await waiter.value
        #expect(await probe.didReturn)
        let observedCalls = await probe.callCount
        #expect(observedCalls == 3, "expected 3 interval evaluations, observed \(observedCalls)")
    }

    @Test("an interval shortened mid-wait shortens the wait")
    func shortenedIntervalShortensInFlightWait() async {
        let clock = TestClock<Duration>()
        // Background cadence, in miniature: 30 ticks away.
        let probe = GatedIntervalProbe(interval: .seconds(300))

        let waiter = Task {
            await Daemon.sleepThroughGatedInterval(
                { await probe.next() }, tick: Self.tick, clock: clock)
            await probe.markReturned()
        }

        await clock.advanceWhenSuspended(by: Self.tick)
        await clock.waitForSuspension()
        let callsBeforeFlip = await probe.callCount
        #expect(callsBeforeFlip == 1, "expected 1 interval evaluation, observed \(callsBeforeFlip)")
        #expect(await probe.didReturn == false)

        // The app comes to the foreground mid-wait: the gate drops to 20s,
        // which the 20s already waited after the next tick satisfies.
        await probe.set(interval: .seconds(20))
        await clock.advanceWhenSuspended(by: Self.tick)

        // THE HEADLINE ASSERTION. A loop that sampled the interval once — or
        // cached the first `due` — is still parked here, waiting out the
        // original 300s, and `checkSuspension()` throws because its sleeper is
        // registered.
        await #expect(throws: Never.self) { try await clock.checkSuspension() }

        waiter.cancel()
        await waiter.value
        #expect(await probe.didReturn)
        let observedCalls = await probe.callCount
        #expect(
            observedCalls == 2,
            """
            expected the shortened gate to end the wait after 2 evaluations, \
            observed \(observedCalls)
            """
        )
    }
}
