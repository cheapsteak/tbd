import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "http")

/// An HTTP server bound to localhost with auto-assigned port.
///
/// Accepts POST requests to `/rpc` with a JSON body containing an `RPCRequest`.
/// Routes through `RPCRouter` and returns JSON `RPCResponse`.
/// The assigned port is written to `~/tbd/port` for discovery.
///
/// Every request must pass `HTTPRequestGate` on its head, before any body is
/// buffered: a loopback `Host` naming the port the connection arrived on
/// (refuses DNS rebinding), no `Origin` header (refuses all browser traffic),
/// and the per-start secret from `~/tbd/http-token` in `X-TBD-Token`. A refused
/// request gets a JSON error and the connection is closed. Any local process
/// can still call the port if it can read the owner-only token file, which is
/// the same trust boundary as the Unix socket.
public final class HTTPServer: Sendable {
    private let router: RPCRouter
    private let portFilePath: String
    private let tokenFilePath: String
    /// This server's secret, kept only so `stop()` can tell its own token file
    /// from a successor's. Never logged.
    private nonisolated(unsafe) var token: String?
    private let group: MultiThreadedEventLoopGroup
    private nonisolated(unsafe) var channel: Channel?

    /// Keeps the shutdown to one run, however many `stop()` calls arrive.
    /// `Daemon.stop()` is not deduplicated and this server is torn down right
    /// after `SocketServer`, so an escalated SIGTERM-then-SIGINT reaches it
    /// twice; a second run would wedge here instead and the shutdown would
    /// never reach its `exit(0)`. See `ShutdownLatch`.
    private let shutdownLatch = ShutdownLatch()

    /// The port the server is bound to, available after start().
    public nonisolated(unsafe) var port: Int = 0

    public init(router: RPCRouter, portFilePath: String? = nil, tokenFilePath: String? = nil) {
        self.router = router
        // See HookResolver — resolve here, not at the caller's site.
        self.portFilePath = portFilePath ?? TBDConstants.portFilePath
        self.tokenFilePath = tokenFilePath ?? TBDConstants.httpTokenFilePath
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    /// Start listening on localhost with auto-assigned port.
    public func start() async throws {
        let router = self.router

        // The token reaches disk before the socket is bound and before the
        // port file is written, so no client can learn the port while the
        // token is still missing.
        let token = HTTPRPCToken.generate()
        try HTTPRPCToken.writeOwnerOnly(token, to: tokenFilePath)
        self.token = token
        let tokenFilePath = self.tokenFilePath

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 64)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    let handler = HTTPRPCHandler(router: router, token: token, tokenFilePath: tokenFilePath)
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }

        let ch: Channel
        do {
            ch = try await bootstrap.bind(
                host: "127.0.0.1",
                port: 0  // Auto-assign port
            ).get()
        } catch {
            try? FileManager.default.removeItem(atPath: tokenFilePath)
            throw error
        }

        self.channel = ch

        // Extract the assigned port
        if let addr = ch.localAddress {
            self.port = addr.port ?? 0
        }

        // Write port to file for discovery
        try "\(self.port)".write(toFile: portFilePath, atomically: true, encoding: .utf8)

        logger.info("Listening on http://127.0.0.1:\(self.port, privacy: .public)")
    }

    /// Stop the server and clean up. Safe to call any number of times, from
    /// any number of tasks at once.
    public func stop() async {
        await shutdownLatch.run {
            do {
                try await self.channel?.close()
            } catch {
                // Already closed
            }
            try? await self.group.shutdownGracefully()
            // In a daemon handover the successor starts first and writes its
            // own files; remove each file only while it still holds this
            // server's value, so the old daemon never deletes the successor's.
            if let contents = try? String(contentsOfFile: self.portFilePath, encoding: .utf8),
               contents == "\(self.port)" {
                try? FileManager.default.removeItem(atPath: self.portFilePath)
            }
            if let token = self.token,
               let contents = try? String(contentsOfFile: self.tokenFilePath, encoding: .utf8),
               contents == token {
                try? FileManager.default.removeItem(atPath: self.tokenFilePath)
            }
        }
    }
}

// MARK: - Sendable context wrapper

/// Wraps a ChannelHandlerContext for use across Task boundaries.
/// Safe because we always dispatch back to the event loop before using it.
private struct HTTPSendableContext: @unchecked Sendable {
    let context: ChannelHandlerContext
}

// MARK: - NIO HTTP Handler

