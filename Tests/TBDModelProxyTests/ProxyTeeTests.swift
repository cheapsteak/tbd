import Foundation
import NIOHTTP1
import Testing

@testable import TBDModelProxy
@testable import TBDShared

extension ModelProxySuites {
    /// What the tee promises the terminal's stream file.
    ///
    /// Every test here runs a real `StreamTee` behind a real `ProxyServer` in
    /// front of a `FakeUpstream`, and asserts on the *file*: the tee's whole
    /// purpose is that a reader tailing it sees assistant text before Claude Code
    /// has written a transcript line, so what the file holds and when it holds it
    /// is the contract. Nothing is asserted from the tee's own counters.
    ///
    /// Two properties the design (`docs/specs/2026-09-05-transcript-streaming-model-proxy-design.md`,
    /// "The tee") makes load-bearing and these tests pin: a response the tee must
    /// not read — a subagent's, a toolless one, one on a route with streaming off
    /// — leaves no file at all, and a tee that cannot write leaves the client's
    /// bytes exactly as they were.
    @Suite("Proxy tee", .serialized)
    struct ProxyTeeTests {

        /// A parent conversation's request body: `tools` non-empty, which is one
        /// of the two conditions that separate it from a subagent or the title
        /// request.
        static let parentBody = #"{"tools":[{"name":"Bash"}],"messages":[]}"#

        // MARK: The happy path

        @Test("a conversation's text deltas reach the terminal's stream file in order")
        func teesTextDeltasOfConversationStream() async throws {
            try await withProxy(
                prefix: "pxtee",
                script: { _, _ in
                    sseTextAnswer(messageID: "msg_A", deltas: ["The", " sea"], delayMs: 100)
                },
                streamingEnabled: true,
                teeFactory: { StreamTee(streamsDir: $0) }
            ) { harness in
                let (data, response) = try await harness.session.data(
                    for: parentRequest(harness, body: Self.parentBody))
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
                #expect(String(decoding: data, as: UTF8.self).contains("message_stop"))

                let file = harness.streamFile
                // The tee runs on a task of its own, so the last line can land
                // after the client's last byte. That is the design, not a race:
                // the forwarder never waits for the tee.
                await waitUntil(
                    "the tee wrote its stop line", sample: { summarizeStream(file) },
                    isSatisfied: { $0.last == "stop:msg_A" })

                #expect(
                    summarizeStream(file) == [
                        "start:msg_A",
                        "block:msg_A:0",
                        "text:msg_A:0:The",
                        "text:msg_A:0: sea",
                        "stop:msg_A",
                    ])
            }
        }

