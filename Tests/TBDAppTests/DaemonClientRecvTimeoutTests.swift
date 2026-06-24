import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import TBDApp

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

    @Test("subscribe() loop unwinds promptly on cancel against a silent daemon")
    func subscribeCancelsPromptlyWhenDaemonSilent() async throws {
        let socketPath = "/tmp/tbd-test-\(UUID().uuidString.prefix(8)).sock"

        // 1. Raw listener bound to the short temp path. bind() creates the
        //    socket file, which makeConnectedSocket() requires to exist.
        let listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(listenFd >= 0)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
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
}
