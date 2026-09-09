import CFNetwork
import Darwin
import Foundation
import NIOHTTP1
import TestSupport
import Testing

@testable import TBDModelProxy
@testable import TBDShared

/// Every proxy suite lives inside this one, and `.serialized` here is
/// recursive: the forwarding, tee, control and route-table suites run one at a
/// time rather than against each other.
///
/// Each of them binds real loopback listeners and asserts on *arrival times* —
/// that an event reaches the client as it arrives, that a text line lands
/// before the stream ends, that a retire answers before its drain. Three such
/// suites racing on a 3-core CI runner measure the runner's load rather than
/// the proxy: the cut-stream test lost its body chunk that way the first time
/// the tee and control suites ran beside it. They also mint and free ephemeral
/// ports, and a port freed by one suite's retire is a port another suite's
/// `bind(0)` can be handed a moment later.
@Suite("Model proxy", .serialized)
struct ModelProxySuites {}

extension ModelProxySuites {
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
    @Suite("Proxy forwarding", .serialized)
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
                // The header the whole feature depends on. `URLSession`
                // documents `Authorization` among the fields it reserves and
                // may set itself, so that it survives the upstream leg
                // unchanged is a promise worth pinning rather than assuming:
                // a proxy that dropped or rewrote it turns every turn into a
                // 401 the moment a base URL is set.
                request.setValue(
                    "Bearer test-token-not-real", forHTTPHeaderField: "Authorization")

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
                #expect(
                    received.head.headers.first(name: "authorization")
                        == "Bearer test-token-not-real")

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
            let spacingMs = 600
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
                // The scripted spacing is 600 ms and the assertion is 300, so
                // half the interval can be lost to a loaded runner before the
                // test reddens — and a proxy that buffered the whole stream,
                // which delivers all three within a millisecond of each other,
                // still cannot pass. The headroom is in the scripted spacing
                // rather than in a smaller floor for a reason: lowering the
                // floor towards zero eventually stops discriminating at all.
                let gap = arrivals[1] - arrivals[0]
                #expect(
                    gap >= .milliseconds(300),
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
                    let port = harness.port
                    let response = try await withPhaseDeadline("raw \(path)", seconds: 25) {
                        try await withCheckedThrowingContinuation {
                            (continuation: CheckedContinuation<String, any Error>) in
                            // A blocking socket on a `DispatchQueue`, never on the
                            // cooperative pool the rest of the suite runs on.
                            DispatchQueue.global().async {
                                continuation.resume(
                                    with: Result {
                                        try rawHTTPExchange(
                                            port: port,
                                            request:
                                                "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
                                    })
                            }
                        }
                    }
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

        // MARK: Endings

        @Test("a client that hangs up mid-stream still ends the relay and the tee")
        func clientDisconnectEndsRelayAndTee() async throws {
            // The ordinary aborted turn: the user presses Esc, Claude Code drops
            // the connection, and the response the proxy is relaying has no reader
            // left. Nothing about that is exceptional, so every accounting the
            // relay owns has to close on it — the in-flight count Task A5's retire
            // drains on, and the tee's `end(error:)`, which is the only signal an
            // `aborted` stream line can come from.
            let recorder = RecordingTee()
            // Deliberately far longer than the cut it is cut by. NIO's
            // `HTTPServerPipelineHandler` swallows `read()` while a response is
            // outstanding, so a client's FIN is not seen when it arrives — the
            // proxy learns the connection is gone when a later write to it fails.
            // A script that ended near that moment would let a relay which
            // reported nothing on cancellation still be rescued by the stream
            // finishing on its own, and the test would pass for the wrong reason.
            // 40 events at 1 s is 40 seconds of stream against the 20-second
            // waits below. The ratio is what matters and it is a discriminating
            // threshold rather than a hang guard, so it is sized by moving the
            // *script* out rather than by shortening the wait: at 250 ms an
            // event the stream ran out after 10 s, which left only a 5-second
            // wait, and 5 seconds is inside the scheduling latency fast pass 2
            // routinely shows — it went red on CI with the count still at 1
            // while nothing was wrong with the relay. Nothing waits for this
            // script to finish: the client cuts after the first event, and
            // `ScriptedUpstreamHandler` stops rescheduling as soon as its
            // channel goes inactive.
            let events = (1...40).map { index in
                (delayMs: 1000, bytes: Array("event: tick\ndata: {\"n\":\(index)}\n\n".utf8))
            }

            try await withProxy(
                prefix: "pxcd",
                script: { _, _ in FakeUpstream.Script(events: events) },
                tee: recorder
            ) { harness in
                let requestBody = #"{"stream":true}"#
                let request = """
                    POST /r/\(harness.token)/v1/messages HTTP/1.1\r
                    Host: 127.0.0.1\r
                    Content-Type: application/json\r
                    Content-Length: \(requestBody.utf8.count)\r
                    \r
                    \(requestBody)
                    """
                let port = harness.port
                // A raw socket rather than a cancelled `URLSession` task: the
                // moment the client's FIN goes out has to be the test's to choose,
                // because every assertion below is about what the proxy does after
                // it.
                let seen = try await withPhaseDeadline("cut after first event", seconds: 30) {
                    try await withCheckedThrowingContinuation {
                        (continuation: CheckedContinuation<String, any Error>) in
                        DispatchQueue.global().async {
                            continuation.resume(
                                with: Result {
                                    try rawHTTPCutAfterMarker(
                                        port: port, request: request, marker: "event: tick")
                                })
                        }
                    }
                }
                #expect(seen.contains("event: tick"), "the client never saw a first event")
                // The stream is still running upstream — 39 more events, a second
                // apart, are scripted — so nothing below can be explained by the
                // response having finished on its own.
                #expect(harness.upstream.requests.count == 1)

                // Bounded well below the script's own 40 seconds, so a relay that
                // only ends because the upstream ran out of events cannot pass.
                await waitUntil(
                    "the relay released its in-flight stream", seconds: 20,
                    sample: { harness.server.streamsInFlight }, isSatisfied: { $0 == 0 })
                await waitUntil(
                    "the tee was told the stream ended", seconds: 20,
                    sample: { recorder.endCount }, isSatisfied: { $0 == 1 })
                #expect(recorder.beginCount == 1)
                // Exactly once: `relayEnd` deduplicates, and a second end would
                // reach a tee that has already written its terminal line.
                #expect(recorder.endCount == 1)
                #expect(
                    recorder.lastEndError != nil,
                    "a hung-up turn is an aborted one, so the tee's end carries an error")
            }
        }

        @Test("a stream in flight is counted while it runs and released when it ends")
        func streamsInFlightTracksAnOpenStream() async throws {
            // The counter is what `POST /tbd/retire` drains on in Task A5, so a
            // leak here is a proxy that never agrees to retire.
            let events = (1...3).map { index in
                (delayMs: 400, bytes: Array("event: tick\ndata: {\"n\":\(index)}\n\n".utf8))
            }

            try await withProxy(
                prefix: "pxif",
                script: { _, _ in FakeUpstream.Script(events: events) }
            ) { harness in
                #expect(harness.server.streamsInFlight == 0)

                var request = URLRequest(url: harness.url("/v1/messages"))
                request.httpMethod = "POST"
                request.httpBody = Data(#"{"stream":true}"#.utf8)

                let (bytes, response) = try await harness.session.bytes(for: request)
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
                // The head has been relayed and the end has not, which is the
                // whole definition of the count.
                #expect(harness.server.streamsInFlight == 1)

                var arrived = 0
                for try await line in bytes.lines where line.hasPrefix("event: ") { arrived += 1 }
                #expect(arrived == 3)

                await waitUntil(
                    "the relay released its in-flight stream",
                    sample: { harness.server.streamsInFlight }, isSatisfied: { $0 == 0 })
            }
        }

        @Test("an upstream that drops mid-body reaches the client as a cut, not a short body")
        func upstreamCutMidBodyIsRelayedAsACut() async throws {
            // A truncated turn must not look like a finished one. If the relay
            // wrote `.end` here, the client would read a complete response that
            // happened to stop early — and Claude would treat a half-written
            // message as the whole answer instead of retrying.
            //
            // The event is delayed so the head is a message of its own: the
            // assertion is about a body that stops mid-flight, not about what a
            // client makes of a response whose head and death arrive together.
            //
            // The body arrives in two writes with clear air between them, and
            // that gap is load-bearing rather than cosmetic. The relay's
            // upstream leg is a `URLSession`, and a write immediately followed
            // by the peer's FIN reaches it as data and a truncation error at
            // once — with no guarantee the delegate is handed the bytes before
            // the error. Measured: with a single write the client received the
            // head and no body at all on a loaded runner. Writing the event's
            // first line 300 ms before the line that precedes the close puts
            // the relayed bytes beyond that race, while the close still
            // follows a write immediately, which is the shape under test.
            let eventHead = Array("event: content_block_delta\n".utf8)
            let eventTail = Array("data: {\"i\":0}\n\n".utf8)

            try await withProxy(
                prefix: "pxcut",
                script: { _, _ in
                    FakeUpstream.Script(
                        status: 200,
                        headers: [
                            ("content-type", "text/event-stream; charset=utf-8"),
                            // Declares more than it will send, and that shape is
                            // deliberate. Measured on CI: an upstream *chunked*
                            // body that stops without its terminating chunk
                            // reaches `URLSession` as a clean completion — the
                            // upstream leg is told nothing failed, so the relay
                            // cannot tell that shape from a finished response. A
                            // body short of a declared length is the truncation
                            // `didCompleteWithError` does report, and so it is the
                            // one that can exercise the relay's cut path at all.
                            ("content-length", "\(eventHead.count + eventTail.count + 64)"),
                        ],
                        events: [
                            (delayMs: 200, bytes: eventHead), (delayMs: 300, bytes: eventTail),
                        ],
                        closeWithoutStop: true)
                }
            ) { harness in
                // Read on a raw socket rather than through `URLSession`: the
                // contract is about the bytes on the wire — a chunked body that
                // stops without its terminating chunk — and how a particular
                // client maps that to an error is its own business.
                let requestBody = #"{"stream":true}"#
                let request = """
                    POST /r/\(harness.token)/v1/messages HTTP/1.1\r
                    Host: 127.0.0.1\r
                    Content-Type: application/json\r
                    Content-Length: \(requestBody.utf8.count)\r
                    Connection: close\r
                    \r
                    \(requestBody)
                    """
                let port = harness.port
                let response = try await withPhaseDeadline("cut read", seconds: 30) {
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
                    "the head was relayed before the cut; got: \(response.prefix(64))")
                #expect(response.lowercased().contains("transfer-encoding: chunked"))
                #expect(response.contains("content_block_delta"))
                // The terminating chunk is the whole difference between a response
                // that completed and one that was cut.
                #expect(
                    !response.hasSuffix("0\r\n\r\n"),
                    "the relay wrote a terminating chunk on a cut stream; tail: \(String(response.suffix(48)).debugDescription)"
                )

                #expect(harness.upstream.requests.count == 1)
                await waitUntil(
                    "the relay released its in-flight stream",
                    sample: { harness.server.streamsInFlight }, isSatisfied: { $0 == 0 })
            }
        }

        @Test("an unreachable upstream is 502 in the API's own error shape")
        func unreachableUpstreamIs502() async throws {
            // Claude's retry and capability-disable logic reads these bodies, so a
            // proxy that answered with its own error shape — or with a bare status
            // — would change what the client does next.
            try await withProxy(
                prefix: "px502",
                script: { _, _ in FakeUpstream.Script(events: []) }
            ) { harness in
                let deadPort = try unusedLoopbackPort()
                let deadToken = ModelProxyRoute.mintToken()
                let dead = ModelProxyRoute(
                    token: deadToken, terminalID: UUID(),
                    upstream: "http://127.0.0.1:\(deadPort)", streamingEnabled: false)
                try dead.encodedForRouteFile().write(
                    to: harness.routesDir.appendingPathComponent(
                        TBDConstants.modelProxyRouteFileName(token: deadToken)))
                try await harness.routes.add(token: deadToken)

                let url = try #require(
                    URL(string: "http://127.0.0.1:\(harness.port)/r/\(deadToken)/v1/messages"))
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.httpBody = Data(#"{"stream":true}"#.utf8)

                let (data, response) = try await harness.session.data(for: request)
                #expect((response as? HTTPURLResponse)?.statusCode == 502)

                // Asserted as a prefix through `message`: what follows is the
                // platform's own wording for a refused connection, which is not
                // ours to pin.
                let text = String(decoding: data, as: UTF8.self)
                let expected =
                    #"{"type":"error","error":{"type":"api_error","message":"upstream unreachable: "#
                #expect(text.hasPrefix(expected), "502 body was: \(text)")
                #expect(text.hasSuffix(#""}}"#), "502 body was: \(text)")

                // Nothing was forwarded, and the count taken when the request
                // was accepted was handed back by the same `relayEnd` that
                // wrote the 502.
                #expect(harness.upstream.requests.isEmpty)
                #expect(harness.server.streamsInFlight == 0)
            }
        }

        @Test("a stream is counted from acceptance, so a retire in the head's window waits")
        func streamsInFlightCountsFromAcceptance() async throws {
            // Time to first byte is a whole model round trip, and for its
            // entire length the request has produced no byte anyone can see.
            // Counted from the upstream *head* instead, a retire arriving in
            // that window samples zero streams in flight and hands the process
            // over — `exit(0)` in production — on a turn that had just started.
            let retired = ProxyFlagBox()
            let headArrived = ProxyFlagBox()

            try await withProxy(
                prefix: "pxacc",
                script: { _, _ in
                    var script = sseTextAnswer(messageID: "msg_TTFB", deltas: ["late"])
                    // The head itself is delayed. No `delayMs` can express
                    // this: the first event's gap is a gap before a body byte,
                    // and by then the head is already on the wire.
                    script.headDelayMs = 2000
                    return script
                },
                onRetire: { retired.set() }
            ) { harness in
                #expect(harness.server.streamsInFlight == 0)

                let turn = Task { () -> Int in
                    var request = URLRequest(url: harness.url("/v1/messages"))
                    request.httpMethod = "POST"
                    request.httpBody = Data(#"{"stream":true}"#.utf8)
                    let (bytes, response) = try await harness.session.bytes(for: request)
                    headArrived.set()
                    #expect((response as? HTTPURLResponse)?.statusCode == 200)
                    var events = 0
                    for try await line in bytes.lines where line.hasPrefix("event: ") {
                        events += 1
                    }
                    return events
                }

                // One second against the head's two. Counted from the head,
                // this wait runs out at zero and names itself.
                await waitUntil(
                    "the accepted request was counted before its head arrived", seconds: 1,
                    sample: { harness.server.streamsInFlight }, isSatisfied: { $0 == 1 })
                #expect(
                    !headArrived.value,
                    "the upstream answered early; the window under test was never entered")

                // A retire issued inside that window. The 200 is immediate
                // either way — what is under test is the drain, whose first
                // sample is taken before it sleeps at all.
                let (body, response) = try await harness.session.data(
                    for: controlRequest(port: harness.port, method: "POST", path: "/tbd/retire"))
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
                #expect(String(decoding: body, as: UTF8.self) == ControlEndpoints.retiringBody)
                #expect(
                    !headArrived.value,
                    "the retire outlasted the head's delay; the window was missed")
                #expect(
                    !retired.value,
                    "the drain handed the process over while a turn was still waiting on its head")

                // `sseTextAnswer` is message_start, content_block_start, one
                // delta, content_block_stop, message_delta, message_stop.
                let events = try await turn.value
                #expect(events == 6, "the retire cut a stream it was supposed to drain")
                await waitUntil(
                    "the relay released its stream once the response ended",
                    sample: { harness.server.streamsInFlight }, isSatisfied: { $0 == 0 })
                await waitUntil(
                    "the drain handed over once the stream ended", sample: { retired.value },
                    isSatisfied: { $0 })
            }
        }

        // MARK: Redirects

        @Test("a redirect is relayed to the client, never followed")
        func redirectIsRelayedNotFollowed() async throws {
            // `URLSession` follows a 3xx by default and copies the original
            // request's headers onto the new one, so a `Location` naming
            // another host would carry the client's `Authorization` — this
            // session's bearer token — to whatever answered it. The redirect
            // is the client's to act on, and relaying it is also what the
            // byte-transparency rule says about every other response.
            let redirectBody = Array(#"{"moved":true}"#.utf8)

            try await withProxy(
                prefix: "pxrdr",
                script: { head, _ in
                    // A relative `Location`, which resolves back to this same
                    // fake. A followed redirect therefore shows up as a second
                    // request here and as a 200 at the client, so the test
                    // fails loudly rather than by omission.
                    if head.uri.hasSuffix("/moved") {
                        return FakeUpstream.Script(
                            status: 200, headers: [("content-type", "application/json")],
                            events: [(delayMs: 0, bytes: Array(#"{"followed":true}"#.utf8))])
                    }
                    return FakeUpstream.Script(
                        status: 302,
                        headers: [("content-type", "application/json"), ("location", "/moved")],
                        events: [(delayMs: 0, bytes: redirectBody)])
                }
            ) { harness in
                // A raw socket, because `URLSession` follows a 302 itself: a
                // client that chased the `Location` would report on where it
                // landed rather than on what the proxy put on the wire.
                let requestBody = #"{"stream":true}"#
                let request = """
                    POST /r/\(harness.token)/v1/messages HTTP/1.1\r
                    Host: 127.0.0.1\r
                    Authorization: Bearer test-token-not-real\r
                    Content-Type: application/json\r
                    Content-Length: \(requestBody.utf8.count)\r
                    Connection: close\r
                    \r
                    \(requestBody)
                    """
                let port = harness.port
                let response = try await withPhaseDeadline("redirect read", seconds: 25) {
                    try await withCheckedThrowingContinuation {
                        (continuation: CheckedContinuation<String, any Error>) in
                        DispatchQueue.global().async {
                            continuation.resume(
                                with: Result { try rawHTTPExchange(port: port, request: request) })
                        }
                    }
                }

                #expect(
                    response.hasPrefix("HTTP/1.1 302"),
                    "the redirect was not relayed; got: \(response.prefix(64))")
                #expect(response.lowercased().contains("location: /moved"))
                #expect(response.contains(#"{"moved":true}"#))
                #expect(
                    !response.contains(#"{"followed":true}"#),
                    "the proxy followed the redirect and relayed what it found")

                // Exactly one, on the one host the route named. A followed
                // redirect would be two — and to another host, the bearer
                // token would have gone with it.
                #expect(harness.upstream.requests.count == 1)
                #expect(harness.upstream.requests.first?.head.uri == "/v1/messages")
            }
        }
    }
}

// MARK: - Route table

extension ModelProxySuites {
    @Suite("Proxy route table")
    struct ProxyRouteTableTests {
        @Test("a trailing slash on the upstream is trimmed before it can double a separator")
        func trimsTrailingSlashFromUpstream() async throws {
            let root = proxyScratchRoot(prefix: "pxrt")
            let routesDir = root.appendingPathComponent("proxy/routes")
            let streamsDir = root.appendingPathComponent("streams")
            try FileManager.default.createDirectory(at: routesDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: streamsDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let token = ModelProxyRoute.mintToken()
            let route = ModelProxyRoute(
                token: token, terminalID: UUID(), upstream: "https://api.anthropic.com/",
                streamingEnabled: false)
            try route.encodedForRouteFile().write(
                to: routesDir.appendingPathComponent(
                    TBDConstants.modelProxyRouteFileName(token: token)))

            let table = RouteTable(routesDir: routesDir, streamsDir: streamsDir)
            let added = try await table.add(token: token)
            #expect(added.upstream == "https://api.anthropic.com")

            let stored = try #require(await table.route(for: token))
            // The rule this exists for: every forwarded URL is `upstream + suffix`
            // and every suffix starts with `/`, so an untrimmed base composes
            // `https://api.anthropic.com//v1/messages` — a different path, and a
            // 404 from the API.
            #expect(stored.upstream + "/v1/messages" == "https://api.anthropic.com/v1/messages")
        }
    }
}

// MARK: - The upstream session's proxy environment

extension ModelProxySuites {
    /// How `HTTPS_PROXY` and `NO_PROXY` become a `connectionProxyDictionary`.
    ///
    /// Tested as a pure function over an injected environment, because it is
    /// the only way it can be tested at all: `connectionProxyDictionary` has
    /// no observable effect on a loopback request, and a test that read the
    /// developer's real shell would pass or fail by whose machine ran it.
    /// What it decides is not cosmetic — a user behind a corporate proxy
    /// reaches the model API through this, and a loopback exception that went
    /// missing would send the proxy's own tests through a proxy that cannot
    /// answer them.
    @Suite("Proxy upstream session")
    struct ProxyUpstreamSessionTests {
        static func dictionary(_ environment: [String: String]) -> [AnyHashable: Any]? {
            UpstreamForwarder.proxyDictionary(environment: environment)
        }

        static func host(_ dictionary: [AnyHashable: Any]?) -> String? {
            dictionary?[kCFNetworkProxiesHTTPSProxy as String] as? String
        }

        static func port(_ dictionary: [AnyHashable: Any]?) -> Int? {
            dictionary?[kCFNetworkProxiesHTTPSPort as String] as? Int
        }

        static func exceptions(_ dictionary: [AnyHashable: Any]?) -> [String] {
            dictionary?[kCFNetworkProxiesExceptionsList as String] as? [String] ?? []
        }

        @Test("NO_PROXY=* means no proxy dictionary at all")
        func noProxyWildcardShortCircuits() {
            // The conventional "never proxy anything". Honoring it by
            // returning no dictionary is what makes the `HTTPS_PROXY` beside
            // it inert, rather than leaving an exception list that would have
            // to match every host in the world.
            #expect(
                Self.dictionary(["NO_PROXY": "*", "HTTPS_PROXY": "http://proxy.acme:8080"]) == nil)
            // Lowercase spelling and surrounding whitespace, both of which a
            // real shell profile produces.
            #expect(
                Self.dictionary(["no_proxy": " * ", "https_proxy": "proxy.acme:8080"]) == nil)
        }

        @Test("no HTTPS_PROXY means no proxy dictionary")
        func absentProxyMeansNoDictionary() {
            #expect(Self.dictionary([:]) == nil)
            #expect(Self.dictionary(["NO_PROXY": ".acme.com"]) == nil)
            #expect(Self.dictionary(["HTTPS_PROXY": "   "]) == nil)
        }

        @Test("a bare host:port is read as a host and a port, not as a scheme")
        func bareHostPortIsParsed() {
            // The trap this exists for: `URLComponents` reads `proxy.acme` in
            // `proxy.acme:3128` as the *scheme*, so a bare `host:port` — as
            // common in these variables as a URL — parses to a nil host unless
            // a scheme is put in front of it first.
            let dictionary = Self.dictionary(["HTTPS_PROXY": "proxy.acme:3128"])
            #expect(Self.host(dictionary) == "proxy.acme")
            #expect(Self.port(dictionary) == 3128)
            #expect(dictionary?[kCFNetworkProxiesHTTPSEnable as String] as? Bool == true)
        }

        @Test("a URL-shaped proxy keeps its host, and its scheme supplies the default port")
        func urlShapedProxyIsParsed() {
            let explicit = Self.dictionary(["HTTPS_PROXY": "http://proxy.acme:8080"])
            #expect(Self.host(explicit) == "proxy.acme")
            #expect(Self.port(explicit) == 8080)

            let httpDefault = Self.dictionary(["https_proxy": "http://proxy.acme"])
            #expect(Self.host(httpDefault) == "proxy.acme")
            #expect(Self.port(httpDefault) == 80)

            let httpsDefault = Self.dictionary(["HTTPS_PROXY": "https://proxy.acme"])
            #expect(Self.host(httpsDefault) == "proxy.acme")
            #expect(Self.port(httpsDefault) == 443)
        }

        @Test("a leading-dot NO_PROXY entry becomes a glob and a bare host stays exact")
        func leadingDotEntriesBecomeGlobs() {
            // `NO_PROXY` suffix-matches on a leading dot by convention;
            // CFNetwork's exception list is glob-shaped, so the two spellings
            // are not the same string and `.acme.com` left alone would match
            // nothing.
            let dictionary = Self.dictionary([
                "HTTPS_PROXY": "http://proxy.acme:8080",
                "NO_PROXY": ".acme.com, internal.acme ,,.corp.example",
            ])
            let exceptions = Self.exceptions(dictionary)
            #expect(exceptions.contains("*.acme.com"))
            #expect(exceptions.contains("*.corp.example"))
            #expect(exceptions.contains("internal.acme"))
            #expect(!exceptions.contains(".acme.com"))
            // Empty entries between commas are dropped rather than becoming an
            // exception that matches nothing under a name of its own.
            #expect(!exceptions.contains(""))
        }

        @Test("loopback is in the exception list whatever the environment says")
        func loopbackIsAlwaysExcepted() {
            // A route's upstream is normally `https://api.anthropic.com`, but
            // every test in this file points one at a loopback fake — and a
            // developer with `HTTPS_PROXY` in their shell would otherwise send
            // those through a corporate proxy that cannot reach 127.0.0.1.
            for environment in [
                ["HTTPS_PROXY": "http://proxy.acme:8080"],
                ["HTTPS_PROXY": "http://proxy.acme:8080", "NO_PROXY": ".acme.com"],
            ] {
                let exceptions = Self.exceptions(Self.dictionary(environment))
                #expect(exceptions.contains("127.0.0.1"), "environment: \(environment)")
                #expect(exceptions.contains("localhost"), "environment: \(environment)")
                #expect(exceptions.contains("::1"), "environment: \(environment)")
            }
        }
    }
}

// MARK: - Recording tee

/// A `StreamTeeing` that records what the relay handed it.
///
/// The signal under test is `end(error:)`. It is what tells the tee's consumer
/// task the response is over, and a relay that never sends it leaves that task
/// awaiting forever — invisibly, since nothing else in the process is waiting
/// on it.
///
/// `@unchecked Sendable`: every field is guarded by the lock.
final class RecordingTee: StreamTeeing, @unchecked Sendable {
    private let lock = NSLock()
    private var begins = 0
    private var chunks = 0
    /// One entry per `end`, holding the description of the error it carried or
    /// nil for a clean end.
    private var ends: [String?] = []

    var beginCount: Int { lock.withLock { begins } }
    var chunkCount: Int { lock.withLock { chunks } }
    var endCount: Int { lock.withLock { ends.count } }
    var lastEndError: String? { lock.withLock { ends.last ?? nil } }

    func begin(
        route: ModelProxyRoute,
        method: String,
        pathSuffix: String,
        requestHeaders: [(String, String)],
        requestBody: [UInt8],
        responseStatus: Int,
        responseHeaders: [(String, String)]
    ) async -> (any TeeSessionHandle)? {
        lock.withLock { begins += 1 }
        return RecordingTeeHandle(tee: self)
    }

    fileprivate func recordChunk() { lock.withLock { chunks += 1 } }
    fileprivate func recordEnd(_ error: Error?) {
        lock.withLock { ends.append(error.map { "\($0)" }) }
    }
}

private final class RecordingTeeHandle: TeeSessionHandle, @unchecked Sendable {
    private let tee: RecordingTee

    init(tee: RecordingTee) { self.tee = tee }

    func feed(_ chunk: [UInt8]) { tee.recordChunk() }
    func end(error: Error?) { tee.recordEnd(error) }
}

// MARK: - Waiting

/// What a bounded wait reports when it runs out.
///
/// An `Error` rather than a message on the `#expect`, and carrying the *last
/// sampled* value rather than one re-read after the deadline: only
/// `Issue.record(_: some Error)` reaches the primary failure line CI summaries
/// keep, and a value re-read afterwards describes a moment the wait never saw
/// (`Tests/CLAUDE.md`, "Timeout errors must report observed state").
struct ProxyWaitTimeout: LocalizedError {
    let what: String
    let observed: String
    let seconds: Double

    var errorDescription: String? {
        "\(what) — last observed \(observed) after polling up to \(seconds) seconds"
    }
}

/// Carries a poll's last sample out of the closure that took it, so a timeout
/// reports the value the wait actually saw rather than one re-read after the
/// budget expired (`Tests/CLAUDE.md`, "Timeout errors must report observed
/// state").
private final class ProxyObservationBox<Observed: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Observed

    init(_ initial: Observed) { stored = initial }

    var value: Observed { lock.withLock { stored } }
    func put(_ observed: Observed) { lock.withLock { stored = observed } }
}

