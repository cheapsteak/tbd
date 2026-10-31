import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "modChannel")

/// The session-mod channel's listener: HTTP/1.1 on the Unix socket
/// `~/tbd/mod.sock` (`TBDConstants.modSocketPath`), mode 0600, which a session
/// mod reaches with `$.http.fetch(url, { socketPath })`
/// (`docs/specs/2026-10-20-mod-channel-prompt-answer-design.md`, "Listener").
///
/// Deliberately thin: it buffers a request, hands it to ``ModChannelRoutes``,
/// writes the reply with `Connection: close` and closes. A held poll or
/// answer wait whose connection closes before its reply — the mod aborted its
/// fetch — is released by cancelling the task handling it, which works whether
/// or not the request has attached yet (it may still be authenticating).
///
/// NIO's HTTP pipelining assistance is off on purpose: while a response is
/// pending it stops reading the socket, so a client's close would go unseen
/// until the held reply was written — up to the full hold, and forever under
/// a clock that never advances. Reading on is what lets the close arrive.
///
/// The socket file follows `SocketServer`'s ownership rules: a stale file is
/// removed before binding, the socket is bound here and handed to NIO (so
/// NIO's close never unlinks a path a successor daemon has since bound), and
/// `stop()` unlinks the file only while it is still the one this server bound.
final class ModChannelServer: Sendable {
    /// Largest request body accepted; a larger one gets 413.
    static let maxBodyBytes = 1 << 20

    private let socketPath: String
    private let routes: ModChannelRoutes
    private let group: MultiThreadedEventLoopGroup
    private let shutdownLatch = ShutdownLatch()

    private let lock = NSLock()
    private nonisolated(unsafe) var channel: Channel?
    private nonisolated(unsafe) var boundIdentity: SocketFileIdentity?

    init(socketPath: String, routes: ModChannelRoutes) {
        self.socketPath = socketPath
        self.routes = routes
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    func start() async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: socketPath) {
            try fileManager.removeItem(atPath: socketPath)
        }
        try fileManager.createDirectory(
            atPath: (socketPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)

        let routes = self.routes
        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                        withPipeliningAssistance: false)
                    try channel.pipeline.syncOperations.addHandler(ModChannelHTTPHandler(routes: routes))
                }
            }

        let boundFD = try bindListeningSocket(at: socketPath)
        // Before NIO listens, so nothing can connect at a wider mode. A socket
        // left at the umask's mode is not served at all.
        guard chmod(socketPath, 0o600) == 0 else {
            let code = errno
            close(boundFD)
            try? fileManager.removeItem(atPath: socketPath)
            logger.error(
                "mod channel could not restrict \(self.socketPath, privacy: .public) to 0600: errno \(code, privacy: .public)")
            throw ModChannelServerError.chmodFailed(path: socketPath, code: code)
        }
        let identity = SocketFileIdentity(path: socketPath)
        let ch: Channel
        do {
            ch = try await bootstrap.withBoundSocket(boundFD).get()
        } catch {
            // NIO owns the descriptor once it wraps it; do not close it here.
            unlink(ifStill: identity)
            throw error
        }
        lock.withLock {
            channel = ch
            boundIdentity = identity
        }
        logger.info("mod channel listening on \(self.socketPath, privacy: .public)")
    }

    /// Stops the listener and unlinks the socket file. Safe to call any number
    /// of times, from any number of tasks at once (see `ShutdownLatch`).
    func stop() async {
        await shutdownLatch.run {
            let (ch, identity) = self.lock.withLock { () -> (Channel?, SocketFileIdentity?) in
                defer {
                    self.channel = nil
                    self.boundIdentity = nil
                }
                return (self.channel, self.boundIdentity)
            }
            do {
                try await ch?.close()
            } catch {
                // Already closed.
            }
            try? await self.group.shutdownGracefully()
            self.unlink(ifStill: identity)
        }
    }

    private func unlink(ifStill identity: SocketFileIdentity?) {
        guard let identity, let current = SocketFileIdentity(path: socketPath), current == identity else {
            return
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }
}

enum ModChannelServerError: LocalizedError, Equatable {
    /// The bound socket could not be restricted to mode 0600.
    case chmodFailed(path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .chmodFailed(let path, let code):
            return "Could not restrict the mod channel socket at \(path) to mode 0600: \(String(cString: strerror(code))) (errno \(code))"
        }
    }
}

