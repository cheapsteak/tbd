import Foundation
import os

/// Accumulates keystroke-latency samples (sidecar frame receipt → after the
/// `send-keys` stream write) and logs a percentile summary at most once per
/// second. The spec's input telemetry budget is soft 50 ms / hard 200 ms at
/// p99; this log line is how we read it during dogfooding.
///
/// Lock-protected so the router's consumer can `record` while nothing else
/// contends. The `now` seam lets tests drive the 1 Hz gate without real time.
final class InputLatencyRecorder: @unchecked Sendable {
    struct Summary: Equatable {
        let count: Int
        let p50Ms: Double
        let p99Ms: Double
        let maxMs: Double
    }

    private let logger = Logger(subsystem: "com.tbd.daemon", category: "tmuxControlMode")
    private let lock = NSLock()
    private let now: @Sendable () -> ContinuousClock.Instant
    private let emitInterval: Duration

    private var samples: [Duration] = []
    /// Start of the current summary window. `nil` until the first sample, which
    /// opens the window WITHOUT emitting (a summary needs a full interval).
    private var windowStart: ContinuousClock.Instant?

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
         emitInterval: Duration = .seconds(1)) {
        self.now = now
        self.emitInterval = emitInterval
    }

    /// Record one latency sample. Emits (and resets) at most once per
    /// `emitInterval`; between emits, samples accumulate.
    func record(_ duration: Duration) {
        let summary: Summary?
        lock.lock()
        samples.append(duration)
        let current = now()
        guard let start = windowStart else {
            windowStart = current            // open the window; first sample never emits
            lock.unlock()
            return
        }
        guard current - start >= emitInterval else {
            lock.unlock()
            return
        }
        windowStart = current
        summary = summarizeAndResetLocked()
        lock.unlock()

        if let summary {
            logger.debug("""
                input latency: n=\(summary.count, privacy: .public) \
                p50=\(summary.p50Ms, privacy: .public)ms \
                p99=\(summary.p99Ms, privacy: .public)ms \
                max=\(summary.maxMs, privacy: .public)ms
                """)
        }
    }

    /// Test seam: compute the current window's summary and clear it. Returns
    /// `nil` when no samples are buffered. Exposed so tests assert percentile
    /// math without racing the 1 Hz log gate.
    func summarizeAndReset() -> Summary? {
        lock.lock()
        defer { lock.unlock() }
        return summarizeAndResetLocked()
    }

    private func summarizeAndResetLocked() -> Summary? {
        guard !samples.isEmpty else { return nil }
        let sortedMs = samples.map(\.milliseconds).sorted()
        samples.removeAll(keepingCapacity: true)
        return Summary(
            count: sortedMs.count,
            p50Ms: Self.percentile(sortedMs, 0.50),
            p99Ms: Self.percentile(sortedMs, 0.99),
            maxMs: sortedMs.last ?? 0)
    }

    /// Nearest-rank percentile over a pre-sorted array (deterministic for
    /// tests): rank = ⌈p·n⌉, clamped into range.
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        let index = min(max(rank - 1, 0), sorted.count - 1)
        return sorted[index]
    }
}

private extension Duration {
    /// Milliseconds as a Double, computed via integer nanoseconds first so
    /// whole-millisecond durations land on exact values.
    var milliseconds: Double {
        let parts = components
        let nanos = parts.attoseconds / 1_000_000_000        // attos → nanos
        return Double(parts.seconds) * 1_000 + Double(nanos) / 1_000_000
    }
}
