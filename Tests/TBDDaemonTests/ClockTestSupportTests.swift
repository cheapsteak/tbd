import Clocks
import Foundation
import Testing

import TestSupport

/// Tier 1 — deterministic, in-process, virtual time only.
///
/// Proves the shared clock seams in `Tests/TestSupport/ClockTestSupport.swift`
/// behave as documented, and (by linking `Clocks` from a test target) that the
/// test-only dependency wiring works.
@Suite(.clockDriven)
struct ClockTestSupportTests {
    /// The exact shape production subsystems get migrated to: a defaulted
    /// `clock: any Clock<Duration>` last parameter, a real `sleep(for:)`, and a
    /// test that drives it with `advanceWhenSuspended` instead of waiting.
    private actor DelayedFlag {
        let clock: any Clock<Duration>
        private(set) var fired = false

        init(clock: any Clock<Duration> = ContinuousClock()) {
            self.clock = clock
        }

        func run(after delay: Duration) async throws {
            try await clock.sleep(for: delay)
            fired = true
        }
    }

    // The two TestClock tests below are this handshake's own self-tests, so
    // they stay on `TestClock` (moving them to `EventDrivenTestClock` would
    // test that clock, which `EventDrivenTestClockSelfTests` already covers).
    // What they change is the arming guard. `advanceWhenSuspended`'s
    // `checkSuspension()` probe is a background-QoS `megaYield`: twenty
    // serially-awaited tasks, i.e. many scheduling hops, not one. Both tests
    // went red on the saturated fast pass with the same signature, "no task was
    // suspended on the clock within 45.0 seconds", and no logic assertion
    // failing. That pass's own green-run latency is p50 65.6 s per test. A
    // multi-hop bounded wait there takes its budget from `TestDeadlines`
    // (Tests/CLAUDE.md, "No bounded wait in a fast-pass target carries a
    // literal deadline"; `pollUntilTrue`'s "size it with
    // `TestDeadlines.saturatedPass` unless the wait is one scheduling hop").
    // The first test pays at most two 90 s guards (arming, then the fire) and
    // the second one, inside `.clockDriven`'s 240 s limit. `advance` itself
    // megaYields without a bound, so a pass starved past that still ends at the
    // suite limit; nothing on `TestClock` can bound it.

    @Test func advanceWhenSuspendedUnblocksASleepingSubsystem() async {
        let clock = TestClock()
        let subject = DelayedFlag(clock: clock)

        let task = Task { try await subject.run(after: .seconds(30)) }
        let firedBeforeAdvance = await subject.fired
        #expect(firedBeforeAdvance == false)

        await clock.advanceWhenSuspended(by: .seconds(30), timeout: TestDeadlines.saturatedPass)

        // Observe the effect under a bound rather than joining first. A missed
        // arming has already recorded its diagnostic and still advanced an
        // empty clock, so a sleep that registers late is scheduled past the new
        // `now` and never fires: an unbounded join would sit there until the
        // suite's time limit. Cancelling releases that sleeper, and a healthy
        // run has already fired by the time the cancel lands.
        let fired = await pollUntilTrue(timeout: TestDeadlines.saturatedPass,
                                        pollInterval: .milliseconds(25)) { await subject.fired }
        task.cancel()
        _ = try? await task.value
        if fired == .timedOut {
            Issue.record(BoundedWaitTimeout(what: "the sleeping subsystem to fire after the advance",
                                            observed: "fired == false",
                                            deadline: TestDeadlines.saturatedPass))
        }
    }

    /// `advanceWhenSuspended` moves `now` by exactly the requested duration,
    /// not merely to the armed sleeper's deadline.
    ///
    /// The advance (7 s) deliberately overshoots the sleep (5 s): `TestClock`
    /// steps `now` to each due sleeper's deadline before settling on the
    /// target, so an advance equal to the sleep could not tell "moved by the
    /// duration" from "moved to the next deadline".
    ///
    /// The sleeper is cancelled rather than joined. That it is *released* is
    /// the test above's claim. Here, joining would hang to the suite's time
    /// limit whenever the sleeper was never released: when the helper stops
    /// advancing, or when a missed arming advances an empty clock before a
    /// late sleep registers. Cancellation ends the sleep on every path.
    @Test func advanceWhenSuspendedMovesTheClockForward() async {
        let clock = TestClock()
        let before = clock.now

        let task = Task { try await clock.sleep(for: .seconds(5)) }
        await clock.advanceWhenSuspended(by: .seconds(7), timeout: TestDeadlines.saturatedPass)
        let moved = before.duration(to: clock.now)
        task.cancel()
        _ = try? await task.value

        #expect(moved == .seconds(7))
    }

    @Test func testDateSourceReadsWritesAndAdvances() {
        let source = TestDateSource(Date(timeIntervalSince1970: 1_000))
        #expect(source.now == Date(timeIntervalSince1970: 1_000))

        source.now = Date(timeIntervalSince1970: 2_000)
        #expect(source.now == Date(timeIntervalSince1970: 2_000))

        source.advance(by: 90)
        #expect(source.now == Date(timeIntervalSince1970: 2_090))
    }

    @Test func testDateSourceProviderObservesLaterMutations() {
        let source = TestDateSource(Date(timeIntervalSince1970: 1_000))
        // Captured once, as a production seam would — it must still see the
        // advance that happens after injection.
        let now = source.provider
        #expect(now() == Date(timeIntervalSince1970: 1_000))

        source.advance(by: 60)
        #expect(now() == Date(timeIntervalSince1970: 1_060))
    }
}
