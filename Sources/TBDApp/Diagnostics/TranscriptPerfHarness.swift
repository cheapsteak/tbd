import Foundation
import TBDShared

// MARK: - Config

/// Parameters for one synthetic streaming run of the live-transcript pane.
/// Built from the process environment by `TranscriptPerfHarness.config(from:)`.
struct TranscriptPerfHarnessConfig: Equatable {
    /// Number of heavy synthetic items present in the transcript at start.
    var preseed: Int
    /// Number of inject ticks during the run.
    var injectCount: Int
    /// Cadence between inject ticks, in milliseconds.
    var injectIntervalMs: Int
    /// Number of heavy items appended per inject tick. Production freezes when a
    /// single poll lands MANY heavy items at once (issue #129 jumped 91→153 = 62
    /// items in one poll), so the harness appends a batch per tick to drive ONE
    /// `scrollTo(.bottom)` over many new heavy rows. Clamped `>= 1`.
    var injectBatch: Int
}

// MARK: - Harness

/// DEBUG/env-gated synthetic-streaming harness for measuring the issue #129
/// transcript scroll freeze. Inert unless `TBD_TRANSCRIPT_PERF_HARNESS` is set:
/// `config(from:)` returns `nil` and the live pane behaves exactly as in
/// production. When active, the pane renders deterministic heavy synthetic
/// items and appends to them on a fixed cadence, driving the real
/// `.onChange(messages.last?.id) → proxy.scrollTo(anchor: .bottom)` path so the
/// `measureEstimates`/`StackLayout.sizeThatFits` cost is reproducibly measured
/// by `HangWatchdog` without touching real appState or the daemon.
enum TranscriptPerfHarness {
    /// Default heavy items present at start.
    static let defaultPreseed = 500
    /// Default number of inject ticks.
    static let defaultInjectCount = 20
    /// Default cadence between injections, in milliseconds.
    static let defaultInjectIntervalMs = 800
    /// Default heavy items appended per inject tick.
    static let defaultInjectBatch = 10
    /// Lower bound for items appended per tick. A tick must add at least one
    /// item, otherwise the run makes no progress.
    static let minInjectBatch = 1
    /// Lower bound for the injection cadence. Below this the run would flood the
    /// main thread faster than a layout pass can complete and stop being a
    /// realistic "streaming" reproduction.
    static let minInjectIntervalMs = 50

    /// Gate key. When present and non-empty, the harness is active.
    static let gateKey = "TBD_TRANSCRIPT_PERF_HARNESS"

    /// Build a config when the gate key is set (non-empty), else `nil`.
    /// Optional numeric overrides — `TBD_PERF_PRESEED`, `TBD_PERF_INJECT_COUNT`,
    /// `TBD_PERF_INJECT_MS`, `TBD_PERF_INJECT_BATCH` — fall back to their defaults
    /// when absent or invalid. Clamps: `preseed >= 0`, `injectCount >= 0`,
    /// `injectIntervalMs >= minInjectIntervalMs`, `injectBatch >= minInjectBatch`.
    /// Pure — tests pass a synthetic dictionary, no `setenv`.
    static func config(from environment: [String: String]) -> TranscriptPerfHarnessConfig? {
        guard let gate = environment[gateKey], !gate.isEmpty else { return nil }

        let preseed = max(0, intOverride(environment["TBD_PERF_PRESEED"], default: defaultPreseed))
        let injectCount = max(0, intOverride(environment["TBD_PERF_INJECT_COUNT"], default: defaultInjectCount))
        let injectIntervalMs = max(
            minInjectIntervalMs,
            intOverride(environment["TBD_PERF_INJECT_MS"], default: defaultInjectIntervalMs)
        )
        let injectBatch = max(
            minInjectBatch,
            intOverride(environment["TBD_PERF_INJECT_BATCH"], default: defaultInjectBatch)
        )

        return TranscriptPerfHarnessConfig(
            preseed: preseed,
            injectCount: injectCount,
            injectIntervalMs: injectIntervalMs,
            injectBatch: injectBatch
        )
    }

