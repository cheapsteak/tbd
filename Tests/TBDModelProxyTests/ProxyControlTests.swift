import Foundation
import NIOHTTP1
import NIOCore
import TestSupport
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

        @Test("status names the TBD home the proxy serves")
        func statusReportsTheHome() async throws {
            // Two TBD homes on one machine draw their proxy port from the same
            // ephemeral range, and every other field of a status answer would
            // match across them: both name a live TBD proxy, and a same-version
            // install reports the same identity. The home is the field that
            // makes the two tellable apart, so a daemon adopts the process
            // holding its port only when this equals its own.
            try await withProxy(
                prefix: "pxhome",
                script: { _, _ in FakeUpstream.Script(events: []) }
            ) { harness in
                let reported = try await status(harness)
                #expect(reported.home == harness.home)
                // Canonical: the same directory reached through a symlinked
                // `/var` or a `..` segment has to compare equal to this, so an
                // uncanonicalized answer is a daemon that refuses to adopt its
                // own proxy.
                #expect(reported.home == ModelProxyStatus.canonicalHome(harness.home))
                #expect(!reported.home.isEmpty)
                // The rest of the identity arrives unchanged around it — the
                // two counters are the only fields the endpoint replaces — so
                // a `home` filled from some other field of the closure fails
                // here rather than passing on a coincidence.
                #expect(reported.version == "test")
                #expect(reported.port == harness.port)
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
            // Six events a second apart: the stream has to still be running
            // when the retire answers, which is what the in-flight count and
            // the untouched event stream below read. The successor's wait for
            // the port is deliberately not paid for out of this script's
            // length; see the wait itself.
            let ticks = (1...6).map { index in
                (delayMs: 1000, bytes: Array("event: tick\ndata: {\"n\":\(index)}\n\n".utf8))
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
                // Bounded well under the ~6 seconds the stream still has to
                // run: an answer that waited for the drain could not land this
                // early. Two seconds rather than 500 ms because the claim is
                // "before the drain", not "in 500 ms" — and a loaded runner
                // that took 600 ms to turn one loopback round trip around
                // would redden a proxy that did exactly the right thing.
                #expect(answered < .seconds(2), "retire answered after \(answered)")
                #expect(harness.server.streamsInFlight == 1, "the stream was cut by the retire")
                #expect(!retired.value, "the process was handed over before the drain finished")

                // The claim the handshake makes, asserted where no race can
                // turn it: at the instant the answer lands, a connect to the
                // port must be refused. Only a listening socket answers one, so
                // a refusal is proof the listener is gone — and a proxy that
                // wrote its 200 first and closed afterwards is still accepting
                // here, however its successor's bind goes. The bind below
                // cannot carry this claim on its own, because a retire frees
                // the port and cannot reserve it.
                #expect(
                    connectRefused(port: harness.port),
                    "the port still accepted a connection when the retire answered")

                // The successor takes the port while the first proxy is still
                // delivering. This is what `SO_REUSEADDR` on the listener buys:
                // the connections carrying the in-flight streams still hold the
                // port, and a bind those refused would fail on the first
                // attempt and on every one after it.
                let successor = ProxyServer(
                    port: harness.port, routes: harness.routes, tee: nil,
                    status: {
                        ModelProxyStatus(
                            version: "successor", pid: getpid(), processStartTime: Date(),
                            port: harness.port, streamsInFlight: 0, routeCount: 0,
                            home: harness.home)
                    },
                    onRetire: {})
                let bindStarted = ContinuousClock().now
                let bindOutcome = ProxyBindOutcomeBox()
                // Waited out rather than budgeted, because a retire frees the
                // port and cannot reserve it. macOS hands ephemeral ports out
                // sequentially from one global counter — `net.inet.tcp
                // .randomize_ports` is 0 — across the 16,384 numbers in
                // 49152-65535, so a freed one comes back around after a single
                // wrap of that range: 16,220 allocations, measured at 0.15 s on
                // an idle machine. Beside every other socket-opening test in
                // the pass, the number this retire just freed is one an
                // unrelated connect or listener can be handed at once, and
                // `SO_REUSEADDR` buys nothing against that: a socket that does
                // not set it refuses a `SO_REUSEADDR` bind, EADDRINUSE, for as
                // long as it lives. A squatter is somebody else holding a port,
                // not a broken handshake — which is why the handshake is
                // asserted above, off the socket the retire answered on, and
                // why this wait only has to outlast the squatter.
                //
                // Thirty seconds rather than the four this waited before, which
                // a peer test's listener outlived four times on `main` in one
                // day. It stays well inside `withProxy`'s 60-second "request"
                // phase deadline. The "no stream was cut" half of the test does
                // not come out of this wait either: it is the in-flight count
                // above and the six events below.
                let poll = await pollUntilTrue(
                    timeout: .seconds(30), pollInterval: .milliseconds(50)
                ) {
                    do {
                        bindOutcome.bound(
                            try await withPhaseDeadline("successor bind", seconds: 5) {
                                try await successor.start()
                            })
                        return true
                    } catch {
                        bindOutcome.failed(error)
                        return false
                    }
                }
                let bindTook = ContinuousClock().now - bindStarted
                switch poll {
                case .satisfied:
                    #expect(bindOutcome.port == harness.port, "the successor bound some other port")
                case .cancelled:
                    // Attribution belongs to whatever cancelled this test, not
                    // to a wait that was about to succeed.
                    break
                case .timedOut:
                    // Both built before the macro, not inside it: `Issue.record`
                    // takes a `Comment`, and a nested closure interpolated into
                    // one is the shape that failed to compile in Task A4.
                    let bindFailure = bindOutcome.lastError ?? "no error"
                    // Which kind of squatter, asked the one way a test inside
                    // the process can: a connect that is answered means
                    // somebody is listening on the port, a refused one means a
                    // socket that never listens — a client connection's local
                    // port, say — holds it.
                    let holder = connectRefused(port: harness.port)
                        ? "nothing is listening on it"
                        : "something is listening on it"
                    Issue.record(
                        """
                        the successor did not take the port in \(bindTook): \(bindFailure); \
                        \(holder)
                        """)
                }
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
                    streamsInFlight: 0, routeCount: 0,
                    home: ModelProxyStatus.canonicalHome(root.path)) },
                onRetire: { retired.set() },
                closeListener: { closed.set() },
                streamsInFlight: { 1 },
                pollInterval: .milliseconds(1),
                drainCap: .milliseconds(20))

            let response = await control.handle(
                method: "POST", path: "/tbd/retire", body: [], remoteAddress: loopbackV4)
            #expect(response.status == .ok)
            #expect(closed.value, "the listener was still open when retire answered")
            // What the server does once the answer is on the wire.
            response.afterAnswer?()

            await waitUntil(
                "the drain gave up at its cap", sample: { retired.value }, isSatisfied: { $0 })
        }

        @Test("the drain cannot begin until the answer has been written")
        func retireDoesNotDrainBeforeItsAnswerIsWritten() async throws {
            // On an idle proxy the drain finishes on its *first* sample and
            // calls `onRetire`, which in production is `exit(0)`. Started
            // inside the endpoint, that races the process's own exit against
            // its 200, and a supervisor that gets a connection reset cannot
            // tell a retiring proxy from a crashed one.
            let root = proxyScratchRoot(prefix: "pxorder")
            defer { try? FileManager.default.removeItem(at: root) }
            let routes = RouteTable(
                routesDir: root.appendingPathComponent("proxy/routes"),
                streamsDir: root.appendingPathComponent("streams"))

            let retires = ProxyCountBox()
            let control = ControlEndpoints(
                routes: routes,
                status: { ModelProxyStatus(
                    version: "test", pid: getpid(), processStartTime: Date(), port: 0,
                    streamsInFlight: 0, routeCount: 0,
                    home: ModelProxyStatus.canonicalHome(root.path)) },
                onRetire: { retires.increment() },
                closeListener: {},
                // Idle: the drain's first sample is already zero, so nothing
                // but the ordering keeps `onRetire` from firing at once.
                streamsInFlight: { 0 },
                pollInterval: .milliseconds(1),
                drainCap: .milliseconds(50))

            let response = await control.handle(
                method: "POST", path: "/tbd/retire", body: [], remoteAddress: loopbackV4)
            #expect(response.status == .ok)
            #expect(response.body == ControlEndpoints.retiringBody)

            // Generously longer than the 1 ms poll: a drain that had started
            // inside `handle` would have finished many times over by now.
            try? await Task.sleep(nanoseconds: 200_000_000)
            #expect(
                retires.value == 0,
                "the drain ran before the answer was written")

            let answer = try #require(response.afterAnswer)
            answer()
            await waitUntil(
                "the drain ran once the answer was written", sample: { retires.value },
                isSatisfied: { $0 == 1 })
        }

        @Test("two retires start one drain and hand over once")
        func twoRetiresHandOverOnce() async throws {
            // A supervisor that retried its retire — or two of them — must not
            // get two drains: each one ends in `onRetire`, and `exit(0)` is not
            // a thing to call twice.
            let root = proxyScratchRoot(prefix: "pxtwice")
            defer { try? FileManager.default.removeItem(at: root) }
            let routes = RouteTable(
                routesDir: root.appendingPathComponent("proxy/routes"),
                streamsDir: root.appendingPathComponent("streams"))

            let retires = ProxyCountBox()
            let closes = ProxyCountBox()
            let control = ControlEndpoints(
                routes: routes,
                status: { ModelProxyStatus(
                    version: "test", pid: getpid(), processStartTime: Date(), port: 0,
                    streamsInFlight: 0, routeCount: 0,
                    home: ModelProxyStatus.canonicalHome(root.path)) },
                onRetire: { retires.increment() },
                closeListener: { closes.increment() },
                streamsInFlight: { 0 },
                pollInterval: .milliseconds(1),
                drainCap: .milliseconds(50))

            let first = await control.handle(
                method: "POST", path: "/tbd/retire", body: [], remoteAddress: loopbackV4)
            let second = await control.handle(
                method: "POST", path: "/tbd/retire", body: [], remoteAddress: loopbackV4)
            // Both are answered — a second retire is not an error, and closing
            // an already-closed listener is a no-op by contract.
            #expect(first.status == .ok)
            #expect(second.status == .ok)
            #expect(closes.value == 2)

            first.afterAnswer?()
            second.afterAnswer?()
            await waitUntil(
                "the drain handed over", sample: { retires.value }, isSatisfied: { $0 >= 1 })
            try? await Task.sleep(nanoseconds: 200_000_000)
            #expect(retires.value == 1, "two retires started two drains")
        }

        @Test("a status round-trips the microseconds the kernel reported")
        func statusRoundTripsSubSecondPrecision() async throws {
            // `ProcessStartTime.startTime` reads a `struct timeval`, so the
            // value carries microseconds, and the daemon adopts a proxy by
            // comparing this field against what it reads from the process
            // table. A coder that rendered whole seconds would make every
            // comparison fail and quietly orphan a live proxy.
            let started = Date(timeIntervalSince1970: 1_789_234_567.123456)
            let status = ModelProxyStatus(
                version: "dev", pid: 4321, processStartTime: started, port: 51234,
                streamsInFlight: 2, routeCount: 3, home: "/tmp/pinned/tbd")

            let decoded = try ModelProxyStatus.decodeStatusResponse(
                try status.encodedForStatusResponse())
            #expect(decoded == status)
            // The assertion that discriminates: an `.iso8601` coder decodes to
            // the whole second, so this is the line that fails if the fraction
            // is ever thrown away again.
            #expect(decoded.processStartTime == started)
            #expect(decoded.processStartTime != Date(timeIntervalSince1970: 1_789_234_567))
        }

        @Test("retire answers on the wire before it hands the process over")
        func retireAnswersOverASocketBeforeHandingOver() async throws {
            // The wiring half of the ordering rule: the endpoint hands the
            // drain back, and the *server* must run it from the response
            // write's completion. A server that dropped it would answer
            // correctly and never retire at all.
            let retired = ProxyFlagBox()
            try await withProxy(
                prefix: "pxidle",
                script: { _, _ in FakeUpstream.Script(events: []) },
                onRetire: { retired.set() }
            ) { harness in
                #expect(harness.server.streamsInFlight == 0)
                let (body, response) = try await harness.session.data(
                    for: controlRequest(port: harness.port, method: "POST", path: "/tbd/retire"))
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
                // The whole body, not a prefix: what a client of a proxy that
                // exited mid-write would have is a truncated read or a reset.
                #expect(String(decoding: body, as: UTF8.self) == ControlEndpoints.retiringBody)

                await waitUntil(
                    "the drain handed the process over", sample: { retired.value },
                    isSatisfied: { $0 })
            }
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

/// A counter a `@Sendable` callback can bump from anywhere.
/// The successor's bind result, carried out of the poll closure that produces
/// it.
///
/// A box rather than two `var`s the closure captures: the capture would be a
/// mutation from inside an `async` closure, and the boxes this suite already
/// uses are the shape that answers it.
final class ProxyBindOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var boundPort: Int?
    private var failure: String?

    /// The port the successor bound, or nil while no attempt has succeeded.
    var port: Int? { lock.withLock { boundPort } }
    /// What the last refused bind said, rendered on the spot: the error is only
    /// ever wanted for a failure message.
    var lastError: String? { lock.withLock { failure } }

    func bound(_ port: Int) { lock.withLock { boundPort = port } }
    func failed(_ error: any Error) { lock.withLock { failure = "\(error)" } }
}

final class ProxyCountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
