import os

/// TEMPORARY diagnostic instrumentation for the terminal render path.
///
/// This file exists only to answer one question: how long do bytes read from
/// the pty sit queued before the main thread renders them? It is **not** a
/// feature, has no flag, and is meant to be reverted once the measurement is
/// taken. See `docs/perf/2026-08-25-terminal-render-cost-investigation.md` for
/// what has already been eliminated.
///
/// Intervals emitted (all on subsystem `com.tbd.app`, category `renderlatency`):
///
/// - `mainThreadHop` — from just before `DispatchQueue.main.async` in
///   `TerminalPanelView.Coordinator.dataReceived(slice:)` to the moment the
///   block actually runs on the main thread. This duration *is* the queueing
///   delay: the time terminal output waited behind whatever else the main
///   thread was doing. Metadata: byte count of the chunk.
/// - `feed` — the nested `TerminalView.feed(byteArray:)` call, so parse and
///   damage-tracking cost can be separated from the queueing delay above.
/// - `displayPass` — begins in `TBDTerminalView.viewWillDraw()` and ends on the
///   next main-queue turn, bounding the cost of one AppKit display pass. Begin
///   timestamps also give the inter-frame gaps.
///
/// Every chunk is instrumented, not a sample: the tail is the whole point.
enum RenderLatencySignposts {
    static let signposter = OSSignposter(subsystem: "com.tbd.app", category: "renderlatency")
}
