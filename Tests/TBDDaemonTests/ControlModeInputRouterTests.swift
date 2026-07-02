import Foundation
import Testing
import TBDShared
@testable import TBDDaemonLib

/// Unit tests for the sidecar-input → send-keys router. No tmux: the router's
/// `commandProvider` hands back a real `TmuxControlCommandClient` whose
/// `writeLine` records the stream writes synchronously (the correlator itself
/// is exercised, only its stdout is faked).
@Suite("ControlModeInputRouter")
struct ControlModeInputRouterTests {

    /// Thread-safe, synchronous recorder of stream writes in call order.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _writes: [String] = []
        func record(_ line: String) { lock.lock(); _writes.append(line); lock.unlock() }
        var writes: [String] { lock.lock(); defer { lock.unlock() }; return _writes }
    }

    /// Build a router whose single server "srv" resolves to a client backed by
    /// `recorder`. An unknown server resolves to nil.
    private func makeRouter(chunkSize: Int = 330,
                            latency: InputLatencyRecorder = InputLatencyRecorder())
        -> (ControlModeInputRouter, Recorder) {
        let recorder = Recorder()
        let client = TmuxControlCommandClient(
            writeLine: { recorder.record($0) },
            onFatalError: {})
        let router = ControlModeInputRouter(
            commandProvider: { server in server == "srv" ? client : nil },
            latency: latency,
            chunkSize: chunkSize)
        return (router, recorder)
    }

    /// Poll until `recorder` has at least `count` writes, or fail on timeout.
    private func waitForWrites(_ recorder: Recorder, count: Int,
                              timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if recorder.writes.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RouterTestError.timedOut(got: recorder.writes.count, want: count)
    }

    @Test("keystrokes for many frames are delivered to the stream in order")
    func orderedDelivery() async throws {
        let worktreeID = UUID()
        let (router, recorder) = makeRouter()
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")

        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: "%0")
        for i in 0..<50 { router.enqueue(header: header, bytes: Data([UInt8(i)])) }

        try await waitForWrites(recorder, count: 50)
        let expected = (0..<50).map { "send-keys -H -t %0 " + String(format: "%02x", UInt8($0)) }
        #expect(recorder.writes == expected)
        router.shutdown()
    }

    @Test("input for an unregistered pane is dropped, not sent")
    func unknownPaneDropped() async throws {
        let worktreeID = UUID()
        let (router, recorder) = makeRouter()
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")

        // The unknown-pane frame is enqueued FIRST; ordered delivery means it
        // is processed (and dropped) before the known frame's write appears.
        router.enqueue(header: SidecarInputHeader(worktreeID: worktreeID, paneID: "%9"),
                       bytes: Data([0x41]))
        router.enqueue(header: SidecarInputHeader(worktreeID: worktreeID, paneID: "%0"),
                       bytes: Data([0x42]))

        try await waitForWrites(recorder, count: 1)
        #expect(recorder.writes == ["send-keys -H -t %0 42"])
        router.shutdown()
    }

    @Test("an empty-bytes frame produces no write")
    func emptyBytesNoWrite() async throws {
        let worktreeID = UUID()
        let (router, recorder) = makeRouter()
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")

        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: "%0")
        router.enqueue(header: header, bytes: Data())      // no command
        router.enqueue(header: header, bytes: Data([0x5a]))

        try await waitForWrites(recorder, count: 1)
        #expect(recorder.writes == ["send-keys -H -t %0 5a"])
        router.shutdown()
    }

    @Test("each delivered event records exactly one latency sample")
    func latencySamplePerEvent() async throws {
        let worktreeID = UUID()
        // Constant clock → the recorder never emits/resets mid-run.
        let base = ContinuousClock.now
        let latency = InputLatencyRecorder(now: { base })
        let (router, recorder) = makeRouter(latency: latency)
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")

        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: "%0")
        for i in 0..<50 { router.enqueue(header: header, bytes: Data([UInt8(i)])) }

        try await waitForWrites(recorder, count: 50)
        #expect(latency.summarizeAndReset()?.count == 50)
        router.shutdown()
    }
}

private enum RouterTestError: Error { case timedOut(got: Int, want: Int) }
