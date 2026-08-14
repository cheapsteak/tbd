import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib

// Tier 1 (docs/specs/2026-07-24-test-hardening-design.md §3): in-process,
// deterministic, driven entirely by virtual time. The only real sleeping is the
// scheduling handshake inside the clock's arming waits, which `Tests/CLAUDE.md`
// ("Clock and date seams") explicitly rules not a tier violation.
//
// CLOCK: `EventDrivenTestClock` with its **strict** waits
// (`docs/specs/2026-08-13-poller-suite-clock-migration-design.md`). This is a
// poller test — arm, advance, re-arm, repeated — so a recorded-and-continued
// missed arming would advance virtual time with nothing registered and desync
// every later step into a hang. `requireAdvanceWhenArmed` throws at the first
// miss instead, and the whole chain costs one hang guard rather than one per
// step.
//
// And the fact each assertion rests on is an *observable*, never the clock's
// own state: `returned.next()` waits for the gated sleep to actually return.
// The predecessor asked `checkSuspension()` whether a sleeper was still
// registered and leaned on its internal megaYield to give the resumed task a
// turn first — a scheduling accident that stops holding under exactly the load
// these guards exist for.
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
//     "the wait ended" assertions catch it, because a loop honouring a stale
//     `due` is still parked and never records a return.

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
    func returnsAfterExpectedPollCount() async throws {
        let clock = EventDrivenTestClock()
        let probe = GatedIntervalProbe(interval: .seconds(30))  // 3 ticks
        let returned = FireRecorder<Int>()

        let waiter = Task {
            await Daemon.sleepThroughGatedInterval(
                { await probe.next() }, tick: Self.tick, clock: clock)
            await probe.markReturned()
            returned.record(await probe.callCount)
        }

        // Tick 1 and 2 re-evaluate and keep waiting; each advance sits next to
        // the re-park it produces rather than being batched at the top. The
        // re-park is also the happens-before for the count read: the loop
        // reaches its next `sleep` only after evaluating the interval.
        try await clock.requireAdvanceWhenArmed(by: Self.tick)
        try await clock.requireSleeperArmed()
        #expect(await probe.callCount == 1)

        try await clock.requireAdvanceWhenArmed(by: Self.tick)
        try await clock.requireSleeperArmed()
        #expect(await probe.callCount == 2)

        // Tick 3 crosses the threshold: 30s waited against a 30s gate.
        try await clock.requireAdvanceWhenArmed(by: Self.tick)

        // THE ASSERTION THAT THE WAIT ENDED, and it is the returning itself
        // that is observed — a loop that re-parked instead records nothing and
        // this fails with the recorder's named diagnostic. The value carried is
        // the evaluation count at the moment of return, so "returned" and
        // "after exactly three polls" are one fact rather than two reads that
        // could disagree.
        #expect(await returned.next() == 3)

        // Deterministic join. `cancel()` is a no-op on a task that already
        // returned; on a defective loop still parked on the clock it resumes
        // the sleeper so the loop head exits, which keeps this suite reporting
        // the assertions above instead of wedging on `await waiter.value`.
        waiter.cancel()
        await waiter.value
        #expect(await probe.didReturn)
    }

    @Test("one tick short of the threshold has not returned; the next tick returns")
    func boundaryIsExact() async throws {
        let clock = EventDrivenTestClock()
        let probe = GatedIntervalProbe(interval: .seconds(30))  // 3 ticks
        let returned = FireRecorder<Int>()

        let waiter = Task {
            await Daemon.sleepThroughGatedInterval(
                { await probe.next() }, tick: Self.tick, clock: clock)
            await probe.markReturned()
            returned.record(await probe.callCount)
        }

        try await clock.requireAdvanceWhenArmed(by: Self.tick)
        try await clock.requireAdvanceWhenArmed(by: Self.tick)

        // 20s waited against a 30s gate. The re-park is the happens-before for
        // the flag read: reaching a suspension means the loop chose to keep
        // waiting rather than return.
        try await clock.requireSleeperArmed()
        let returnedEarly = await probe.didReturn
        let callsAtBoundary = await probe.callCount
        #expect(
            !returnedEarly,
            """
            returned after \(callsAtBoundary) tick(s) — 20s waited against a 30s \
            gate should still be waiting
            """
        )

        // The final tick, and only it, ends the wait — proven by the return
        // itself arriving, after exactly three evaluations.
        try await clock.requireAdvanceWhenArmed(by: Self.tick)
        #expect(await returned.next() == 3)

        waiter.cancel()
        await waiter.value
        #expect(await probe.didReturn)
    }

    @Test("an interval shortened mid-wait shortens the wait")
    func shortenedIntervalShortensInFlightWait() async throws {
        let clock = EventDrivenTestClock()
        // Background cadence, in miniature: 30 ticks away.
        let probe = GatedIntervalProbe(interval: .seconds(300))
        let returned = FireRecorder<Int>()

        let waiter = Task {
            await Daemon.sleepThroughGatedInterval(
                { await probe.next() }, tick: Self.tick, clock: clock)
            await probe.markReturned()
            returned.record(await probe.callCount)
        }

        try await clock.requireAdvanceWhenArmed(by: Self.tick)
        try await clock.requireSleeperArmed()
        let callsBeforeFlip = await probe.callCount
        #expect(callsBeforeFlip == 1, "expected 1 interval evaluation, observed \(callsBeforeFlip)")
        #expect(await probe.didReturn == false)

        // The app comes to the foreground mid-wait: the gate drops to 20s,
        // which the 20s already waited after the next tick satisfies.
        await probe.set(interval: .seconds(20))
        try await clock.requireAdvanceWhenArmed(by: Self.tick)

        // THE HEADLINE ASSERTION. A loop that sampled the interval once — or
        // cached the first `due` — is still parked here, waiting out the
        // original 300s, so it never returns and never records: this fails with
        // the recorder's diagnostic instead of passing on a clock snapshot
        // taken before the resumed task had run.
        #expect(
            await returned.next() == 2,
            "expected the shortened gate to end the wait after 2 evaluations"
        )

        waiter.cancel()
        await waiter.value
        #expect(await probe.didReturn)
    }
}
