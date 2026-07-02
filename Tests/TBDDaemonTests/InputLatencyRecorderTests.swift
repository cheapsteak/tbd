import Foundation
import Testing
@testable import TBDDaemonLib

/// Unit tests for the input-latency percentile recorder and its 1 Hz log gate.
@Suite("InputLatencyRecorder")
struct InputLatencyRecorderTests {

    /// A hand-cranked clock so the 1 Hz gate can be tested without real time.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        func advance(_ d: Duration) { lock.lock(); instant += d; lock.unlock() }
        var current: ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return instant }
    }

    @Test("percentiles over a known 1…100 ms distribution")
    func percentileMath() {
        let clock = FakeClock()   // never advanced → no interim emit/reset
        let recorder = InputLatencyRecorder(now: { clock.current })
        for i in 1...100 { recorder.record(.milliseconds(i)) }

        let summary = recorder.summarizeAndReset()
        #expect(summary?.count == 100)
        #expect(summary?.p50Ms == 50)
        #expect(summary?.p99Ms == 99)
        #expect(summary?.maxMs == 100)
    }

    @Test("percentiles over a tiny distribution use nearest-rank")
    func percentileTinyDistribution() {
        let clock = FakeClock()
        let recorder = InputLatencyRecorder(now: { clock.current })
        for ms in [10, 20, 30, 40] { recorder.record(.milliseconds(ms)) }

        let summary = recorder.summarizeAndReset()
        #expect(summary?.count == 4)
        #expect(summary?.p50Ms == 20)
        #expect(summary?.p99Ms == 40)
        #expect(summary?.maxMs == 40)
    }

    @Test("summarizeAndReset on no samples returns nil")
    func emptyReturnsNil() {
        let clock = FakeClock()
        let recorder = InputLatencyRecorder(now: { clock.current })
        #expect(recorder.summarizeAndReset() == nil)
    }

    @Test("no emit before the interval elapses; samples accumulate")
    func gateHoldsBeforeInterval() {
        let clock = FakeClock()
        let recorder = InputLatencyRecorder(now: { clock.current }, emitInterval: .seconds(1))
        recorder.record(.milliseconds(1))        // establishes the window
        clock.advance(.milliseconds(500))
        recorder.record(.milliseconds(2))        // < 1 s → no emit/reset

        // Both samples are still buffered (no emit happened).
        #expect(recorder.summarizeAndReset()?.count == 2)
    }

    @Test("emit fires and resets once the interval elapses")
    func gateFiresAfterInterval() {
        let clock = FakeClock()
        let recorder = InputLatencyRecorder(now: { clock.current }, emitInterval: .seconds(1))
        recorder.record(.milliseconds(1))        // establishes the window
        clock.advance(.milliseconds(1_100))
        recorder.record(.milliseconds(2))        // ≥ 1 s → emit + reset

        // The emitting record cleared the buffer, so nothing remains.
        #expect(recorder.summarizeAndReset() == nil)
    }
}
