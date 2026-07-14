import Foundation
import Testing
@testable import TBDDaemonLib

/// Fake wall clock + recording sleeper for `SystemPollerClock`'s injection seams.
/// The sleeper records each requested duration and advances the fake clock by exactly
/// that amount, returning immediately — no real sleeping, so tests are CI-load independent.
private final class FakeClock: @unchecked Sendable {
    private let queue = DispatchQueue(label: "FakeClock")
    private var _now: Date
    private var _calls: [UInt64] = []

    init(start: Date) { _now = start }

    var now: Date { queue.sync { _now } }
    var calls: [UInt64] { queue.sync { _calls } }

    func sleep(_ ns: UInt64) {
        queue.sync {
            _calls.append(ns)
            _now = _now.addingTimeInterval(Double(ns) / 1_000_000_000)
        }
    }
}

@Suite struct SystemPollerClockTests {
    @Test func pastDeadlineReturnsImmediately() async throws {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let fake = FakeClock(start: start)
        let clock = SystemPollerClock(sleeper: { fake.sleep($0) }, now: { fake.now })
        try await clock.sleep(until: start.addingTimeInterval(-10))
        #expect(fake.calls.isEmpty)
    }

    @Test func deadlineBeyondMaxChunkSleepsInBoundedChunks() async throws {
        // Whole-second values are exact in Double, so the chunk sequence is exact —
        // fractional chunks (e.g. 0.03) leave fp dust that can add a spurious 0ns call.
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let fake = FakeClock(start: start)
        let clock = SystemPollerClock(
            maxChunk: 30,
            sleeper: { fake.sleep($0) },
            now: { fake.now }
        )
        try await clock.sleep(until: start.addingTimeInterval(80))
        // Pre-fix single-sleep code would make exactly one 80s call.
        #expect(fake.calls == [30_000_000_000, 30_000_000_000, 20_000_000_000])
    }

    @Test func cancellationSurfacesCancellationError() async throws {
        // Deadline 120s with default maxChunk 60s: even extreme scheduler latency
        // can't make the cancel miss the first 60s chunk. No elapsed-time assertions —
        // if cancellation propagation breaks, the sleep completes normally and the
        // failure assertion below fails deterministically.
        let task = Task {
            try await SystemPollerClock().sleep(until: Date().addingTimeInterval(120))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let result = await task.result
        guard case .failure(let error) = result else {
            Issue.record("expected sleep to throw after cancellation")
            return
        }
        #expect(error is CancellationError)
    }
}
