import Darwin
import Foundation
import NIOHTTP1
import Testing

@testable import TBDModelProxy
@testable import TBDShared

/// What the proxy promises a forwarded request and its response.
///
/// Every test here spins a real `ProxyServer` on a kernel-assigned loopback
/// port in front of a `FakeUpstream` on another, and asserts on both halves at
/// once: what the upstream *received*, verbatim, and what the client got back.
/// Nothing is inferred from the proxy's own logs or counters.
///
/// The rules pinned here each have a measured reason in the design
/// (`docs/specs/2026-09-05-transcript-streaming-model-proxy-design.md`,
/// "Forwarding"): Claude's retry and capability-disable logic matches on the
/// upstream's error *wording*, prompt caching depends on the `system` array
/// arriving in the order it was written, and Claude counts SSE pings and
/// aborts a stream silent for 300 seconds. A proxy that re-serializes a body
/// or batches a flush breaks those silently, so the assertions are on bytes
/// and on arrival times rather than on shapes.
@Suite("Proxy forwarding")
struct ProxyForwardingTests {

    // MARK: Byte identity

    @Test("a request's body and headers reach the upstream byte-identical")
    func forwardsBodyAndHeadersByteIdentical() async throws {
        // 300 KB, which is the size a real Claude Code request runs to once a
        // few files are in context — big enough that any accumulate-then-parse
        // step in the request leg would show up.
        let filler = String(repeating: "context ", count: 37_500)
        let requestBody = Data(
            #"{"model":"claude-stub","stream":true,"system":["\#(filler)"]}"#.utf8)
        #expect(requestBody.count > 300_000)

        try await withProxy(
            prefix: "pxid",
            script: { _, _ in
                FakeUpstream.Script(
                    status: 200, headers: [("content-type", "application/json")],
                    events: [(delayMs: 0, bytes: Array(#"{"ok":true}"#.utf8))])
            }
        ) { harness in
            var request = URLRequest(url: harness.url("/v1/messages"))
            request.httpMethod = "POST"
            request.httpBody = requestBody
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("a,b", forHTTPHeaderField: "anthropic-beta")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("s", forHTTPHeaderField: "x-claude-code-session-id")
            request.setValue("js", forHTTPHeaderField: "x-stainless-lang")
            request.setValue("gzip", forHTTPHeaderField: "accept-encoding")

            let (_, response) = try await harness.session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)

            let received = try #require(harness.upstream.requests.first)
            // The whole body, compared as bytes. A re-serializing proxy would
            // still produce valid JSON here and still break prompt caching.
            #expect(Data(received.body) == requestBody)

            // Open lists, not an allowlist: Anthropic has refused new beta
            // headers behind a custom base URL before, and the OAuth
            // capability rides in `anthropic-beta`.
            #expect(received.head.headers.first(name: "anthropic-beta") == "a,b")
            #expect(received.head.headers.first(name: "anthropic-version") == "2023-06-01")
            #expect(received.head.headers.first(name: "x-claude-code-session-id") == "s")
            #expect(received.head.headers.first(name: "x-stainless-lang") == "js")

            // `accept-encoding` is the one request header that never passes
            // through. It is replaced rather than merely dropped because
            // `URLSession` adds `gzip, deflate, br` to a request that sets
            // none and then transparently decompresses the answer, which would
            // leave the relay handing the client bytes that disagree with the
            // `Content-Encoding` header beside them.
            let forwardedEncoding = received.head.headers.first(name: "accept-encoding")
            #expect(forwardedEncoding == UpstreamForwarder.requestedEncoding)
            #expect(forwardedEncoding != "gzip")
        }
    }

    // MARK: Streaming

    @Test("each event reaches the client as it arrives, not batched at the end")
    func relaysStreamChunkByChunk() async throws {
        let spacingMs = 300
        let events = (1...3).map { index in
            (delayMs: spacingMs, bytes: Array("event: tick\ndata: {\"n\":\(index)}\n\n".utf8))
        }

        try await withProxy(
            prefix: "pxst",
            script: { _, _ in FakeUpstream.Script(events: events) }
        ) { harness in
            var request = URLRequest(url: harness.url("/v1/messages"))
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"stream":true}"#.utf8)

            let clock = ContinuousClock()
            let (bytes, response) = try await harness.session.bytes(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)

            var arrivals: [ContinuousClock.Instant] = []
            for try await line in bytes.lines where line.hasPrefix("event: ") {
                arrivals.append(clock.now)
            }

            #expect(arrivals.count == 3)
            guard arrivals.count >= 2 else { return }
            // The scripted spacing is 300 ms; asserting 200 leaves room for a
            // loaded CI machine to be late without letting a proxy that
            // buffered the whole stream — which would deliver all three within
            // a millisecond of each other — pass.
            let gap = arrivals[1] - arrivals[0]
            #expect(
                gap >= .milliseconds(200),
                "second event arrived \(gap) after the first; a buffered relay collapses this to ~0")
        }
    }

    @Test("comment lines and pings reach the client byte for byte")
    func relaysCommentPingsUnchanged() async throws {
        // A comment line carries no event and no data. Claude counts these to
        // decide a stream is alive, so a relay that coalesced or dropped them
        // would look correct on the deltas and still time a turn out.
        let frames = [
            Array("event: content_block_delta\ndata: {\"i\":0}\n\n".utf8),
            Array(": ping\n\n".utf8),
            Array("event: content_block_delta\ndata: {\"i\":1}\n\n".utf8),
            Array(": ping\n\n".utf8),
            Array("event: message_stop\ndata: {}\n\n".utf8),
        ]
        let expected = Data(frames.flatMap { $0 })

        try await withProxy(
            prefix: "pxpi",
            script: { _, _ in
                FakeUpstream.Script(events: frames.map { (delayMs: 0, bytes: $0) })
            }
        ) { harness in
            var request = URLRequest(url: harness.url("/v1/messages"))
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"stream":true}"#.utf8)

            let (data, response) = try await harness.session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(data == expected)
        }
    }

    @Test("an upstream error status and body are relayed verbatim")
    func relaysUpstreamErrorBodyVerbatim() async throws {
        // The exact wording matters: Claude's retry and capability-disable
        // logic matches on it, so a proxy that rewrote this into its own error
        // shape would change what Claude does next.
        let errorBody = Array(
            #"{"type":"error","error":{"type":"rate_limit_error","message":"Number of request tokens has exceeded your per-minute rate limit"}}"#
                .utf8)

        try await withProxy(
            prefix: "pxer",
            script: { _, _ in
                FakeUpstream.Script(
                    status: 429,
                    headers: [("content-type", "application/json"), ("retry-after", "17")],
                    events: [(delayMs: 0, bytes: errorBody)])
            }
        ) { harness in
            var request = URLRequest(url: harness.url("/v1/messages"))
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"stream":true}"#.utf8)

            let (data, response) = try await harness.session.data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 429)
            #expect(Array(data) == errorBody)
            // A non-hop-by-hop response header passes untouched, which is how
            // Claude learns how long to wait.
            #expect(http.value(forHTTPHeaderField: "retry-after") == "17")
        }
    }

    // MARK: Refusals

    @Test("an unknown token is 404 and reaches no upstream")
    func unknownTokenIs404AndForwardsNothing() async throws {
        try await withProxy(
            prefix: "pxun",
            script: { _, _ in FakeUpstream.Script(events: []) }
        ) { harness in
            let unknown = String(repeating: "0", count: 32)
            #expect(ModelProxyRoute.isValidToken(unknown), "the token must be well-formed to be a fair test")

            let unknownURL = try #require(
                URL(string: "http://127.0.0.1:\(harness.port)/r/\(unknown)/v1/messages"))
            var request = URLRequest(url: unknownURL)
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"stream":true}"#.utf8)

            let (data, response) = try await harness.session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 404)
            #expect(String(decoding: data, as: UTF8.self) == ProxyServer.unknownRouteBody)
            // The refusal is the point: a proxy on loopback that forwarded an
            // unknown token would be an open forwarder for every local process.
            #expect(harness.upstream.requests.isEmpty)
        }
    }

    @Test("a malformed token is 404 before it can compose a path")
    func malformedTokenIs404() async throws {
        try await withProxy(
            prefix: "pxmt",
            script: { _, _ in FakeUpstream.Script(events: []) }
        ) { harness in
            // Sent over a raw socket on purpose. `URL` and `URLSession`
            // normalize `..` out of a path before it leaves the process, so a
            // URL-based client cannot put the traversal on the wire at all —
            // and it is the wire the proxy has to refuse.
            for path in ["/r/../../v1/messages", "/r/ABC/v1/messages"] {
                let response = try rawHTTPExchange(
                    port: harness.port,
                    request: "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
                #expect(
                    response.hasPrefix("HTTP/1.1 404"),
                    "\(path) answered: \(response.prefix(64))")
                #expect(response.contains("unknown route"))
            }
            #expect(harness.upstream.requests.isEmpty)
        }
    }

    // MARK: Everything under the base URL

    @Test("the HEAD probe and count_tokens reach the upstream with their paths intact")
    func forwardsHeadAndCountTokens() async throws {
        // The base URL governs whatever Claude Code calls on it, not only
        // `/v1/messages`: the warm-up probe and count-tokens are both real
        // traffic, and a proxy that only knew one endpoint would fail a
        // session before its first turn.
        try await withProxy(
            prefix: "pxhd",
            script: { head, _ in
                if head.method == .HEAD {
                    return FakeUpstream.Script(
                        status: 200, headers: [("content-length", "0")], events: [])
                }
                return FakeUpstream.Script(
                    status: 200, headers: [("content-type", "application/json")],
                    events: [(delayMs: 0, bytes: Array(#"{"input_tokens":7}"#.utf8))])
            }
        ) { harness in
            var probe = URLRequest(url: harness.url("/api/hello"))
            probe.httpMethod = "HEAD"
            let (_, probeResponse) = try await harness.session.data(for: probe)
            #expect((probeResponse as? HTTPURLResponse)?.statusCode == 200)

            var count = URLRequest(url: harness.url("/v1/messages/count_tokens"))
            count.httpMethod = "POST"
            count.httpBody = Data(#"{"model":"claude-stub"}"#.utf8)
            let (countData, countResponse) = try await harness.session.data(for: count)
            #expect((countResponse as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: countData, as: UTF8.self) == #"{"input_tokens":7}"#)

            let received = harness.upstream.requests
            #expect(received.count == 2)
            #expect(received.first?.head.method == .HEAD)
            #expect(received.first?.head.uri == "/api/hello")
            #expect(received.last?.head.method == .POST)
            #expect(received.last?.head.uri == "/v1/messages/count_tokens")
        }
    }
}

// MARK: - Harness

/// One proxy in front of one fake upstream, with a route between them.
struct ProxyHarness {
    let port: Int
    let token: String
    let terminalID: UUID
    let upstream: FakeUpstream
    let routesDir: URL
    let streamsDir: URL
    /// A session of its own per harness, so a connection left open by one test
    /// cannot be reused by another against a port the kernel has since given
    /// to somebody else.
    let session: URLSession

    func url(_ suffix: String) -> URL {
        // Force-unwrapped deliberately: every caller composes this from a
        // literal suffix and a port the kernel just handed out, so a nil here
        // is a broken test rather than a condition worth propagating.
        URL(string: "http://127.0.0.1:\(port)/r/\(token)\(suffix)")!
    }
}

/// Runs `body` against a freshly bound proxy, and tears both servers down on
/// every exit from it.
///
/// Not a `defer`: `ProxyServer.stop()` is `async` and `defer` cannot await, so
/// the teardown is explicit on both the success and the failure path. The
/// upstream is created before anything can throw, for the same reason
/// `FakeUpstreamTests` registers its `defer` before `start()` — a bind that
/// throws must not leak an event-loop group into the rest of the test process.
@discardableResult
func withProxy<T>(
    prefix: String,
    script: @escaping FakeUpstream.Handler,
    streamingEnabled: Bool = false,
    body: (ProxyHarness) async throws -> T
) async throws -> T {
    let upstream = FakeUpstream(script: script)
    let root = proxyScratchRoot(prefix: prefix)
    var startedServer: ProxyServer?
    var clientSession: URLSession?

    func teardown() async {
        if let startedServer { await startedServer.stop() }
        upstream.stop()
        clientSession?.invalidateAndCancel()
        try? FileManager.default.removeItem(at: root)
    }

    do {
        let upstreamPort = try upstream.start()

        let routesDir = root.appendingPathComponent("proxy/routes")
        let streamsDir = root.appendingPathComponent("streams")
        try FileManager.default.createDirectory(at: routesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: streamsDir, withIntermediateDirectories: true)

        let token = ModelProxyRoute.mintToken()
        let terminalID = UUID()
        let route = ModelProxyRoute(
            token: token, terminalID: terminalID,
            upstream: "http://127.0.0.1:\(upstreamPort)", streamingEnabled: streamingEnabled)
        try route.encodedForRouteFile().write(
            to: routesDir.appendingPathComponent(
                TBDConstants.modelProxyRouteFileName(token: token)))

        let table = RouteTable(routesDir: routesDir, streamsDir: streamsDir)
        try await table.loadAll()

        let server = ProxyServer(
            port: 0, routes: table, tee: nil,
            status: {
                ModelProxyStatus(
                    version: "test", pid: 0, processStartTime: Date(), port: 0,
                    streamsInFlight: 0, routeCount: 0)
            },
            onRetire: {},
            // An explicit environment, so the forwarder's proxy resolution
            // cannot pick up an `HTTPS_PROXY` from the developer's shell and
            // send a loopback request through a corporate proxy.
            forwarder: UpstreamForwarder(session: UpstreamForwarder.makeSession(environment: [:])))
        startedServer = server
        let port = try await server.start()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        clientSession = session

        let harness = ProxyHarness(
            port: port, token: token, terminalID: terminalID, upstream: upstream,
            routesDir: routesDir, streamsDir: streamsDir, session: session)
        let result = try await body(harness)
        await teardown()
        return result
    } catch {
        await teardown()
        throw error
    }
}

/// A scratch directory under the run root `scripts/test.sh` reclaims, so a
/// killed test process leaks nothing. Duplicated from `TestSupport`'s
/// `fencedScratchRoot` rather than imported: that target pulls in
/// `TBDDaemonLib`, and this one deliberately links only the proxy and NIO.
func proxyScratchRoot(prefix: String) -> URL {
    let fenced = ProcessInfo.processInfo.environment["TBD_TEST_SCRATCH_ROOT"] ?? ""
    let root = fenced.isEmpty ? FileManager.default.temporaryDirectory.path : fenced
    return URL(fileURLWithPath: "\(root)/\(prefix)-\(UUID().uuidString.prefix(8).lowercased())")
}

// MARK: - Raw HTTP

enum RawHTTPError: LocalizedError {
    case socketFailed(Int32)
    case connectFailed(Int32)
    case writeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .socketFailed(let code): return "socket() failed with errno \(code)"
        case .connectFailed(let code): return "connect() failed with errno \(code)"
        case .writeFailed(let code): return "write() failed with errno \(code)"
        }
    }
}

/// Sends a request exactly as written and reads until the server closes.
///
/// Exists because `URLSession` normalizes a path before it puts it on the
/// wire: `/r/../../v1/messages` never leaves the process as itself, and the
/// traversal the proxy has to refuse is the one a hand-written client — or a
/// hostile local process — can send.
func rawHTTPExchange(port: Int, request: String, timeoutSeconds: Int = 15) throws -> String {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw RawHTTPError.socketFailed(errno) }
    defer { close(descriptor) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")

    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
            connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { throw RawHTTPError.connectFailed(errno) }

    // A receive timeout, so a proxy that answered nothing fails the test
    // instead of wedging the run.
    var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    setsockopt(
        descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    let outgoing = Array(request.utf8)
    var sent = 0
    while sent < outgoing.count {
        let written = outgoing.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return write(descriptor, base.advanced(by: sent), outgoing.count - sent)
        }
        guard written > 0 else { throw RawHTTPError.writeFailed(errno) }
        sent += written
    }

    var response: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let read = chunk.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return Darwin.read(descriptor, base, buffer.count)
        }
        guard read > 0 else { break }
        response.append(contentsOf: chunk[0..<read])
    }
    return String(decoding: response, as: UTF8.self)
}