/// Samples until `isSatisfied` holds, and records what it last saw if it never
/// does.
///
/// A poll rather than a signal because the things waited on here — a counter
/// decremented on an event loop, a tee fed from a task of its own — have no
/// completion the test can await.
///
/// The loop itself is `pollUntilTrue`, the repo's one bounded poll, rather than
/// a seventh hand-rolled one: this used to sleep through `try? await
/// Task.sleep`, which cannot tell expiry from cancellation and throws
/// *instantly* once the task is cancelled — turning a 20 ms poll into a busy
/// spin over its whole remaining budget on a cooperative thread every other
/// test in the pass is queued behind. What stays here is the diagnostic, which
/// is the only part that was ever this helper's own.
@discardableResult
func waitUntil<Observed: Sendable>(
    _ what: String,
    seconds: Double = 15,
    sample: @escaping @Sendable () -> Observed,
    isSatisfied: @escaping @Sendable (Observed) -> Bool
) async -> Bool {
    let last = ProxyObservationBox(sample())
    let outcome = await pollUntilTrue(
        timeout: .seconds(seconds), pollInterval: .milliseconds(20)
    ) {
        let observed = sample()
        last.put(observed)
        return isSatisfied(observed)
    }
    switch outcome {
    case .satisfied:
        return true
    case .cancelled:
        // Reported nowhere, per `pollUntilTrue`'s contract: attribution belongs
        // to whatever cancelled this test, not to a wait that may have been
        // about to succeed. The `false` is for the two callers that gate a
        // message on it, and a cancelled test is already ending.
        return false
    case .timedOut:
        Issue.record(ProxyWaitTimeout(what: what, observed: "\(last.value)", seconds: seconds))
        return false
    }
}

