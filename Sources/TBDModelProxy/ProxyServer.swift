import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import TBDShared
import os

// MARK: - The tee seam

/// Where a forwarded response is copied for the transcript stream.
///
/// A protocol rather than the concrete `StreamTee`, because the forwarder must
/// not be able to wait on it: the tee parses SSE and writes a file, and a
/// proxy that let either of those sit in front of a `writeAndFlush` would put
/// the transcript's convenience ahead of the turn the user is watching. The
/// server awaits `begin` once and never awaits again.
protocol StreamTeeing: Sendable {
    /// Called once, after the upstream head arrives and before any chunk is
    /// fed. Returning nil means this response is not worth teeing — a
    /// subagent's request, a non-stream, a route with streaming off — and the
    /// server then feeds nothing.
    func begin(
        route: ModelProxyRoute,
        method: String,
        pathSuffix: String,
        requestHeaders: [(String, String)],
        requestBody: [UInt8],
        responseStatus: Int,
        responseHeaders: [(String, String)]
    ) async -> (any TeeSessionHandle)?
}

/// One teed response. Both calls are synchronous and must not block: they hand
/// bytes over and return.
protocol TeeSessionHandle: Sendable {
    func feed(_ chunk: [UInt8])
    /// Called exactly once. A non-nil error is an upstream leg that failed or
    /// was cut, which is what distinguishes a finished message from an
    /// aborted one.
    func end(error: Error?)
}

// MARK: - The server

/// The proxy's loopback listener.
///
/// Everything under `/r/<token>/` is forwarded — not only `/v1/messages`,
/// because the base URL governs whatever Claude Code chooses to call on it:
/// the `HEAD /api/hello` warm-up, `/v1/messages/count_tokens`, and endpoints a
/// future release adds. A token that names no route is refused with 404 and
/// nothing is forwarded, which is what keeps a proxy on loopback from being an
/// open forwarder for any other local process.
final class ProxyServer: Sendable {
    static let log = Logger(subsystem: "com.tbd.modelproxy", category: "server")

    /// What every `/tbd/...` request answers until Task A5 lands the control
    /// endpoints. One dispatch point, so that task replaces a single `switch`
    /// rather than hunting for the paths.
    static let controlNotWiredBody = #"{"error":"not yet wired"}"#
    static let unknownRouteBody = #"{"error":"unknown route"}"#

    private let requestedPort: Int
    private let routes: RouteTable
    private let tee: (any StreamTeeing)?
    /// Read by `GET /tbd/status` in Task A5. Stored now so the wiring the
    /// daemon's supervisor needs is settled before the endpoint exists.
    private let status: @Sendable () -> ModelProxyStatus
    /// Called by `POST /tbd/retire` in Task A5.
    private let onRetire: @Sendable () -> Void
    private let forwarder: UpstreamForwarder
    private let group: MultiThreadedEventLoopGroup
    private let inFlight = StreamCounter()
    private let channelBox = ChannelBox()

