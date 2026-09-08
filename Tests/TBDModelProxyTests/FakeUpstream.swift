import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// An in-process stand-in for the model API, bound to loopback on a
/// kernel-assigned port.
///
/// It exists so a proxy test can assert on both halves of a forward at once:
/// what the upstream *received* (`requests`, verbatim, in order) and what the
/// client got back from bytes this fake chose. Nothing about a turn is
/// inferred — the script says exactly which bytes leave, and when.
///
/// Two properties are load-bearing for the tests that come after this one:
///
/// - **Each event is written and flushed on its own**, after its own delay, so
///   a test can prove the proxy relays chunk by chunk rather than buffering a
///   stream to its end. `TCP_NODELAY` is set on accepted channels for the same
///   reason: Nagle would coalesce the small writes back together and the
///   measurement would be of the kernel, not the proxy.
/// - **Nothing here touches `~/tbd` or the network beyond `127.0.0.1`.**
///
/// `@unchecked Sendable` because `requests` is guarded by a lock rather than by
/// the type system; every other stored property is set once during `start()`.
final class FakeUpstream: @unchecked Sendable {
    /// One canned response.
    ///
    /// `events` are the SSE frames in wire order — `bytes` is the whole
    /// `event: …\ndata: …\n\n` frame, so a test can hand over a malformed or
    /// split frame as easily as a well-formed one. `delayMs` is the gap
    /// *before* that event, so delays accumulate down the script.
    struct Script: Sendable {
        var status: Int = 200
        var headers: [(String, String)] = [("content-type", "text/event-stream; charset=utf-8")]
        var events: [(delayMs: Int, bytes: [UInt8])]
        /// Close the connection after the last event without ending the
        /// response, which is how a truncated stream reaches a client: the
        /// chunked body never gets its terminating chunk.
        var closeWithoutStop: Bool = false
        /// The gap before the response *head*, which no other field can
        /// express: `delayMs` on the first event delays a byte of the body,
        /// and by then the head is already on the wire. A real turn spends
        /// this window queued at the model, and it is the window in which a
        /// request exists but has produced no evidence of itself.
        ///
        /// Last in the memberwise initializer on purpose, so every existing
        /// `Script(...)` call site keeps compiling unchanged.
        var headDelayMs: Int = 0
    }

    typealias Handler = @Sendable (HTTPRequestHead, [UInt8]) -> Script

    private let script: Handler
    private let group: MultiThreadedEventLoopGroup
    private let lock = NSLock()
    private var received: [(head: HTTPRequestHead, body: [UInt8])] = []
    private var channel: Channel?

    init(script: @escaping Handler) {
        self.script = script
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    /// Everything received, in order. Safe to read while the server runs.
    var requests: [(head: HTTPRequestHead, body: [UInt8])] {
        lock.withLock { received }
    }

    /// Binds loopback on a kernel-assigned port and returns it.
    @discardableResult
    func start() throws -> Int {
        let script = self.script
        let record: @Sendable (HTTPRequestHead, [UInt8]) -> Void = { [weak self] head, body in
            guard let self else { return }
            self.lock.withLock { self.received.append((head: head, body: body)) }
        }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 16)
            // See the note on per-event flushing above.
            .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(
                        ScriptedUpstreamHandler(script: script, record: record))
                }
            }

        let bound = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        channel = bound
        // Thrown rather than defaulted: port 0 is a legal thing to *ask* for
        // and means "the kernel picks one", so handing it back as the bound
        // port would send every later request to a port nothing listens on and
        // fail the test that used it instead of the bind that broke.
        guard let port = bound.localAddress?.port else {
            throw FakeUpstreamError.boundAddressUnreadable
        }
        return port
    }

    /// Closes the listener and shuts the event loop down. Safe to call twice,
    /// and safe to call after a `start()` that threw — which is why callers
    /// register their `defer { stop() }` *before* starting, so a failed bind
    /// cannot leak the event-loop group.
    func stop() {
        try? channel?.close().wait()
        channel = nil
        try? group.syncShutdownGracefully()
    }
}

enum FakeUpstreamError: LocalizedError {
    case boundAddressUnreadable

    var errorDescription: String? {
        switch self {
        case .boundAddressUnreadable:
            return "the fake upstream bound a channel whose local address has no port"
        }
    }
}

/// Wraps a `ChannelHandlerContext` for a `@Sendable` scheduled task. Safe
/// because `scheduleTask` runs its closure on the channel's own event loop —
/// the same reason `HTTPServer`'s `HTTPSendableContext` is safe.
private struct SendableUpstreamContext: @unchecked Sendable {
    let context: ChannelHandlerContext
}

