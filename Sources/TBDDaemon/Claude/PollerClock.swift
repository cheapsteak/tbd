import Foundation

/// Abstract clock used by `ClaudeUsagePoller` so tests can advance virtual time
/// instead of sleeping. Production uses `SystemPollerClock`; tests use a fake.
public protocol PollerClock: Sendable {
    func now() -> Date
    /// Sleep until `deadline`. May throw `CancellationError` to wake early.
    func sleep(until deadline: Date) async throws
}

public struct SystemPollerClock: PollerClock {
    private static let maxChunk: TimeInterval = 60

    public init() {}
    public func now() -> Date { Date() }

    /// Sleeps in bounded chunks, re-checking the wall clock each iteration.
    ///
    /// `Task.sleep` uses the suspending (uptime) clock on Darwin — time the machine
    /// spends asleep doesn't count — so a single full-interval sleep overshoots the
    /// wall-clock deadline by however long the machine slept. Chunking caps post-wake
    /// lateness at one chunk (60s; `LimitResumeScheduler.slack` is already 60s, so
    /// sub-minute precision is not needed). `CancellationError` from `Task.sleep`
    /// propagates out of the loop, waking waiters promptly.
    public func sleep(until deadline: Date) async throws {
        while true {
            let interval = deadline.timeIntervalSince(Date())
            guard interval > 0 else { return }
            try await Task.sleep(nanoseconds: UInt64(min(interval, Self.maxChunk) * 1_000_000_000))
        }
    }
}
