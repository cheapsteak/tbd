import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The daemon's half of the control endpoint, driven against a real socket.
///
/// A real listener rather than a stubbed `URLProtocol`, because two of the
/// things worth pinning are wire facts: that `addRoute` sends
/// `{"token":"…"}` as a POST body and nothing else, and that a status answer
/// round-trips a start time with its fraction intact. A stub that handed back
/// a `ModelProxyStatus` would prove neither — the sub-second half is exactly
/// what an encoder in the middle would silently round away, and that value is
/// what adoption compares against the process table.
@Suite("Model proxy client")
struct ModelProxyClientTests {

    /// A start time with microseconds, the shape `ProcessStartTime` produces
    /// out of a `struct timeval`.
    static let startTime = Date(timeIntervalSince1970: 1_800_000_000.123456)

    static func statusBody(port: Int, pid: Int32 = 4321) throws -> String {
        let status = ModelProxyStatus(
            version: "8192-1800000000",
            pid: pid,
            processStartTime: startTime,
            port: port,
            streamsInFlight: 2,
            routeCount: 3)
        return String(decoding: try status.encodedForStatusResponse(), as: UTF8.self)
    }

    // MARK: - status

    /// The probe every adoption and every watch poll runs, including the
    /// fraction of a second that makes the identity check work.
    @Test("status decodes the proxy's answer and keeps the sub-second start time")
    func statusRoundTripsTheStartTime() async throws {
        let server = try LoopbackHTTPTestServer { request in
            guard request.method == "GET", request.path == "/tbd/status" else {
                return LoopbackHTTPTestServer.Reply(status: 404, body: "{}")
            }
            return .ok((try? Self.statusBody(port: 51234)) ?? "{}")
        }
        defer { server.stop() }

        let client = ModelProxyClient(port: server.port)
        let status = try await client.status()

        #expect(status.pid == 4321)
        #expect(status.port == 51234)
        #expect(status.version == "8192-1800000000")
        #expect(status.streamsInFlight == 2)
        #expect(status.routeCount == 3)
        // Not `==` on the `Date`: the wire carries a double of seconds, so the
        // claim is that the fraction survived, not that the bits are identical.
        #expect(
            abs(status.processStartTime.timeIntervalSince1970 - 1_800_000_000.123456) < 0.000_001,
            "the sub-second start time was rounded away: \(status.processStartTime)")

