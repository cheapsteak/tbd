import Darwin
import Foundation
import Testing
import TBDShared
@testable import TBDApp

/// Tests for the app-side sidecar client's header demux — the mechanism that
/// keeps concurrent attaches from cross-delivering vended fds (review finding
/// B3). All tests drive an adopted `socketpair()` end; no on-disk socket.
@Suite("FDSidecarClient")
struct FDSidecarClientTests {

    private func makeSocketPair() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        try pair.withUnsafeMutableBufferPointer { buf in
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress) == 0 else {
                throw FDChannelError.sendFailed(errno)
            }
        }
        return (pair[0], pair[1])
    }

    /// Allocate a pipe, returning (readFD, writeFD).
    private func makePipe() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        try fds.withUnsafeMutableBufferPointer { buf in
            guard pipe(buf.baseAddress) == 0 else {
                throw FDChannelError.sendFailed(errno)
            }
        }
        return (fds[0], fds[1])
    }

    private func vend(readFD: Int32, worktreeID: UUID, paneID: String, attachID: UUID, over socket: Int32) throws {
        let header = try JSONEncoder().encode(FDVendHeader(worktreeID: worktreeID, paneID: paneID, attachID: attachID))
        let frame = SidecarFrameCodec.encode(type: .fdVend, payload: header)
        try FDChannel.sendFD(readFD, over: socket, frame: frame)
        Darwin.close(readFD)
    }

    @Test("a header-matched vend is delivered to its waiter")
    func matchedDelivery() async throws {
        let (daemonSide, appSide) = try makeSocketPair()
        defer { Darwin.close(daemonSide) }
        let client = FDSidecarClient()
        client.adopt(fd: appSide)

        let worktreeID = UUID()
        let attachID = UUID()
        let promise = client.expectFD(worktreeID: worktreeID, paneID: "%1", attachID: attachID)

        let (readFD, writeFD) = try makePipe()
        defer { Darwin.close(writeFD) }
        try vend(readFD: readFD, worktreeID: worktreeID, paneID: "%1", attachID: attachID, over: daemonSide)

        let rxFD = try await promise.value(timeout: .seconds(2))
        defer { Darwin.close(rxFD) }

        let marker = Data("marker".utf8)
        _ = marker.withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress, $0.count) }
        var buffer = [UInt8](repeating: 0, count: 16)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(rxFD, $0.baseAddress, $0.count) }
        #expect(Data(buffer[0..<Int(n)]) == marker)
    }

    private static func isCloseOnExec(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFD)
        return flags >= 0 && (flags & FD_CLOEXEC) != 0
    }

    /// The discriminator for the test below it. `FD_CLOEXEC` is a property of a
    /// descriptor, not of the open file, and `SCM_RIGHTS` does not carry it —
    /// so the receiving side's descriptor arrives inheritable however loudly
    /// the sender flagged its own copy. Should this ever stop being true, the
    /// assertion below would pass without `FDSidecarClient` doing anything, and
    /// this row is what says so.
    @Test("the transport delivers what it was handed, inheritable")
    func transportDeliversInheritableDescriptors() throws {
        let (senderSide, receiverSide) = try makeSocketPair()
        defer { Darwin.close(senderSide); Darwin.close(receiverSide) }

        let (readFD, writeFD) = try makePipe()
        defer { Darwin.close(readFD); Darwin.close(writeFD) }
        // The sender's copy says close-on-exec as loudly as it can.
        #expect(fcntl(readFD, F_SETFD, FD_CLOEXEC) == 0)
        #expect(Self.isCloseOnExec(readFD))

        try FDChannel.sendFDMinimal(readFD, over: senderSide, payload: Data("x".utf8))
        let received = try FDChannel.receiveMessage(from: receiverSide, capacity: 4096)
        defer { received.fds.forEach { Darwin.close($0) } }

        let arrived = try #require(received.fds.first)
        #expect(
            !Self.isCloseOnExec(arrived),
            """
            the transport now delivers close-on-exec descriptors on its own, so the assertion \
            that FDSidecarClient sets the flag is vacuous and must be rewritten
            """)
    }

    /// A vended descriptor is a session's pty master and outlives every child
    /// this app spawns — a `forkpty` panel, a shelled-out git or PR-status
    /// probe. One inherited copy holds the session open past the panel that
    /// closed: no EOF at the far end, no death detection, no clean handback.
    /// The flag is therefore set in the receive loop, so it is already on by
    /// the time any waiter is resumed — not later, on the main actor, after an
    /// async return.
    ///
    /// Both production callers register through `expectFD` and are settled by
    /// that one loop — `HolderAttachClient.attach` (a holder session, empty
    /// `windowID`) and `DaemonClient.openAttach` (a control-mode pane) — so
    /// both key shapes are driven here.
    @Test("a vended descriptor is close-on-exec by the time its waiter sees it")
    func vendedDescriptorIsCloseOnExec() async throws {
        let (daemonSide, appSide) = try makeSocketPair()
        defer { Darwin.close(daemonSide) }
        let client = FDSidecarClient()
        client.adopt(fd: appSide)

        let worktreeID = UUID()
        let holderAttach = UUID()
        let controlAttach = UUID()
        let holderPromise = client.expectFD(
            worktreeID: worktreeID, paneID: "holder-pane", attachID: holderAttach)
        let controlPromise = client.expectFD(
            worktreeID: worktreeID, paneID: "%7", attachID: controlAttach)

        for (paneID, attachID) in [("holder-pane", holderAttach), ("%7", controlAttach)] {
            let (readFD, writeFD) = try makePipe()
            defer { Darwin.close(writeFD) }
            // Clear it on the sender's side, so "the flag rode across" is not
            // an available reading of a pass — the row above shows it cannot.
            #expect(fcntl(readFD, F_SETFD, 0) == 0)
            #expect(!Self.isCloseOnExec(readFD))
            try vend(readFD: readFD, worktreeID: worktreeID, paneID: paneID,
                     attachID: attachID, over: daemonSide)
        }

        let holderFD = try await holderPromise.value(timeout: .seconds(2))
        defer { Darwin.close(holderFD) }
        let controlFD = try await controlPromise.value(timeout: .seconds(2))
        defer { Darwin.close(controlFD) }

        #expect(
            Self.isCloseOnExec(holderFD),
            """
            a holder session's pty reached its waiter inheritable, so any child this app spawns \
            holds that session open for as long as it lives
            """)
        #expect(
            Self.isCloseOnExec(controlFD),
            """
            a control-mode attach's pty reached its waiter inheritable — the same window, on the \
            path that shares this receive loop
            """)
    }

    @Test("interleaved vends for two panes route by header, not arrival order")
    func interleavedVendsRouteByHeader() async throws {
        let (daemonSide, appSide) = try makeSocketPair()
        defer { Darwin.close(daemonSide) }
        let client = FDSidecarClient()
        client.adopt(fd: appSide)

        let worktreeID = UUID()
        // Register A first, B second…
        let attachA = UUID()
        let attachB = UUID()
        let promiseA = client.expectFD(worktreeID: worktreeID, paneID: "%A", attachID: attachA)
        let promiseB = client.expectFD(worktreeID: worktreeID, paneID: "%B", attachID: attachB)

        let (readA, writeA) = try makePipe()
        let (readB, writeB) = try makePipe()
        defer { Darwin.close(writeA); Darwin.close(writeB) }
        _ = Data("for-A".utf8).withUnsafeBytes { Darwin.write(writeA, $0.baseAddress, $0.count) }
        _ = Data("for-B".utf8).withUnsafeBytes { Darwin.write(writeB, $0.baseAddress, $0.count) }

        // …but vend B first, then A (reverse order).
        try vend(readFD: readB, worktreeID: worktreeID, paneID: "%B", attachID: attachB, over: daemonSide)
        try vend(readFD: readA, worktreeID: worktreeID, paneID: "%A", attachID: attachA, over: daemonSide)

        let rxA = try await promiseA.value(timeout: .seconds(2))
        let rxB = try await promiseB.value(timeout: .seconds(2))
        defer { Darwin.close(rxA); Darwin.close(rxB) }

        var buffer = [UInt8](repeating: 0, count: 16)
        let nA = buffer.withUnsafeMutableBytes { Darwin.read(rxA, $0.baseAddress, $0.count) }
        #expect(Data(buffer[0..<Int(nA)]) == Data("for-A".utf8))
        let nB = buffer.withUnsafeMutableBytes { Darwin.read(rxB, $0.baseAddress, $0.count) }
        #expect(Data(buffer[0..<Int(nB)]) == Data("for-B".utf8))
    }

    @Test("a vend frame split across writes (fd on the first chunk) still pairs and delivers")
    func splitFrameVendStillPairs() async throws {
        let (daemonSide, appSide) = try makeSocketPair()
        defer { Darwin.close(daemonSide) }
        let client = FDSidecarClient()
        client.adopt(fd: appSide)

        let worktreeID = UUID()
        let attachID = UUID()
        let promise = client.expectFD(worktreeID: worktreeID, paneID: "%split", attachID: attachID)

        let (readFD, writeFD) = try makePipe()
        defer { Darwin.close(writeFD) }
        _ = Data("split-ok".utf8).withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress, $0.count) }

        // Build the full vend frame, then send the first byte carrying the fd
        // (SCM_RIGHTS ancillary rides the first byte of its segment) and the
        // remainder as a plain write with no ancillary.
        let header = try JSONEncoder().encode(FDVendHeader(worktreeID: worktreeID, paneID: "%split", attachID: attachID))
        let frame = SidecarFrameCodec.encode(type: .fdVend, payload: header)
        let firstChunk = frame.prefix(1)
        let rest = frame.suffix(from: frame.startIndex + 1)
        try FDChannel.sendFD(readFD, over: daemonSide, frame: Data(firstChunk))
        Darwin.close(readFD)
        try FDChannel.sendData(Data(rest), over: daemonSide)

        let rxFD = try await promise.value(timeout: .seconds(2))
        defer { Darwin.close(rxFD) }
        var buffer = [UInt8](repeating: 0, count: 16)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(rxFD, $0.baseAddress, $0.count) }
        #expect(Data(buffer[0..<Int(n)]) == Data("split-ok".utf8))
    }

    @Test("sendInput writes a decodable input frame to the daemon side")
    func sendInputWritesFrame() async throws {
        let (daemonSide, appSide) = try makeSocketPair()
        defer { Darwin.close(daemonSide) }
        let client = FDSidecarClient()
        client.adopt(fd: appSide)

        let worktreeID = UUID()
        client.sendInput(worktreeID: worktreeID, paneID: "%in", bytes: Data("hi\r".utf8))

        // Read the framed input on the daemon side and decode it.
        let scanner = SidecarFrameScanner()
        var decoded: (header: SidecarInputHeader, bytes: Data)?
        let deadline = ContinuousClock.now + .seconds(2)
        while decoded == nil && ContinuousClock.now < deadline {
            let message = try FDChannel.receiveMessage(from: daemonSide, capacity: 4096)
            for frame in scanner.append(message.data) where frame.type == SidecarFrameType.input.rawValue {
                decoded = try SidecarFrameCodec.decodeInput(payload: frame.payload)
            }
        }
        let result = try #require(decoded)
        #expect(result.header.worktreeID == worktreeID)
        #expect(result.header.paneID == "%in")
        #expect(result.bytes == Data("hi\r".utf8))
    }

    @Test("sendPaste writes a decodable paste frame to the daemon side")
    func sendPasteWritesFrame() async throws {
        let (daemonSide, appSide) = try makeSocketPair()
        defer { Darwin.close(daemonSide) }
        let client = FDSidecarClient()
        client.adopt(fd: appSide)

        let worktreeID = UUID()
        let payload = Data("pasted content\n".utf8)
        client.sendPaste(worktreeID: worktreeID, paneID: "%pa", bytes: payload)

        // Read the framed paste on the daemon side and decode it.
        let scanner = SidecarFrameScanner()
        var decoded: (header: SidecarInputHeader, bytes: Data)?
        let deadline = ContinuousClock.now + .seconds(2)
        while decoded == nil && ContinuousClock.now < deadline {
            let message = try FDChannel.receiveMessage(from: daemonSide, capacity: 4096)
            for frame in scanner.append(message.data) where frame.type == SidecarFrameType.paste.rawValue {
                decoded = try SidecarFrameCodec.decodeTagged(payload: frame.payload)
            }
        }
        let result = try #require(decoded)
        #expect(result.header.worktreeID == worktreeID)
        #expect(result.header.paneID == "%pa")
        #expect(result.bytes == payload)
    }

    @Test("sendInput refuses an oversize payload — the frame is never written (R6-H3)")
    func sendInputOversizeRefused() async throws {
        let (daemonSide, appSide) = try makeSocketPair()
        defer { Darwin.close(daemonSide) }
        let client = FDSidecarClient()
        client.adopt(fd: appSide)

        let worktreeID = UUID()
        // One byte past the cap: had this been encoded and written, the
        // daemon-side scanner would desync and the whole shared sidecar
        // connection would tear down.
        let oversize = Data(repeating: 0x41, count: SidecarFrameCodec.maxPasteBytes + 1)
        client.sendInput(worktreeID: worktreeID, paneID: "%big", bytes: oversize)
        // A small frame follows on the SAME serial send queue: the first
        // frame the daemon side sees must be this one — proof the oversize
        // frame was refused, not merely delayed.
        client.sendInput(worktreeID: worktreeID, paneID: "%ok", bytes: Data("k".utf8))

        let scanner = SidecarFrameScanner()
        var decoded: (header: SidecarInputHeader, bytes: Data)?
        let deadline = ContinuousClock.now + .seconds(2)
        while decoded == nil && ContinuousClock.now < deadline {
            let message = try FDChannel.receiveMessage(from: daemonSide, capacity: 4096)
            for frame in scanner.append(message.data) where frame.type == SidecarFrameType.input.rawValue {
                decoded = try SidecarFrameCodec.decodeInput(payload: frame.payload)
                break
            }
        }
        let result = try #require(decoded)
        #expect(result.header.paneID == "%ok", "the oversize frame must never hit the wire")
        #expect(result.bytes == Data("k".utf8))
        #expect(!scanner.isDesynced)
    }

    @Test("sendInput reports its synchronous refusals instead of fabricating an ack (R19)")
    func sendInputReturnsWhetherTheFrameWasHandedOff() throws {
        let (daemonSide, appSide) = try makeSocketPair()
        defer { Darwin.close(daemonSide) }
        let client = FDSidecarClient()
        client.adopt(fd: appSide)

        let worktreeID = UUID()
        // The return value is the ack `TerminalPanelView.performOutgoingWrite`
        // hands to `OutgoingInputQueue`, and from there to the daemon's
        // injection path. A `sendInput` that returned nothing (or always
        // `true`) made the `.sidecarInput` arm fabricate "written" for a
        // payload it had just dropped, so the daemon would not fall back and
        // the prompt would be lost invisibly.
        let oversize = Data(repeating: 0x41, count: SidecarFrameCodec.maxPasteBytes + 1)
        #expect(client.sendInput(worktreeID: worktreeID, paneID: "%big", bytes: oversize) == false)

        // And a payload that IS handed to the send queue says so — otherwise
        // a mutation returning a constant `false` would satisfy the line
        // above and silently route every keystroke through the daemon's
        // fallback.
        #expect(client.sendInput(worktreeID: worktreeID, paneID: "%ok", bytes: Data("k".utf8)) == true)

        // Draining the frame is not decoration: `sendInput` returns as soon
        // as the write is QUEUED, so on its own the `true` above only says
        // "accepted for writing" — it does not say the bytes reached the
        // wire. Reading blocks until the write has landed and decodes what
        // arrived, which is what turns that `true` into an assertion about
        // the frame rather than about the queue. Deleting the drain would
        // leave the `#expect(... == true)` above satisfiable by a `sendInput`
        // that queued a block which then failed.
        //
        // It is *not* what keeps the process alive, so do not propagate the
        // pattern to a test that only needs to survive an un-drained write:
        // `adopt` sets `SO_NOSIGPIPE` on this fd (see
        // `SocketSIGPIPETests.adoptedSidecarSocketIsProtected`), so a write
        // racing the `defer`'s close returns `EPIPE` to the send queue's
        // `catch`, which logs and drops it.
        let scanner = SidecarFrameScanner()
        var decoded: (header: SidecarInputHeader, bytes: Data)?
        let deadline = ContinuousClock.now + .seconds(2)
        while decoded == nil && ContinuousClock.now < deadline {
            let message = try FDChannel.receiveMessage(from: daemonSide, capacity: 4096)
            for frame in scanner.append(message.data) where frame.type == SidecarFrameType.input.rawValue {
                decoded = try SidecarFrameCodec.decodeInput(payload: frame.payload)
                break
            }
        }
        let result = try #require(decoded)
        #expect(result.header.paneID == "%ok")
    }

    @Test("sendInput while disconnected is dropped without crashing")
    func sendInputWhileDisconnectedDrops() async throws {
        let client = FDSidecarClient()   // never connected
        client.sendInput(worktreeID: UUID(), paneID: "%x", bytes: Data("bytes".utf8))
        // Give the send queue a beat; reaching here without a crash is the point.
        try await Task.sleep(for: .milliseconds(50))
        #expect(!client.isConnected)
    }

    @Test("sendInput after the receive loop exits is dropped without crashing")
    func sendInputAfterLoopExitDrops() async throws {
        let (daemonSide, appSide) = try makeSocketPair()
        let client = FDSidecarClient()
        client.adopt(fd: appSide)

        Darwin.close(daemonSide)   // peer dies → receive loop hits EOF and tears down

        // Wait for the loop to finish teardown (socketFD == -1 under the barrier).
        var spins = 0
        while client.isConnected && spins < 200 {
            try await Task.sleep(for: .milliseconds(10))
            spins += 1
        }
        #expect(!client.isConnected)

        // Post-exit send races the just-closed fd: the disconnected guard must
        // drop it silently — no write into a recycled fd, no crash.
        client.sendInput(worktreeID: UUID(), paneID: "%late", bytes: Data("late".utf8))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!client.isConnected)
    }

    @Test("value(timeout:) throws timedOut when nothing is vended; a late vend is closed safely")
    func timeoutThenLateVend() async throws {
        let (daemonSide, appSide) = try makeSocketPair()
        defer { Darwin.close(daemonSide) }
        let client = FDSidecarClient()
        client.adopt(fd: appSide)

        let worktreeID = UUID()
        let attachID = UUID()
        let promise = client.expectFD(worktreeID: worktreeID, paneID: "%9", attachID: attachID)

        await #expect(throws: FDSidecarError.self) {
            _ = try await promise.value(timeout: .milliseconds(100))
        }

        // Late vend after the waiter timed out: the receive loop must close
        // the unmatched fd without crashing.
        let (readFD, writeFD) = try makePipe()
        defer { Darwin.close(writeFD) }
        try vend(readFD: readFD, worktreeID: worktreeID, paneID: "%9", attachID: attachID, over: daemonSide)
        try await Task.sleep(for: .milliseconds(200))
        // Reaching here without a crash is the assertion; the client stays usable.
        #expect(client.isConnected)
    }

    @Test("a valid vend followed by a desync-tripping tail in one read still delivers the fd")
    func validFrameBeforeDesyncStillDelivers() async throws {
        let (daemonSide, appSide) = try makeSocketPair()
        defer { Darwin.close(daemonSide) }
        let client = FDSidecarClient()
        client.adopt(fd: appSide)

        let worktreeID = UUID()
        let attachID = UUID()
        let promise = client.expectFD(worktreeID: worktreeID, paneID: "%desync", attachID: attachID)

        let (readFD, writeFD) = try makePipe()
        defer { Darwin.close(writeFD) }
        _ = Data("survives".utf8).withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress, $0.count) }

        // One sendmsg carrying: a complete valid fdVend frame (fd rides the
        // first byte's SCM_RIGHTS ancillary) IMMEDIATELY followed by a corrupt
        // outer length (0xFFFFFFFF > the 4 MiB cap) that trips the scanner's
        // isDesynced flag. The scanner returns the valid frame AND flags desync
        // in the same `append`; the receive loop must process the returned
        // frame (delivering the fd) BEFORE breaking on desync. Pre-fix it broke
        // first and this waiter got .disconnected instead of its fd.
        let header = try JSONEncoder().encode(
            FDVendHeader(worktreeID: worktreeID, paneID: "%desync", attachID: attachID))
        var combined = SidecarFrameCodec.encode(type: .fdVend, payload: header)
        combined.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])   // corrupt length → desync
        try FDChannel.sendFD(readFD, over: daemonSide, frame: combined)
        Darwin.close(readFD)

        // The valid frame's fd must arrive despite the trailing desync.
        let rxFD = try await promise.value(timeout: .seconds(2))
        defer { Darwin.close(rxFD) }
        var buffer = [UInt8](repeating: 0, count: 16)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(rxFD, $0.baseAddress, $0.count) }
        #expect(Data(buffer[0..<Int(n)]) == Data("survives".utf8))
    }

    @Test("socket EOF fails pending waiters with disconnected")
    func eofFailsPendingWaiters() async throws {
        let (daemonSide, appSide) = try makeSocketPair()
        let client = FDSidecarClient()
        client.adopt(fd: appSide)

        let promise = client.expectFD(worktreeID: UUID(), paneID: "%3", attachID: UUID())
        Darwin.close(daemonSide)   // daemon goes away

        await #expect(throws: FDSidecarError.self) {
            _ = try await promise.value(timeout: .seconds(2))
        }
        // The receive loop marks the client disconnected on EOF.
        try await Task.sleep(for: .milliseconds(200))
        #expect(!client.isConnected)
    }
}