/// Handles HTTP requests for the RPC endpoint.
private final class HTTPRPCHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: RPCRouter
    private let token: String
    private let tokenFilePath: String
    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?
    /// Set at `.head` when the gate refuses; the body is then ignored and the
    /// refusal is written at `.end`.
    private var pendingRefusal: (gate: HTTPRequestGate, refusal: HTTPRequestGate.Refusal)?
    /// Once a refusal has been written the connection is closing; ignore the rest.
    private var closing = false

    init(router: RPCRouter, token: String, tokenFilePath: String) {
        self.router = router
        self.token = token
        self.tokenFilePath = tokenFilePath
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        if closing { return }

        switch part {
        case .head(let head):
            requestHead = head
            // Runs on the event loop, so localAddress is read here, not elsewhere.
            let gate = HTTPRequestGate(
                port: context.channel.localAddress?.port ?? 0,
                token: token,
                tokenFilePath: tokenFilePath
            )
            if let refusal = gate.refusal(for: head) {
                logger.info("Refused HTTP request: \(refusal.category, privacy: .public)")
                pendingRefusal = (gate, refusal)
                bodyBuffer = nil
            } else {
                bodyBuffer = context.channel.allocator.buffer(capacity: 0)
            }

        case .body(var body):
            if pendingRefusal == nil {
                bodyBuffer?.writeBuffer(&body)
            }

        case .end:
            if let (gate, refusal) = pendingRefusal {
                pendingRefusal = nil
                closing = true
                let encoded = try? JSONEncoder().encode(RPCResponse(error: gate.message(for: refusal)))
                let body = encoded.flatMap { String(data: $0, encoding: .utf8) }
                    ?? "{\"success\":false,\"error\":\"Request refused\"}"
                Self.sendResponseOnLoop(
                    context: context, status: refusal.status, body: body, closeAfter: true
                )
                return
            }
            guard let head = requestHead else { return }

            // Only accept POST /rpc
            guard head.method == .POST, head.uri == "/rpc" else {
                sendResponse(context: context, status: .notFound,
                             body: "{\"success\":false,\"error\":\"Not found. Use POST /rpc\"}")
                return
            }

            guard let body = bodyBuffer, body.readableBytes > 0 else {
                sendResponse(context: context, status: .badRequest,
                             body: "{\"success\":false,\"error\":\"Empty request body\"}")
                return
            }

            let bodyData = Data(body.readableBytesView)
            let wrappedCtx = HTTPSendableContext(context: context)
            let router = self.router

            Task {
                await Self.processRequest(bodyData, router: router, wrappedCtx: wrappedCtx)
            }

            // Reset for next request
            requestHead = nil
            bodyBuffer = nil
        }
    }

    /// The refusal for a method this transport does not serve, or nil to route
    /// the request. A body that does not decode is routed, so the router
    /// answers it with its own error, as it always has.
    static func socketOnlyRefusal(_ bodyData: Data) -> RPCResponse? {
        guard let method = (try? JSONDecoder().decode(RPCRequest.self, from: bodyData))?.method,
              RPCMethod.socketOnly.contains(method) else { return nil }
        return RPCResponse(error: "\(method) is served only on the daemon's Unix socket, not over HTTP")
    }

    private static func processRequest(_ bodyData: Data, router: RPCRouter, wrappedCtx: HTTPSendableContext) async {
        let response: RPCResponse
        if let refusal = socketOnlyRefusal(bodyData) {
            response = refusal
        } else {
            response = await router.handleRaw(bodyData)
        }

        do {
            let responseData = try JSONEncoder().encode(response)
            guard let responseString = String(data: responseData, encoding: .utf8) else { return }

            let eventLoop = wrappedCtx.context.eventLoop
            eventLoop.execute {
                let context = wrappedCtx.context
                guard context.channel.isActive else { return }
                Self.sendResponseOnLoop(context: context, status: .ok, body: responseString)
            }
        } catch {
            let eventLoop = wrappedCtx.context.eventLoop
            eventLoop.execute {
                let context = wrappedCtx.context
                guard context.channel.isActive else { return }
                Self.sendResponseOnLoop(context: context, status: .internalServerError,
                                        body: "{\"success\":false,\"error\":\"Failed to encode response\"}")
            }
        }
    }

    private func sendResponse(context: ChannelHandlerContext, status: HTTPResponseStatus, body: String) {
        Self.sendResponseOnLoop(context: context, status: status, body: body)
    }

    private static func sendResponseOnLoop(
        context: ChannelHandlerContext, status: HTTPResponseStatus, body: String, closeAfter: Bool = false
    ) {
        let bodyData = body.utf8
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: "\(bodyData.count)")
        if closeAfter { headers.add(name: "Connection", value: "close") }

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: bodyData.count)
        buffer.writeString(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

        if closeAfter {
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                context.close(promise: nil)
            }
        } else {
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Error: \(error.localizedDescription, privacy: .public)")
        context.close(promise: nil)
    }
}
