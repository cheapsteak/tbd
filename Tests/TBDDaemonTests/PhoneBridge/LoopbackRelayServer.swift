import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

/// One request a ``LoopbackRelayServer`` received, upgraded or not.
struct LoopbackRelayRequest: Sendable, Equatable {
    let method: String
    /// The percent-encoded path, without the query.
    let path: String
    /// The percent-encoded query, without the `?`; nil when there is none.
    let query: String?
    let userAgent: String?
}

/// A real HTTP and WebSocket server on `127.0.0.1`, on a port the system
/// picks, for the tests of the URLSession relay transport and info client.
///
/// - It records every request's method, path, query and `User-Agent`.
/// - `GET /v1/info` answers with the status, body and headers
///   `setInfoResponse` last set: 200 and a TBD relay's info object at first.
/// - `GET /v1/redirect-target` answers 200 with a TBD relay's info object,
///   so a client that follows a redirect there would read a usable relay.
/// - `GET /v1/rooms/<anything>` upgrades to a WebSocket that echoes binary
///   frames, answers the text `ping` with `pong`, and closes with code 4000
///   on the text `close-4000`.
/// - `GET /v1/silent` is never answered; the connection stays open until the
///   client closes it. `silentConnections` counts those still open, and the
///   server keeps reading so that it sees the client's close.
/// - Every other request gets 404.
///
/// Test-only. Start one with `withLoopbackRelay`, which shuts it down
/// whatever the test does.
final class LoopbackRelayServer: Sendable {
    /// The relay URL to hand to the code under test: `http://127.0.0.1:<port>`.
    let baseURL: URL

    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let state: LoopbackRelayState

    private init(baseURL: URL, group: MultiThreadedEventLoopGroup, channel: Channel, state: LoopbackRelayState) {
        self.baseURL = baseURL
        self.group = group
        self.channel = channel
        self.state = state
    }

    /// Binds a new server to `127.0.0.1:0`.
    static func start() async throws -> LoopbackRelayServer {
        let state = LoopbackRelayState()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try Self.configure(channel, state: state)
                }
            }
        let channel: Channel
        do {
            channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        guard let port = channel.localAddress?.port, let url = URL(string: "http://127.0.0.1:\(port)") else {
            try? await channel.close()
            try? await group.shutdownGracefully()
            throw LoopbackRelayServerError.noPort
        }
        return LoopbackRelayServer(baseURL: url, group: group, channel: channel, state: state)
    }

    /// Every request so far, in arrival order.
    var requests: [LoopbackRelayRequest] {
        state.requests
    }

    /// How many `/v1/silent` connections are still open.
    var silentConnections: Int {
        state.silentConnections
    }

    /// The path a test can redirect `GET /v1/info` to; it answers like a
    /// TBD relay's `/v1/info`.
    static let redirectTargetPath = "/v1/redirect-target"

    /// Sets the status and body every later `GET /v1/info` gets, with a
    /// `Location` header when `location` is set. With `declaresLength`
    /// false, the answer carries no `Content-Length`, so a client learns the
    /// body's size only by reading it.
    func setInfoResponse(status: Int, body: String, location: String? = nil, declaresLength: Bool = true) {
        state.setInfoResponse(LoopbackInfoResponse(
            status: status, body: body, location: location, declaresLength: declaresLength))
    }

    /// Closes the listener and every connection, and stops the event loop.
    func shutdown() async {
        try? await channel.close()
        try? await group.shutdownGracefully()
    }

    /// The pipeline of one accepted connection: HTTP with a WebSocket
    /// upgrade for room paths. Runs on the connection's event loop.
    private static func configure(_ channel: Channel, state: LoopbackRelayState) throws {
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 1 << 20,
            shouldUpgrade: { channel, head in
                let request = LoopbackRelayState.request(from: head)
                guard request.path.hasPrefix("/v1/rooms/") else {
                    // Refused: the request goes on to the HTTP handler, which
                    // records it and answers 404.
                    return channel.eventLoop.makeSucceededFuture(nil)
                }
                state.record(request)
                return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, _ in
                channel.eventLoop.makeCompletedFuture {
                    // A client may split a large message into fragments; the
                    // echo handler sees each message whole.
                    try channel.pipeline.syncOperations.addHandler(NIOWebSocketFrameAggregator(
                        minNonFinalFragmentSize: 1,
                        maxAccumulatedFrameCount: 1 << 10,
                        maxAccumulatedFrameSize: 1 << 20))
                    try channel.pipeline.syncOperations.addHandler(LoopbackWebSocketHandler())
                }
            })
        let upgrade: NIOHTTPServerUpgradeConfiguration = (
            upgraders: [upgrader],
            completionHandler: { context in
                // The upgrade handler has removed the HTTP codec; the HTTP
                // handler goes too, before the first WebSocket frame.
                context.pipeline.syncOperations.removeHandler(name: LoopbackHTTPHandler.name, promise: nil)
            }
        )
        // No pipelining assistance. Its handler stops reading from the socket
        // while a response is pending, and on Darwin NIO learns that the peer
        // closed only by reading: it registers no kqueue filter for EOF
        // without read interest. An unanswered `/v1/silent` request would
        // then never see its client close, and `silentConnections` would
        // never fall. Every answer closes its connection, so there is no
        // second request to pipeline.
        try channel.pipeline.syncOperations.configureHTTPServerPipeline(
            withPipeliningAssistance: false, withServerUpgrade: upgrade)
        try channel.pipeline.syncOperations.addHandler(LoopbackHTTPHandler(state: state), name: LoopbackHTTPHandler.name)
    }
}

