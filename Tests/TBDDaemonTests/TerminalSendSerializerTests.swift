import Foundation
import Testing
@testable import TBDDaemonLib

/// Tier 2 — real concurrency, no tmux and no wall-clock deadlines in the
/// assertions: each arm hands control back through a continuation, so the proof
/// is ordering, not timing.
@Suite("terminal.send serialization")
struct TerminalSendSerializerTests {

    /// Records entry/exit order across tasks.
    private actor Trace {
        private(set) var events: [String] = []
        func note(_ event: String) { events.append(event) }
    }

    /// A one-shot gate a test can open from the outside.
    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            opened = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Poll until `condition` holds or the deadline passes. Bounded wait, not a
    /// sleep-as-synchronization: it bounds a hang and asserts nothing on its own.
    private func waitUntil(
        _ description: String, _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        struct Timeout: Error, CustomStringConvertible { let description: String }
        throw Timeout(description: "timed out waiting for \(description)")
    }

    @Test("a second send to the same terminal queues behind the first, and is not refused")
    func sameTerminalSerializes() async throws {
        let serializer = TerminalSendSerializer()
        let trace = Trace()
        let gate = Gate()
        let terminal = UUID()

        async let first: Void = serializer.run(terminalID: terminal) {
            await trace.note("first-in")
            await gate.wait()
            await trace.note("first-out")
        }
        // Let the first send take the lane before the second asks for it.
        try await waitUntil("the first send to enter") { await trace.events == ["first-in"] }

        async let second: Void = serializer.run(terminalID: terminal) {
            await trace.note("second-in")
            await trace.note("second-out")
        }
        // The second send must still be waiting: nothing new on the trace.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await trace.events == ["first-in"])

        await gate.open()
        _ = try await (first, second)

        // Queued, not interleaved — and not refused: both bodies ran.
        #expect(await trace.events == ["first-in", "first-out", "second-in", "second-out"])
    }

    @Test("sends to different terminals overlap")
    func differentTerminalsOverlap() async throws {
        let serializer = TerminalSendSerializer()
        let trace = Trace()
        let gate = Gate()

        async let first: Void = serializer.run(terminalID: UUID()) {
            await trace.note("a-in")
            await gate.wait()
            await trace.note("a-out")
        }
        try await waitUntil("the first send to enter") { await trace.events == ["a-in"] }

        // A different terminal is a different composer: this must run to
        // completion while the first is still holding its own lane.
        try await serializer.run(terminalID: UUID()) {
            await trace.note("b-in")
            await trace.note("b-out")
        }
        #expect(await trace.events == ["a-in", "b-in", "b-out"])

        await gate.open()
        try await first
        #expect(await trace.events == ["a-in", "b-in", "b-out", "a-out"])
    }

    @Test("a send that throws releases the lane and does not poison its successor")
    func throwingSendReleasesLane() async throws {
        struct Boom: Error {}
        let serializer = TerminalSendSerializer()
        let terminal = UUID()

        await #expect(throws: Boom.self) {
            try await serializer.run(terminalID: terminal) { throw Boom() }
        }
        let value = try await serializer.run(terminalID: terminal) { 42 }
        #expect(value == 42)
    }

    @Test("lanes are pruned once idle, so the table does not grow per terminal")
    func lanesArePruned() async throws {
        let serializer = TerminalSendSerializer()
        for _ in 0..<5 {
            try await serializer.run(terminalID: UUID()) {}
        }
        try await waitUntil("lanes to drain") { await serializer.trackedTerminalCount == 0 }
    }
}
