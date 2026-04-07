import Foundation

/// Abstract clock used by `ClaudeUsagePoller` so tests can advance virtual time
/// instead of sleeping. Production uses `SystemPollerClock`; tests use a fake.
public protocol PollerClock: Sendable {
    func now() -> Date
    /// Sleep until `deadline`. May throw `CancellationError` to wake early.
    func sleep(until deadline: Date) async throws
}

public struct SystemPollerClock: PollerClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(until deadline: Date) async throws {
        let interval = deadline.timeIntervalSince(Date())
        if interval > 0 {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}