/// Runs `body` with a fresh ``LoopbackRelayServer`` and shuts the server down
/// afterwards, whether `body` returns or throws.
func withLoopbackRelay(_ body: (LoopbackRelayServer) async throws -> Void) async throws {
    let server = try await LoopbackRelayServer.start()
    do {
        try await body(server)
    } catch {
        await server.shutdown()
        throw error
    }
    await server.shutdown()
}

enum LoopbackRelayServerError: Error, LocalizedError {
    /// The bound listener reported no port.
    case noPort

    var errorDescription: String? {
        switch self {
        case .noPort:
            return "The loopback relay's listener reported no port."
        }
    }
}

/// What `GET /v1/info` answers.
private struct LoopbackInfoResponse: Sendable {
    var status: Int
    var body: String
    var location: String?
    var declaresLength: Bool
}

/// The server's shared state, written on the event loop and read by tests.
private final class LoopbackRelayState: @unchecked Sendable {
    // @unchecked: every stored property is read and written only under `lock`.

    static let tbdRelayInfo = #"{"name":"tbd-relay","version":"1.0.0","api":[1]}"#

    private let lock = NSLock()
    private var recorded: [LoopbackRelayRequest] = []
    private var info = LoopbackInfoResponse(
        status: 200, body: LoopbackRelayState.tbdRelayInfo, location: nil, declaresLength: true)
    private var silentOpen = 0

    var requests: [LoopbackRelayRequest] {
        lock.withLock { recorded }
    }

    var infoResponse: LoopbackInfoResponse {
        lock.withLock { info }
    }

    func setInfoResponse(_ response: LoopbackInfoResponse) {
        lock.withLock { info = response }
    }

    func record(_ request: LoopbackRelayRequest) {
        lock.withLock { recorded.append(request) }
    }

    var silentConnections: Int {
        lock.withLock { silentOpen }
    }

    func silentConnection(opened: Bool) {
        lock.withLock { silentOpen += opened ? 1 : -1 }
    }

    static func request(from head: HTTPRequestHead) -> LoopbackRelayRequest {
        let parts = URLComponents(string: head.uri)
        return LoopbackRelayRequest(
            method: head.method.rawValue,
            path: parts?.percentEncodedPath ?? head.uri,
            query: parts?.percentEncodedQuery,
            userAgent: head.headers.first(name: "user-agent"))
    }
}

