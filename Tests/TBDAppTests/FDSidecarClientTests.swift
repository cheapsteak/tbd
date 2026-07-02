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