private final class ScriptedUpstreamHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let script: FakeUpstream.Handler
    private let record: @Sendable (HTTPRequestHead, [UInt8]) -> Void
    private var head: HTTPRequestHead?
    private var body: [UInt8] = []

    init(script: @escaping FakeUpstream.Handler, record: @escaping @Sendable (HTTPRequestHead, [UInt8]) -> Void) {
        self.script = script
        self.record = record
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let requestHead):
            head = requestHead
            body = []

        case .body(let buffer):
            body.append(contentsOf: buffer.readableBytesView)

        case .end:
            guard let requestHead = head else { return }
            let requestBody = body
            head = nil
            body = []
            record(requestHead, requestBody)
            respond(context: context, script: script(requestHead, requestBody))
        }
    }

    private func respond(context: ChannelHandlerContext, script: FakeUpstream.Script) {
        guard script.headDelayMs > 0 else {
            writeHead(context: context, script: script)
            return
        }
        let boxed = SendableUpstreamContext(context: context)
        context.eventLoop.scheduleTask(in: .milliseconds(Int64(script.headDelayMs))) { [self] in
            let context = boxed.context
            guard context.channel.isActive else { return }
            writeHead(context: context, script: script)
        }
    }

    private func writeHead(context: ChannelHandlerContext, script: FakeUpstream.Script) {
        var headers = HTTPHeaders()
        for (name, value) in script.headers {
            headers.add(name: name, value: value)
        }
        // No content-length is set, so NIO frames the body as
        // `transfer-encoding: chunked` — what a real event stream is.
        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: script.status),
            headers: headers)
        context.writeAndFlush(wrapOutboundOut(.head(responseHead)), promise: nil)
        writeEvent(at: 0, context: context, script: script)
    }

    private func writeEvent(at index: Int, context: ChannelHandlerContext, script: FakeUpstream.Script) {
        guard index < script.events.count else {
            if script.closeWithoutStop {
                context.close(promise: nil)
            } else {
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            }
            return
        }

        let event = script.events[index]
        let boxed = SendableUpstreamContext(context: context)
        context.eventLoop.scheduleTask(in: .milliseconds(Int64(event.delayMs))) { [self] in
            let context = boxed.context
            guard context.channel.isActive else { return }
            var buffer = context.channel.allocator.buffer(capacity: event.bytes.count)
            buffer.writeBytes(event.bytes)
            context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            writeEvent(at: index + 1, context: context, script: script)
        }
    }
}

// MARK: - Canned scripts

/// A Messages-API stream for a text answer, in the wire order the real API
/// uses: `message_start` → `content_block_start` → one `content_block_delta`
/// per delta → `content_block_stop` → `message_delta` → `message_stop`.
///
/// It emits the same event sequence and payload shape as `sse_events` in the
/// fake model API (`.github/workflows/claude-review-v2/tests/e2e/stub_server.py`),
/// rendered with the real API's compact separators, and with the tool blocks
/// omitted since the tee only reads text. It is a fixture modelled on that
/// stream, not a byte-for-byte copy of any one recorded turn.
/// Payloads are hand-written rather than encoded from dictionaries so the
/// bytes are fixed: a `JSONEncoder` over a dictionary orders keys however it
/// likes, and a fixture whose bytes move cannot witness a byte-identical
/// forward. Separators are compact, as the real API's are.
///
/// - Parameter delayMs: the gap before each event, so a script of n events
///   takes n × `delayMs` to finish.
func sseTextAnswer(messageID: String, deltas: [String], delayMs: Int = 0) -> FakeUpstream.Script {
    var events: [(delayMs: Int, bytes: [UInt8])] = []

    func append(_ name: String, _ payload: String) {
        events.append((delayMs: delayMs, bytes: Array("event: \(name)\ndata: \(payload)\n\n".utf8)))
    }

    append(
        "message_start",
        #"{"type":"message_start","message":{"id":\#(jsonString(messageID)),"type":"message","role":"assistant","model":"claude-stub","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":1}}}"#
    )
    append(
        "content_block_start",
        #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#
    )
    for delta in deltas {
        append(
            "content_block_delta",
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":\#(jsonString(delta))}}"#
        )
    }
    append("content_block_stop", #"{"type":"content_block_stop","index":0}"#)
    append(
        "message_delta",
        #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":1}}"#
    )
    append("message_stop", #"{"type":"message_stop"}"#)

    return FakeUpstream.Script(events: events)
}

/// `value` as a JSON string literal, quotes included — a real encoder rather
/// than hand-rolled escaping, so a delta carrying a quote, a newline or an
/// emoji stays a fixture instead of becoming a parse error.
private func jsonString(_ value: String) -> String {
    guard let data = try? JSONEncoder().encode([value]),
        let text = String(data: data, encoding: .utf8),
        text.count > 2
    else {
        return "\"\""
    }
    return String(text.dropFirst().dropLast())
}
