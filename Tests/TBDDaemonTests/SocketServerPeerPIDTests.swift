import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared
import TestSupport

/// The kernel's answer about who connected has to reach the handler that
/// decides on it, on the very first request, over a real socket.
///
/// Everything else about envelope suppression is stated over a hand-built
/// `RPCConnectionContext`: `EnvelopeSuppressionAuthTests` pins every way the
/// authority check answers no — an unestablished peer pid, a stranger's pid, a
/// reused one — and `PeerIdentityOverSocketpairTests` pins that
/// `ProcessIdentity.ofPeer` reads the pid from the socket rather than from the
/// caller. Neither runs `SocketServer.channelActive`, which is the one link in
/// the chain that has to populate the context from `LOCAL_PEERPID` *before* the
/// first `channelRead` dispatches a line. That ordering is an assumption about
/// NIO — the socket-option provider completing its promise inline when asked on
/// the event loop — and an assumption is exactly what a real connection can
/// check and a hand-built context cannot.
///
/// So these two rows drive the whole path from a `connect(2)` in this process:
/// the kernel names this process, `channelActive` reads it, `channelRead`
/// carries it, and the send handler compares it. The observable is the
/// suppression itself, because that outcome happens if and only if the pid the
/// router received equals the recorded one — and the negative row moves the
/// recorded pid by one to show the comparison is against a specific number
/// rather than against anything at all.
@Suite("a connection's peer pid reaches the router over a real socket")
struct SocketServerPeerPIDTests {

    /// Answers the re-verification for whatever pid it is asked about, with the
    /// values the recorded identity carries, so the only thing left deciding
    /// the outcome is the pid comparison — which is this suite's subject.
    ///
    /// Inert on the signalling half: a stub that could kill something is a stub
    /// that will, on a mistake. It is never asked anything in the negative row,
    /// where the pid comparison refuses first.
    private struct StubSignaller: ProcessSignaller {
        func isAlive(_ pid: Int32) -> Bool { true }
        func startTime(_ pid: Int32) -> Date? { SocketServerPeerPIDTests.recordedStart }
        func commandLine(_ pid: Int32) -> String? { SocketServerPeerPIDTests.recordedCommand }
        func stat(_ pid: Int32) -> String? { nil }
        func children(ofServerPID serverPID: Int32) -> [Int32] { [] }
        func terminate(_ pid: Int32) {}
        func forceKill(_ pid: Int32) {}
    }

    private static let recordedStart = Date(timeIntervalSince1970: 1_800_000_000)
    private static let recordedCommand = "/Applications/TBD.app/Contents/MacOS/TBDApp"

    /// Short `/tmp` path, well under the ~104-byte `sun_path` limit. NOT
    /// `~/tbd/sock`: this suite binds a socket of its own and never goes near
    /// the live daemon's rendezvous path.
    private func scratchSocketPath() -> String {
        "/tmp/tbd-peerpid-\(UUID().uuidString.prefix(8)).sock"
    }

    /// One send over one fresh connection, with the recorded sidecar identity
    /// claiming `recordedPID`. Returns what reached the pane.
    ///
    /// The request is the first and only line the connection ever carries, so a
    /// context that arrived late — after `channelRead` had already dispatched —
    /// is a context that never arrived at all.
    private func pastedBodiesForSend(recordedPID: Int32) async throws -> [String] {
        let identity = ProcessIdentity(
            pid: recordedPID, startedAt: Self.recordedStart,
            commandLine: Self.recordedCommand)
        let harness = try await SendHarness.make(
            recordedAppIdentity: { identity },
            processSignaller: StubSignaller())

        let socketPath = scratchSocketPath()
        defer { unlink(socketPath) }
        let server = SocketServer(router: harness.router, socketPath: socketPath)
        try await server.start()
        defer { Task { await server.stop() } }

        let client = RawRPCClient()
        defer { client.disconnect() }
        try #require(
            client.connect(to: socketPath, receiveTimeout: TestDeadlines.saturatedPassSeconds),
            "the test process could not connect to the server it just started")