    init(
        port: Int,
        routes: RouteTable,
        tee: (any StreamTeeing)?,
        status: @escaping @Sendable () -> ModelProxyStatus,
        onRetire: @escaping @Sendable () -> Void,
        forwarder: UpstreamForwarder = UpstreamForwarder(session: UpstreamForwarder.makeSession())
    ) {
        self.requestedPort = port
        self.routes = routes
        self.tee = tee
        self.status = status
        self.onRetire = onRetire
        self.forwarder = forwarder
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    /// Number of forwarded responses whose head has been relayed and whose end
    /// has not. `POST /tbd/retire` drains on this; the status endpoint reports
    /// it.
    var streamsInFlight: Int { inFlight.value }

    /// Binds loopback and returns the port actually bound, which is the point
    /// of the call when `port` was zero.
    @discardableResult
    func start() async throws -> Int {
        let routes = self.routes
        let tee = self.tee
        let forwarder = self.forwarder
        let inFlight = self.inFlight

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 64)
            // Claude aborts a stream that has been silent for 300 seconds and
            // counts SSE pings, so an event must reach the socket when it
            // arrives. Nagle would hold a small write back waiting for company
            // and turn the proxy's timing into the kernel's.
            .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
            // Deliberately no idle-state handler: a legitimate stream may sit
            // silent between pings for longer than any timeout worth setting.
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(
                        ProxyRequestHandler(
                            routes: routes, tee: tee, forwarder: forwarder, inFlight: inFlight))
                }
            }

        let bound = try await bootstrap.bind(host: "127.0.0.1", port: requestedPort).get()
        channelBox.channel = bound
        guard let port = bound.localAddress?.port else {
            try? await bound.close()
            channelBox.channel = nil
            throw ProxyServerError.boundAddressUnreadable
        }
        Self.log.debug("listening on 127.0.0.1:\(port, privacy: .public)")
        return port
    }

    /// Stops accepting new connections. In-flight responses keep streaming on
    /// the connections they are already on — the retire handshake in Task A5
    /// answers as soon as this returns and drains afterwards.
    func closeListener() async {
        guard let channel = channelBox.take() else { return }
        try? await channel.close()
    }

    /// Closes the listener and shuts the event loops down. Safe to call after
    /// `closeListener`, and safe to call twice.
    func stop() async {
        await closeListener()
        try? await group.shutdownGracefully()
    }
}

enum ProxyServerError: LocalizedError {
    case boundAddressUnreadable

    var errorDescription: String? {
        switch self {
        case .boundAddressUnreadable:
            return "the proxy bound a channel whose local address has no port"
        }
    }
}

// MARK: - Shared mutable boxes

/// The count of open forwarded responses. A lock rather than an actor because
/// it is read from `streamsInFlight`, which is synchronous by contract.
final class StreamCounter: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
    func decrement() { lock.withLock { count = max(0, count - 1) } }
}

/// Holds the listening channel. `Channel` is `Sendable`; the box exists only
/// so `ProxyServer` can stay a `Sendable` class with one mutable field.
private final class ChannelBox: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var stored: (any Channel)?

    var channel: (any Channel)? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// Reads and clears in one step, so two `closeListener` calls close once.
    func take() -> (any Channel)? {
        lock.withLock {
            defer { stored = nil }
            return stored
        }
    }
}

/// Carries a `ChannelHandlerContext` and the two things reachable from it that
/// a forwarding task needs, captured while on the event loop. Every use of
/// `context` itself happens back inside `eventLoop.execute`.
private struct SendableChannelContext: @unchecked Sendable {
    let context: ChannelHandlerContext
    let eventLoop: any EventLoop
    let allocator: ByteBufferAllocator
}

// MARK: - The request handler

/// What the relay hands the tee, in wire order. The forwarding path only
/// yields into an unbounded stream, so it never waits on the tee.
private enum TeeRelayEvent: @unchecked Sendable {
    case begin(Int, [(String, String)])
    case chunk([UInt8])
    case end(Error?)
}

