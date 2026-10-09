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

    @Test func advanceWhenSuspendedUnblocksASleepingSubsystem() async throws {
        let clock = TestClock()
        let subject = DelayedFlag(clock: clock)

        let task = Task { try await subject.run(after: .seconds(30)) }
        let firedBeforeAdvance = await subject.fired
        #expect(firedBeforeAdvance == false)

        await clock.advanceWhenSuspended(by: .seconds(30))
        try await task.value

        let firedAfterAdvance = await subject.fired
        #expect(firedAfterAdvance)
    }

    /// Advancing past an armed sleeper moves `now` by exactly the advance.
    ///
    /// Runs on `EventDrivenTestClock` rather than `TestClock`: the polled
    /// `advanceWhenSuspended` handshake (a megaYield probe every 25 ms) starved
    /// past its 45 s guard on the saturated fast pass, while this test asserts
    /// only the virtual-time contract. The arming wait parks on a continuation
    /// signalled by the sleep itself, with a budget sized to the pass's latency.
    /// `advanceWhenSuspended` itself stays covered by the test above.
    @Test func advanceMovesTheClockForward() async throws {
        let clock = EventDrivenTestClock()
        let before = clock.now

        let task = Task { try await clock.sleep(for: .seconds(5)) }
        try await clock.requireAdvanceWhenArmed(by: .seconds(5), timeout: TestDeadlines.saturatedPass)
        try await task.value

        #expect(before.duration(to: clock.now) == .seconds(5))
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