// MARK: - Harness

/// One proxy in front of one fake upstream, with a route between them.
struct ProxyHarness: Sendable {
    let port: Int
    let token: String
    let terminalID: UUID
    let upstream: FakeUpstream
    let routesDir: URL
    let streamsDir: URL
    /// The running server, so a test can read `streamsInFlight` — the counter
    /// Task A5's retire handshake drains on, and the one that inflates forever
    /// if a response ends by a path that never relays an end.
    let server: ProxyServer
    /// The table the server routes against, so a test can add a second route
    /// (an unreachable upstream, say) after the server is already bound.
    let routes: RouteTable
    /// A session of its own per harness, so a connection left open by one test
    /// cannot be reused by another against a port the kernel has since given
    /// to somebody else.
    let session: URLSession
    /// The scratch directory standing in for a TBD home, canonical, which is
    /// the form the status endpoint reports and a daemon compares against.
    let home: String

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
///
/// Every phase runs under a deadline. Two servers, a `URLSession` upstream leg
/// and a client all have their own ways of waiting forever, and a wedge in any
/// of them inside a 4,800-test pass is invisible: the runner's stdout is block
/// buffered, so the log names whichever test flushed last rather than the one
/// that stopped. A phase that overruns names itself and fails the test instead.
///
/// `body` runs inside a single "request" phase (60s), sized for an ordinary
/// request/response round trip against `Tests/CLAUDE.md`'s fast-pass-2 numbers
/// (p90 51.4s / max 55.3s reported per-test on a green run). A test whose
/// follow-on work needs its own, differently-sized budget — a bind that races
/// a squatter, a multi-second drain — should not stack that work inside
/// `body`: `withPhaseDeadline` races its operation against a plain
/// `Task.sleep` timer that starts ticking the moment "request" begins, so
/// nested phases *share* that 60s wall-clock window rather than getting one
/// each, and a slow nested phase can trip the generic
/// `ProxyPhaseTimeout("request", 60)` instead of its own named diagnostic
/// (this is exactly what happened to the successor-bind wait in
/// `retireAnswersBeforeDrainAndSuccessorCanBind`). Pass `afterRequest`
/// instead: it runs after `body` returns, with the harness still live and
/// before teardown, but outside "request"'s deadline — so it can size its own
/// phases as siblings, not children, of "request". State `body` opens that
/// `afterRequest` still needs (a still-streaming response body, say) crosses
/// between them the way every other cross-closure value in this file does —
/// a small `@unchecked Sendable` box captured by both — rather than through a
/// return value, so this signature does not have to grow a generic for it.
func withProxy(
    prefix: String,
    script: @escaping FakeUpstream.Handler,
    streamingEnabled: Bool = false,
    tee: (any StreamTeeing)? = nil,
    /// Builds the tee once the scratch `streams/` directory exists, which is
    /// the only way a test can hand the server a real `StreamTee`: the
    /// directory is minted in here, after the caller has been called.
    teeFactory: (@Sendable (URL) -> any StreamTeeing)? = nil,
    onRetire: (@Sendable () -> Void)? = nil,
    body: @escaping @Sendable (ProxyHarness) async throws -> Void,
    afterRequest: (@Sendable (ProxyHarness) async throws -> Void)? = nil
) async throws {
    let upstream = FakeUpstream(script: script)
    let root = proxyScratchRoot(prefix: prefix)
    let serverBox = ProxyServerBox()
    let sessionBox = ClientSessionBox()

    func teardown() async {
        // Both of these can block: `ProxyServer.stop()` shuts an event-loop
        // group down, and `FakeUpstream.stop()` does it synchronously. They run
        // under their own deadlines so a teardown that wedges reports rather
        // than eating the job's whole budget.
        if let server = serverBox.take() {
            _ = try? await withPhaseDeadline("proxy stop", seconds: 20) { await server.stop() }
        }
        _ = try? await withPhaseDeadline("upstream stop", seconds: 20) {
            await offCooperativePool { upstream.stop() }
        }
        sessionBox.take()?.invalidateAndCancel()
        try? FileManager.default.removeItem(at: root)
    }

    do {
        let upstreamPort = try upstream.start()

        let routesDir = root.appendingPathComponent("proxy/routes")
        let streamsDir = root.appendingPathComponent("streams")
        // Canonical, as `run()` reports it: the scratch root lives under a
        // `/tmp` or `/var` that is itself a symlink on macOS, so the raw path
        // and the resolved one differ here in practice.
        let canonicalHome = ModelProxyStatus.canonicalHome(root.path)
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

        // The identity half of a status answer, as `run()` composes it. The
        // two counters are deliberately wrong here — the control endpoint
        // replaces them with live state, and a test that reads them back is
        // reading the server's own counter and route table rather than this.
        // The same box `run()` uses, for the same reason: `--port 0` means the
        // number worth reporting does not exist until the bind returns.
        let portBox = ProxyPortBox(requested: 0)
        let server = ProxyServer(
            port: 0, routes: table, tee: teeFactory?(streamsDir) ?? tee,
            status: {
                ModelProxyStatus(
                    version: "test", pid: getpid(), processStartTime: Date(),
                    port: portBox.value, streamsInFlight: -1, routeCount: -1,
                    home: canonicalHome)
            },
            onRetire: onRetire ?? {},
            // An explicit environment, so the forwarder's proxy resolution
            // cannot pick up an `HTTPS_PROXY` from the developer's shell and
            // send a loopback request through a corporate proxy. The short
            // timeouts are the test's own: production waits 600 seconds for a
            // silent stream, and a test that inherited that would hang rather
            // than fail.
            forwarder: UpstreamForwarder(
                session: UpstreamForwarder.makeSession(
                    environment: [:], requestTimeout: 15, resourceTimeout: 30)))
        serverBox.put(server)
        let port = try await withPhaseDeadline("proxy bind", seconds: 20) {
            try await server.start()
        }
        portBox.value = port

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        sessionBox.put(session)

        let harness = ProxyHarness(
            port: port, token: token, terminalID: terminalID, upstream: upstream,
            routesDir: routesDir, streamsDir: streamsDir, server: server, routes: table,
            session: session, home: canonicalHome)
        try await withPhaseDeadline("request", seconds: 60) { try await body(harness) }
        if let afterRequest {
            try await afterRequest(harness)
        }
        await teardown()
    } catch {
        await teardown()
        throw error
    }
}

/// A scratch directory under the run root `scripts/test.sh` reclaims, so a
/// killed test process leaks nothing. The `URL`-returning sibling of
/// `TestSupport.fencedScratchRoot` — every caller here composes further path
/// components onto it — agreeing with it on the fenced root and differing only
/// in the unfenced fallback, which is `FileManager`'s temporary directory
/// rather than `/tmp`.
func proxyScratchRoot(prefix: String) -> URL {
    let fenced = ProcessInfo.processInfo.environment["TBD_TEST_SCRATCH_ROOT"] ?? ""
    let root = fenced.isEmpty ? FileManager.default.temporaryDirectory.path : fenced
    return URL(fileURLWithPath: "\(root)/\(prefix)-\(UUID().uuidString.prefix(8).lowercased())")
}

// MARK: - Deadlines

struct ProxyPhaseTimeout: LocalizedError {
    let phase: String
    let seconds: Double