        @Test("a text line is readable before the client has read the end of the stream")
        func firstTextLineLandsBeforeStreamEnds() async throws {
            // The whole reason the feature exists: a reader tailing the file sees
            // text while the turn is still generating. A tee that buffered to the
            // end of the response would still produce a correct file and would be
            // worth nothing.
            try await withProxy(
                prefix: "pxtlive",
                script: { _, _ in
                    sseTextAnswer(messageID: "msg_L", deltas: ["one", "two"], delayMs: 400)
                },
                streamingEnabled: true,
                teeFactory: { StreamTee(streamsDir: $0) }
            ) { harness in
                let sawStop = ProxyFlagBox()
                let file = harness.streamFile

                let reader = Task {
                    let (bytes, _) = try await harness.session.bytes(
                        for: parentRequest(harness, body: Self.parentBody))
                    for try await line in bytes.lines where line.contains("message_stop") {
                        sawStop.set()
                    }
                }

                await waitUntil(
                    "a text line landed", seconds: 20, sample: { summarizeStream(file) },
                    isSatisfied: { lines in lines.contains { $0.hasPrefix("text:") } })
                #expect(
                    !sawStop.value,
                    "the text was only readable once the client had already seen the whole stream")

                _ = try? await reader.value
                await waitUntil(
                    "the tee wrote its stop line", sample: { summarizeStream(file) },
                    isSatisfied: { $0.last == "stop:msg_L" })
            }
        }

        // MARK: What is not teed

        @Test("a subagent's request writes no stream file")
        func skipsSubagentRequests() async throws {
            // `x-claude-code-agent-id` is a subagent's turn. Its text belongs to no
            // pane the user is watching, and writing it would replace the parent
            // conversation's text in the file with a subagent's.
            let spy = SpyTee()
            try await withProxy(
                prefix: "pxsub",
                script: { _, _ in sseTextAnswer(messageID: "msg_S", deltas: ["hi"]) },
                streamingEnabled: true,
                teeFactory: { spy.attach(StreamTee(streamsDir: $0)); return spy }
            ) { harness in
                var request = parentRequest(harness, body: Self.parentBody)
                request.setValue("abc", forHTTPHeaderField: "x-claude-code-agent-id")
                let (_, response) = try await harness.session.data(for: request)
                #expect((response as? HTTPURLResponse)?.statusCode == 200)

                // Asserted on the decision rather than on the file's absence alone:
                // a file that has not appeared *yet* and one that never will look
                // identical, and only the first is a bug.
                await waitUntil(
                    "the tee was asked to decide", sample: { spy.beginCount },
                    isSatisfied: { $0 == 1 })
                #expect(spy.openedCount == 0)
                #expect(!FileManager.default.fileExists(atPath: harness.streamFile.path))
            }
        }

        @Test("a request with no tools writes no stream file")
        func skipsNoToolsRequests() async throws {
            // An empty `tools` array is Claude Code's title request and its other
            // side errands, not the conversation.
            let spy = SpyTee()
            try await withProxy(
                prefix: "pxnotools",
                script: { _, _ in sseTextAnswer(messageID: "msg_T", deltas: ["hi"]) },
                streamingEnabled: true,
                teeFactory: { spy.attach(StreamTee(streamsDir: $0)); return spy }
            ) { harness in
                let (_, response) = try await harness.session.data(
                    for: parentRequest(harness, body: #"{"tools":[],"messages":[]}"#))
                #expect((response as? HTTPURLResponse)?.statusCode == 200)

                await waitUntil(
                    "the tee was asked to decide", sample: { spy.beginCount },
                    isSatisfied: { $0 == 1 })
                #expect(spy.openedCount == 0)
                #expect(!FileManager.default.fileExists(atPath: harness.streamFile.path))
            }
        }

        @Test("a route with streaming off writes no stream file and still forwards")
        func skipsWhenRouteStreamingOff() async throws {
            // The flag lives in the route, so the daemon decides per terminal and
            // the proxy never has to ask anything else. Off must cost the session
            // nothing at all.
            let spy = SpyTee()
            let script = sseTextAnswer(messageID: "msg_O", deltas: ["off"])
            let expected = script.events.flatMap { $0.bytes }

            try await withProxy(
                prefix: "pxoff",
                script: { _, _ in script },
                streamingEnabled: false,
                teeFactory: { spy.attach(StreamTee(streamsDir: $0)); return spy }
            ) { harness in
                let (data, response) = try await harness.session.data(
                    for: parentRequest(harness, body: Self.parentBody))
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
                #expect(Array(data) == expected, "the forward changed when the tee was off")

                await waitUntil(
                    "the tee was asked to decide", sample: { spy.beginCount },
                    isSatisfied: { $0 == 1 })
                #expect(spy.openedCount == 0)
                #expect(!FileManager.default.fileExists(atPath: harness.streamFile.path))
            }
        }

        // MARK: Endings

        @Test("a stream that ends without message_stop is recorded as aborted")
        func abortedWhenUpstreamClosesEarly() async throws {
            // Measured on CI (Task A4): an upstream that truncates a chunked body
            // reaches `URLSession` as a *clean* completion, so "did an error
            // arrive?" cannot tell a finished message from a dead one. The rule is
            // therefore "no stop line was written", which is true in both shapes.
            let events = [
                sseEvent("message_start", messageStartPayload(id: "msg_B")),
                sseEvent("content_block_start", textBlockStartPayload(index: 0)),
                sseEvent("content_block_delta", textDeltaPayload(index: 0, text: "half")),
            ]

            try await withProxy(
                prefix: "pxabort",
                script: { _, _ in
                    FakeUpstream.Script(
                        events: events.map { (delayMs: 50, bytes: $0) }, closeWithoutStop: true)
                },
                streamingEnabled: true,
                teeFactory: { StreamTee(streamsDir: $0) }
            ) { harness in
                // The client's own outcome is not the subject here — a cut stream
                // may surface as a completion or as an error depending on framing.
                _ = try? await harness.session.data(for: parentRequest(harness, body: Self.parentBody))

                let file = harness.streamFile
                await waitUntil(
                    "the tee wrote its terminal line", sample: { summarizeStream(file) },
                    isSatisfied: { $0.last?.hasPrefix("aborted:msg_B") == true })

                let lines = summarizeStream(file)
                #expect(lines.first == "start:msg_B")
                #expect(lines.contains("text:msg_B:0:half"))
                let sawStop = lines.contains(where: { $0.hasPrefix("stop:") })
                #expect(!sawStop, "a cut stream was recorded as a finished one")
            }
        }

        // MARK: Concurrency and retention

        @Test("a second stream on one route appends, and the next one alone truncates")
        func truncatesOnlyWhenNothingInFlight() async throws {
            // Two parent turns can run on one terminal at once. Truncating on the
            // second one's `message_start` would delete the first one's text
            // mid-turn, so truncation waits until nothing is in flight — and the
            // file then holds at most the messages running plus the last completed
            // one (spec, "Retention").
            let teeBox = StreamTeeBox()
            try await withProxy(
                prefix: "pxtwo",
                script: { _, body in
                    let text = String(decoding: body, as: UTF8.self)
                    if text.contains(#""probe":"A""#) {
                        return sseTextAnswer(messageID: "msg_A", deltas: ["a1", "a2"], delayMs: 500)
                    }
                    if text.contains(#""probe":"B""#) {
                        return sseTextAnswer(messageID: "msg_B", deltas: ["b1", "b2"], delayMs: 500)
                    }
                    return sseTextAnswer(messageID: "msg_C", deltas: ["c1"], delayMs: 20)
                },
                streamingEnabled: true,
                teeFactory: { streamsDir in
                    let tee = StreamTee(streamsDir: streamsDir)
                    teeBox.put(tee)
                    return tee
                }
            ) { harness in
                let tee = try #require(teeBox.value)
                let file = harness.streamFile

                async let first = harness.session.data(
                    for: parentRequest(harness, body: #"{"tools":[{"name":"Bash"}],"probe":"A"}"#))
                async let second = harness.session.data(
                    for: parentRequest(harness, body: #"{"tools":[{"name":"Bash"}],"probe":"B"}"#))
                _ = try await first
                _ = try await second

                await waitUntil(
                    "both messages stopped", seconds: 20, sample: { summarizeStream(file) },
                    isSatisfied: { lines in
                        lines.contains("stop:msg_A") && lines.contains("stop:msg_B")
                    })

                let both = summarizeStream(file)
                #expect(both.contains("start:msg_A"))
                #expect(both.contains("start:msg_B"))
                // Interleaving, stated as the property that matters: neither
                // message's lines form an unbroken run, so neither turn waited for
                // the other and neither clobbered it.
                let firstB = try #require(both.firstIndex(where: { $0.contains("msg_B") }))
                let lastA = try #require(both.lastIndex(where: { $0.contains("msg_A") }))
                #expect(firstB < lastA, "the two turns did not interleave: \(both)")

                // The truncation decision is made against this count, so the third
                // request must not start until both have released their claim.
                var settled = false
                for _ in 0..<300 where !settled {
                    settled = await tee.inFlightCount(terminalID: harness.terminalID) == 0
                    if !settled { try? await Task.sleep(nanoseconds: 20_000_000) }
                }
                #expect(settled, "the tee never released the two finished messages")

                _ = try await harness.session.data(
                    for: parentRequest(harness, body: #"{"tools":[{"name":"Bash"}],"probe":"C"}"#))
                await waitUntil(
                    "the third message stopped", sample: { summarizeStream(file) },
                    isSatisfied: { $0.last == "stop:msg_C" })

                let alone = summarizeStream(file)
                #expect(alone == ["start:msg_C", "block:msg_C:0", "text:msg_C:0:c1", "stop:msg_C"])
            }
        }

        @Test("thinking and tool-input deltas are not written as text")
        func ignoresThinkingAndToolDeltas() async throws {
            // Only assistant text belongs in a stream file: thinking is the
            // model's own, and a tool call's arguments are a partial JSON document
            // that would render as noise in a pane.
            let events = [
                sseEvent("message_start", messageStartPayload(id: "msg_D")),
                sseEvent(
                    "content_block_start",
                    #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
                sseEvent(
                    "content_block_delta",
                    #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"pondering"}}"#),
                sseEvent("content_block_start", textBlockStartPayload(index: 1)),
                sseEvent("content_block_delta", textDeltaPayload(index: 1, text: "answer")),
                sseEvent(
                    "content_block_start",
                    #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"tu_1","name":"Bash","input":{}}}"#),
                sseEvent(
                    "content_block_delta",
                    #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"cmd\":"}}"#),
                sseEvent("message_stop", #"{"type":"message_stop"}"#),
            ]

            try await withProxy(
                prefix: "pxkinds",
                script: { _, _ in FakeUpstream.Script(events: events.map { (delayMs: 20, bytes: $0) }) },
                streamingEnabled: true,
                teeFactory: { StreamTee(streamsDir: $0) }
            ) { harness in
                let (_, response) = try await harness.session.data(
                    for: parentRequest(harness, body: Self.parentBody))
                #expect((response as? HTTPURLResponse)?.statusCode == 200)

                let file = harness.streamFile
                await waitUntil(
                    "the tee wrote its stop line", sample: { summarizeStream(file) },
                    isSatisfied: { $0.last == "stop:msg_D" })

                #expect(
                    summarizeStream(file) == [
                        "start:msg_D",
                        "block:msg_D:1",
                        "text:msg_D:1:answer",
                        "stop:msg_D",
                    ])
            }
        }

        // MARK: Failure

        @Test("a tee that cannot write leaves the client's bytes untouched")
        func teeFailureLeavesForwardingIntact() async throws {
            // The forwarder never awaits the tee, so a tee that cannot open its
            // file must cost the turn nothing — not a byte, not a status, not a
            // delay. The streams directory here has a *regular file* as its
            // parent, so both the create and the open fail.
            let script = sseTextAnswer(messageID: "msg_F", deltas: ["intact"], delayMs: 20)
            let expected = script.events.flatMap { $0.bytes }
            let blockedBox = ProxyURLBox()

            try await withProxy(
                prefix: "pxfail",
                script: { _, _ in script },
                streamingEnabled: true,
                teeFactory: { streamsDir in
                    let blocker = streamsDir.deletingLastPathComponent()
                        .appendingPathComponent("blocker")
                    try? Data("not a directory".utf8).write(to: blocker)
                    let blocked = blocker.appendingPathComponent("streams")
                    blockedBox.put(blocked)
                    return StreamTee(streamsDir: blocked)
                }
            ) { harness in
                let (data, response) = try await harness.session.data(
                    for: parentRequest(harness, body: Self.parentBody))
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
                #expect(Array(data) == expected, "a failing tee changed the forwarded bytes")

                // Nothing was written anywhere: not under the unusable directory,
                // and not into the real one either.
                let blocked = try #require(blockedBox.value)
                #expect(
                    !FileManager.default.fileExists(
                        atPath: blocked.appendingPathComponent(
                            TBDConstants.streamFileName(terminalID: harness.terminalID)
                        ).path))
                #expect(!FileManager.default.fileExists(atPath: harness.streamFile.path))
            }
        }

        @Test("a write that fails mid-message gives the terminal's in-flight slot back")
        func failedWriteReleasesTheInFlightCount() async throws {
            // The slot is what decides whether the *next* message truncates the
            // file. A give-up that kept it would leave every later turn on this
            // terminal appending, and the file's only bound — truncation when
            // nothing is in flight (spec, "Retention") — would be gone for the
            // life of the proxy. One ENOSPC on a `start` line is enough.
            //
            // Driven through the tee directly: a filesystem that accepts an
            // `open` and then refuses a `write` is not a state a loopback test
            // can produce, so the write itself is the injected seam.
            let root = proxyScratchRoot(prefix: "pxwfail")
            defer { try? FileManager.default.removeItem(at: root) }
            let streamsDir = root.appendingPathComponent("streams")

            // `start` and the text block's `block` line land; the first delta
            // fails, which is a failure *after* the message was counted.
            let writes = FailingWriter(succeedingWrites: 2)
            let tee = StreamTee(
                streamsDir: streamsDir,
                writeBytes: { descriptor, bytes in writes.write(descriptor, bytes) })

            let terminalID = UUID()
            let route = ModelProxyRoute(
                token: ModelProxyRoute.mintToken(), terminalID: terminalID,
                upstream: "http://127.0.0.1:1", streamingEnabled: true)
            let session = try #require(
                await tee.beginSession(
                    route: route, method: "POST", pathSuffix: "/v1/messages",
                    requestHeaders: [], requestBody: Array(Self.parentBody.utf8),
                    responseStatus: 200,
                    responseHeaders: [("content-type", "text/event-stream")]))

            session.feed(sseEvent("message_start", messageStartPayload(id: "msg_W")))
            session.feed(sseEvent("content_block_start", textBlockStartPayload(index: 0)))
            session.feed(sseEvent("content_block_delta", textDeltaPayload(index: 0, text: "boom")))

            var released = false
            for _ in 0..<250 where !released {
                released = await tee.inFlightCount(terminalID: terminalID) == 0
                if !released { try? await Task.sleep(nanoseconds: 20_000_000) }
            }
            #expect(released, "a failed write kept the terminal's in-flight slot for good")
            #expect(writes.attempts >= 3, "the injected writer was never asked to fail")

            // And the end of the stream does not double-release or resurrect it.
            session.end(error: nil)
            var settled = false
            for _ in 0..<50 where !settled {
                settled = await tee.inFlightCount(terminalID: terminalID) == 0
                if !settled { try? await Task.sleep(nanoseconds: 20_000_000) }
            }
            #expect(settled)
        }

        // MARK: The decision, directly

        @Test("the tee decision refuses everything that is not a parent conversation stream")
        func teeDecisionRefusesEverythingElse() async throws {
            // The end-to-end tests above cover the conditions one at a time
            // through a real server; this pins the whole predicate in one place,
            // including the two shapes a loopback test cannot produce — a non-200
            // stream and a JSON content type.
            let token = ModelProxyRoute.mintToken()
            let terminalID = UUID()

            func decide(
                streamingEnabled: Bool = true,
                method: String = "POST",
                path: String = "/v1/messages",
                requestHeaders: [(String, String)] = [],
                requestBody: [UInt8]? = nil,
                status: Int = 200,
                responseHeaders: [(String, String)]? = nil
            ) -> Bool {
                let route = ModelProxyRoute(
                    token: token, terminalID: terminalID, upstream: "http://127.0.0.1:1",
                    streamingEnabled: streamingEnabled)
                return StreamTee.shouldTee(
                    route: route, method: method, pathSuffix: path, requestHeaders: requestHeaders,
                    requestBody: requestBody ?? Array(Self.parentBody.utf8), responseStatus: status,
                    responseHeaders: responseHeaders
                        ?? [("content-type", "text/event-stream; charset=utf-8")])
            }

            #expect(decide())
            // A query string is not part of the path the rule matches on.
            #expect(decide(path: "/v1/messages?beta=true"))
            #expect(!decide(method: "GET"))
            #expect(!decide(path: "/v1/messages/count_tokens"))
            #expect(!decide(status: 429))
            #expect(!decide(responseHeaders: [("content-type", "application/json")]))
            #expect(!decide(requestHeaders: [("X-Claude-Code-Agent-Id", "abc")]))
            #expect(!decide(requestBody: Array(#"{"messages":[]}"#.utf8)))
            #expect(!decide(requestBody: Array("not json".utf8)))
            #expect(!decide(streamingEnabled: false))
        }
    }
}

// MARK: - Reading a stream file

extension ProxyHarness {
    /// The terminal's stream file, whether or not it exists.
    var streamFile: URL {
        streamsDir.appendingPathComponent(TBDConstants.streamFileName(terminalID: terminalID))
    }
}

/// Every decodable line of a stream file, rendered as one short string apiece.
///
/// A projection rather than the values themselves, because `start` carries a
/// timestamp the test does not control and comparing whole enum cases would
/// mean either freezing the clock through a seam the server does not expose or
/// asserting on everything except the field that moves. The projection keeps
/// every field that is a promise — type, message id, block index, text — and
/// drops the one that is not.
func summarizeStream(_ file: URL) -> [String] {
    guard let data = FileManager.default.contents(atPath: file.path) else { return [] }
    return String(decoding: data, as: UTF8.self)
        .split(separator: "\n", omittingEmptySubsequences: true)
        .compactMap { ModelProxyStreamLine.decode(line: String($0)) }
        .map { line in
            switch line {
            case .start(let message, _): return "start:\(message)"
            case .block(let message, let index): return "block:\(message):\(index)"
            case .text(let message, let index, let text): return "text:\(message):\(index):\(text)"
            case .stop(let message): return "stop:\(message)"
            case .aborted(let message, let reason): return "aborted:\(message):\(reason)"
            }
        }
}

// MARK: - Requests and events

/// A parent conversation's POST, as Claude Code sends it.
func parentRequest(_ harness: ProxyHarness, body: String) -> URLRequest {
    var request = URLRequest(url: harness.url("/v1/messages"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = Data(body.utf8)
    return request
}

/// One SSE frame, whole, in the wire shape the Messages API uses.
func sseEvent(_ name: String, _ payload: String) -> [UInt8] {
    Array("event: \(name)\ndata: \(payload)\n\n".utf8)
}

func messageStartPayload(id: String) -> String {
    #"{"type":"message_start","message":{"id":"\#(id)","type":"message","role":"assistant","model":"claude-stub","content":[],"stop_reason":null,"usage":{"input_tokens":1,"output_tokens":1}}}"#
}

func textBlockStartPayload(index: Int) -> String {
    #"{"type":"content_block_start","index":\#(index),"content_block":{"type":"text","text":""}}"#
}

func textDeltaPayload(index: Int, text: String) -> String {
    #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":"\#(text)"}}"#
}

// MARK: - Boxes

/// A one-way flag, so a task can report what it saw without the test awaiting
/// it.
final class ProxyFlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

/// Holds the tee `withProxy` built, so a test can ask it what it thinks is in
/// flight.
final class StreamTeeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: StreamTee?

    var value: StreamTee? { lock.withLock { stored } }
    func put(_ tee: StreamTee) { lock.withLock { stored = tee } }
}

final class ProxyURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?

    var value: URL? { lock.withLock { stored } }
    func put(_ url: URL) { lock.withLock { stored = url } }
}

/// A real `StreamTee` with a count of how often it was asked to decide and how
/// often it said yes.
///
/// The counts are what make "no file was written" an assertion rather than a
/// race: a file that has not appeared *yet* and a file that never will look
/// exactly alike from the outside, and only one of them is correct.
final class SpyTee: StreamTeeing, @unchecked Sendable {
    private let lock = NSLock()
    private var inner: (any StreamTeeing)?
    private var begins = 0
    private var opened = 0

    var beginCount: Int { lock.withLock { begins } }
    var openedCount: Int { lock.withLock { opened } }

    func attach(_ tee: any StreamTeeing) { lock.withLock { inner = tee } }

    func begin(
        route: ModelProxyRoute,
        method: String,
        pathSuffix: String,
        requestHeaders: [(String, String)],
        requestBody: [UInt8],
        responseStatus: Int,
        responseHeaders: [(String, String)]
    ) async -> (any TeeSessionHandle)? {
        let inner = lock.withLock { self.inner }
        let handle = await inner?.begin(
            route: route, method: method, pathSuffix: pathSuffix, requestHeaders: requestHeaders,
            requestBody: requestBody, responseStatus: responseStatus,
            responseHeaders: responseHeaders)
        lock.withLock {
            begins += 1
            if handle != nil { opened += 1 }
        }
        return handle
    }
}

/// A `writeBytes` seam that accepts a fixed number of lines and then fails
/// every one after, the way a filesystem that has just run out of space does.
final class FailingWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let succeedingWrites: Int
    private var calls = 0

    init(succeedingWrites: Int) { self.succeedingWrites = succeedingWrites }

    var attempts: Int { lock.withLock { calls } }

    func write(_ descriptor: Int32, _ bytes: [UInt8]) -> Bool {
        let ordinal = lock.withLock { () -> Int in
            calls += 1
            return calls
        }
        guard ordinal <= succeedingWrites else { return false }
        return StreamTee.writeAllBytes(descriptor, bytes)
    }
}
