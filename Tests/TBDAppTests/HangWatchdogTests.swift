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
    /// 1000 ms threshold matches `HangWatchdog.defaultThresholdMs`. Tests that
    /// follow choose stall values clearly above/below this so a small drift
    /// in the constant doesn't silently break the suite.
    private let thresholdMs: UInt64 = 1000

    @Test func healthy_belowThreshold_isNoop() {
        // wasHung=false, stall<threshold — first tick of a healthy app.
        let stallNs: UInt64 = 100 * 1_000_000  // 100 ms
        let action = HangWatchdog.evaluate(stallNs: stallNs, wasHung: false, thresholdMs: thresholdMs)
        #expect(action == .noop)
    }

    @Test func healthy_aboveThreshold_logsToHung() {
        // wasHung=false, stall>threshold — onset of a hang.
        let stallNs: UInt64 = 3_000 * 1_000_000  // 3 s
        let action = HangWatchdog.evaluate(stallNs: stallNs, wasHung: false, thresholdMs: thresholdMs)
        #expect(action == .log(.toHung))
    }

    @Test func hung_aboveThreshold_isNoop() {
        // wasHung=true, stall>threshold — sustained hang. Must NOT re-log.
        let stallNs: UInt64 = 5_000 * 1_000_000  // 5 s
        let action = HangWatchdog.evaluate(stallNs: stallNs, wasHung: true, thresholdMs: thresholdMs)
        #expect(action == .noop)
    }

    @Test func hung_belowThreshold_logsToHealthy() {
        // wasHung=true, stall<threshold — recovery edge.
        let stallNs: UInt64 = 50 * 1_000_000  // 50 ms
        let action = HangWatchdog.evaluate(stallNs: stallNs, wasHung: true, thresholdMs: thresholdMs)
        #expect(action == .log(.toHealthy))
    }

    @Test func boundaryAtThreshold_isHung() {
        // Stall exactly at threshold counts as hung (>=). Pinning this so a
        // future "off by one" refactor doesn't quietly drop the boundary tick.
        let stallNs: UInt64 = thresholdMs * 1_000_000
        let action = HangWatchdog.evaluate(stallNs: stallNs, wasHung: false, thresholdMs: thresholdMs)
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

    // MARK: - thresholdMs(from:) — env override branches

    @Test func thresholdMs_absent_isDefault() {
        // No env var set → default 1000 ms (production launch).
        #expect(HangWatchdog.thresholdMs(from: [:]) == 1000)
    }

    @Test func thresholdMs_validPositive_overrides() {
        // A valid positive integer is honored so a run can catch sub-second stalls.
        #expect(HangWatchdog.thresholdMs(from: ["TBD_HANG_THRESHOLD_MS": "150"]) == 150)
    }

    @Test func thresholdMs_invalid_isDefault() {
        // Non-numeric junk falls back to the default rather than crashing.
        #expect(HangWatchdog.thresholdMs(from: ["TBD_HANG_THRESHOLD_MS": "abc"]) == 1000)
    }

    @Test func thresholdMs_zero_isDefault() {
        // Zero is not a usable threshold (every tick would be "hung") → default.
        #expect(HangWatchdog.thresholdMs(from: ["TBD_HANG_THRESHOLD_MS": "0"]) == 1000)
    }

    @Test func thresholdMs_empty_isDefault() {
        // Empty string → default.
        #expect(HangWatchdog.thresholdMs(from: ["TBD_HANG_THRESHOLD_MS": ""]) == 1000)
    }
}