// MARK: - Handler

/// Wraps a `ChannelHandlerContext` for use across a `Task`. Safe because every
/// use dispatches back to the context's event loop first.
private struct ModChannelSendableContext: @unchecked Sendable {
    let context: ChannelHandlerContext
}

/// One connection's request. All stored state is touched only on the
/// channel's event loop: in the `ChannelInboundHandler` callbacks, and in the
/// `eventLoop.execute` that writes the reply.
private final class ModChannelHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let routes: ModChannelRoutes
    private var head: HTTPRequestHead?
    private var body = Data()
    private var tooLarge = false
    /// The token of the request being handled, from dispatch until its reply
    /// is written. Set means a connection close abandons that request.
    private var inFlightToken: UUID?
    /// A request has been answered or handed to the routes. Set, the
    /// connection takes no further request.
    private var dispatched = false
    /// The task answering a held poll or answer wait, while it is in flight.
    /// Cancelled when the connection closes, which releases the hold.
    private var holdingTask: Task<Void, Never>?

    init(routes: ModChannelRoutes) {
        self.routes = routes
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // One request per connection: every response carries
        // `Connection: close`, so anything pipelined behind the first
        // request is ignored and goes with the close.
        guard !dispatched else { return }
        switch unwrapInboundIn(data) {
        case .head(let requestHead):
            head = requestHead
            body = Data()
            tooLarge = false
            if let declared = requestHead.headers.first(name: "content-length").flatMap(Int.init),
               declared > ModChannelServer.maxBodyBytes {
                tooLarge = true
            }
        case .body(let buffer):
            guard !tooLarge else { return }
            if body.count + buffer.readableBytes > ModChannelServer.maxBodyBytes {
                tooLarge = true
                body = Data()
                return
            }
            body.append(contentsOf: buffer.readableBytesView)
        case .end:
            guard let requestHead = head else { return }
            head = nil
            dispatched = true
            if tooLarge {
                Self.writeResponse(
                    context: context, ModChannelRoutes.error(413, "payload too large"))
                return
            }
            let components = URLComponents(string: requestHead.uri)
            var query: [String: String] = [:]
            for item in components?.queryItems ?? [] {
                query[item.name] = item.value ?? ""
            }
            var headers: [String: String] = [:]
            for (name, value) in requestHead.headers {
                headers[name.lowercased()] = value
            }
            let request = ModChannelRequest(
                method: requestHead.method.rawValue,
                path: components?.path ?? requestHead.uri,
                query: query,
                headers: headers,
                body: body)
            body = Data()

            let token = UUID()
            inFlightToken = token
            let routes = self.routes
            let wrapped = ModChannelSendableContext(context: context)
            let eventLoop = context.eventLoop
            let task = Task {
                let response = await routes.handle(request, token: token)
                eventLoop.execute {
                    // Still the request in flight: the connection did not close.
                    guard self.inFlightToken == token else { return }
                    self.inFlightToken = nil
                    self.holdingTask = nil
                    let context = wrapped.context
                    guard context.channel.isActive else { return }
                    Self.writeResponse(context: context, response)
                }
            }
            if ModChannelRoutes.holdsConnection(method: request.method, path: request.path) {
                holdingTask = task
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        inFlightToken = nil
        // Runs the hold's cancellation handlers here, on the event loop; each
        // only schedules its release, so nothing blocks.
        holdingTask?.cancel()
        holdingTask = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.debug("mod channel connection error: \(error.localizedDescription, privacy: .public)")
        context.close(promise: nil)
    }

    /// Writes `response` and closes the connection. Event loop only.
    private static func writeResponse(context: ChannelHandlerContext, _ response: ModChannelResponse) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: "\(response.body.count)")
        headers.add(name: "Connection", value: "close")
        let head = HTTPResponseHead(
            version: .http1_1, status: HTTPResponseStatus(statusCode: response.status), headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: response.body.count)
        buffer.writeBytes(response.body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        let channel = context.channel
        let written = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: written)
        written.futureResult.whenComplete { _ in channel.close(promise: nil) }
    }
}