    /// Parse an optional override into an Int, falling back to `default` on
    /// absent/empty/non-numeric input.
    private static func intOverride(_ raw: String?, default fallback: Int) -> Int {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty,
              let value = Int(raw) else {
            return fallback
        }
        return value
    }

    // MARK: - View-gating decision helpers (pure, tested)

    /// Whether the auto-scroll onChange should fire. In harness mode the
    /// transcript must behave like a user pinned at the bottom so the real
    /// `proxy.scrollTo` path fires on EVERY injected batch — otherwise
    /// the 1pt `atBottom` sentinel flips false the instant a batch lands below
    /// the fold and we measure only append/reconcile cost, never the scroll
    /// cost (issue #129). In production (`harnessActive == false`) this returns
    /// `atBottom` unchanged, so behavior is identical when the harness is off.
    static func autoscrollGate(harnessActive: Bool, atBottom: Bool) -> Bool {
        return harnessActive ? true : atBottom
    }

    /// Which array the transcript view should render: synthetic items in
    /// harness mode, the real appState-derived messages otherwise.
    static func displayedMessages(
        harnessActive: Bool,
        harness: [TranscriptItem],
        real: [TranscriptItem]
    ) -> [TranscriptItem] {
        return harnessActive ? harness : real
    }

    // MARK: - Synthetic items

    /// Build `count` heavy synthetic `.assistantText` items with stable,
    /// distinct ids (`perf-harness-<index>`). `startIndex` offsets the ids so a
    /// preseed batch and a later injected batch never collide. Deterministic
    /// given `(count, startIndex)` — no `Date.now()`/random — with `timestamp`
    /// nil. Each item's body is a heavy ~15-40 KB markdown blob (several prose
    /// paragraphs + at least TWO large 8×15 tables + multiple fenced code blocks)
    /// so rows carry the representative `StyledTextLayoutEngine.lengthThatFits`
    /// N×M layout cost that drives the issue #129 freeze. Content varies by index
    /// so rows aren't byte-identical, mirroring a real transcript.
    static func makeSyntheticItems(count: Int, startIndex: Int = 0) -> [TranscriptItem] {
        guard count > 0 else { return [] }
        return (0..<count).map { offset in
            let index = startIndex + offset
            return TranscriptItem.assistantText(
                id: "perf-harness-\(index)",
                text: syntheticBody(index: index),
                timestamp: nil,
                usage: nil
            )
        }
    }

    /// Deterministic heavy (~15-40 KB) markdown body for synthetic item `index`.
    ///
    /// Structure faithful to a heavy real assistant turn: several prose
    /// paragraphs, TWO 8-column × 15-row tables (the N×M layout cost that tops
    /// out `StyledTextLayoutEngine.lengthThatFits` in #129), and three ~20-40
    /// line fenced code blocks. Index-varied throughout so no two rows are
    /// byte-identical, but fully deterministic (no `Date.now()`/random).
    private static func syntheticBody(index: Int) -> String {
        var out = "## Synthetic item \(index)\n\n"
        out += "_Variant token: \(variantWord(index)) / nonce \(index &* 2_654_435_761 % 1_000_000)_\n\n"

        // Several prose paragraphs, varied by index.
        for p in 0..<6 {
            out += syntheticParagraph(index: index, paragraph: p)
            out += "\n\n"
        }

        out += "### First data table\n\n"
        out += syntheticTable(index: index, salt: 0)
        out += "\n\n"

        out += syntheticParagraph(index: index, paragraph: 6)
        out += "\n\n"

        out += syntheticCodeBlock(index: index, variant: 0)
        out += "\n\n"

        out += syntheticParagraph(index: index, paragraph: 7)
        out += "\n\n"

        out += syntheticCodeBlock(index: index, variant: 1)
        out += "\n\n"

        out += "### Second data table\n\n"
        out += syntheticTable(index: index, salt: 1)
        out += "\n\n"

        out += syntheticParagraph(index: index, paragraph: 8)
        out += "\n\n"

        out += syntheticCodeBlock(index: index, variant: 2)
        out += "\n\n"

        for p in 9..<13 {
            out += syntheticParagraph(index: index, paragraph: p)
            out += "\n\n"
        }

        return out
    }

