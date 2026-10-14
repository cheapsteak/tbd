import Testing
import Foundation
import NIOHTTP1
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

// The daemon's HTTP RPC port is reachable by every local process and, through
// DNS rebinding or a cross-origin POST, by any web page in a local browser. It
// serves a request only when the Host names the loopback address and the
// connection's own port, there is no Origin, and the per-start token matches.

private let gatePort = 51234
private let gateToken = String(repeating: "ab", count: 32)

private func head(
    host: [String]? = ["127.0.0.1:\(gatePort)"],
    origin: [String] = [],
    tokenHeaders: [(String, String)] = [("X-TBD-Token", gateToken)]
) -> HTTPRequestHead {
    var headers = HTTPHeaders()
    for h in host ?? [] { headers.add(name: "Host", value: h) }
    for o in origin { headers.add(name: "Origin", value: o) }
    for (name, value) in tokenHeaders { headers.add(name: name, value: value) }
    return HTTPRequestHead(version: .http1_1, method: .POST, uri: "/rpc", headers: headers)
}

@Suite("HTTP request gate")
struct HTTPRequestGateTests {
    let gate = HTTPRequestGate(port: gatePort, token: gateToken)

    @Test("the three loopback host spellings pass with the right token and no origin",
          arguments: ["127.0.0.1:\(gatePort)", "localhost:\(gatePort)", "LocalHost:\(gatePort)", "[::1]:\(gatePort)"])
    func allowedHosts(host: String) {
        #expect(gate.refusal(for: head(host: [host])) == nil)
    }

    @Test("a wrong Host is refused with 403 even when the token is right",
          arguments: [
            [] as [String],
            ["127.0.0.1:\(gatePort)", "127.0.0.1:\(gatePort)"],
            ["127.0.0.1"],
            ["127.0.0.1:\(gatePort + 1)"],
            ["attacker.example:\(gatePort)"],
            ["localhost.attacker.example:\(gatePort)"],
            ["127.0.0.1.attacker.example:\(gatePort)"],
            [""],
            ["127.0.0.1:\(gatePort), attacker.example:\(gatePort)"],
          ])
    func refusedHosts(hosts: [String]) {
        let refusal = gate.refusal(for: head(host: hosts))
        #expect(refusal == .host)
        #expect(refusal?.status == .forbidden)
    }

    @Test("any Origin is refused with 403, whatever its value",
          arguments: ["http://127.0.0.1:\(gatePort)", "http://localhost:\(gatePort)", "null", "http://attacker.example", ""])
    func refusedOrigins(origin: String) {
        let refusal = gate.refusal(for: head(origin: [origin]))
        #expect(refusal == .origin)
        #expect(refusal?.status == .forbidden)
    }

    @Test("a missing, empty, wrong or duplicated token is refused with 401",
          arguments: [
            [] as [(String, String)],
            [("X-TBD-Token", "")],
            [("X-TBD-Token", String(repeating: "cd", count: 32))],
            [("X-TBD-Token", String(gateToken.dropLast()))],
            [("X-TBD-Token", gateToken + "a")],
            [("X-TBD-Token", gateToken), ("X-TBD-Token", gateToken)],
            [("Authorization", "Bearer \(gateToken)")],
          ])
    func refusedTokens(headers: [(String, String)]) {
        let refusal = gate.refusal(for: head(tokenHeaders: headers))
        #expect(refusal == .token)
        #expect(refusal?.status == .unauthorized)
    }

    @Test("Host is checked before Origin, and Origin before the token")
    func checkOrder() {
        #expect(gate.refusal(for: head(host: ["attacker.example"], origin: ["null"], tokenHeaders: [])) == .host)
        #expect(gate.refusal(for: head(origin: ["null"], tokenHeaders: [])) == .origin)
    }

    @Test("the token never appears in a refusal message")
    func messagesNameTheFileNotTheToken() {
        let gate = HTTPRequestGate(port: gatePort, token: gateToken, tokenFilePath: "/tmp/example/http-token")
        for refusal in [HTTPRequestGate.Refusal.host, .origin, .token] {
            #expect(!gate.message(for: refusal).contains(gateToken))
        }
        #expect(gate.message(for: .token).contains("/tmp/example/http-token"))
    }
}