        let seen = server.requests()
        #expect(seen.count == 1)
        #expect(seen.first?.method == "GET")
        #expect(seen.first?.path == "/tbd/status")
    }

    /// A process on the port that is not a proxy is told apart by its answer,
    /// not by its silence — which is the whole reason the port probe reads the
    /// body at all.
    @Test("an answer that is not a status document is a malformed response")
    func aNonStatusAnswerIsMalformed() async throws {
        let server = try LoopbackHTTPTestServer { _ in .ok("<html>hello from nginx</html>") }
        defer { server.stop() }

        let client = ModelProxyClient(port: server.port)
        do {
            _ = try await client.status()
            Issue.record("an HTML page was accepted as a status document")
        } catch let error as ModelProxyClient.Error {
            // The *case*, not merely the type: `unexpectedStatus` and
            // `unreachable` are also `ModelProxyClient.Error`, and a 200 whose
            // body is not a status document has to be told apart from both —
            // it is what a stranger on the port looks like.
            guard case .malformedResponse = error else {
                Issue.record("a non-status answer was reported as \(error)")
                return
            }
        }
    }

    @Test("a non-200 carries the status and an excerpt of the body")
    func aNon200IsAnUnexpectedStatus() async throws {
        let server = try LoopbackHTTPTestServer { _ in
            LoopbackHTTPTestServer.Reply(status: 500, body: #"{"error":"nope"}"#)
        }
        defer { server.stop() }

        let client = ModelProxyClient(port: server.port)
        do {
            _ = try await client.status()
            Issue.record("a 500 was accepted as a status answer")
        } catch let error as ModelProxyClient.Error {
            #expect(error == .unexpectedStatus(code: 500, body: #"{"error":"nope"}"#))
        }
    }

    /// The request timeout, exercised against a listener that accepts and then
    /// says nothing at all — the shape a wedged proxy has.
    @Test("a proxy that accepts and never answers is unreachable, not a hang")
    func aSilentProxyTimesOut() async throws {
        let server = try LoopbackHTTPTestServer { _ in nil }
        defer { server.stop() }

        let client = ModelProxyClient(
            port: server.port,
            session: ModelProxyClient.makeSession(requestTimeout: 0.4),
            requestTimeout: 0.4)
        do {
            _ = try await client.status()
            Issue.record("a silent proxy answered a status probe")
        } catch let error as ModelProxyClient.Error {
            guard case .unreachable = error else {
                Issue.record("a timeout was reported as \(error)")
                return
            }
        }
        // Deliberately no wall-clock assertion. `timeoutIntervalForRequest` is
        // a budget the URL loading system spends on a starved cooperative
        // pool, not a deadline: this call returned in 32 seconds against a
        // 0.4-second timeout on a saturated CI runner. The claim is that it
        // gives up at all rather than hanging forever, and a true hang is
        // caught by the harness's own time limit, so measuring the elapsed
        // time here only manufactures a flake.
        #expect(server.requests().count == 1, "the request never reached the listener")
    }

    // MARK: - retire

    @Test("retire posts to /tbd/retire and returns once the proxy answers")
    func retirePostsToTheRetireEndpoint() async throws {
        let server = try LoopbackHTTPTestServer { _ in .ok(#"{"retiring":true}"#) }
        defer { server.stop() }

        try await ModelProxyClient(port: server.port).retire()

        let seen = server.requests()
        #expect(seen.count == 1)
        #expect(seen.first?.method == "POST")
        #expect(seen.first?.path == "/tbd/retire")
    }

    // MARK: - routes

    /// The body names a token and nothing else. Asserted on the composed
    /// document rather than on a substring: an extra field here would be a
    /// fact the proxy is being invited to trust from a request, and the whole
    /// route design says it must not.
    @Test("addRoute posts exactly {\"token\":…} to /tbd/routes")
    func addRoutePostsOnlyTheToken() async throws {
        let server = try LoopbackHTTPTestServer { _ in .ok(#"{"version":1}"#) }
        defer { server.stop() }

        let token = String(repeating: "ab", count: 16)
        try await ModelProxyClient(port: server.port).addRoute(token: token)

        let seen = server.requests()
        #expect(seen.count == 1)
        #expect(seen.first?.method == "POST")
        #expect(seen.first?.path == "/tbd/routes")
        let body = try #require(seen.first?.body)
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(decoded == ["token": token])
    }

    @Test("removeRoute deletes the token's path")
    func removeRouteDeletesTheTokenPath() async throws {
        let server = try LoopbackHTTPTestServer { _ in .ok(#"{"removed":true}"#) }
        defer { server.stop() }

        let token = String(repeating: "0f", count: 16)
        try await ModelProxyClient(port: server.port).removeRoute(token: token)

        let seen = server.requests()
        #expect(seen.count == 1)
        #expect(seen.first?.method == "DELETE")
        #expect(seen.first?.path == "/tbd/routes/\(token)")
    }

    /// The whitelist runs **before** anything is sent, so a token that could
    /// compose a path outside `routes/` never reaches the wire — the same
    /// claim `RouteTable` makes on the proxy's side, made here so a bad token
    /// cannot even be delivered.
    @Test("a token that is not 32 hex characters is refused without a request")
    func anInvalidTokenNeverReachesTheWire() async throws {
        let server = try LoopbackHTTPTestServer { _ in .ok("{}") }
        defer { server.stop() }

        let client = ModelProxyClient(port: server.port)
        for bad in ["../../etc/passwd", "", String(repeating: "A", count: 32), "abc"] {
            await #expect(throws: ModelProxyClient.Error.invalidToken(bad)) {
                try await client.addRoute(token: bad)
            }
            await #expect(throws: ModelProxyClient.Error.invalidToken(bad)) {
                try await client.removeRoute(token: bad)
            }
        }
        #expect(server.requests().isEmpty, "a refused token still reached the proxy")
    }

    // MARK: - The listener these tests are driven through

    /// `stop` **joins** the accept thread rather than closing the descriptor
    /// out from under it.
    ///
    /// A claim about the harness rather than about the client, asserted here
    /// because the failure it prevents has no fingerprint of its own: a thread
    /// left blocked in `accept()` on a closed fd number wakes up on whichever
    /// listening socket the kernel hands that number to next — another suite's,
    /// in this same test process — sees that *its* server was stopped, and
    /// drops that suite's connection. What anyone would see is a stranger's
    /// test failing intermittently.
    @Test("stop wakes the accept thread instead of leaving it on a closed descriptor")
    func stopJoinsTheAcceptThread() async throws {
        let server = try LoopbackHTTPTestServer { _ in .ok("{}") }

        // One real request first, so what is joined below is a thread proven
        // to have reached the accept loop rather than one that never started.
        _ = try? await ModelProxyClient(port: server.port).status()
        #expect(server.requests().count == 1, "the listener never served a request")

        server.stop()
        #expect(
            server.waitForAcceptThread(timeout: 1),
            "the accept thread was still blocked a second after stop() returned")
    }
}