        let request = try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: harness.terminal.id, text: "hi", submit: true,
                envelope: .suppressed),
            actor: .app)
        let line = try #require(String(data: try JSONEncoder().encode(request), encoding: .utf8))
        try #require(client.send(line: line), "the request could not be written to the socket")

        // Blocking reads run off the cooperative pool — a parked pool thread is
        // one the daemon's own handling can no longer run on — and the socket
        // carries a receive timeout, so a response that never comes reports
        // itself rather than parking anything forever.
        let responseLine = await gateHoldingTask { client.receiveLine() }.value
        let raw = try #require(
            responseLine, "no response line arrived within the receive timeout")
        let response = try JSONDecoder().decode(RPCResponse.self, from: Data(raw.utf8))
        #expect(response.success, "error was: \(response.error ?? "none")")

        // The response is written after the handler has run, so the paste has
        // already happened by here; the bounded wait covers the write itself
        // racing the recorder rather than any part of the decision.
        try await waitFor(
            "the send to reach the pane",
            observed: { "\(harness.tmux.pastedBodies.count) pastes" }
        ) { !harness.tmux.pastedBodies.isEmpty }
        return harness.tmux.pastedBodies
    }

    /// The positive row: the recorded sidecar identity is this process, and the
    /// only way the daemon can know that is by reading the pid off the socket
    /// this process connected on. Suppression is therefore the assertion that
    /// `channelActive` populated the context, and did it before the first
    /// request was dispatched.
    @Test func theConnectingProcessesOwnPIDAuthenticatesTheFirstRequest() async throws {
        let bodies = try await pastedBodiesForSend(recordedPID: getpid())
        #expect(
            bodies == ["hi"],
            "the first request over a real socket did not carry this process's peer pid")
    }

    /// The negative row, and the reason the positive one is not vacuous: move
    /// the recorded pid by one and the same connection, the same request and
    /// the same `{"kind":"app"}` actor keep the envelope. The comparison is
    /// against a specific number the kernel supplied, not against whatever
    /// happened to be there.
    ///
    /// The stranger's pid is only ever compared, never signalled: the
    /// comparison refuses before the identity check is reached.
    @Test func aPIDOneOffFromTheConnectingProcessKeepsTheEnvelope() async throws {
        let bodies = try await pastedBodiesForSend(recordedPID: getpid() &+ 1)
        #expect(
            try #require(bodies.first).hasPrefix("<tbd-dispatch"),
            "suppression was granted to a connection whose peer pid was not the recorded one")
    }
}

/// A newline-delimited-JSON client over a plain `AF_UNIX` socket — the daemon's
/// wire protocol and nothing else, so nothing in TBD's own client code stands
/// between the test and `connect(2)`.
private final class RawRPCClient: @unchecked Sendable {
    private var fd: Int32 = -1

    func connect(to path: String, receiveTimeout: TimeInterval) -> Bool {
        let newFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard newFD >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(newFD)
            return false
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(newFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(newFD)
            return false
        }
        // Bounds the blocking read below, so a response that never comes fails
        // the test instead of holding a thread for the rest of the run.
        var timeout = timeval(
            tv_sec: Int(receiveTimeout), tv_usec: 0)
        _ = setsockopt(
            newFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        fd = newFD
        return true
    }

    func send(line: String) -> Bool {
        guard fd >= 0 else { return false }
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { buffer in
                Darwin.write(fd, buffer.baseAddress, buffer.count)
            }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    /// The first newline-terminated line, or nil if the peer closed or the
    /// receive timeout expired first.
    func receiveLine() -> String? {
        guard fd >= 0 else { return nil }
        var accumulated: [UInt8] = []
        var scratch = [UInt8](repeating: 0, count: 4096)
        while !accumulated.contains(UInt8(ascii: "\n")) {
            let count = scratch.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress, buffer.count)
            }
            guard count > 0 else { return nil }
            accumulated.append(contentsOf: scratch[0..<count])
        }
        guard let newline = accumulated.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        return String(bytes: accumulated[0..<newline], encoding: .utf8)
    }

    func disconnect() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }
}