@Suite("HTTP server gate over the wire")
struct HTTPServerGateTests {

    private func makeRouter() throws -> RPCRouter {
        let db = try TBDDatabase(inMemory: true)
        return RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog()
        )
    }

    private struct Paths {
        let port = "/tmp/tbd-httpgate-\(UUID().uuidString.prefix(8)).port"
        let token = "/tmp/tbd-httpgate-\(UUID().uuidString.prefix(8)).token"
        func cleanUp() {
            unlink(port)
            unlink(token)
        }
    }

    private struct RawResponse {
        let status: Int
        let body: String
        let connectionClosed: Bool
    }

    /// Sends `request` verbatim over a TCP socket and reads one response. Lets
    /// the test control `Host` exactly, which URLSession will not. With
    /// `probeClose`, one more read reports whether the server then closed; an
    /// accepted request keeps its connection open, so that read would only wait
    /// out the receive timeout.
    private func rawExchange(port: Int, request: String, probeClose: Bool) throws -> RawResponse {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(rc == 0)

        let bytes = Array(request.utf8)
        try #require(send(fd, bytes, bytes.count, 0) == bytes.count)

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        func complete() -> Bool {
            guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
            let headText = String(decoding: data[..<range.lowerBound], as: UTF8.self).lowercased()
            guard let line = headText.split(separator: "\r\n").first(where: { $0.hasPrefix("content-length:") }),
                  let length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            else { return false }
            return data.count - range.upperBound >= length
        }
        while !complete() {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }

        let text = String(decoding: data, as: UTF8.self)
        let parts = text.components(separatedBy: "\r\n\r\n")
        let statusLine = parts[0].components(separatedBy: "\r\n")[0]
        let status = Int(statusLine.split(separator: " ")[1]) ?? 0
        let body = parts.dropFirst().joined(separator: "\r\n\r\n")

        // After the response, a refusing server closes: the next read is EOF.
        let closed = probeClose && recv(fd, &buf, buf.count, 0) == 0
        return RawResponse(status: status, body: body, connectionClosed: closed)
    }

    private func post(
        port: Int, host: String? = nil, origin: String? = nil, token: String? = nil,
        body: String = #"{"method":"daemon.status","params":"{}"}"#, probeClose: Bool = true
    ) throws -> RawResponse {
        var req = "POST /rpc HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(port)")\r\n"
        if let origin { req += "Origin: \(origin)\r\n" }
        if let token { req += "X-TBD-Token: \(token)\r\n" }
        req += "Content-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        return try rawExchange(port: port, request: req, probeClose: probeClose)
    }

    private func readToken(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    /// Starts a server on throwaway paths, runs `body`, and awaits `stop()` on
    /// both the success and the throw path before removing the files.
    private func withServer(
        _ body: (HTTPServer, String, Paths) async throws -> Void
    ) async throws {
        let paths = Paths()
        defer { paths.cleanUp() }
        let server = HTTPServer(router: try makeRouter(), portFilePath: paths.port, tokenFilePath: paths.token)
        try await server.start()
        do {
            try await body(server, try readToken(paths.token), paths)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    @Test("the token file is owner-only, 64 lowercase hex, fresh per start, and removed on stop")
    func tokenFileLifecycle() async throws {
        let paths = Paths()
        defer { paths.cleanUp() }
        let router = try makeRouter()

        let first = HTTPServer(router: router, portFilePath: paths.port, tokenFilePath: paths.token)
        try await first.start()
        let firstToken = try readToken(paths.token)
        var st = stat()
        try #require(stat(paths.token, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(firstToken.count == 64)
        #expect(firstToken.allSatisfy { "0123456789abcdef".contains($0) })
        await first.stop()
        #expect(!FileManager.default.fileExists(atPath: paths.token))

        let second = HTTPServer(router: router, portFilePath: paths.port, tokenFilePath: paths.token)
        try await second.start()
        let secondToken = try readToken(paths.token)
        await second.stop()
        #expect(secondToken != firstToken)
    }

    @Test("stop() leaves port and token files that a successor has overwritten")
    func stopSparesSuccessorFiles() async throws {
        let paths = Paths()
        defer { paths.cleanUp() }
        let server = HTTPServer(router: try makeRouter(), portFilePath: paths.port, tokenFilePath: paths.token)
        try await server.start()
        try "1".write(toFile: paths.port, atomically: true, encoding: .utf8)
        try "successor-token".write(toFile: paths.token, atomically: true, encoding: .utf8)
        await server.stop()
        #expect(try String(contentsOfFile: paths.port, encoding: .utf8) == "1")
        #expect(try readToken(paths.token) == "successor-token")
    }

    @Test("stop() removes its own port and token files")
    func stopRemovesOwnFiles() async throws {
        let paths = Paths()
        defer { paths.cleanUp() }
        let server = HTTPServer(router: try makeRouter(), portFilePath: paths.port, tokenFilePath: paths.token)
        try await server.start()
        await server.stop()
        #expect(!FileManager.default.fileExists(atPath: paths.port))
        #expect(!FileManager.default.fileExists(atPath: paths.token))
    }

    @Test("writeOwnerOnly leaves no temporary file behind and replaces an existing file")
    func writeOwnerOnlyReplaces() throws {
        let path = "/tmp/tbd-httpgate-\(UUID().uuidString.prefix(8)).token"
        defer { unlink(path) }
        try HTTPRPCToken.writeOwnerOnly("one", to: path)
        try HTTPRPCToken.writeOwnerOnly("two", to: path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "two")
        var st = stat()
        #expect(stat(path, &st) == 0 && st.st_mode & 0o777 == 0o600)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: "/tmp")
            .filter { $0.hasPrefix((path as NSString).lastPathComponent + ".tmp-") }
        #expect(siblings.isEmpty)
    }

    @Test("a request with the right Host and token is served")
    func acceptedRequest() async throws {
        try await withServer { server, token, _ in
            let response = try post(port: server.port, token: token, probeClose: false)
            #expect(response.status == 200)
            #expect(response.body.contains("\"success\":true"))
        }
    }

    @Test("curl in the documented shape is served")
    func documentedCurlShape() async throws {
        try await withServer { server, token, _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = [
                "-s", "-H", "X-TBD-Token: \(token)",
                "-d", #"{"method":"daemon.status","params":"{}"}"#,
                "http://127.0.0.1:\(server.port)/rpc",
            ]
            let out = Pipe()
            process.standardOutput = out
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            #expect(String(decoding: data, as: UTF8.self).contains("\"success\":true"))
        }
    }

    @Test("URLSession with the token header is served")
    func urlSessionRequest() async throws {
        try await withServer { server, token, _ in
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/rpc")!)
            request.httpMethod = "POST"
            request.setValue(token, forHTTPHeaderField: "X-TBD-Token")
            request.httpBody = Data(#"{"method":"daemon.status","params":"{}"}"#.utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: data, as: UTF8.self).contains("\"success\":true"))
        }
    }

    @Test("refused requests get the gate's JSON, never the router's, never the token, and the connection closes")
    func refusedOverTheWire() async throws {
        try await withServer { server, token, _ in
            let port = server.port
            let cases: [(String, RawResponse, Int, String)] = [
                ("rebinding host", try post(port: port, host: "attacker.example:\(port)", token: token), 403, "Host"),
                ("origin", try post(port: port, origin: "http://attacker.example", token: token), 403, "Origin"),
                ("no token", try post(port: port), 401, "X-TBD-Token"),
                ("wrong token", try post(port: port, token: String(repeating: "0", count: 64)), 401, "X-TBD-Token"),
            ]
            for (name, response, status, mentions) in cases {
                #expect(response.status == status, "\(name)")
                let decoded = try? JSONDecoder().decode(RPCResponse.self, from: Data(response.body.utf8))
                #expect(decoded?.success == false, "\(name): \(response.body)")
                #expect(decoded?.error?.contains(mentions) == true, "\(name): \(response.body)")
                // A routed daemon.status carries a result; a refusal never does.
                #expect(decoded?.result == nil, "\(name) reached the router")
                #expect(!response.body.contains(token), "\(name) leaked the token")
                #expect(response.connectionClosed, "\(name) left the connection open")
            }
        }
    }
}
