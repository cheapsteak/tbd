import Foundation
import TestSupport
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
            chunkSize: chunkSize,
            executor: GateExecutor.shared)
        return (router, recorder)
    }

    /// Poll until `recorder` has at least `count` writes, or fail on timeout
    /// (shared `waitFor`, which keeps the post-deadline re-check this suite
    /// needed under parallel-suite load).
    @discardableResult
    private func waitForWrites(_ recorder: LineRecorder, count: Int,
                               sourceLocation: SourceLocation = #_sourceLocation) async throws -> Bool {
        try await waitFor("\(count) stream writes",
                          observed: { "\(recorder.writes.count): \(recorder.writes)" },
                          sourceLocation: sourceLocation) {
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

        try #require(await waitForWrites(recorder, count: 50))
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

        try #require(await waitForWrites(recorder, count: 1))
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

        try #require(await waitForWrites(recorder, count: 1))
        #expect(recorder.writes == ["send-keys -H -t %0 5a"])
        router.shutdown()
    }

    /// A router whose client AUTO-COMPLETES every written command with a success
    /// reply — required because `PasteExecutor` awaits `client.send(...)` (the
    /// keystroke path uses fire-and-forget `sendList`, but paste does not), so
    /// without a reply feed the consumer would hang on the first paste.
    ///
    /// Replies go through the shared `ReplyFeed`: one long-lived consumer hands
    /// them to the correlator in write order, which is the invariant its
    /// order-based matching assumes and that production gets from
    /// `TmuxControlSupervisor`'s single drain loop. Uniform verdicts make the
    /// difference latent here, but a per-write `Task { … }` is the shape that
    /// stranded `ControlModeInputHealthTests` under load (#494) — don't
    /// reintroduce it in either suite.
    private func makeSelfRespondingRouter(chunkSize: Int = 330)
        -> (ControlModeInputRouter, LineRecorder, ReplyFeed) {
        let (client, recorder, feed) = makeRespondingClient()
        let router = ControlModeInputRouter(
            commandProvider: { server in server == "srv" ? client : nil },
            chunkSize: chunkSize,
            executor: GateExecutor.shared)
        return (router, recorder, feed)
    }

    @Test("a paste enqueued between two keystrokes writes load/paste-buffer BETWEEN the send-keys")
    func pasteOrderedBetweenKeystrokes() async throws {
        let worktreeID = UUID()
        let (router, recorder, feed) = makeSelfRespondingRouter()
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")
        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: "%0")

        // input(A) → paste(P) → input(B), all enqueued in order on the one stream.
        router.enqueue(header: header, bytes: Data([0x41]))                       // "A"
        router.enqueuePaste(header: header, bytes: Data(repeating: 0x50, count: 8 * 1024))  // large "P…"
        router.enqueue(header: header, bytes: Data([0x42]))                       // "B"

        try #require(await waitForWrites(recorder, count: 4))
        let writes = recorder.writes
        #expect(writes.count == 4)
        // send-keys A, then load-buffer + paste-buffer -p, then send-keys B.
        #expect(writes[0] == "send-keys -H -t %0 41")
        #expect(writes[1].hasPrefix("load-buffer -b "))
        #expect(writes[2].hasPrefix("paste-buffer -d -p -b "))
        #expect(writes[2].hasSuffix("-t %0"))
        #expect(writes[3] == "send-keys -H -t %0 42")
        router.shutdown()
        await feed.finish()
    }

    @Test("a paste failure does not stall the stream: a following keystroke still lands")
    func pasteFailureDoesNotStall() async throws {
        // Client whose paste-buffer command FAILS (%error, tolerated); every
        // other command succeeds. The keystroke after the paste must still be
        // written — deliverPaste logs the failure and tears nothing down.
        //
        // These are MIXED verdicts, so the ordered feed is load-bearing rather
        // than latent: a per-write `Task { … }` could hand the `%error` to the
        // wrong queue entry. Sequential `PasteExecutor` sends happened to keep
        // that from biting here; the feed makes it structural.
        let (client, recorder, feed) = makeRespondingClient(
            shouldFail: { $0.hasPrefix("paste-buffer") })
        let router = ControlModeInputRouter(
            commandProvider: { server in server == "srv" ? client : nil },
            executor: GateExecutor.shared)

        let worktreeID = UUID()
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")
        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: "%0")

        router.enqueuePaste(header: header, bytes: Data(repeating: 0x50, count: 8 * 1024))
        router.enqueue(header: header, bytes: Data([0x5a]))   // "Z" after the failed paste

        // The follow-up keystroke must reach the stream despite the failed
        // paste. Assert THAT invariant directly rather than pinning it to the
        // LAST write: the failure-cleanup `delete-buffer` and the keystroke are
        // order-independent (buffer GC vs a keypress), so `.last` couples the
        // test to an incidental ordering. Wait for the keystroke itself.
        try #require(await waitFor("the post-paste keystroke reaches the stream",
                                   observed: { "\(recorder.writes.count): \(recorder.writes)" }) {
            recorder.writes.contains("send-keys -H -t %0 5a")
        })
        router.shutdown()
        await feed.finish()
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

        try #require(await waitForWrites(recorder, count: 50))
        #expect(latency.summarizeAndReset()?.count == 50)
        router.shutdown()
    }

    @Test("the delivery pipeline runs on the injected executor")
    func deliveryRunsOnTheInjectedExecutor() async throws {
        // The seam every bound in this suite and in `ControlModeInputHealth`
        // now rests on, pinned rather than remembered — the same shape
        // `ServerShutdownLatchTests.latchRunsItsBodyOnTheInjectedExecutor`
        // uses for `ShutdownLatch(executor:)`.
        //
        // Delivering one keystroke costs several suspension hops — the
        // consumer, the `commandProvider` lookup, the `TmuxControlCommandClient`
        // actor, the reply feed's drain — and on a saturated pass each hop
        // costs that pass's own per-test latency, which is how these suites
        // came to report partial progress ("observed 2 of 4 writes") at a 90 s
        // bound with every assertion in them sound. No bound buys a hop its
        // turn; taking the hops off the shared queue is the fix. Drop the
        // `executor:` argument below and this is what goes red.
        let providerThread = DeliveryThreadNameBox()
        let inputThread = DeliveryThreadNameBox()
        let healthThread = DeliveryThreadNameBox()
        // send-keys replies `%error`, so the health edge fires — and it is
        // reported from inside the correlator actor, one SE-0417 default-actor
        // hop past the consumer, which is the half a call-site-only
        // `gateHoldingTask` could never have reached.
        let (client, recorder, feed) = makeRespondingClient(
            shouldFail: { $0.hasPrefix("send-keys") })
        let router = ControlModeInputRouter(
            commandProvider: { server in
                providerThread.recordCurrentThread()
                return server == "srv" ? client : nil
            },
            onHealthChange: { _, _, _, _ in healthThread.recordCurrentThread() },
            onInput: { _ in inputThread.recordCurrentThread() },
            executor: GateExecutor.shared)

        let worktreeID = UUID()
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")
        router.enqueue(header: SidecarInputHeader(worktreeID: worktreeID, paneID: "%0"),
                       bytes: Data([0x41]))

        try #require(await waitForWrites(recorder, count: 1))
        // `reportDelivery` runs synchronously inside `client.handle`, so one
        // delivered reply block means the health sink has already been called.
        try #require(await feed.waitForDeliveries(1))

        #expect(
            providerThread.name == GateExecutor.threadName,
            "the command-client lookup ran on \(providerThread.name ?? "an unnamed thread")")
        #expect(
            inputThread.name == GateExecutor.threadName,
            "delivery resumed on \(inputThread.name ?? "an unnamed thread") after the lookup")
        #expect(
            healthThread.name == GateExecutor.threadName,
            "the health edge fired on \(healthThread.name ?? "an unnamed thread")")
        router.shutdown()
        await feed.finish()
    }
}

/// Records the thread a point in the router's delivery pipeline ran on, from
/// inside that pipeline.
///
/// The read is synchronous on purpose: `Thread.current` is unavailable across a
/// suspension point precisely because the answer can change there, and which
/// thread each hop lands on is the thing under test.
private final class DeliveryThreadNameBox: @unchecked Sendable {
    private var value: String?
    private let lock = NSLock()

    func recordCurrentThread() {
        lock.lock()
        defer { lock.unlock() }
        value = Thread.current.name
    }

    var name: String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
