import CryptoKit
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib

/// Tier 1 — `ModChannelServer` over a real Unix socket: HTTP/1.1 in, the route
/// table's reply out, and a closing client releasing its held poll. Time is
/// virtual (`EventDrivenTestClock`); only socket I/O is real.
@Suite(.clockDriven)
struct ModChannelServerTests {

    private struct Harness {
        let server: ModChannelServer
        let channel: ModChannel
        let clock: EventDrivenTestClock
        let socketPath: String
        let root: String
        let terminal: UUID
        let incarnation: UUID
        let bearer: String

        func pollRequest(after: UInt64 = 0) -> String {
            "GET /v1/poll?after=\(after) HTTP/1.1\r\n"
                + "Host: localhost\r\n"
                + "Authorization: Bearer \(bearer)\r\n"
                + "X-TBD-Terminal: \(terminal.uuidString)\r\n"
                + "X-TBD-Incarnation: \(incarnation.uuidString)\r\n"
                + "\r\n"
        }
    }

    private func startServer() async throws -> Harness {
        // Short on purpose: sun_path caps the whole path near 104 bytes.
        let root = fencedScratchRoot(prefix: "mods")
        let socketPath = "\(root)/m.sock"
        let clock = EventDrivenTestClock()
        let channel = ModChannel(clock: clock)
        let store = PendingPromptStore(clock: clock)
        let token = ModChannelToken(key: SymmetricKey(size: .bits256))
        let terminal = UUID()
        let incarnation = UUID()
        let routes = ModChannelRoutes(
            channel: channel, store: store, token: token,
            incarnationOf: { $0 == terminal ? incarnation : nil },
            promptAnswerEnabled: { true },
            broadcast: { _ in })
        let server = ModChannelServer(socketPath: socketPath, routes: routes)
        try await server.start()
        return Harness(
            server: server, channel: channel, clock: clock, socketPath: socketPath, root: root,
            terminal: terminal, incarnation: incarnation,
            bearer: token.token(incarnationID: incarnation))
    }

    private func tearDown(_ h: Harness) async {
        await h.server.stop()
        try? FileManager.default.removeItem(atPath: h.root)
    }

    /// Starts a server, runs `body`, and stops the server and removes its
    /// root whether `body` returns or throws (a failed `#require` included).
    private func withServer(_ body: (Harness) async throws -> Void) async throws {
        let h = try await startServer()
        do {
            try await body(h)
        } catch {
            await tearDown(h)
            throw error
        }
        await tearDown(h)
    }

    @Test func serverRoundTripsOverUnixSocket() async throws {
        var socketPath = ""
        try await withServer { h in
            socketPath = h.socketPath
            let mode = try FileManager.default.attributesOfItem(atPath: h.socketPath)[.posixPermissions] as? Int
            #expect(mode == 0o600)

            let fd = try connectUnix(h.socketPath)
            defer { close(fd) }
            try writeAll(fd, h.pollRequest())

            // Nothing queued: the poll holds for its full 25 s, then answers empty.
            try await h.clock.requireAdvanceWhenArmed(by: .seconds(25))
            let data = await readToEOF(fd)
            let response = try #require(String(data: data, encoding: .utf8))

            let parts = response.components(separatedBy: "\r\n\r\n")
            let head = parts.first ?? ""
            #expect(head.hasPrefix("HTTP/1.1 200"), "\(response)")
            #expect(head.lowercased().contains("content-type: application/json"), "\(response)")
            #expect(head.lowercased().contains("connection: close"), "\(response)")
            let body = parts.dropFirst().joined(separator: "\r\n\r\n")
            let json = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? NSDictionary
            #expect(json == ["items": [Any]()])
        }
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test func unauthorizedRequestIs401OverTheSocket() async throws {
        try await withServer { h in
            let fd = try connectUnix(h.socketPath)
            defer { close(fd) }
            try writeAll(fd, "GET /v1/poll?after=0 HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let data = await readToEOF(fd)
            let response = String(data: data, encoding: .utf8) ?? ""
            #expect(response.hasPrefix("HTTP/1.1 401"), "\(response)")
            #expect(response.hasSuffix(#"{"error":"unauthorized"}"#), "\(response)")
        }
    }

    /// Review Focus 3: the mod aborts its fetch while the poll is held. The
    /// connection's close releases the held poll rather than leaving it to
    /// its 25 s hold.
    @Test func closingClientReleasesPoll() async throws {
        try await withServer { h in
            let fd = try connectUnix(h.socketPath)
            try writeAll(fd, h.pollRequest())

            let attached = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
                await h.channel.isPollAttached(terminalID: h.terminal)
            }
            #expect(attached == .satisfied)

            close(fd)
            let released = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
                await !h.channel.isPollAttached(terminalID: h.terminal)
            }
            #expect(released == .satisfied)
        }
    }

    @Test func startReplacesStaleSocketFile() async throws {
        let root = fencedScratchRoot(prefix: "mods")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = "\(root)/m.sock"
        #expect(FileManager.default.createFile(atPath: socketPath, contents: Data("stale".utf8)))

        let clock = EventDrivenTestClock()
        let routes = ModChannelRoutes(
            channel: ModChannel(clock: clock), store: PendingPromptStore(clock: clock),
            token: ModChannelToken(key: SymmetricKey(size: .bits256)),
            incarnationOf: { _ in nil }, promptAnswerEnabled: { true }, broadcast: { _ in })
        let server = ModChannelServer(socketPath: socketPath, routes: routes)
        try await server.start()
        let fd = try connectUnix(socketPath)
        close(fd)
        await server.stop()
        // A second stop is harmless.
        await server.stop()
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    // MARK: - Raw socket client

    private struct SocketError: Error, CustomStringConvertible {
        let description: String
    }

    private func connectUnix(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(description: "socket() failed: errno \(errno)") }
        // A hang guard for the blocking read below.
        var timeout = timeval(tv_sec: 90, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw SocketError(description: "socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw SocketError(description: "connect(\(path)) failed: errno \(code)")
        }
        return fd
    }

    private func writeAll(_ fd: Int32, _ text: String) throws {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard written > 0 else { throw SocketError(description: "write failed: errno \(errno)") }
            offset += written
        }
    }

    /// Reads until the server closes the connection, on a dispatch thread so
    /// the blocking `read` never parks a cooperative-pool thread.
    private func readToEOF(_ fd: Int32) async -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            DispatchQueue.global().async {
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                    if count <= 0 { break }
                    data.append(contentsOf: buffer[0..<count])
                }
                continuation.resume(returning: data)
            }
        }
    }
}