    var errorDescription: String? {
        "the proxy test's \"\(phase)\" phase did not finish within \(Int(seconds))s"
    }
}

/// Returns whichever of `operation` and the deadline finishes first, **without
/// waiting for the loser**.
///
/// Deliberately not `withThrowingTaskGroup`: a group waits for every child
/// before it returns, so racing a sleeper against a wedged operation there
/// still hangs. This resumes on the first result and abandons the other task.
func withPhaseDeadline<Value: Sendable>(
    _ phase: String,
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let outcome = FirstOutcomeBox<Result<Value, any Error>>()
    let work = Task {
        do { outcome.finish(.success(try await operation())) } catch { outcome.finish(.failure(error)) }
    }
    let timer = Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        outcome.finish(.failure(ProxyPhaseTimeout(phase: phase, seconds: seconds)))
    }
    let result = await outcome.value
    work.cancel()
    timer.cancel()
    return try result.get()
}

/// Runs a blocking call on a `DispatchQueue` rather than on the cooperative
/// pool, which has one thread per core and is what every other test in the
/// process is also running on.
func offCooperativePool(_ work: @escaping @Sendable () -> Void) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            work()
            continuation.resume()
        }
    }
}

/// A one-shot value: the first `finish` wins and wakes whoever is awaiting.
final class FirstOutcomeBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    private var waiter: CheckedContinuation<Value, Never>?

    func finish(_ value: Value) {
        let waiter: CheckedContinuation<Value, Never>? = lock.withLock {
            guard stored == nil else { return nil }
            stored = value
            let pending = self.waiter
            self.waiter = nil
            return pending
        }
        waiter?.resume(returning: value)
    }

    var value: Value {
        get async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
                let ready: Value? = lock.withLock {
                    if let stored { return stored }
                    waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }
}

