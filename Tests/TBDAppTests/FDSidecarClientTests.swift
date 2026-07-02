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
        try FDChannel.sendFD(readFD, over: socket, header: header)
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
