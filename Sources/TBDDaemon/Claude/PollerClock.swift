import Foundation

/// Abstract clock used by `ClaudeUsagePoller` so tests can advance virtual time
/// instead of sleeping. Production uses `SystemPollerClock`; tests use a fake.
public protocol PollerClock: Sendable {
    func now() -> Date
    /// Sleep until `deadline`. May throw `CancellationError` to wake early.
    func sleep(until deadline: Date) async throws
}

public struct SystemPollerClock: PollerClock {
    private let maxChunk: TimeInterval
    private let sleeper: @Sendable (UInt64) async throws -> Void
    private let nowProvider: @Sendable () -> Date

    /// `maxChunk`, `sleeper`, and `now` are injection seams for tests; production uses the defaults.
    public init(
        maxChunk: TimeInterval = 60,
        sleeper: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.maxChunk = maxChunk
        self.sleeper = sleeper
        self.nowProvider = now
    }

    public func now() -> Date { nowProvider() }

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
            let interval = deadline.timeIntervalSince(nowProvider())
            guard interval > 0 else { return }
            try await sleeper(UInt64(min(interval, maxChunk) * 1_000_000_000))
        }
    }
}