private final class ProxyRequestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let routes: RouteTable
    private let tee: (any StreamTeeing)?
    private let forwarder: UpstreamForwarder
    private let inFlight: StreamCounter

    private var head: HTTPRequestHead?
    /// The whole request body, buffered before anything is forwarded.
    ///
    /// Claude's requests run to a few hundred kilobytes and are sent in one
    /// shot; streaming the request leg would buy nothing and would mean
    /// holding a `URLSession` upload stream open across the event loop.
    private var body: [UInt8] = []
    private var forwardTask: Task<Void, Never>?

    init(
        routes: RouteTable, tee: (any StreamTeeing)?, forwarder: UpstreamForwarder,
        inFlight: StreamCounter
    ) {
        self.routes = routes
        self.tee = tee
        self.forwarder = forwarder
        self.inFlight = inFlight
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
            dispatch(context: context, head: requestHead, body: requestBody)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // The client hung up. Cancelling propagates into the upstream leg,
        // which cancels its `URLSessionTask` rather than holding a model
        // request open for a response nobody will read.
        forwardTask?.cancel()
        forwardTask = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        ProxyServer.log.error("channel error: \(error.localizedDescription, privacy: .public)")
        context.close(promise: nil)
    }

    // MARK: Routing

    /// `/r/<token>` split into the token and everything the upstream should
    /// see, which is the rest of the path *and* the query.
    ///
    /// The token is whitelisted before it is used for anything at all, so
    /// `/r/../../v1/messages` and `/r/ABC/v1/messages` never reach a route
    /// lookup, never compose a file path, and forward nothing.
    static func routeTarget(uri: String) -> (token: String, suffix: String)? {
        let prefix = "/r/"
        guard uri.hasPrefix(prefix) else { return nil }
        let rest = uri.dropFirst(prefix.count)
        let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? rest.endIndex
        let token = String(rest[rest.startIndex..<end])
        guard ModelProxyRoute.isValidToken(token) else { return nil }
        let tail = String(rest[end...])
        // `/r/<token>` and `/r/<token>?x=1` both address the upstream's root.
        let suffix = tail.hasPrefix("/") ? tail : "/\(tail)"
        return (token, suffix)
    }

    /// True for the control endpoints Task A5 owns.
    static func isControlPath(_ path: String) -> Bool {
        path == "/tbd/status" || path == "/tbd/retire" || path == "/tbd/routes"
            || path.hasPrefix("/tbd/routes/")
    }

    private func dispatch(context: ChannelHandlerContext, head: HTTPRequestHead, body: [UInt8]) {
        let path = String(head.uri.prefix(while: { $0 != "?" }))
        let keepAlive = head.isKeepAlive

        if Self.isControlPath(path) {
            // One dispatch point for `/tbd/...`, replaced wholesale in Task
            // A5 by the status, retire and routes handlers.
            Self.respondJSON(
                context: context, status: .notImplemented,
                body: ProxyServer.controlNotWiredBody, keepAlive: keepAlive)
            return
        }

        guard let target = Self.routeTarget(uri: head.uri) else {
            Self.respondJSON(
                context: context, status: .notFound,
                body: ProxyServer.unknownRouteBody, keepAlive: keepAlive)
            return
        }

        let boxed = SendableChannelContext(
            context: context, eventLoop: context.eventLoop,
            allocator: context.channel.allocator)
        let requestHeaders = head.headers.map { ($0.name, $0.value) }
        let method = head.method
        let routes = self.routes
        let tee = self.tee
        let forwarder = self.forwarder
        let inFlight = self.inFlight

        forwardTask = Task {
            guard let route = await routes.route(for: target.token) else {
                ProxyRequestHandler.respondJSON(
                    on: boxed, status: .notFound,
                    body: ProxyServer.unknownRouteBody, keepAlive: keepAlive)
                return
            }
            guard let url = URL(string: route.upstream + target.suffix) else {
                ProxyRequestHandler.respondJSON(
                    on: boxed, status: .badGateway,
                    body: ProxyRequestHandler.upstreamErrorBody("upstream url is not usable"),
                    keepAlive: keepAlive)
                return
            }

            var teeContinuation: AsyncStream<TeeRelayEvent>.Continuation?
            if let tee {
                let (stream, continuation) = AsyncStream.makeStream(of: TeeRelayEvent.self)
                teeContinuation = continuation
                // A task of its own: the relay yields and returns, so a slow
                // tee costs the client nothing. Chunks that arrive while
                // `begin` is still running queue in the stream and are fed in
                // order once it answers.
                Task {
                    var handle: (any TeeSessionHandle)?
                    for await event in stream {
                        switch event {
                        case .begin(let responseStatus, let responseHeaders):
                            handle = await tee.begin(
                                route: route, method: method.rawValue,
                                pathSuffix: target.suffix, requestHeaders: requestHeaders,
                                requestBody: body, responseStatus: responseStatus,
                                responseHeaders: responseHeaders)
                        case .chunk(let bytes):
                            handle?.feed(bytes)
                        case .end(let error):
                            handle?.end(error: error)
                            handle = nil
                        }
                    }
                }
            }

            let relay = ResponseRelay(
                boxed: boxed, isHeadRequest: method == .HEAD, keepAlive: keepAlive,
                inFlight: inFlight, tee: teeContinuation)

            await forwarder.forward(
                method: method.rawValue, url: url, headers: requestHeaders, body: body,
                onHead: { status, headers in relay.relayHead(status: status, headers: headers) },
                onChunk: { chunk in relay.relayChunk(chunk) },
                onEnd: { error in relay.relayEnd(error) })
        }
    }

    // MARK: Fixed responses

    static func upstreamErrorBody(_ message: String) -> String {
        // The shape Claude's own error handling expects, so an unreachable
        // upstream reads to it as an API error rather than as garbage from a
        // base URL it does not recognise.
        let escaped =
            (try? String(data: JSONEncoder().encode([message]), encoding: .utf8))
            .flatMap { text -> String? in
                guard text.count > 2 else { return nil }
                return String(text.dropFirst().dropLast())
            } ?? "\"upstream unreachable\""
        return #"{"type":"error","error":{"type":"api_error","message":\#(escaped)}}"#
    }

    private static func respondJSON(
        context: ChannelHandlerContext, status: HTTPResponseStatus, body: String, keepAlive: Bool
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "application/json")
        headers.add(name: "content-length", value: "\(body.utf8.count)")
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        let promise = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
        if !keepAlive {
            // The channel, not the context: `whenComplete` takes a `@Sendable`
            // closure, `ChannelHandlerContext` is not `Sendable`, and `Channel`
            // is — closing through it is the same close, correctly typed.
            let channel = context.channel
            promise.futureResult.whenComplete { _ in channel.close(promise: nil) }
        }
    }

    private static func respondJSON(
        on boxed: SendableChannelContext, status: HTTPResponseStatus, body: String, keepAlive: Bool
    ) {
        boxed.eventLoop.execute {
            let context = boxed.context
            guard context.channel.isActive else { return }
            respondJSON(context: context, status: status, body: body, keepAlive: keepAlive)
        }
    }
}

