import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import TBDShared

/// An HTTP server bound to localhost with auto-assigned port.
///
/// Accepts POST requests to `/rpc` with a JSON body containing an `RPCRequest`.
/// Routes through `RPCRouter` and returns JSON `RPCResponse`.
/// The assigned port is written to `~/tbd/port` for discovery.
public final class HTTPServer: Sendable {
    private let router: RPCRouter
    private let portFilePath: String
    private let group: MultiThreadedEventLoopGroup
    private nonisolated(unsafe) var channel: Channel?

    /// The port the server is bound to, available after start().
    public nonisolated(unsafe) var port: Int = 0

    public init(router: RPCRouter, portFilePath: String = TBDConstants.portFilePath) {
        self.router = router
        self.portFilePath = portFilePath
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    /// Start listening on localhost with auto-assigned port.
    public func start() async throws {
        let router = self.router

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 64)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    let handler = HTTPRPCHandler(router: router)
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }

        let ch = try await bootstrap.bind(
            host: "127.0.0.1",
            port: 0  // Auto-assign port
        ).get()

        self.channel = ch

        // Extract the assigned port
        if let addr = ch.localAddress {
            self.port = addr.port ?? 0
        }

        // Write port to file for discovery
        try "\(self.port)".write(toFile: portFilePath, atomically: true, encoding: .utf8)

        print("[HTTPServer] Listening on http://127.0.0.1:\(self.port)")
    }

    /// Stop the server and clean up.
    public func stop() async {
        do {
            try await channel?.close()
        } catch {
            // Already closed
        }
        try? await group.shutdownGracefully()
        try? FileManager.default.removeItem(atPath: portFilePath)
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
    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?

    init(router: RPCRouter) {
        self.router = router
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestHead = head
            bodyBuffer = context.channel.allocator.buffer(capacity: 0)

        case .body(var body):
            bodyBuffer?.writeBuffer(&body)

        case .end:
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

    private static func processRequest(_ bodyData: Data, router: RPCRouter, wrappedCtx: HTTPSendableContext) async {
        let response = await router.handleRaw(bodyData)

        do {
            let responseData = try JSONEncoder().encode(response)
            guard let responseString = String(data: responseData, encoding: .utf8) else { return }

            let context = wrappedCtx.context
            context.eventLoop.execute {
                guard context.channel.isActive else { return }
                Self.sendResponseOnLoop(context: context, status: .ok, body: responseString)
            }
        } catch {
            let context = wrappedCtx.context
            context.eventLoop.execute {
                guard context.channel.isActive else { return }
                Self.sendResponseOnLoop(context: context, status: .internalServerError,
                                        body: "{\"success\":false,\"error\":\"Failed to encode response\"}")
            }
        }
    }

    private func sendResponse(context: ChannelHandlerContext, status: HTTPResponseStatus, body: String) {
        Self.sendResponseOnLoop(context: context, status: status, body: body)
    }

    private static func sendResponseOnLoop(context: ChannelHandlerContext, status: HTTPResponseStatus, body: String) {
        let bodyData = body.utf8
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: "\(bodyData.count)")

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: bodyData.count)
        buffer.writeString(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("[HTTPServer] Error: \(error)")
        context.close(promise: nil)
    }
}
