import AppKit
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// Env-gated, headless, deterministic eager-measure benchmark for issue #129
/// (continuing PR #278). Force-measures the FULL list of transcript rows in
/// plain `VStack`s (NOT `LazyVStack`) so EVERY row pays its cold layout cost in
/// one pass, then reports wall-clock min/median over the measured iterations.
/// Built to compare the per-row layout cost of candidate flattenings: build the
/// same commit twice with and without a change and diff the `BENCH` lines.
///
/// ## Why LIGHT rows
///
/// The per-row layer #129 flattenings target is the row WRAPPER (e.g.
/// `TranscriptRow`'s optional-badge `VStack`), which is body-weight-invariant.
/// A heavy 15-40KB MarkdownUI body costs the same in every build, so it only
/// adds a large change-invariant constant that dilutes the wrapper delta and
/// makes each pass minutes-slow. Single-line prose rows make the wrapper the
/// dominant per-row cost, so removing a wrapper node is a fast, high-signal
/// delta. Caveat: a flat list under-represents the DEPTH recursion (nested
/// alignment guides) seen in real hover/activation spindumps, so this bench is
/// a lower bound on a flattening's real-world benefit, not the whole story.
///
/// Inert during normal `swift test`: the test early-returns unless
/// `TBD_PERF_BENCH=1`, so it never slows the regular suite. Run explicitly:
///
///     TBD_PERF_BENCH=1 swift test --filter TranscriptEagerMeasureBench
///
/// ## Why chunked + autoreleasepool, not one giant VStack
///
/// SwiftUI/CoreGraphics aborts (SIGABRT) once a single hosted layout's realized
/// geometry exceeds ~2.1M points. To keep the measure an honest EAGER full-list
/// pass while staying under the cap for any row height, the rows are measured in
/// fixed `chunkSize`-row plain `VStack`s, each hosted in its own `NSHostingView`
/// inside an `autoreleasepool` so its backing store is freed before the next
/// chunk. The per-iteration time is the SUM across all chunks — i.e. the cold
/// eager layout cost of all N rows.
@Suite("Transcript eager-measure bench")
@MainActor
struct TranscriptEagerMeasureBench {
    /// Rows per hosted chunk — kept well under the ~2.1M-pt realized-geometry
    /// cap that aborts a single hosting pass, with headroom for tall rows.
    private static let chunkSize = 100
    /// Render width matching the transcript pane's typical content column.
    private static let width: CGFloat = 700

    @Test("eager full-list NSHostingView measure (gated by TBD_PERF_BENCH=1)")
    func eagerMeasure() {
        // GATE: do nothing (pass trivially) unless explicitly enabled. Keeps the
        // normal test suite fast — this bench measures hundreds of rows per pass.
        guard ProcessInfo.processInfo.environment["TBD_PERF_BENCH"] == "1" else {
            #expect(true)
            return
        }

        for count in [500, 1000] {
            // Build items + render nodes ONCE per N. Node construction is not
            // what we measure — the cold EAGER SwiftUI layout over all rows is —
            // so reusing the nodes across iterations isolates the layout cost.
            //
            // LIGHT rows (single short prose line), NOT the heavy 15-40KB
            // generator: the per-row layer that PR #278 / changes A & B flatten
            // is the WRAPPER (TranscriptRow's VStack, ChatBubbleView's
            // flex-frame), which is body-weight-invariant. Heavy MarkdownUI
            // bodies cost the same in every build, so they only add a large
            // A/B-invariant constant that dilutes the wrapper delta and makes
            // the measure minutes-slow. Light bodies make the wrapper the
            // dominant per-row cost, so removing wrapper nodes is a clean,
            // fast, high-signal delta. All `.assistantText` (badge-less, so
            // change A's VStack-drop applies to every row; assistant, so change
            // B's flex-frame-drop applies to every row) to maximize sensitivity.
            let items: [TranscriptItem] = (0..<count).map { i in
                .assistantText(
                    id: "bench-\(i)",
                    text: "Short assistant reply \(i): one line of prose with **bold**, `code`, and a [link](https://example.com).",
                    timestamp: nil,
                    usage: nil
                )
            }
            let nodes = transcriptRenderNodes(from: items)

            let iterations = 20
            let warmup = 4
            var samplesMs: [Double] = []

            for iter in 0..<iterations {
                let result = measureEagerLayout(nodes: nodes)

                // Guard: the bench is useless if layout produced a degenerate
                // size. A full list of heavy rows must measure to a tall extent.
                #expect(
                    result.totalHeight > 1,
                    "summed fittingSize height was \(result.totalHeight) for N=\(count) — headless layout did not measure content"
                )

                if iter >= warmup {
                    samplesMs.append(result.milliseconds)
                }
            }

            let sorted = samplesMs.sorted()
            let minMs = sorted.first ?? 0
            let medianMs = median(sorted)

            print(String(
                format: "BENCH N=%d samples=%d min=%.2f ms median=%.2f ms",
                count, samplesMs.count, minMs, medianMs
            ))
            fflush(stdout)
        }

        #expect(true)
    }

    /// One cold eager full-list measure of `nodes`: hosts the rows in
    /// `chunkSize`-row plain `VStack`s (fresh `NSHostingView` per chunk inside an
    /// `autoreleasepool`) and reads `fittingSize` to force a full content-extent
    /// layout. Returns the wall-clock duration summed across chunks and the
    /// summed measured height (a degenerate-layout sentinel).
    private func measureEagerLayout(
        nodes: [TranscriptRenderNode]
    ) -> (milliseconds: Double, totalHeight: CGFloat) {
        let clock = ContinuousClock()
        let start = clock.now

        var totalHeight: CGFloat = 0
        var index = 0
        while index < nodes.count {
            autoreleasepool {
                let upper = min(index + Self.chunkSize, nodes.count)
                let slice = Array(nodes[index..<upper])

                // Plain VStack (NOT LazyVStack) so the whole chunk is eagerly
                // force-measured in one pass — the "cold full-list eager
                // measure" of PR #278.
                let root = VStack(alignment: .leading, spacing: 4) {
                    ForEach(slice) { node in
                        TranscriptRow(node: node, terminalID: nil)
                    }
                }
                .frame(width: Self.width)

                // Fresh hosting view per chunk so SwiftUI cannot reuse a cached
                // layout. A modest viewport frame keeps the realized backing
                // store small; `fittingSize` still forces the full content
                // extent to be measured.
                let hostingView = NSHostingView(rootView: root)
                hostingView.frame = NSRect(x: 0, y: 0, width: Self.width, height: 800)
                totalHeight += hostingView.fittingSize.height
            }
            index += Self.chunkSize
        }

        let elapsed = start.duration(to: clock.now)
        let ms = Double(elapsed.components.seconds) * 1000.0
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
        return (ms, totalHeight)
    }

    /// Median of a pre-sorted, non-empty array; 0 for empty input.
    private func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2.0
        }
        return sorted[mid]
    }
}