/// Answers the requests that are not upgraded: `GET /v1/info`,
/// `GET /v1/redirect-target`, nothing for `/v1/silent`, and 404 for the
/// rest. Each answer closes its connection.
private final class LoopbackHTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    static let name = "loopback-relay-http"

    private let state: LoopbackRelayState
    private var head: HTTPRequestHead?
    /// Set while this connection holds an unanswered `/v1/silent` request.
    private var holdsSilentRequest = false

    init(state: LoopbackRelayState) {
        self.state = state
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch Self.unwrapInboundIn(data) {
        case .head(let requestHead):
            head = requestHead
            state.record(LoopbackRelayState.request(from: requestHead))
        case .body:
            break
        case .end:
            guard let requestHead = head else { return }
            head = nil
            let request = LoopbackRelayState.request(from: requestHead)
            if requestHead.method == .GET, request.path == "/v1/info" {
                let info = state.infoResponse
                respond(context: context, status: info.status, body: info.body, location: info.location,
                        declaresLength: info.declaresLength)
            } else if requestHead.method == .GET, request.path == LoopbackRelayServer.redirectTargetPath {
                respond(context: context, status: 200, body: LoopbackRelayState.tbdRelayInfo)
            } else if request.path == "/v1/silent" {
                holdsSilentRequest = true
                state.silentConnection(opened: true)
            } else {
                respond(context: context, status: 404, body: "not found")
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if holdsSilentRequest {
            holdsSilentRequest = false
            state.silentConnection(opened: false)
        }
        context.fireChannelInactive()
    }

    /// Without `declaresLength`, the answer carries no `Content-Length`, so
    /// the client learns the body's size only by reading it.
    private func respond(context: ChannelHandlerContext, status: Int, body: String, location: String? = nil,
                         declaresLength: Bool = true) {
        let bytes = Array(body.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        if declaresLength {
            headers.add(name: "Content-Length", value: "\(bytes.count)")
        }
        if let location {
            headers.add(name: "Location", value: location)
        }
        headers.add(name: "Connection", value: "close")
        let responseHead = HTTPResponseHead(
            version: .http1_1, status: HTTPResponseStatus(statusCode: status), headers: headers)
        context.write(Self.wrapOutboundOut(.head(responseHead)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.write(Self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        let channel = context.channel
        let written = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(Self.wrapOutboundOut(.end(nil)), promise: written)
        written.futureResult.whenComplete { _ in channel.close(promise: nil) }
    }
}

/// One upgraded room socket: echoes binary frames, answers `ping` with
/// `pong`, and closes with 4000 on `close-4000`.
private final class LoopbackWebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    /// Set once this end has sent a close frame; the client's answering close
    /// then ends the connection.
    private var sentClose = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = Self.unwrapInboundIn(data)
        switch frame.opcode {
        case .binary:
            send(context: context, opcode: .binary, data: frame.unmaskedData)
        case .text:
            var data = frame.unmaskedData
            let text = data.readString(length: data.readableBytes) ?? ""
            if text == "ping" {
                send(context: context, opcode: .text, data: context.channel.allocator.buffer(string: "pong"))
            } else if text == "close-4000" {
                sentClose = true
                var payload = context.channel.allocator.buffer(capacity: 2)
                payload.write(webSocketErrorCode: WebSocketErrorCode(codeNumber: 4000))
                send(context: context, opcode: .connectionClose, data: payload)
            }
        case .ping:
            send(context: context, opcode: .pong, data: frame.unmaskedData)
        case .connectionClose:
            if sentClose {
                context.close(promise: nil)
                return
            }
            // The client closed first: answer with its code, then close.
            sentClose = true
            var data = frame.unmaskedData
            let code = data.readSlice(length: 2) ?? context.channel.allocator.buffer(capacity: 0)
            let channel = context.channel
            let written = context.eventLoop.makePromise(of: Void.self)
            context.writeAndFlush(
                Self.wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: code)),
                promise: written)
            written.futureResult.whenComplete { _ in channel.close(promise: nil) }
        default:
            break
        }
    }

    private func send(context: ChannelHandlerContext, opcode: WebSocketOpcode, data: ByteBuffer) {
        context.writeAndFlush(Self.wrapOutboundOut(WebSocketFrame(fin: true, opcode: opcode, data: data)), promise: nil)
    }
}
