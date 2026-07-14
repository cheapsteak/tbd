import Foundation
import Testing
@testable import TBDDaemonLib

/// Records the nanosecond durations requested from the injected sleeper.
private actor SleepRecorder {
    var calls: [UInt64] = []
    func record(_ ns: UInt64) { calls.append(ns) }
}

@Suite struct SystemPollerClockTests {
    @Test func pastDeadlineReturnsImmediately() async throws {
        let recorder = SleepRecorder()
        let clock = SystemPollerClock(sleeper: { await recorder.record($0) })
        try await clock.sleep(until: Date().addingTimeInterval(-10))
        #expect(await recorder.calls.isEmpty)
    }

    @Test func shortFutureDeadlineSleepsAtLeastTheInterval() async throws {
        let clock = SystemPollerClock()
        let start = Date()
        try await clock.sleep(until: start.addingTimeInterval(0.15))
        // Lower bound only — load can't make this flake, it only slows things down.
        #expect(Date().timeIntervalSince(start) >= 0.14)
    }

    @Test func deadlineBeyondMaxChunkSleepsInBoundedChunks() async throws {
        let recorder = SleepRecorder()
        let maxChunk: TimeInterval = 0.02
        let clock = SystemPollerClock(maxChunk: maxChunk, sleeper: { ns in
            await recorder.record(ns)
            try await Task.sleep(nanoseconds: ns)  // real sleep so the wall clock advances
        })
        try await clock.sleep(until: Date().addingTimeInterval(0.08))
        let calls = await recorder.calls
        // Pre-fix single-sleep code would make exactly one 0.08s call.
        #expect(calls.count > 1)
        let maxNs = UInt64((maxChunk + 0.001) * 1_000_000_000)
        #expect(calls.allSatisfy { $0 <= maxNs })
    }

    @Test func cancellationWakesSleepPromptly() async throws {
        let start = Date()
        let task = Task {
            try await SystemPollerClock().sleep(until: Date().addingTimeInterval(30))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let result = await task.result
        // Must finish well before the 30s deadline (generous bound for CI load).
        #expect(Date().timeIntervalSince(start) < 15)
        guard case .failure(let error) = result else {
            Issue.record("expected sleep to throw after cancellation")
            return
        }
        #expect(error is CancellationError)
    }
}