/// Holds the server between `withProxy`'s setup and its teardown. A box rather
/// than a `var`, because the teardown closure has to see it and a captured
/// `var` cannot cross into a `@Sendable` context.
final class ProxyServerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ProxyServer?

    func put(_ server: ProxyServer) { lock.withLock { stored = server } }
    func take() -> ProxyServer? {
        lock.withLock {
            defer { stored = nil }
            return stored
        }
    }
}

final class ClientSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLSession?

    func put(_ session: URLSession) { lock.withLock { stored = session } }
    func take() -> URLSession? {
        lock.withLock {
            defer { stored = nil }
            return stored
        }
    }
}

// MARK: - Raw HTTP

enum RawHTTPError: LocalizedError {
    case socketFailed(Int32)
    case connectFailed(Int32)
    case writeFailed(Int32)
    case bindFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .socketFailed(let code): return "socket() failed with errno \(code)"
        case .connectFailed(let code): return "connect() failed with errno \(code)"
        case .writeFailed(let code): return "write() failed with errno \(code)"
        case .bindFailed(let code): return "bind() failed with errno \(code)"
        }
    }
}

/// A loopback address for `port`, filled in the way the socket calls want it.
private func loopbackAddress(port: Int) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return address
}

/// Connects to loopback and sets a receive timeout, so a proxy that answered
/// nothing fails the test instead of wedging the run. The caller owns the
/// descriptor.
private func connectLoopback(port: Int, timeoutSeconds: Int) throws -> Int32 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw RawHTTPError.socketFailed(errno) }

    var address = loopbackAddress(port: port)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
            connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        let code = errno
        close(descriptor)
        throw RawHTTPError.connectFailed(code)
    }

    var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    setsockopt(
        descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    return descriptor
}

