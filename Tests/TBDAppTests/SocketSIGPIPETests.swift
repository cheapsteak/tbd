import Darwin
import Foundation
import Testing
import TBDShared
@testable import TBDApp

/// The app writes to sockets whose peer (the daemon) can vanish mid-write.
/// Unprotected, that write raises SIGPIPE and the default disposition kills
/// TBDApp — every terminal panel with it — instead of handing the writer the
/// `EPIPE` its error path already handles.
///
/// **These tests deliberately assert the per-socket option and NOT the
/// process-wide disposition.** Asserting `signal(SIGPIPE, ...)` would mean
/// mutating it, which is process-wide state shared with every suite running
/// concurrently in this same test process — and it is the wrong fix anyway
/// (`SocketSIGPIPE` explains why: SwiftTerm's `forkpty` children inherit
/// `SIG_IGN` across exec).
@Suite("SocketSIGPIPE")
struct SocketSIGPIPETests {

    private func makeSocketPair() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        try pair.withUnsafeMutableBufferPointer { buf in
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress) == 0 else {
                throw FDChannelError.sendFailed(errno)
            }
        }
        return (pair[0], pair[1])
    }

    private func noSIGPIPE(on fd: Int32) -> Bool {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, &length) == 0 else { return false }
        return value != 0
    }

    @Test("suppress sets SO_NOSIGPIPE on the socket it is given")
    func suppressSetsTheOption() throws {
        let (a, b) = try makeSocketPair()
        defer { Darwin.close(a); Darwin.close(b) }
        #expect(!noSIGPIPE(on: a))   // the option is off on a fresh socket
        #expect(SocketSIGPIPE.suppress(on: a))
        #expect(noSIGPIPE(on: a))
    }

    /// `adopt(fd:)` is the one funnel every sidecar socket passes through —
    /// `connect(path:)` calls it, and so do the tests' `socketpair` ends — so
    /// this is the assertion that covers the production connection too.
    @Test("FDSidecarClient protects the socket it adopts")
    func adoptedSidecarSocketIsProtected() throws {
        let (daemonSide, appSide) = try makeSocketPair()
        defer { Darwin.close(daemonSide) }
        #expect(!noSIGPIPE(on: appSide))
        let client = FDSidecarClient()
        client.adopt(fd: appSide)   // ownership transfers; the receive loop closes it on EOF
        #expect(noSIGPIPE(on: appSide))
    }

    /// The window the crash lived in: a frame written to a socket whose peer
    /// has already closed, with nobody having waited for the receive loop to
    /// notice. With the option set this raises `EPIPE`, which the sidecar's
    /// `catch` logs and drops.
    ///
    /// **What this covers is the helper, not the production path.** It applies
    /// `SocketSIGPIPE.suppress` itself and never goes through
    /// `FDSidecarClient.adopt` or `DaemonClient.makeConnectedSocket`, so
    /// deleting the production call sites would not redden it. What it does
    /// prove is that a suppressed socket really does convert the peer-closed
    /// write into a catchable `EPIPE` — i.e. that the mechanism the production
    /// path relies on works, and that `sendData`'s error path is what runs.
    /// `adoptedSidecarSocketIsProtected` above is the test that detects a
    /// regression in the production path.
    ///
    /// The `#require` on `suppress` is load-bearing: a broken helper would
    /// otherwise leave the socket unprotected and this write would kill the
    /// whole test process by signal 13, discarding the run's summary line for
    /// every other suite — instead of failing here by name with the write
    /// never attempted.
    ///
    /// It is written against a raw `socketpair` rather than a live
    /// `FDSidecarClient` so the close and the write are strictly ordered on
    /// one thread: routing it through the client's `sendQueue` would race the
    /// receive loop's teardown and could not assert the throw at all.
    @Test("a write to a peer-closed protected socket throws EPIPE instead of killing the process")
    func writeToClosedPeerThrowsEPIPE() throws {
        let (daemonSide, appSide) = try makeSocketPair()
        defer { Darwin.close(appSide) }
        try #require(SocketSIGPIPE.suppress(on: appSide))

        Darwin.close(daemonSide)   // the daemon goes away with a frame still to write

        let error = #expect(throws: FDChannelError.self) {
            try FDChannel.sendData(Data("input frame".utf8), over: appSide)
        }
        #expect(error == .sendFailed(EPIPE))
    }
}
