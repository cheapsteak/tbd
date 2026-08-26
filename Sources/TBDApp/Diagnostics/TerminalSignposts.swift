import os

/// Shared `OSSignposter` for `category: "perf-terminal"` — the path terminal
/// output travels from the pty to the screen.
///
/// Signposts are silent unless a recording tool is attached, so these live in
/// the code permanently rather than being added and deleted per investigation
/// (see `docs/diagnostics-strategy.md`, and `TranscriptSignposts` for the
/// sibling on `perf-transcript`).
///
/// Region names emitted today — **these are load-bearing**: the analysis
/// scripts under `scripts/diag/` match on them verbatim, and
/// `TerminalSignpostsTests` asserts them so a rename cannot silently break the
/// tooling:
///
/// - `mainThreadHop` — begins on the pty reader thread immediately before the
///   `DispatchQueue.main.async` in
///   `TerminalPanelRepresentable.Coordinator.dataReceived(slice:)`, and ends
///   inside that block. The duration *is* the main-thread queueing delay for
///   terminal output — the thing average CPU utilisation cannot show, since a
///   mostly-idle main thread still stalls output behind any long run-loop
///   callout. Metadata: byte count of the chunk.
///
///   This interval also *defines* an analysis window: a period during which one
///   is open is a period when terminal bytes were demonstrably sitting
///   undelivered. That makes it a window derived from the symptom rather than
///   from a suspect, which is what let the 2026-08-26 attribution rule the poll
///   cycle out instead of assuming it in.
///
/// - `feed` — the nested `TerminalView.feed(byteArray:)` call, separating parse
///   cost from queueing delay. Measured at 0.11 ms p50, which is what exonerates
///   the parser.
///
/// Every chunk is instrumented rather than sampled: the median hop is 0.05 ms in
/// every window measured, and the finding lives at the 99th percentile.
///
/// A third interval, `displayPass`, was deliberately **not** kept. Closing it
/// required posting an extra block to the main queue on every display pass —
/// the very queue whose delay `mainThreadHop` exists to measure. See
/// `docs/specs/2026-08-26-terminal-latency-signposts-design.md`.
enum TerminalSignposts {
    /// Subsystem/category pair. Exposed so tests can assert it, since the
    /// capture recipes and analysis scripts filter on it.
    static let subsystem = "com.tbd.app"
    static let category = "perf-terminal"

    /// Interval names, referenced by the analysis scripts.
    ///
    /// `StaticString`, because `OSSignposter` requires it — the name is baked
    /// into the binary at compile time rather than formatted at each emission,
    /// which is a large part of why a signpost costs nothing when nobody is
    /// recording.
    enum Region {
        static let mainThreadHop: StaticString = "mainThreadHop"
        static let feed: StaticString = "feed"
    }

    nonisolated static let signposter = OSSignposter(subsystem: subsystem, category: category)
}
