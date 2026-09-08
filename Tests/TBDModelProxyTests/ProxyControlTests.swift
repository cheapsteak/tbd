import Foundation
import NIOHTTP1
import NIOCore
import Testing

@testable import TBDModelProxy
@testable import TBDShared

extension ModelProxySuites {
    /// The `/tbd/...` verbs the daemon supervises the proxy with.
    ///
    /// These are the only requests the proxy answers itself rather than forwards,
    /// and each one carries a promise the supervisor's logic is built on
    /// (`docs/specs/2026-09-05-transcript-streaming-model-proxy-design.md`,
    /// "Control endpoint"): `status` is how a daemon that cannot bind the port
    /// decides whether to adopt the process holding it, `retire` is how a
    /// successor takes the port without cutting a turn, and `routes` is how the
    /// proxy learns of a route file without watching a directory.
    @Suite("Proxy control", .serialized)
    struct ProxyControlTests {

        // MARK: Status

        @Test("status reports the live in-flight count and the routes it holds")
        func statusReportsInFlightAndRoutes() async throws {
            let ticks = (1...4).map { index in
                (delayMs: 300, bytes: Array("event: tick\ndata: {\"n\":\(index)}\n\n".utf8))
            }

            try await withProxy(
                prefix: "pxstat",
                script: { _, _ in FakeUpstream.Script(events: ticks) }
            ) { harness in
                let idle = try await status(harness)
                #expect(idle.streamsInFlight == 0)
                #expect(idle.routeCount == 1)
                // The port and identity come from the closure the process supplies;
                // the two counters do not, which is the whole point of reading them
                // at the moment of the request. The harness deliberately reports
                // -1 for both, so a status that passed them through would fail
                // here rather than silently report a number nobody counted.
                #expect(idle.port == harness.port)
                #expect(idle.pid == getpid())
                #expect(idle.version == "test")

                var request = URLRequest(url: harness.url("/v1/messages"))
                request.httpMethod = "POST"
                request.httpBody = Data(#"{"stream":true}"#.utf8)
                let (bytes, response) = try await harness.session.bytes(for: request)
                #expect((response as? HTTPURLResponse)?.statusCode == 200)

                let busy = try await status(harness)
                #expect(busy.streamsInFlight == 1)

                // A second route, taken the way the daemon takes one.
                let second = ModelProxyRoute(
                    token: ModelProxyRoute.mintToken(), terminalID: UUID(),
                    upstream: "http://127.0.0.1:1", streamingEnabled: false)
                try second.encodedForRouteFile().write(
                    to: harness.routesDir.appendingPathComponent(
                        TBDConstants.modelProxyRouteFileName(token: second.token)))
                try await harness.routes.add(token: second.token)
                let withTwo = try await status(harness)
                #expect(withTwo.routeCount == 2)

                var arrived = 0
                for try await line in bytes.lines where line.hasPrefix("event: ") { arrived += 1 }
                #expect(arrived == 4)

                await waitUntil(
                    "the relay released its in-flight stream",
                    sample: { harness.server.streamsInFlight }, isSatisfied: { $0 == 0 })
                let drained = try await status(harness)
                #expect(drained.streamsInFlight == 0)
            }
        }

        // MARK: Retire

        @Test("retire answers before the drain and a successor binds the port")
        func retireAnswersBeforeDrainAndSuccessorCanBind() async throws {
            // The handshake the whole supervisor design rests on: the answer means
            // "the listener is closed", not "the streams are done", so the
            // no-listener gap is the successor's bind time rather than the length
            // of whatever turn is still running.
            let retired = ProxyFlagBox()
            let ticks = (1...6).map { index in
                (delayMs: 500, bytes: Array("event: tick\ndata: {\"n\":\(index)}\n\n".utf8))
            }

            try await withProxy(
                prefix: "pxret",
                script: { _, _ in FakeUpstream.Script(events: ticks) },
                onRetire: { retired.set() }
            ) { harness in
                var request = URLRequest(url: harness.url("/v1/messages"))
                request.httpMethod = "POST"
                request.httpBody = Data(#"{"stream":true}"#.utf8)
                let (bytes, response) = try await harness.session.bytes(for: request)
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
                #expect(harness.server.streamsInFlight == 1)

                let asked = ContinuousClock().now
                let (body, retireResponse) = try await harness.session.data(
                    for: controlRequest(port: harness.port, method: "POST", path: "/tbd/retire"))
                let answered = ContinuousClock().now - asked

                #expect((retireResponse as? HTTPURLResponse)?.statusCode == 200)
                #expect(String(decoding: body, as: UTF8.self) == ControlEndpoints.retiringBody)
                // Bounded well under the ~3 seconds the stream still has to run:
                // an answer that waited for the drain could not land this early.
                #expect(answered < .milliseconds(500), "retire answered after \(answered)")
                #expect(harness.server.streamsInFlight == 1, "the stream was cut by the retire")
                #expect(!retired.value, "the process was handed over before the drain finished")

                // The successor takes the port while the first proxy is still
                // delivering. This is what `SO_REUSEADDR` on the listener buys: the
                // connections carrying the in-flight streams still hold the port.
                let successor = ProxyServer(
                    port: harness.port, routes: harness.routes, tee: nil,
                    status: {
                        ModelProxyStatus(
                            version: "successor", pid: getpid(), processStartTime: Date(),
                            port: harness.port, streamsInFlight: 0, routeCount: 0)
                    },
                    onRetire: {})
                let bindStarted = ContinuousClock().now
                var boundPort: Int?
                var lastBindError: (any Error)?
                // Retried inside the second the promise allows rather than
                // tried once: an ephemeral port the retire just freed is a port
                // any concurrently starting listener in this process can be
                // handed, and that is a squatter, not a broken handshake. The
                // bound is still the assertion — a successor that cannot take
                // the port within a second fails here with what it last saw.
                while ContinuousClock().now - bindStarted < .seconds(1) {
                    do {
                        boundPort = try await withPhaseDeadline("successor bind", seconds: 5) {
                            try await successor.start()
                        }
                        break
                    } catch {
                        lastBindError = error
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
                let bindTook = ContinuousClock().now - bindStarted
                // Built before the macro, not inside it: `#expect`'s message is
                // a `Comment`, and a nested closure interpolated into one is
                // the shape that failed to compile in Task A4.
                let bindFailure = lastBindError.map { "\($0)" } ?? "no error"
                #expect(
                    boundPort == harness.port,
                    "the successor did not take the port in \(bindTook): \(bindFailure)")
                #expect(harness.server.streamsInFlight == 1, "the first stream ended early")
                await successor.stop()

                // No stream was cut: every scripted event still arrives.
                var arrived = 0
                for try await line in bytes.lines where line.hasPrefix("event: ") { arrived += 1 }
                #expect(arrived == 6)

                await waitUntil(
                    "the drain handed the process over", sample: { retired.value },
                    isSatisfied: { $0 })
            }
        }

        @Test("the drain gives up at its cap and hands over anyway")
        func retireDrainGivesUpAtItsCap() async throws {
            // A stream that never ends must not leave a retired proxy running
            // forever. Exercised directly with a tiny cap: at 10 minutes and a
            // 250 ms poll the branch is unreachable from a test.
            let root = proxyScratchRoot(prefix: "pxcap")
            defer { try? FileManager.default.removeItem(at: root) }
            let routes = RouteTable(
                routesDir: root.appendingPathComponent("proxy/routes"),
                streamsDir: root.appendingPathComponent("streams"))

            let retired = ProxyFlagBox()
            let closed = ProxyFlagBox()
            let control = ControlEndpoints(
                routes: routes,
                status: { ModelProxyStatus(
                    version: "test", pid: getpid(), processStartTime: Date(), port: 0,
                    streamsInFlight: 0, routeCount: 0) },
                onRetire: { retired.set() },
                closeListener: { closed.set() },
                streamsInFlight: { 1 },
                pollInterval: .milliseconds(1),
                drainCap: .milliseconds(20))

            let response = await control.handle(
                method: "POST", path: "/tbd/retire", body: [], remoteAddress: loopbackV4)
            #expect(response.status == .ok)
            #expect(closed.value, "the listener was still open when retire answered")

            await waitUntil(
                "the drain gave up at its cap", sample: { retired.value }, isSatisfied: { $0 })
        }

        @Test("the drain samples the count for as long as its cap allows")
        func drainPollCountFollowsTheCap() async throws {
            #expect(ControlEndpoints.pollCount(cap: .seconds(600), interval: .milliseconds(250)) == 2400)
            #expect(ControlEndpoints.pollCount(cap: .seconds(1), interval: .milliseconds(250)) == 4)
            // A cap shorter than one interval still samples once, so a drain never
            // hands the process over without having looked at all.
            #expect(ControlEndpoints.pollCount(cap: .milliseconds(100), interval: .seconds(1)) == 1)
        }

        // MARK: Routes

        @Test("a route is taken by token and dropped with its files")
        func routesAddAndDelete() async throws {
            try await withProxy(
                prefix: "pxroutes",
                script: { _, _ in
                    FakeUpstream.Script(
                        status: 200, headers: [("content-type", "application/json")],
                        events: [(delayMs: 0, bytes: Array(#"{"ok":true}"#.utf8))])
                }
            ) { harness in
                let upstream = try #require(await harness.routes.route(for: harness.token)?.upstream)
                let token = ModelProxyRoute.mintToken()
                let terminalID = UUID()
                let route = ModelProxyRoute(
                    token: token, terminalID: terminalID, upstream: upstream, streamingEnabled: true)
                let routeFile = harness.routesDir.appendingPathComponent(
                    TBDConstants.modelProxyRouteFileName(token: token))
                try route.encodedForRouteFile().write(to: routeFile)

                // A file on disk is not a route: the proxy loads at start and is
                // told about the rest, which is what this verb is for.
                let beforeAdd = try await forwardStatus(harness, token: token)
                #expect(beforeAdd == 404)

                let (added, addResponse) = try await harness.session.data(
                    for: controlRequest(
                        port: harness.port, method: "POST", path: "/tbd/routes",
                        body: #"{"token":"\#(token)"}"#))
                #expect((addResponse as? HTTPURLResponse)?.statusCode == 200)
                let echoed = try ModelProxyRoute.decodeRouteFile(added)
                #expect(echoed.token == token)
                #expect(echoed.terminalID == terminalID)
                #expect(echoed.streamingEnabled)

                let afterAdd = try await forwardStatus(harness, token: token)
                #expect(afterAdd == 200)

                // A stream file the tee would have written, so the delete has both
                // of the route's files to reclaim.
                let streamFile = harness.streamsDir.appendingPathComponent(
                    TBDConstants.streamFileName(terminalID: terminalID))
                try Data(#"{"type":"stop","message":"msg_X"}\#n"#.utf8).write(to: streamFile)

                let (removed, deleteResponse) = try await harness.session.data(
                    for: controlRequest(
                        port: harness.port, method: "DELETE", path: "/tbd/routes/\(token)"))
                #expect((deleteResponse as? HTTPURLResponse)?.statusCode == 200)
                #expect(String(decoding: removed, as: UTF8.self) == ControlEndpoints.removedBody)

                #expect(!FileManager.default.fileExists(atPath: routeFile.path))
                #expect(!FileManager.default.fileExists(atPath: streamFile.path))
                let afterDelete = try await forwardStatus(harness, token: token)
                #expect(afterDelete == 404)

                // Idempotent: the daemon's cleanup pass retires routes it may have
                // retired already, and a 404 there would read as a failure.
                let (_, again) = try await harness.session.data(
                    for: controlRequest(
                        port: harness.port, method: "DELETE", path: "/tbd/routes/\(token)"))
                #expect((again as? HTTPURLResponse)?.statusCode == 200)
            }
        }

        @Test("a malformed token is refused and a missing route file is a 404")
        func routesRefusesMalformedAndMissing() async throws {
            try await withProxy(
                prefix: "pxrbad",
                script: { _, _ in FakeUpstream.Script(events: []) }
            ) { harness in
                // Not 32 lowercase hex characters: refused before it can compose a
                // path, which is the check that keeps `..` out of `routes/`.
                let (_, malformed) = try await harness.session.data(
                    for: controlRequest(
                        port: harness.port, method: "POST", path: "/tbd/routes",
                        body: #"{"token":"../../etc/passwd"}"#))
                #expect((malformed as? HTTPURLResponse)?.statusCode == 400)

                // Well-formed and naming nothing: the daemon and the proxy
                // disagree about what was written, which is a different fix from a
                // bad request.
                let (_, missing) = try await harness.session.data(
                    for: controlRequest(
                        port: harness.port, method: "POST", path: "/tbd/routes",
                        body: #"{"token":"\#(ModelProxyRoute.mintToken())"}"#))
                #expect((missing as? HTTPURLResponse)?.statusCode == 404)

                let (_, garbage) = try await harness.session.data(
                    for: controlRequest(
                        port: harness.port, method: "POST", path: "/tbd/routes", body: "not json"))
                #expect((garbage as? HTTPURLResponse)?.statusCode == 400)
            }
        }

        @Test("a control path answers only the verb it owns")
        func controlVerbsAreChecked() async throws {
            try await withProxy(
                prefix: "pxverbs",
                script: { _, _ in FakeUpstream.Script(events: []) }
            ) { harness in
                let (_, wrongVerb) = try await harness.session.data(
                    for: controlRequest(port: harness.port, method: "GET", path: "/tbd/retire"))
                #expect((wrongVerb as? HTTPURLResponse)?.statusCode == 405)

                let (_, unknown) = try await harness.session.data(
                    for: controlRequest(port: harness.port, method: "GET", path: "/tbd/nope"))
                #expect((unknown as? HTTPURLResponse)?.statusCode == 404)
            }
        }

        // MARK: Loopback

        @Test("only a loopback peer reaches a control verb")
        func controlVerbsAreLoopbackOnly() async throws {
            // The predicate first: the listener only ever binds 127.0.0.1, so a
            // non-loopback connection is not something a test on this machine can
            // produce, and the check is defense in depth against a future change
            // to the bind address rather than against today's traffic.
            func admits(_ address: String) throws -> Bool {
                ControlEndpoints.isLoopback(try SocketAddress(ipAddress: address, port: 1))
            }
            #expect(try admits("127.0.0.1"))
            #expect(try admits("127.4.5.6"))
            #expect(try admits("::1"))
            #expect(try admits("::ffff:127.0.0.1"))
            #expect(try !admits("10.0.0.5"))
            #expect(try !admits("192.168.1.9"))
            #expect(try !admits("::ffff:10.0.0.5"))
            #expect(try !admits("2001:db8::1"))
            let unixAddress = try SocketAddress(unixDomainSocketPath: "/tmp/proxy-control-test.sock")
            #expect(!ControlEndpoints.isLoopback(unixAddress))
            #expect(!ControlEndpoints.isLoopback(nil))

            // And the same check, reached through a real connection, so the
            // address the handler reads off the channel is proved to be one the
            // predicate admits — a status endpoint that 403s every caller would
            // pass every assertion above.
            try await withProxy(
                prefix: "pxloop",
                script: { _, _ in FakeUpstream.Script(events: []) }
            ) { harness in
                let request = """
                    GET /tbd/status HTTP/1.1\r
                    Host: 127.0.0.1\r
                    Connection: close\r
                    \r

                    """
                let port = harness.port
                let response = try await withPhaseDeadline("raw status", seconds: 20) {
                    try await withCheckedThrowingContinuation {
                        (continuation: CheckedContinuation<String, any Error>) in
                        DispatchQueue.global().async {
                            continuation.resume(
                                with: Result { try rawHTTPExchange(port: port, request: request) })
                        }
                    }
                }
                #expect(
                    response.hasPrefix("HTTP/1.1 200"),
                    "a loopback control request was refused: \(response.prefix(64))")
                #expect(response.contains(#""routeCount":1"#))
            }
        }
    }
}

// MARK: - Helpers

/// A loopback address for the tests that call `ControlEndpoints` directly.
///
/// Force-unwrapped through `try!`-free construction: the literal is a valid
/// IPv4 address, so a failure here is a broken test rather than a condition
/// worth propagating.
let loopbackV4: SocketAddress? = try? SocketAddress(ipAddress: "127.0.0.1", port: 1)

/// One `/tbd/...` request against the proxy under test.
func controlRequest(port: Int, method: String, path: String, body: String? = nil) -> URLRequest {
    // Force-unwrapped for the same reason `ProxyHarness.url` is: the URL is
    // composed from a literal path and a port the kernel just handed out.
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.httpMethod = method
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data(body.utf8)
    }
    return request
}

/// `GET /tbd/status`, decoded through the coder pair the daemon will use.
func status(_ harness: ProxyHarness) async throws -> ModelProxyStatus {
    let (data, response) = try await harness.session.data(
        for: controlRequest(port: harness.port, method: "GET", path: "/tbd/status"))
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    return try ModelProxyStatus.decodeStatusResponse(data)
}

/// The status code a forwarded request through `token` comes back with.
func forwardStatus(_ harness: ProxyHarness, token: String) async throws -> Int {
    // Force-unwrapped for the same reason `ProxyHarness.url` is.
    var request = URLRequest(
        url: URL(string: "http://127.0.0.1:\(harness.port)/r/\(token)/v1/messages")!)
    request.httpMethod = "POST"
    request.httpBody = Data(#"{"stream":true}"#.utf8)
    let (_, response) = try await harness.session.data(for: request)
    return (response as? HTTPURLResponse)?.statusCode ?? 0
}