private func sendAll(_ descriptor: Int32, _ request: String) throws {
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
}

/// A loopback port nothing is listening on: bound to learn its number, then
/// released without ever listening.
///
/// The kernel does not hand an ephemeral port straight back out, so a connect
/// to it is refused immediately — which is the upstream failure the 502 path
/// exists for, produced without waiting on a timeout.
func unusedLoopbackPort() throws -> Int {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw RawHTTPError.socketFailed(errno) }
    defer { close(descriptor) }

    var address = loopbackAddress(port: 0)
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
            Darwin.bind(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { throw RawHTTPError.bindFailed(errno) }

    var assigned = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &assigned) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
            getsockname(descriptor, generic, &length)
        }
    }
    guard named == 0 else { throw RawHTTPError.bindFailed(errno) }
    return Int(UInt16(bigEndian: assigned.sin_port))
}

/// Sends `request`, reads until `marker` appears in the response, then closes
/// the socket mid-response and returns what had arrived.
///
/// This is the wire shape of a user pressing Esc: a client that hangs up while
/// the proxy is still relaying. A cancelled `URLSession` task would do it too,
/// but not at a moment the test chooses, and every assertion that follows is
/// about what the proxy does *after* the FIN.
func rawHTTPCutAfterMarker(
    port: Int, request: String, marker: String, timeoutSeconds: Int = 15
) throws -> String {
    let descriptor = try connectLoopback(port: port, timeoutSeconds: timeoutSeconds)
    defer { close(descriptor) }
    try sendAll(descriptor, request)

    var response: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let read = chunk.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return Darwin.read(descriptor, base, buffer.count)
        }
        guard read > 0 else { break }
        response.append(contentsOf: chunk[0..<read])
        if String(decoding: response, as: UTF8.self).contains(marker) { break }
    }
    return String(decoding: response, as: UTF8.self)
}

/// Sends a request exactly as written and reads until the server closes.
///
/// Exists because `URLSession` normalizes a path before it puts it on the
/// wire: `/r/../../v1/messages` never leaves the process as itself, and the
/// traversal the proxy has to refuse is the one a hand-written client — or a
/// hostile local process — can send.
func rawHTTPExchange(port: Int, request: String, timeoutSeconds: Int = 15) throws -> String {
    let descriptor = try connectLoopback(port: port, timeoutSeconds: timeoutSeconds)
    defer { close(descriptor) }
    try sendAll(descriptor, request)

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
