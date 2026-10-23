import Darwin
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
import TBDShared

/// `.clockDriven` bounds the classic virtual-time hang (a test-clock sleep
/// nobody advances); `.serialized` keeps the retry-window tests out of each
/// other's way, which is the house pattern for clock-driven suites here. The remaining tests are bounded-wait, so
/// serializing costs the suite almost nothing.
@Suite("FDVendingServer", .clockDriven, .serialized)
struct FDVendingServerTests {

    /// The retry pacing these tests inject. Deliberately the same *shape* as
    /// production (a fixed interval between connection checks) with a smaller
    /// attempt budget, so advance chains stay in the single digits per
    /// `Tests/CLAUDE.md` — "exhaustion" below means exhausting the injected
    /// budget, and each test's name says what it actually crosses.
    private static let interval: Duration = .milliseconds(50)

    /// A peer every identity read names at once, for the tests below that are
    /// about which connection is current rather than about who is on it.
    private static let peer = ProcessIdentity(
        pid: 7, startedAt: Date(timeIntervalSince1970: 7), commandLine: "/opt/acme/TBDApp")
    private static let identifiedPeer: @Sendable (Int32) -> ProcessIdentity? = { _ in
        FDVendingServerTests.peer
    }

    /// Waits until a `send` is either parked on its next retry wait or has
    /// finished, for the "still retrying" reads below. `advance` resumes a due
    /// sleeper without running it, so reading the finished flag straight after
    /// an advance would pass whether or not that wake was the last one; this
    /// waits for the outcome to show, and the caller's read then discriminates.
    private func parkedOrFinished(_ clock: EventDrivenTestClock,
                                  _ finished: SidecarInputCollector) async -> Bool {
        await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            clock.hasSleeper || finished.count > 0
        } == .satisfied
    }

    private func makeSocketPair() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        try pair.withUnsafeMutableBufferPointer { buf in
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress) == 0 else {
                throw FDChannelError.sendFailed(errno)
            }
        }
        return (pair[0], pair[1])
    }

    private func makePipe() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        try fds.withUnsafeMutableBufferPointer { buf in
            guard pipe(buf.baseAddress) == 0 else { throw FDChannelError.sendFailed(errno) }
        }
        return (fds[0], fds[1])
    }

    // MARK: daemon → app framed fd vend

    @Test("adopting a client fd allows sending a framed fd to that peer")
    func adoptAndSend() async throws {
        let (serverSideFD, clientSideFD) = try makeSocketPair()
        defer { Darwin.close(clientSideFD) }

        let server = FDVendingServer()
        await server.adoptConnection(fd: serverSideFD)
        defer { Task { await server.disconnect() } }

        let (readFD, writeFD) = try makePipe()
        defer { Darwin.close(writeFD) }

        let header = try JSONEncoder().encode(FDVendHeader(worktreeID: UUID(), paneID: "%3", attachID: UUID()))
        try await server.send(fd: readFD, header: header)
        Darwin.close(readFD)

        let (rxFD, rxHeader) = try SidecarTestSupport.receiveVend(from: clientSideFD)
        defer { Darwin.close(rxFD) }
        #expect(rxHeader.paneID == "%3")

        // sanity: the received fd is a real pipe end
        let msg = Data("ok".utf8)
        _ = msg.withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress, $0.count) }
        var buf = [UInt8](repeating: 0, count: 8)
        let n = buf.withUnsafeMutableBytes { Darwin.read(rxFD, $0.baseAddress, $0.count) }
        #expect(Int(n) == msg.count)
    }

    @Test("send without an adopted connection throws once its retry window is exhausted")
    func sendBeforeAdoptFails() async throws {
        // Tier 1: virtual time. 3 attempts → 2 waits; crossing both exhausts
        // the window, which is the same claim the 10/50 ms production pair
        // makes over 450 ms of real time.
        let clock = EventDrivenTestClock()
        let server = FDVendingServer(retryAttempts: 3, retryInterval: Self.interval, clock: clock)

        let send = Task { try await server.send(fd: 0, header: Data()) }
        try await clock.requireAdvanceWhenArmed(by: Self.interval)
        try await clock.requireAdvanceWhenArmed(by: Self.interval)

        await #expect(throws: FDVendingServerError.notConnected) { try await send.value }
    }

    @Test("the retry loop vends to a client that only connects mid-window")
    func sendSucceedsWhenClientAdoptsMidWindow() async throws {
        // The behaviour the docstring claims — papering over a connect-vs-accept
        // race — and the half nothing asserted before this test: that the retry
        // can SUCCEED, not merely that it eventually gives up.
        let (serverSideFD, clientSideFD) = try makeSocketPair()
        defer { Darwin.close(clientSideFD) }

        let clock = EventDrivenTestClock()
        let server = FDVendingServer(retryAttempts: 5, retryInterval: Self.interval, clock: clock)

        let (readFD, writeFD) = try makePipe()
        defer { Darwin.close(writeFD) }
        let header = try JSONEncoder().encode(
            FDVendHeader(worktreeID: UUID(), paneID: "%late", attachID: UUID()))

        let send = Task { try await server.send(fd: readFD, header: header) }

        // Two intervals with nobody connected: still retrying, not yet failed.
        try await clock.requireAdvanceWhenArmed(by: Self.interval)
        try await clock.requireAdvanceWhenArmed(by: Self.interval)

        // The app finally connects, mid-window. Waiting for the re-arm first
        // is what puts `send` inside the actor's sleep — `advance` resumes the
        // sleeper without running it — so this adoption lands while it is
        // parked and the next iteration re-reads `clientFD`.
        try await clock.requireSleeperArmed()
        await server.adoptConnection(fd: serverSideFD)
        try await clock.requireAdvanceWhenArmed(by: Self.interval)

        try await send.value   // must NOT throw
        Darwin.close(readFD)

        let (rxFD, rxHeader) = try SidecarTestSupport.receiveVend(from: clientSideFD)
        defer { Darwin.close(rxFD) }
        #expect(rxHeader.paneID == "%late", "the late-adopted client must receive the vend")

        await server.disconnect()
    }

    @Test("send gives up on its last retry interval, not before")
    func sendGivesUpOnlyOnItsLastInterval() async throws {
        // Pins the attempt count itself: with N attempts there are N-1 waits,
        // so at N-2 crossings it must still be retrying and the N-1st crossing
        // is what makes it throw. Nothing pinned this boundary before.
        let clock = EventDrivenTestClock()
        let attempts = 4
        let server = FDVendingServer(retryAttempts: attempts, retryInterval: Self.interval, clock: clock)

        let finished = SidecarInputCollector()   // reused as a thread-safe flag holder
        let send = Task {
            defer { finished.record(SidecarInputHeader(worktreeID: UUID(), paneID: ""), Data()) }
            try await server.send(fd: 0, header: Data())
        }

        try await clock.requireAdvanceWhenArmed(by: Self.interval)
        try await clock.requireAdvanceWhenArmed(by: Self.interval)

        // Either re-armed for wait 3 of 3 or finished: waiting for one of the
        // two is the happens-before that makes the count check non-vacuous,
        // since `advance` resumes the second wait without running what follows.
        #expect(await parkedOrFinished(clock, finished))
        #expect(finished.count == 0,
                "must still be retrying after \(attempts - 2) of its \(attempts - 1) waits")

        try await clock.requireAdvanceWhenArmed(by: Self.interval)
        await #expect(throws: FDVendingServerError.notConnected) { try await send.value }
    }

    @Test("the default retry interval is 50 ms")
    func defaultRetryIntervalIsFiftyMilliseconds() async throws {
        // The injected-pacing tests above deliberately say nothing about the
        // production numbers. This one pins the default interval exactly, in
        // two advances: 2 attempts → exactly 1 wait, so 49 ms must not fire it
        // and the 50th millisecond must.
        let clock = EventDrivenTestClock()
        let server = FDVendingServer(retryAttempts: 2, clock: clock)   // default interval

        let finished = SidecarInputCollector()
        let send = Task {
            defer { finished.record(SidecarInputHeader(worktreeID: UUID(), paneID: ""), Data()) }
            try await server.send(fd: 0, header: Data())
        }

        try await clock.requireAdvanceWhenArmed(by: .milliseconds(49))
        #expect(await parkedOrFinished(clock, finished))   // still parked → the wait is > 49 ms
        #expect(finished.count == 0, "a 50 ms interval must not elapse at 49 ms")

        try await clock.requireAdvanceWhenArmed(by: .milliseconds(1))
        await #expect(throws: FDVendingServerError.notConnected) { try await send.value }
    }

    @Test("bytes written to the daemon-side pipe reach the client-side reader")
    func endToEndPipeThroughVendedFD() async throws {
        let (serverSideFD, clientSideFD) = try makeSocketPair()
        defer { Darwin.close(clientSideFD) }

        let server = FDVendingServer()
        await server.adoptConnection(fd: serverSideFD)
        defer { Task { await server.stop() } }

        let (readFD, writeFD) = try makePipe()

        let header = try JSONEncoder().encode(FDVendHeader(worktreeID: UUID(), paneID: "%42", attachID: UUID()))
        try await server.send(fd: readFD, header: header)
        Darwin.close(readFD)

        let (rxFD, rxHeader) = try SidecarTestSupport.receiveVend(from: clientSideFD)
        defer { Darwin.close(rxFD) }
        #expect(rxHeader.paneID == "%42")

        // Write in three chunks, verify the reader assembles them.
        for chunk in ["ab", "cde", "fgh"] {
            let data = Data(chunk.utf8)
            _ = data.withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress, $0.count) }
        }
        Darwin.close(writeFD)  // signal EOF

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 32)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(rxFD, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            received.append(contentsOf: buffer[0..<Int(n)])
        }
        #expect(received == Data("abcdefgh".utf8))
    }

    // MARK: app → daemon input frames

    @Test("an app input frame is delivered to onInput tagged with its header")
    func inputFrameReachesOnInput() async throws {
        let (serverSideFD, clientSideFD) = try makeSocketPair()
        defer { Darwin.close(clientSideFD) }

        let collector = SidecarInputCollector()
        let server = FDVendingServer()
        await server.setOnInput { header, bytes in collector.record(header, bytes) }
        await server.adoptConnection(fd: serverSideFD)
        defer { Task { await server.stop() } }

        let worktreeID = UUID()
        let frame = try SidecarFrameCodec.encodeInput(
            header: SidecarInputHeader(worktreeID: worktreeID, paneID: "%7"),
            bytes: Data("ls -la\r".utf8))
        try FDChannel.sendData(frame, over: clientSideFD)

        #expect(await waitUntil { collector.count == 1 })
        let item = try #require(collector.all.first)
        #expect(item.header.worktreeID == worktreeID)
        #expect(item.header.paneID == "%7")
        #expect(item.bytes == Data("ls -la\r".utf8))
    }

    @Test("0-byte and 4 KiB input payloads both round-trip to onInput")
    func inputFramePayloadSizes() async throws {
        let (serverSideFD, clientSideFD) = try makeSocketPair()
        defer { Darwin.close(clientSideFD) }

        let collector = SidecarInputCollector()
        let server = FDVendingServer()
        await server.setOnInput { header, bytes in collector.record(header, bytes) }
        await server.adoptConnection(fd: serverSideFD)
        defer { Task { await server.stop() } }

        let worktreeID = UUID()
        let empty = Data()
        let big = Data(repeating: 0x41, count: 4096)
        let f0 = try SidecarFrameCodec.encodeInput(
            header: SidecarInputHeader(worktreeID: worktreeID, paneID: "%0"), bytes: empty)
        let f1 = try SidecarFrameCodec.encodeInput(
            header: SidecarInputHeader(worktreeID: worktreeID, paneID: "%1"), bytes: big)
        try FDChannel.sendData(f0, over: clientSideFD)
        try FDChannel.sendData(f1, over: clientSideFD)

        #expect(await waitUntil { collector.count == 2 })
        let items = collector.all
        #expect(items.contains { $0.header.paneID == "%0" && $0.bytes.isEmpty })
        #expect(items.contains { $0.header.paneID == "%1" && $0.bytes == big })
    }

    @Test("two input frames written in one burst arrive as two onInput calls")
    func twoInputFramesInOneBurst() async throws {
        let (serverSideFD, clientSideFD) = try makeSocketPair()
        defer { Darwin.close(clientSideFD) }

        let collector = SidecarInputCollector()
        let server = FDVendingServer()
        await server.setOnInput { header, bytes in collector.record(header, bytes) }
        await server.adoptConnection(fd: serverSideFD)
        defer { Task { await server.stop() } }

        let worktreeID = UUID()
        var burst = Data()
        burst.append(try SidecarFrameCodec.encodeInput(
            header: SidecarInputHeader(worktreeID: worktreeID, paneID: "%a"), bytes: Data("A".utf8)))
        burst.append(try SidecarFrameCodec.encodeInput(
            header: SidecarInputHeader(worktreeID: worktreeID, paneID: "%b"), bytes: Data("B".utf8)))
        try FDChannel.sendData(burst, over: clientSideFD)   // both frames in one write

        #expect(await waitUntil { collector.count == 2 })
        let panes = collector.all.map(\.header.paneID)
        #expect(panes.contains("%a"))
        #expect(panes.contains("%b"))
    }

    // MARK: app → daemon paste frames

    @Test("an app paste frame is delivered to onPaste (not onInput) tagged with its header")
    func pasteFrameReachesOnPaste() async throws {
        let (serverSideFD, clientSideFD) = try makeSocketPair()
        defer { Darwin.close(clientSideFD) }

        let inputs = SidecarInputCollector()
        let pastes = SidecarInputCollector()
        let server = FDVendingServer()
        await server.setOnInput { header, bytes in inputs.record(header, bytes) }
        await server.setOnPaste { header, bytes in pastes.record(header, bytes) }
        await server.adoptConnection(fd: serverSideFD)
        defer { Task { await server.stop() } }

        let worktreeID = UUID()
        let big = Data(repeating: 0x50, count: 8 * 1024)
        let frame = try SidecarFrameCodec.encodePaste(
            header: SidecarInputHeader(worktreeID: worktreeID, paneID: "%p"), bytes: big)
        try FDChannel.sendData(frame, over: clientSideFD)

        #expect(await waitUntil { pastes.count == 1 })
        let item = try #require(pastes.all.first)
        #expect(item.header.worktreeID == worktreeID)
        #expect(item.header.paneID == "%p")
        #expect(item.bytes == big)
        // The paste must NOT leak into the keystroke sink.
        #expect(inputs.count == 0)
    }

    @Test("interleaved input+paste+input frames reach their sinks in wire order")
    func interleavedInputPasteOrder() async throws {
        let (serverSideFD, clientSideFD) = try makeSocketPair()
        defer { Darwin.close(clientSideFD) }

        // Both sinks append to ONE ordered recorder so we can assert wire order
        // across the two callbacks (the sidecar delivers both from one thread).
        let sequence = TaggedFrameSequence()
        let server = FDVendingServer()
        await server.setOnInput { header, _ in sequence.record(kind: "input", pane: header.paneID) }
        await server.setOnPaste { header, _ in sequence.record(kind: "paste", pane: header.paneID) }
        await server.adoptConnection(fd: serverSideFD)
        defer { Task { await server.stop() } }

        let worktreeID = UUID()
        // input(%1) → paste(%2) → input(%3), all in one burst.
        var burst = Data()
        burst.append(try SidecarFrameCodec.encodeInput(
            header: SidecarInputHeader(worktreeID: worktreeID, paneID: "%1"), bytes: Data("a".utf8)))
        burst.append(try SidecarFrameCodec.encodePaste(
            header: SidecarInputHeader(worktreeID: worktreeID, paneID: "%2"), bytes: Data(repeating: 0x41, count: 100)))
        burst.append(try SidecarFrameCodec.encodeInput(
            header: SidecarInputHeader(worktreeID: worktreeID, paneID: "%3"), bytes: Data("b".utf8)))
        try FDChannel.sendData(burst, over: clientSideFD)

        #expect(await waitUntil { sequence.count == 3 })
        #expect(sequence.all == [
            "input:%1", "paste:%2", "input:%3",
        ])
    }

    @Test("after the app dies, the stale client fd is cleared so send refuses (no cross-fd write)")
    func sendAfterAppDeathClearsStaleFD() async throws {
        let (serverSideFD, clientSideFD) = try makeSocketPair()

        // Deterministic teardown: the exit hook now fires AFTER the actor clears
        // clientFD, so once it fires the stale fd is already gone.
        let exited = SidecarInputCollector()
        let clock = EventDrivenTestClock()
        let server = FDVendingServer(retryAttempts: 3, retryInterval: Self.interval, clock: clock)
        await server.setOnReceiveLoopExit {
            exited.record(SidecarInputHeader(worktreeID: UUID(), paneID: ""), Data())
        }
        await server.adoptConnection(fd: serverSideFD)

        Darwin.close(clientSideFD)   // app dies → reader sees EOF
        #expect(await waitUntil { exited.count == 1 })

        // A real payload fd to vend. The point: send() must REFUSE because the
        // stale clientFD was cleared — NOT sendmsg() a vend frame into a closed
        // or recycled fd number. The retry window is virtual here (3 attempts →
        // 2 waits), so exhausting it costs no wall time, but the assertion is
        // unchanged: it must still throw rather than write.
        let (readFD, writeFD) = try makePipe()
        defer { Darwin.close(readFD); Darwin.close(writeFD) }
        let header = try JSONEncoder().encode(FDVendHeader(worktreeID: UUID(), paneID: "%stale", attachID: UUID()))
        let send = Task { try await server.send(fd: readFD, header: header) }
        try await clock.requireAdvanceWhenArmed(by: Self.interval)
        try await clock.requireAdvanceWhenArmed(by: Self.interval)
        await #expect(throws: FDVendingServerError.notConnected) { try await send.value }

        await server.stop()
    }

    @Test("a superseded receive thread cannot deliver stale frames after a new adoption")
    func staleThreadFramesDroppedAfterAdopt() async throws {
        let (oldServerFD, oldClientFD) = try makeSocketPair()
        let (newServerFD, newClientFD) = try makeSocketPair()
        defer { Darwin.close(oldClientFD); Darwin.close(newClientFD) }

        // The sink BLOCKS on the old connection's first frame until released,
        // holding the OLD receive thread mid-loop (past its read, second frame
        // decoded but undelivered) while the NEW connection is adopted — the
        // exact interleave that would break wire order == stream order.
        let sequence = TaggedFrameSequence()
        // Blocks the server's dedicated receive `Thread`, never a
        // cooperative-pool thread, so this gate needs no `gateHoldingTask`.
        let releaseSink = DispatchSemaphore(value: 0)
        let exits = TaggedFrameSequence()
        let server = FDVendingServer()
        await server.setOnInput { header, _ in
            sequence.record(kind: "input", pane: header.paneID)
            if header.paneID == "%old-1" {
                releaseSink.waitForGate("FDVendingServer superseded receive thread held mid-loop")
            }
        }
        await server.setOnReceiveLoopExit { exits.record(kind: "exit", pane: "") }
        await server.adoptConnection(fd: oldServerFD)

        // Two frames in ONE write: the old thread reads both in one burst,
        // delivers the first, and is held with the second still pending.
        let worktreeID = UUID()
        var burst = Data()
        burst.append(try SidecarFrameCodec.encodeInput(
            header: SidecarInputHeader(worktreeID: worktreeID, paneID: "%old-1"), bytes: Data("a".utf8)))
        burst.append(try SidecarFrameCodec.encodeInput(
            header: SidecarInputHeader(worktreeID: worktreeID, paneID: "%old-2"), bytes: Data("b".utf8)))
        try FDChannel.sendData(burst, over: oldClientFD)
        #expect(await waitUntil { sequence.count == 1 })

        // Reconnect: the app's new socket replaces the old one.
        await server.adoptConnection(fd: newServerFD)

        // Release the old thread — its buffered second frame is now stale and
        // must be dropped, not delivered into the shared sinks.
        releaseSink.signal()
        #expect(await waitUntil { exits.count == 1 }, "superseded thread must exit")

        // The NEW connection's frames still flow.
        let newFrame = try SidecarFrameCodec.encodeInput(
            header: SidecarInputHeader(worktreeID: worktreeID, paneID: "%new-1"), bytes: Data("c".utf8))
        try FDChannel.sendData(newFrame, over: newClientFD)
        #expect(await waitUntil { sequence.count == 2 })

        #expect(sequence.all == ["input:%old-1", "input:%new-1"],
                "no old-connection frame may reach the sink after adoption")

        await server.stop()
    }

    @Test("the receive loop exits when the client disconnects")
    func receiveLoopExitsOnDisconnect() async throws {
        let (serverSideFD, clientSideFD) = try makeSocketPair()

        let exited = SidecarInputCollector()   // reuse as a thread-safe flag holder
        let server = FDVendingServer()
        await server.setOnReceiveLoopExit {
            exited.record(SidecarInputHeader(worktreeID: UUID(), paneID: ""), Data())
        }
        await server.adoptConnection(fd: serverSideFD)

        Darwin.close(clientSideFD)   // app goes away → reader sees EOF
        #expect(await waitUntil { exited.count == 1 })

        await server.stop()
    }

    // MARK: peer identity at adopt

    /// Whether the daemon-side end of a socket pair has been closed, read from
    /// the client end without blocking: end of file once it has, `EAGAIN`
    /// while it is still open.
    private func peerHasClosed(_ clientSideFD: Int32) -> Bool {
        _ = fcntl(clientSideFD, F_SETFL, fcntl(clientSideFD, F_GETFL) | O_NONBLOCK)
        var byte: UInt8 = 0
        return Darwin.read(clientSideFD, &byte, 1) == 0
    }

    /// A frame with no descriptor, for proving a connection is adopted:
    /// `sendFrame` refuses with `.notConnected` when none is.
    private static let probeFrame = SidecarFrameCodec.encode(type: .screenRequest, payload: Data())

    @Test("an identity read that fails once is retried, and the connection is adopted identified")
    func identityReadIsRetriedAfterATransientFailure() async throws {
        // A read fails for reasons that say nothing about the peer — a `ps`
        // spawn refused under load — and a connection adopted unidentified
        // turns every descriptor vended over it into a claim no app's death
        // can take back.
        let (serverSideFD, clientSideFD) = try makeSocketPair()
        defer { Darwin.close(clientSideFD) }
        let reads = ScriptedIdentityReads(failing: 1, then: Self.peer)
        let server = FDVendingServer(peerIdentity: { _ in reads.read() })

        await server.adoptConnection(fd: serverSideFD)

        #expect(await server.currentClientIdentity() == Self.peer, """
            a connection whose first identity read failed was adopted unidentified, so a dead \
            app's sessions vended over it can never be taken back
            """)
        #expect(reads.count == 2)

        await server.stop()
    }

    @Test("an identity no read answers is given up on after three attempts, and the connection is still adopted")
    func identityReadGivesUpAfterItsAttempts() async throws {
        let (serverSideFD, clientSideFD) = try makeSocketPair()
        defer { Darwin.close(clientSideFD) }
        // The read after the last attempt would answer, so a server that read
        // once too often would adopt an identity here rather than nil.
        let attempts = FDVendingServer.identityAttempts
        let reads = ScriptedIdentityReads(failing: attempts, then: Self.peer)
        let server = FDVendingServer(peerIdentity: { _ in reads.read() })

        await server.adoptConnection(fd: serverSideFD)

        #expect(attempts == 3, "the bound on reads held on the actor moved")
        #expect(await server.currentClientIdentity() == nil)
        #expect(reads.count == attempts, "the identity was read more or fewer times than its attempts")
        // Unidentified is still adopted: the app's tabs work, and only the
        // take-back on its death is lost.
        _ = try await server.sendFrame(Self.probeFrame)

        await server.stop()
    }

    @Test("adoption is one actor turn: a frame sent in the same turn goes out on the new connection")
    func adoptionIsOneActorTurn() async throws {
        // Nothing may run between a connection reaching the actor and its
        // installation. A vend that ran in between would go onto the socket
        // being replaced — about to be shut down, so its ack never comes —
        // while naming the replaced app, still alive, as the descriptor's
        // holder. `adoptAndSendFrame` is synchronous and isolated to the
        // server, so it compiles only while adoption has no suspension point;
        // the reads below check what that turn leaves behind.
        let (oldServerFD, oldClientFD) = try makeSocketPair()
        let (newServerFD, newClientFD) = try makeSocketPair()
        defer { Darwin.close(oldClientFD); Darwin.close(newClientFD) }
        let replacedApp = ProcessIdentity(
            pid: 8, startedAt: Date(timeIntervalSince1970: 8), commandLine: "/opt/acme/TBDApp")
        let server = FDVendingServer(peerIdentity: { $0 == oldServerFD ? replacedApp : Self.peer })
        await server.adoptConnection(fd: oldServerFD)

        let recipient = try await Self.adoptAndSendFrame(Self.probeFrame, adopting: newServerFD, on: server)

        #expect(recipient == Self.peer, """
            a frame sent in the adoption's own turn was recorded as going to the app being replaced
            """)
        // Already written by the time the turn ended, so a non-blocking read
        // finds it; a frame that went elsewhere fails here instead of hanging.
        _ = fcntl(newClientFD, F_SETFL, fcntl(newClientFD, F_GETFL) | O_NONBLOCK)
        let received = try FDChannel.receiveMessage(from: newClientFD, capacity: 1024)
        #expect(received.data == Self.probeFrame, "the new connection's peer did not receive the frame")
        // The replaced socket was shut down with nothing written on it: its
        // peer reads end of file, not a frame.
        #expect(peerHasClosed(oldClientFD), "the replaced connection was left open or written to")

        await server.stop()
    }

    /// Adopts `fd` and sends `frame` in one synchronous stretch on `server`'s
    /// actor, answering who the frame was recorded as going to. Synchronous on
    /// purpose: it compiles only while `adoptConnection(fd:stamp:)` — the entry
    /// the accept thread uses — is, which is what `adoptionIsOneActorTurn`
    /// pins.
    private static func adoptAndSendFrame(
        _ frame: Data, adopting fd: Int32, on server: isolated FDVendingServer
    ) throws -> ProcessIdentity? {
        server.adoptConnection(fd: fd, stamp: server.stampConnection())
        try server.sendFrame(frame)
        return server.currentClientIdentity()
    }

    @Test("an older connection whose adoption reaches the server after a newer one's is refused, and reports nothing")
    func anOlderConnectionAdoptedAfterANewerOneIsRefused() async throws {
        // The accept thread starts one task per connection, and those tasks
        // reach the actor in no fixed order. Installing the older connection
        // second would take the sidecar from the newer one — the socket its
        // peer is using — and, with a different app on each, report the live
        // app on the newer one as departed.
        let (olderServerFD, olderClientFD) = try makeSocketPair()
        let (newerServerFD, newerClientFD) = try makeSocketPair()
        defer { Darwin.close(olderClientFD); Darwin.close(newerClientFD) }
        let olderApp = ProcessIdentity(
            pid: 8, startedAt: Date(timeIntervalSince1970: 8), commandLine: "/opt/acme/TBDApp")
        let olderReads = ScriptedIdentityReads(failing: 0, then: olderApp)
        let departures = ReportedDepartures()
        let server = FDVendingServer(
            peerIdentity: { $0 == olderServerFD ? olderReads.read() : Self.peer })
        await server.setOnClientDisconnect { departures.record($0) }

        // Accepted in this order...
        let older = server.stampConnection()
        let newer = server.stampConnection()
        // ...and reaching the actor in the other.
        await server.adoptConnection(fd: newerServerFD, stamp: newer)
        await server.adoptConnection(fd: olderServerFD, stamp: older)

        #expect(await server.currentClientIdentity() == Self.peer, """
            an older connection whose adoption arrived late took the sidecar from the newer \
            connection its peer is using
            """)
        #expect(departures.count == 0, """
            refusing an older connection reported a departure — the live app on the newer \
            connection would be arbitrated as gone
            """)
        #expect(peerHasClosed(olderClientFD), "the refused connection's socket was left open")
        #expect(!peerHasClosed(newerClientFD), "the newer connection was torn down")
        #expect(olderReads.count == 0, "a connection refused on arrival was identified first")

        await server.stop()
    }

    @Test("no adoption installs after a stop, including one accepted before it")
    func adoptionsAfterAStopAreRefused() async throws {
        // A task the accept thread queued before `stop` can reach the actor
        // after it, and so can any caller that adopts later. A stopped server
        // installs neither.
        let (earlyServerFD, earlyClientFD) = try makeSocketPair()
        let (lateServerFD, lateClientFD) = try makeSocketPair()
        defer { Darwin.close(earlyClientFD); Darwin.close(lateClientFD) }
        let departures = ReportedDepartures()
        let server = FDVendingServer(peerIdentity: Self.identifiedPeer)
        await server.setOnClientDisconnect { departures.record($0) }

        let acceptedBeforeTheStop = server.stampConnection()
        await server.stop()
        await server.adoptConnection(fd: earlyServerFD, stamp: acceptedBeforeTheStop)
        await server.adoptConnection(fd: lateServerFD)

        #expect(await server.currentClientIdentity() == nil, "a stopped server adopted a connection")
        await #expect(throws: FDVendingServerError.notConnected) {
            try await server.sendFrame(Self.probeFrame)
        }
        #expect(peerHasClosed(earlyClientFD), """
            a connection accepted before the stop, adopted after it, was left open
            """)
        #expect(peerHasClosed(lateClientFD), "a connection adopted after the stop was left open")
        #expect(departures.count == 0)
    }

    @Test("a listen after a stop adopts connections accepted from then on, and none accepted before it")
    func aListenAfterAStopStartsAFreshLifetime() async throws {
        // `stop` refuses every later adoption, and a server that listens again
        // must take that back — or it binds a socket and closes every
        // connection made to it. What it must not take back is the refusal of a
        // connection accepted before the listen, whose task can still reach the
        // actor afterwards.
        let root = fencedScratchRoot(prefix: "tbd-fdv")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = "\(root)/vend.sock"
        let (earlyServerFD, earlyClientFD) = try makeSocketPair()
        let (lateServerFD, lateClientFD) = try makeSocketPair()
        defer { Darwin.close(earlyClientFD); Darwin.close(lateClientFD) }
        let server = FDVendingServer(peerIdentity: Self.identifiedPeer)

        try await server.listen(on: socketPath)
        await server.stop()
        let acceptedBeforeTheListen = server.stampConnection()
        try await server.listen(on: socketPath)

        // Adopted first, so only the listen's floor can refuse it: no
        // connection accepted after it has been installed yet.
        await server.adoptConnection(fd: earlyServerFD, stamp: acceptedBeforeTheListen)
        #expect(peerHasClosed(earlyClientFD), """
            a connection accepted before the server listened again was installed in the new \
            lifetime
            """)
        #expect(await server.currentClientIdentity() == nil)

        await server.adoptConnection(fd: lateServerFD)
        #expect(await server.currentClientIdentity() == Self.peer, """
            a server that listened again after a stop refused a connection accepted after the \
            listen
            """)
        #expect(!peerHasClosed(lateClientFD), "the connection accepted after the listen was torn down")
        _ = try await server.sendFrame(Self.probeFrame)

        await server.stop()
    }
}

/// Answers identity reads from a script: nil for the first `failing` reads,
/// then `identity` for every read after. Lock-guarded: the server reads on its
/// actor while the test reads the count from its own task.
private final class ScriptedIdentityReads: @unchecked Sendable {
    private let lock = NSLock()
    private let failing: Int
    private let identity: ProcessIdentity?
    private var reads = 0

    init(failing: Int, then identity: ProcessIdentity?) {
        self.failing = failing
        self.identity = identity
    }

    func read() -> ProcessIdentity? {
        lock.withLock {
            reads += 1
            return reads > failing ? identity : nil
        }
    }

    var count: Int { lock.withLock { reads } }
}

/// The departures a server reported through `onClientDisconnect`.
/// Lock-guarded: reported from the server's actor, read from the test's task.
private final class ReportedDepartures: @unchecked Sendable {
    private let lock = NSLock()
    private var reported: [ProcessIdentity?] = []

    func record(_ identity: ProcessIdentity?) {
        lock.withLock { reported.append(identity) }
    }

    var count: Int { lock.withLock { reported.count } }
}