// MARK: - Response relay

/// Copies one upstream response onto the client's channel, one flush per
/// chunk.
///
/// `@unchecked Sendable`: the two mutable flags are guarded by a lock, and
/// every channel touch is dispatched onto the channel's own event loop.
private final class ResponseRelay: @unchecked Sendable {
    private let boxed: SendableChannelContext
    private let isHeadRequest: Bool
    private let keepAlive: Bool
    private let inFlight: StreamCounter
    private let tee: AsyncStream<TeeRelayEvent>.Continuation?

    private let lock = NSLock()
    private var wroteHead = false
    private var finished = false

    init(
        boxed: SendableChannelContext, isHeadRequest: Bool, keepAlive: Bool,
        inFlight: StreamCounter, tee: AsyncStream<TeeRelayEvent>.Continuation?
    ) {
        self.boxed = boxed
        self.isHeadRequest = isHeadRequest
        self.keepAlive = keepAlive
        self.inFlight = inFlight
        self.tee = tee
    }

    func relayHead(status: Int, headers: [(String, String)]) {
        let firstHead = lock.withLock {
            guard !wroteHead, !finished else { return false }
            wroteHead = true
            return true
        }
        guard firstHead else { return }
        inFlight.increment()

        let responseHead = makeResponseHead(status: status, headers: headers)
        boxed.eventLoop.execute {
            let context = self.boxed.context
            guard context.channel.isActive else { return }
            context.writeAndFlush(
                NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
        }
        tee?.yield(.begin(status, headers))
    }

    func relayChunk(_ chunk: [UInt8]) {
        guard !chunk.isEmpty else { return }
        let allocator = boxed.allocator
        boxed.eventLoop.execute {
            let context = self.boxed.context
            guard context.channel.isActive else { return }
            var buffer = allocator.buffer(capacity: chunk.count)
            buffer.writeBytes(chunk)
            // Flushed per chunk, never batched: an SSE event that sits in a
            // write buffer is an event Claude has not seen.
            context.writeAndFlush(
                NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
        }
        tee?.yield(.chunk(chunk))
    }

    func relayEnd(_ error: Error?) {
        let state = lock.withLock { () -> (alreadyFinished: Bool, hadHead: Bool) in
            let already = finished
            finished = true
            return (already, wroteHead)
        }
        guard !state.alreadyFinished else { return }

        tee?.yield(.end(error))
        tee?.finish()

        guard state.hadHead else {
            // Nothing has been written to the client yet, so the whole failure
            // is still expressible as a status. This is the only place the
            // proxy invents a body.
            let message = error.map { "upstream unreachable: \($0.localizedDescription)" }
                ?? "upstream returned no response"
            ProxyRequestHandler.respondUpstreamFailure(
                on: boxed, message: message, keepAlive: keepAlive)
            return
        }

        inFlight.decrement()
        let keepAlive = self.keepAlive
        boxed.eventLoop.execute {
            let context = self.boxed.context
            guard context.channel.isActive else { return }
            let promise = context.eventLoop.makePromise(of: Void.self)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: promise)
            // A stream cut mid-body is relayed as a cut: the client's chunked
            // framing has no terminating chunk, which is exactly what it would
            // have seen from the upstream directly.
            if !keepAlive || error != nil {
                let channel = context.channel
                promise.futureResult.whenComplete { _ in channel.close(promise: nil) }
            }
        }
    }

    /// The head written to the client: the upstream's status, the upstream's
    /// headers minus the ones this connection's framing owns, and chunked
    /// framing.
    private func makeResponseHead(status: Int, headers: [(String, String)]) -> HTTPResponseHead {
        var out = HTTPHeaders()
        var upstreamContentLength: String?
        for (name, value) in headers {
            let lowered = name.lowercased()
            if lowered == "content-length" { upstreamContentLength = value }
            guard !UpstreamForwarder.droppedResponseHeaders.contains(lowered) else { continue }
            out.add(name: name, value: value)
        }

        let responseStatus = HTTPResponseStatus(statusCode: status)
        if isHeadRequest || !responseStatus.mayHaveResponseBody {
            // A HEAD response carries the header fields a GET would, but no
            // body — and NIO frames by status alone, so leaving it to chunked
            // framing would put a terminating `0\r\n\r\n` on the wire after a
            // response that must have none, desynchronising a keep-alive
            // connection. Content-length framing writes nothing for `.end`.
            // NIO strips both framing headers itself for a 204 or a 304.
            out.add(name: "content-length", value: upstreamContentLength ?? "0")
        } else {
            out.add(name: "transfer-encoding", value: "chunked")
        }
        return HTTPResponseHead(version: .http1_1, status: responseStatus, headers: out)
    }
}

extension ProxyRequestHandler {
    /// The 502 a failed upstream leg becomes. Split out so the relay can reach
    /// it without holding a handler.
    fileprivate static func respondUpstreamFailure(
        on boxed: SendableChannelContext, message: String, keepAlive: Bool
    ) {
        boxed.eventLoop.execute {
            let context = boxed.context
            guard context.channel.isActive else { return }
            let body = upstreamErrorBody(message)
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "application/json")
            headers.add(name: "content-length", value: "\(body.utf8.count)")
            let head = HTTPResponseHead(version: .http1_1, status: .badGateway, headers: headers)
            context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
            var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
            buffer.writeString(body)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            let promise = context.eventLoop.makePromise(of: Void.self)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: promise)
            if !keepAlive {
                let channel = context.channel
                promise.futureResult.whenComplete { _ in channel.close(promise: nil) }
            }
        }
    }
}
