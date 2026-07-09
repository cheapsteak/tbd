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

    /// Build a router whose single server "srv" resolves to a client backed by
    /// `recorder`. An unknown server resolves to nil.
    private func makeRouter(chunkSize: Int = 330,
                            latency: InputLatencyRecorder = InputLatencyRecorder())
        -> (ControlModeInputRouter, LineRecorder) {
        let (client, recorder) = makeFakeClient()
        let router = ControlModeInputRouter(
            commandProvider: { server in server == "srv" ? client : nil },
            latency: latency,
            chunkSize: chunkSize)
        return (router, recorder)
    }

    /// Poll until `recorder` has at least `count` writes, or fail on timeout
    /// (shared `waitFor`, which keeps the post-deadline re-check this suite
    /// needed under parallel-suite load).
    private func waitForWrites(_ recorder: LineRecorder, count: Int,
                               sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await waitFor("\(count) stream writes", sourceLocation: sourceLocation) {
            recorder.writes.count >= count
        }
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

    /// Holds a weak ref to the client so the `writeLine` closure (created before
    /// the client) can feed replies back into it.
    private final class ClientHolder: @unchecked Sendable {
        weak var client: TmuxControlCommandClient?
    }

    /// A router whose client AUTO-COMPLETES every written command with a success
    /// reply — required because `PasteExecutor` awaits `client.send(...)` (the
    /// keystroke path uses fire-and-forget `sendList`, but paste does not), so
    /// without a reply feed the consumer would hang on the first paste. Each
    /// written stream line (a command list is one `\n`-joined write) is answered
    /// with one `%end` per contained command, preserving FIFO order.
    private func makeSelfRespondingRouter(chunkSize: Int = 330)
        -> (ControlModeInputRouter, LineRecorder) {
        let recorder = LineRecorder()
        let holder = ClientHolder()
        let client = TmuxControlCommandClient(
            writeLine: { line in
                recorder.record(line)
                let commandCount = line.split(separator: "\n", omittingEmptySubsequences: false).count
                Task {
                    for _ in 0..<commandCount {
                        await holder.client?.handle(
                            .commandSucceeded(number: 0, fromClient: true, lines: []))
                    }
                }
            },
            onFatalError: {})
        holder.client = client
        let router = ControlModeInputRouter(
            commandProvider: { server in server == "srv" ? client : nil },
            chunkSize: chunkSize)
        return (router, recorder)
    }

    @Test("a paste enqueued between two keystrokes writes load/paste-buffer BETWEEN the send-keys")
    func pasteOrderedBetweenKeystrokes() async throws {
        let worktreeID = UUID()
        let (router, recorder) = makeSelfRespondingRouter()
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")
        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: "%0")

        // input(A) → paste(P) → input(B), all enqueued in order on the one stream.
        router.enqueue(header: header, bytes: Data([0x41]))                       // "A"
        router.enqueuePaste(header: header, bytes: Data(repeating: 0x50, count: 8 * 1024))  // large "P…"
        router.enqueue(header: header, bytes: Data([0x42]))                       // "B"

        try await waitForWrites(recorder, count: 4)
        let writes = recorder.writes
        #expect(writes.count == 4)
        // send-keys A, then load-buffer + paste-buffer -p, then send-keys B.
        #expect(writes[0] == "send-keys -H -t %0 41")
        #expect(writes[1].hasPrefix("load-buffer -b "))
        #expect(writes[2].hasPrefix("paste-buffer -d -p -b "))
        #expect(writes[2].hasSuffix("-t %0"))
        #expect(writes[3] == "send-keys -H -t %0 42")
        router.shutdown()
    }

    @Test("a paste failure does not stall the stream: a following keystroke still lands")
    func pasteFailureDoesNotStall() async throws {
        // Client whose paste-buffer command FAILS (%error, tolerated). The
        // keystroke after the paste must still be written — deliverPaste logs
        // the failure and tears nothing down.
        let recorder = LineRecorder()
        let holder = ClientHolder()
        let client = TmuxControlCommandClient(
            writeLine: { line in
                recorder.record(line)
                let isPasteBuffer = line.hasPrefix("paste-buffer")
                Task {
                    // paste-buffer → %error (tolerated); everything else → %end.
                    if isPasteBuffer {
                        await holder.client?.handle(.commandFailed(number: 0, fromClient: true, lines: ["no pane"]))
                    } else {
                        await holder.client?.handle(.commandSucceeded(number: 0, fromClient: true, lines: []))
                    }
                }
            },
            onFatalError: {})
        holder.client = client
        let router = ControlModeInputRouter(
            commandProvider: { server in server == "srv" ? client : nil })

        let worktreeID = UUID()
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")
        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: "%0")

        router.enqueuePaste(header: header, bytes: Data(repeating: 0x50, count: 8 * 1024))
        router.enqueue(header: header, bytes: Data([0x5a]))   // "Z" after the failed paste

        // load-buffer, paste-buffer(fail), delete-buffer (cleanup on failure),
        // then send-keys Z → 4 writes; the keystroke must be last.
        try await waitForWrites(recorder, count: 4)
        #expect(recorder.writes.last == "send-keys -H -t %0 5a")
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
