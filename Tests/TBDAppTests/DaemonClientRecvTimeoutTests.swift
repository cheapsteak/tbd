import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import TBDApp
import TBDShared
import TestSupport

// BUG 1: the persistent subscribe() loop must unwind promptly when its Task is
// cancelled, even if the daemon has gone silent without closing the socket
// (the "half-dead / live tmux-server death" wedge). Before the fix, recv()
// blocked forever and Task.isCancelled was never re-checked, parking a
// cooperative-pool thread permanently. SO_RCVTIMEO (1s) + the isCancelled
// re-check makes the loop return within ~1-2s.
@Suite("DaemonClient recv timeout / cancellation")
struct DaemonClientRecvTimeoutTests {

    /// Stand up a raw AF_UNIX listener that accepts one connection, reads the
    /// subscribe request, then STAYS SILENT (never sends, never closes) —
    /// simulating a wedged daemon. The accepted fd is retained in `acceptedBox`
    /// so it isn't closed early.
    private final class FdBox: @unchecked Sendable {
        var fd: Int32 = -1
    }

    /// A raw AF_UNIX listener bound to `path`, with a backlog of one. bind()
    /// creates the socket file, which makeConnectedSocket() requires to exist.
    /// The caller closes the returned fd and unlinks `path`.
    private static func makeListeningSocket(path: String) -> Int32 {
        let listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(listenFd >= 0)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let raw = UnsafeMutableRawPointer(pathPtr)
                raw.copyMemory(from: ptr, byteCount: strlen(ptr) + 1)
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(listenFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bindResult == 0)
        #expect(listen(listenFd, 1) == 0)
        return listenFd
    }

    @Test("subscribe() loop unwinds promptly on cancel against a silent daemon")
    func subscribeCancelsPromptlyWhenDaemonSilent() async throws {
        let socketPath = "/tmp/tbd-test-\(UUID().uuidString.prefix(8)).sock"

        // 1. Raw listener bound to the short temp path.
        let listenFd = Self.makeListeningSocket(path: socketPath)

        let acceptedBox = FdBox()
        defer {
            if acceptedBox.fd >= 0 { close(acceptedBox.fd) }
            close(listenFd)
            unlink(socketPath)
        }

        // 2. Background: accept one connection, drain the subscribe request,
        //    then stay silent (do not send, do not close). Hold the fd.
        DispatchQueue.global().async {
            let clientFd = accept(listenFd, nil, nil)
            acceptedBox.fd = clientFd
            if clientFd >= 0 {
                var buf = [UInt8](repeating: 0, count: 4096)
                _ = recv(clientFd, &buf, buf.count, 0) // read the subscribe bytes, then go silent
            }
        }

        // 3-4. Connect and enter the subscribe recv loop.
        let client = DaemonClient(socketPath: socketPath)
        let task = Task { await client.subscribe { _ in } }

        // 5. Let it connect and park in recv(), then cancel.
        try await Task.sleep(nanoseconds: 300_000_000) // 300ms
        task.cancel()

        // 6. The cancelled subscription must finish promptly (within 3s).
        //    Race task completion against a timeout.
        let finishedInTime = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        #expect(finishedInTime, "subscribe() did not unwind within 3s after cancel — recv wedge not fixed")
    }

    /// Counts calls from whichever thread makes them.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0

        func increment() {
            lock.lock()
            calls += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    /// Subscribe against a fake daemon that accepts one connection, reads the
    /// subscribe request, writes `lines` and closes, and return how many times
    /// `onConnected` ran once the stream ended.
    ///
    /// `lines` are framed as the daemon frames them: `SocketServer` and
    /// `StateSubscriptionManager` encode the acknowledgment and every delta
    /// with a default `JSONEncoder` and end each with a newline.
    ///
    /// The wait is a hang guard on the shared saturated-pass deadline, never a
    /// short literal. `subscribe` reads on a cooperative thread, and the fast
    /// parallel pass keeps a test suspended behind other runnable ones for tens
    /// of seconds on a green run (Tests/CLAUDE.md), so a 5-second bound expired
    /// before `subscribe` had read a byte, and recorded no connect for a daemon
    /// that answered. The daemon runs on a thread of its own, so it waits for
    /// no pooled one.
    private static func connectsAfterServing(_ lines: Data) async -> Int {
        let socketPath = "/tmp/tbd-test-\(UUID().uuidString.prefix(8)).sock"
        let listenFd = makeListeningSocket(path: socketPath)
        defer {
            close(listenFd)
            unlink(socketPath)
        }
        let daemon = Thread {
            let clientFd = accept(listenFd, nil, nil)
            guard clientFd >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            _ = recv(clientFd, &buf, buf.count, 0) // read the subscribe bytes
            lines.withUnsafeBytes { bytes in
                _ = send(clientFd, bytes.baseAddress!, bytes.count, 0)
            }
            close(clientFd)
        }
        daemon.start()

        let connects = CallCounter()
        let finished = CallCounter()
        let client = DaemonClient(socketPath: socketPath)
        let task = Task {
            await client.subscribe(onDelta: { _ in }, onConnected: { connects.increment() })
            finished.increment()
        }
        let ended = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { finished.count == 1 }
        task.cancel()

        #expect(ended == .satisfied, "subscribe() did not return at the end of the stream")
        return connects.count
    }

    /// One daemon line, framed as the daemon frames it.
    private static func line(_ encodable: some Encodable) throws -> Data {
        var line = try JSONEncoder().encode(encodable)
        line.append(0x0A)
        return line
    }

    /// `onConnected` runs once per subscription, however many lines follow:
    /// the app re-sends its stored program-status reports from it, so a second
    /// call would re-send them twice.
    @Test("subscribe() calls onConnected once, on the daemon's first line")
    func subscribeAnnouncesTheConnectOnce() async throws {
        let ack = try Self.line(RPCResponse.ok())

        let connects = await Self.connectsAfterServing(ack + ack)

        #expect(connects == 1)
    }

    /// What the daemon's first line is, for `subscribeAnnouncesOnlyALiveDaemon`.
    enum FirstLine: String, CaseIterable, Sendable {
        case errorResponse
        case acknowledgment
        case delta
        case undecodable

        func encoded() throws -> Data {
            switch self {
            case .errorResponse:
                return try DaemonClientRecvTimeoutTests.line(
                    RPCResponse(error: "acme refused the subscription"))
            case .acknowledgment:
                return try DaemonClientRecvTimeoutTests.line(RPCResponse.ok())
            case .delta:
                return try DaemonClientRecvTimeoutTests.line(StateDelta.devServersChanged)
            case .undecodable:
                return Data("not json\n".utf8)
            }
        }

        var announcesTheConnect: Bool {
            switch self {
            case .acknowledgment, .delta: return true
            case .errorResponse, .undecodable: return false
            }
        }
    }

    /// The app re-sends its stored program-status reports from `onConnected`,
    /// so it must mean a live daemon answered the subscription: its
    /// acknowledgment, or a delta broadcast ahead of it. An error response, or
    /// a line this build cannot decode, does not.
    @Test("subscribe() calls onConnected only for an acknowledgment or a delta", arguments: FirstLine.allCases)
    func subscribeAnnouncesOnlyALiveDaemon(firstLine: FirstLine) async throws {
        let line = try firstLine.encoded()

        let connects = await Self.connectsAfterServing(line)

        #expect(connects == (firstLine.announcesTheConnect ? 1 : 0))
    }
}
