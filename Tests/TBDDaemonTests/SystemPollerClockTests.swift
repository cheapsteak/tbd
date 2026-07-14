import Foundation
import Testing
@testable import TBDDaemonLib

@Suite struct SystemPollerClockTests {
    @Test func pastDeadlineReturnsImmediately() async throws {
        let start = Date()
        try await SystemPollerClock().sleep(until: start.addingTimeInterval(-10))
        // Generous bound: only asserting "did not actually sleep".
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func shortFutureDeadlineSleepsAtLeastTheInterval() async throws {
        let clock = SystemPollerClock()
        let start = Date()
        try await clock.sleep(until: start.addingTimeInterval(0.15))
        #expect(Date().timeIntervalSince(start) >= 0.14)
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