    /// A deterministic prose paragraph varied by `(index, paragraph)`.
    private static func syntheticParagraph(index: Int, paragraph p: Int) -> String {
        let topic = variantWord(index &+ p)
        return """
        Paragraph \(p) of synthetic transcript item \(index) (\(topic)). This body \
        is deliberately heavy and structurally varied so each row carries a \
        representative `StyledTextLayoutEngine.lengthThatFits` measurement cost \
        when SwiftUI sizes the LazyVStack during a streaming append. Real \
        assistant turns interleave dense prose with large tables and fenced code \
        blocks, and that mixed N×M layout is exactly what stresses the layout \
        pass behind issue #129. We restate the analysis here so the rendered \
        height is non-trivial: the \(topic) pathway re-measures every glyph run, \
        wraps across the available width, and resolves attributes for item \
        \(index) before the scroll-to-bottom anchor can settle. The freeze \
        manifests when one poll lands many such rows at once and every one must \
        be measured on the main thread before the next frame can be drawn.
        """
    }

    /// An 8-column × 15-row table, index- and salt-varied.
    private static func syntheticTable(index: Int, salt: Int) -> String {
        var rows = "| Metric | Variant | Count | State | Latency (ms) | Region | Owner | Notes |\n"
        rows += "| --- | --- | --- | --- | --- | --- | --- | --- |\n"
        for r in 0..<15 {
            let seed = index &* 31 &+ salt &* 7 &+ r
            rows += "| metric-\(index)-\(salt)-\(r) "
            rows += "| \(variantWord(seed)) "
            rows += "| \((seed &* 97) % 10_000) "
            rows += "| \(r % 2 == 0 ? "enabled" : "disabled") "
            rows += "| \((seed &* 13) % 2_500) "
            rows += "| region-\(seed % 12) "
            rows += "| owner-\(variantWord(seed &+ 3)) "
            rows += "| row \(r) of table \(salt) for item \(index) re-measures glyphs |\n"
        }
        return rows
    }

    /// A ~20-40 line fenced Swift code block, varied by `(index, variant)`.
    private static func syntheticCodeBlock(index: Int, variant: Int) -> String {
        let fn = "process_\(index)_\(variant)"
        return """
        ```swift
        // Representative fenced code block \(variant) for item \(index).
        // Heavy enough to force a real layout/measure pass for the row.
        struct Sample_\(index)_\(variant) {
            let id: String
            let weight: Int
            let label: String
        }

        func \(fn)(_ items: [Sample_\(index)_\(variant)]) -> Int {
            var total = 0
            var seen: Set<String> = []
            for (offset, item) in items.enumerated() {
                guard !seen.contains(item.id) else { continue }
                seen.insert(item.id)
                let contribution = offset &* item.weight &+ item.label.count
                total &+= contribution
                if contribution % \(variant + 2) == 0 {
                    total &-= item.weight
                }
            }
            return total &* \(index % 7 + 1)
        }

        // Drive it deterministically so the snippet is non-trivial.
        let samples = (0..<24).map { i in
            Sample_\(index)_\(variant)(id: "s-\(index)-\\(i)", weight: i &* \(variant + 1), label: "row-\\(i)")
        }
        assert(\(fn)(samples) >= 0)
        ```
        """
    }

    /// Deterministic word picked from a small lexicon, varied by `seed`.
    private static func variantWord(_ seed: Int) -> String {
        let words = [
            "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf",
            "hotel", "india", "juliet", "kilo", "lima", "mike", "november",
            "oscar", "papa", "quebec", "romeo", "sierra", "tango"
        ]
        let i = ((seed % words.count) + words.count) % words.count
        return words[i]
    }
}
