import Foundation
import Testing
import TBDShared

@testable import TBDApp

/// Tests for `TranscriptPerfHarness` — the pure, env-gated synthetic-streaming
/// harness used to reproduce the issue #129 transcript scroll freeze.
///
/// CLAUDE.md: "When adding a branching conditional that gates behavior, add a
/// test for each branch." The gate is `TBD_TRANSCRIPT_PERF_HARNESS` (active vs
/// inert) plus the per-override fallbacks. All tests pass synthetic env
/// dictionaries — no `setenv`.
@Suite("TranscriptPerfHarness")
struct TranscriptPerfHarnessTests {

    // MARK: - config(from:) gate

    @Test func config_gateAbsent_isNil() {
        // No gate key → harness inert, production behavior preserved.
        #expect(TranscriptPerfHarness.config(from: [:]) == nil)
    }

    @Test func config_gateEmpty_isNil() {
        // Empty gate value counts as not-set.
        #expect(TranscriptPerfHarness.config(from: ["TBD_TRANSCRIPT_PERF_HARNESS": ""]) == nil)
    }

    @Test func config_gateSet_defaults() {
        // Gate set, no overrides → documented defaults (500/20/800/10).
        let cfg = TranscriptPerfHarness.config(from: ["TBD_TRANSCRIPT_PERF_HARNESS": "1"])
        #expect(cfg == TranscriptPerfHarnessConfig(
            preseed: 500, injectCount: 20, injectIntervalMs: 800, injectBatch: 10
        ))
    }

    @Test func config_overridesParsed() {
        let cfg = TranscriptPerfHarness.config(from: [
            "TBD_TRANSCRIPT_PERF_HARNESS": "yes",
            "TBD_PERF_PRESEED": "120",
            "TBD_PERF_INJECT_COUNT": "10",
            "TBD_PERF_INJECT_MS": "300",
            "TBD_PERF_INJECT_BATCH": "25"
        ])
        #expect(cfg == TranscriptPerfHarnessConfig(
            preseed: 120, injectCount: 10, injectIntervalMs: 300, injectBatch: 25
        ))
    }

    @Test func config_invalidOverrides_fallBackToDefaults() {
        // Non-numeric overrides must not crash — fall back to defaults.
        let cfg = TranscriptPerfHarness.config(from: [
            "TBD_TRANSCRIPT_PERF_HARNESS": "1",
            "TBD_PERF_PRESEED": "abc",
            "TBD_PERF_INJECT_COUNT": "",
            "TBD_PERF_INJECT_MS": "x",
            "TBD_PERF_INJECT_BATCH": "nope"
        ])
        #expect(cfg == TranscriptPerfHarnessConfig(
            preseed: 500, injectCount: 20, injectIntervalMs: 800, injectBatch: 10
        ))
    }

    @Test func config_injectBatch_defaultWhenAbsent() {
        let cfg = TranscriptPerfHarness.config(from: ["TBD_TRANSCRIPT_PERF_HARNESS": "1"])
        #expect(cfg?.injectBatch == 10)
    }

    @Test func config_clampsInjectBatchFloor() {
        // Zero and negative batch sizes clamp up to the minimum of 1.
        let zero = TranscriptPerfHarness.config(from: [
            "TBD_TRANSCRIPT_PERF_HARNESS": "1",
            "TBD_PERF_INJECT_BATCH": "0"
        ])
        #expect(zero?.injectBatch == 1)

        let negative = TranscriptPerfHarness.config(from: [
            "TBD_TRANSCRIPT_PERF_HARNESS": "1",
            "TBD_PERF_INJECT_BATCH": "-7"
        ])
        #expect(negative?.injectBatch == 1)
    }

    @Test func config_clampsInjectIntervalFloor() {
        // Below the 50 ms floor clamps up to 50.
        let cfg = TranscriptPerfHarness.config(from: [
            "TBD_TRANSCRIPT_PERF_HARNESS": "1",
            "TBD_PERF_INJECT_MS": "10"
        ])
        #expect(cfg?.injectIntervalMs == 50)
    }

    @Test func config_clampsNegativeCountsToZero() {
        let cfg = TranscriptPerfHarness.config(from: [
            "TBD_TRANSCRIPT_PERF_HARNESS": "1",
            "TBD_PERF_PRESEED": "-5",
            "TBD_PERF_INJECT_COUNT": "-3"
        ])
        #expect(cfg?.preseed == 0)
        #expect(cfg?.injectCount == 0)
    }

    // MARK: - View-gating decision helpers (both branches)

    @Test func autoscrollGate_harnessActive_alwaysTrue() {
        // Harness pins to bottom: scroll must fire regardless of atBottom so
        // every injected batch drives the real scroll path (issue #129).
        #expect(TranscriptPerfHarness.autoscrollGate(harnessActive: true, atBottom: false) == true)
        #expect(TranscriptPerfHarness.autoscrollGate(harnessActive: true, atBottom: true) == true)
    }

    @Test func autoscrollGate_harnessInactive_returnsAtBottom() {
        // Production: gate == atBottom, so behavior is identical to before.
        #expect(TranscriptPerfHarness.autoscrollGate(harnessActive: false, atBottom: false) == false)
        #expect(TranscriptPerfHarness.autoscrollGate(harnessActive: false, atBottom: true) == true)
    }

    @Test func displayedMessages_branches() {
        let real = TranscriptPerfHarness.makeSyntheticItems(count: 2, startIndex: 0)
        let harness = TranscriptPerfHarness.makeSyntheticItems(count: 3, startIndex: 1000)

        let whenOff = TranscriptPerfHarness.displayedMessages(harnessActive: false, harness: harness, real: real)
        #expect(whenOff == real)

        let whenOn = TranscriptPerfHarness.displayedMessages(harnessActive: true, harness: harness, real: real)
        #expect(whenOn == harness)
    }

    // MARK: - makeSyntheticItems

    @Test func makeSyntheticItems_honorsCount() {
        #expect(TranscriptPerfHarness.makeSyntheticItems(count: 7).count == 7)
        #expect(TranscriptPerfHarness.makeSyntheticItems(count: 0).isEmpty)
    }

    @Test func makeSyntheticItems_idsDistinctAndStable() {
        let first = TranscriptPerfHarness.makeSyntheticItems(count: 5)
        let second = TranscriptPerfHarness.makeSyntheticItems(count: 5)
        let ids = first.map(\.id)
        // Stable across calls.
        #expect(ids == second.map(\.id))
        // Distinct within a batch.
        #expect(Set(ids).count == ids.count)
    }

    @Test func makeSyntheticItems_startIndexAvoidsCollision() {
        let preseed = TranscriptPerfHarness.makeSyntheticItems(count: 10, startIndex: 0)
        let injected = TranscriptPerfHarness.makeSyntheticItems(count: 10, startIndex: 10)
        let preseedIDs = Set(preseed.map(\.id))
        let injectedIDs = Set(injected.map(\.id))
        #expect(preseedIDs.isDisjoint(with: injectedIDs))
    }

    @Test func makeSyntheticItems_areHeavyAssistantText() {
        for item in TranscriptPerfHarness.makeSyntheticItems(count: 3) {
            guard case let .assistantText(_, text, timestamp, usage) = item else {
                Issue.record("expected .assistantText, got \(item)")
                continue
            }
            // Heavy rows: ~15-40 KB markdown each (prose + 2 tables + 3 code
            // blocks) to drive the real #129 layout/measure cost.
            #expect(text.count > 10_000)
            #expect(timestamp == nil)
            #expect(usage == nil)
        }
    }

    @Test func makeSyntheticItems_idsOffsetByStartIndex() {
        // startIndex offsets the numeric suffix of every id.
        let items = TranscriptPerfHarness.makeSyntheticItems(count: 3, startIndex: 42)
        #expect(items.map(\.id) == ["perf-harness-42", "perf-harness-43", "perf-harness-44"])
    }

    @Test func makeSyntheticItems_contentVariesByIndex() {
        // Rows must not be byte-identical (realistic transcript).
        let items = TranscriptPerfHarness.makeSyntheticItems(count: 2)
        func body(_ item: TranscriptItem) -> String {
            guard case let .assistantText(_, text, _, _) = item else { return "" }
            return text
        }
        #expect(body(items[0]) != body(items[1]))
    }
}
