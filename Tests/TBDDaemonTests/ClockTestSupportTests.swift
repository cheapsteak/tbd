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
    // One 90 s guard per test sits well inside `.clockDriven`'s 240 s limit.

    @Test func advanceWhenSuspendedUnblocksASleepingSubsystem() async throws {
        let clock = TestClock()
        let subject = DelayedFlag(clock: clock)

        let task = Task { try await subject.run(after: .seconds(30)) }
        let firedBeforeAdvance = await subject.fired
        #expect(firedBeforeAdvance == false)

        await clock.advanceWhenSuspended(by: .seconds(30), timeout: TestDeadlines.saturatedPass)
        try await task.value

        let firedAfterAdvance = await subject.fired
        #expect(firedAfterAdvance)
    }

    /// `advanceWhenSuspended` moves `now` by exactly the requested duration,
    /// not merely to the armed sleeper's deadline.
    ///
    /// The advance (7 s) deliberately overshoots the sleep (5 s): `TestClock`
    /// steps `now` to each due sleeper's deadline before settling on the
    /// target, so an advance equal to the sleep could not tell "moved by the
    /// duration" from "moved to the next deadline". `now` is read before the
    /// task is joined. If the helper stopped advancing, the sleeper would never
    /// be released, and joining first would turn this red assertion into an
    /// unattributed hang at the suite's time limit.
    @Test func advanceWhenSuspendedMovesTheClockForward() async throws {
        let clock = TestClock()
        let before = clock.now

        let task = Task { try await clock.sleep(for: .seconds(5)) }
        defer { task.cancel() }
        await clock.advanceWhenSuspended(by: .seconds(7), timeout: TestDeadlines.saturatedPass)

        try #require(before.duration(to: clock.now) == .seconds(7))
        try await task.value
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
