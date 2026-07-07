import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

@Suite("FDVendingServer")
struct FDVendingServerTests {

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

    @Test("send without an adopted connection throws")
    func sendBeforeAdoptFails() async {
        let server = FDVendingServer()
        await #expect(throws: FDVendingServerError.notConnected) {
            try await server.send(fd: 0, header: Data())
        }
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
        let server = FDVendingServer()
        await server.setOnReceiveLoopExit {
            exited.record(SidecarInputHeader(worktreeID: UUID(), paneID: ""), Data())
        }
        await server.adoptConnection(fd: serverSideFD)

        Darwin.close(clientSideFD)   // app dies → reader sees EOF
        #expect(await waitUntil { exited.count == 1 })

        // A real payload fd to vend. The point: send() must REFUSE because the
        // stale clientFD was cleared — NOT sendmsg() a vend frame into a closed
        // or recycled fd number.
        let (readFD, writeFD) = try makePipe()
        defer { Darwin.close(readFD); Darwin.close(writeFD) }
        let header = try JSONEncoder().encode(FDVendHeader(worktreeID: UUID(), paneID: "%stale", attachID: UUID()))
        await #expect(throws: FDVendingServerError.notConnected) {
            try await server.send(fd: readFD, header: header)
        }

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
        let releaseSink = DispatchSemaphore(value: 0)
        let exits = TaggedFrameSequence()
        let server = FDVendingServer()
        await server.setOnInput { header, _ in
            sequence.record(kind: "input", pane: header.paneID)
            if header.paneID == "%old-1" { releaseSink.wait() }
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
}
