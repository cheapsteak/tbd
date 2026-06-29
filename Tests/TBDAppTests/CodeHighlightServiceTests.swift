import Testing
import AppKit
@testable import TBDApp

@MainActor
@Suite("Code highlight service (async, off-main)")
struct CodeHighlightServiceTests {
    /// The size cap is a pure guard (no JSContext), so it returns `[]` quickly and
    /// deterministically — assert it via a bounded async wait. A code blob over the
    /// 30k-UTF16 cap must be skipped (highlight.js is pathologically slow on huge
    /// inputs; the open path must never pay it).
    @Test("oversized input is skipped (returns no color runs)")
    func sizeCapSkips() async {
        let huge = String(repeating: "let x = 1\n", count: 4_000) // ~40k UTF-16
        let runs: [HighlightColorRun] = await withCheckedContinuation { continuation in
            CodeHighlightService.shared.highlight(
                code: huge, language: "swift"
            ) { result in
                continuation.resume(returning: result)
            }
        }
        #expect(runs.isEmpty)
    }

    /// Live highlight.js path: a small Swift snippet eventually yields ≥1 foreground
    /// color run, delivered on the main thread, with ranges local to the input.
    /// Exercises the dedicated serial queue + JSContext confinement end to end.
    @Test("small swift snippet eventually returns at least one color run")
    func liveHighlightProducesColorRuns() async {
        let code = "let x = 1"
        let runs: [HighlightColorRun] = await withCheckedContinuation { continuation in
            CodeHighlightService.shared.highlight(
                code: code, language: "swift"
            ) { result in
                continuation.resume(returning: result)
            }
        }
        // Highlightr/highlight.js should color at least the `let` keyword.
        #expect(!runs.isEmpty)
        // Ranges are LOCAL to the input string (never out of bounds).
        let length = (code as NSString).length
        for run in runs {
            #expect(run.range.location >= 0)
            #expect(run.range.location + run.range.length <= length)
        }
    }
}
