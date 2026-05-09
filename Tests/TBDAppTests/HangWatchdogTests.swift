import Foundation
import Testing

@testable import TBDApp

/// Tests for `HangWatchdog.evaluate` — the pure decision helper.
///
/// CLAUDE.md: "When adding a branching conditional that gates behavior, add a
/// test for each branch." The four branches here are the (wasHung, isHungNow)
/// quadrants of the state machine.
@Suite("HangWatchdog")
struct HangWatchdogTests {
    /// 1500 ms threshold matches `HangWatchdog.defaultThresholdMs`. Tests that
    /// follow choose stall values clearly above/below this so a small drift
    /// in the constant doesn't silently break the suite.
    private let thresholdMs: UInt64 = 1500

    @Test func healthy_belowThreshold_isNoop() {
        // wasHung=false, stall<threshold — first tick of a healthy app.
        let stallNs: UInt64 = 100 * 1_000_000  // 100 ms
        let action = HangWatchdog.evaluate(nowNs: stallNs, wasHung: false, thresholdMs: thresholdMs)
        #expect(action == .noop)
    }

    @Test func healthy_aboveThreshold_logsToHung() {
        // wasHung=false, stall>threshold — onset of a hang.
        let stallNs: UInt64 = 3_000 * 1_000_000  // 3 s
        let action = HangWatchdog.evaluate(nowNs: stallNs, wasHung: false, thresholdMs: thresholdMs)
        #expect(action == .log(.toHung))
    }

    @Test func hung_aboveThreshold_isNoop() {
        // wasHung=true, stall>threshold — sustained hang. Must NOT re-log.
        let stallNs: UInt64 = 5_000 * 1_000_000  // 5 s
        let action = HangWatchdog.evaluate(nowNs: stallNs, wasHung: true, thresholdMs: thresholdMs)
        #expect(action == .noop)
    }

    @Test func hung_belowThreshold_logsToHealthy() {
        // wasHung=true, stall<threshold — recovery edge.
        let stallNs: UInt64 = 50 * 1_000_000  // 50 ms
        let action = HangWatchdog.evaluate(nowNs: stallNs, wasHung: true, thresholdMs: thresholdMs)
        #expect(action == .log(.toHealthy))
    }

    @Test func boundaryAtThreshold_isHung() {
        // Stall exactly at threshold counts as hung (>=). Pinning this so a
        // future "off by one" refactor doesn't quietly drop the boundary tick.
        let stallNs: UInt64 = thresholdMs * 1_000_000
        let action = HangWatchdog.evaluate(nowNs: stallNs, wasHung: false, thresholdMs: thresholdMs)
        #expect(action == .log(.toHung))
    }

    @Test func machDeltaToNanos_zeroThen_isZero() {
        // `then == 0` means uninitialized — must return 0 instead of treating
        // mach_absolute_time() as the entire delta.
        let nanos = HangWatchdog.machDeltaToNanos(now: 1_000_000, then: 0)
        #expect(nanos == 0)
    }

    @Test func machDeltaToNanos_clockBackwards_isZero() {
        // `now < then` shouldn't underflow into a giant UInt64.
        let nanos = HangWatchdog.machDeltaToNanos(now: 100, then: 200)
        #expect(nanos == 0)
    }

    @Test func snapshotEmpty_hasDistantPast() {
        // Sanity that `.empty` doesn't accidentally claim "captured just now".
        #expect(HangWatchdogSnapshot.empty.capturedAt == .distantPast)
        #expect(HangWatchdogSnapshot.empty.focusedTerminalIDShort == nil)
    }
}
