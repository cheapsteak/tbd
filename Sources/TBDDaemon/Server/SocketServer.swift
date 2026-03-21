import Foundation
import NIOCore
import NIOPosix
import TBDShared

/// A Unix domain socket server that accepts newline-delimited JSON RPC requests.
///
/// Each line received is parsed as an `RPCRequest`, routed through `RPCRouter`,
/// and the `RPCResponse` is written back as JSON + newline.
public final class SocketServer: Sendable {
    private let router: RPCRouter
    private let socketPath: String
    private let group: MultiThreadedEventLoopGroup
    private nonisolated(unsafe) var channel: Channel?

    /// Number of currently connected clients. Updated atomically.
    private let _connectedClients = ManagedAtomic<Int>(0)

    public var connectedClients: Int {
        _connectedClients.load(ordering: .relaxed)
    }

    public init(router: RPCRouter, socketPath: String = TBDConstants.socketPath) {
        self.router = router
        self.socketPath = socketPath
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    /// Start listening on the Unix domain socket.
    public func start() async throws {
        // Clean up stale socket file
        let fm = FileManager.default
        if fm.fileExists(atPath: socketPath) {
            try fm.removeItem(atPath: socketPath)
        }

        let router = self.router
        let connectedClients = self._connectedClients

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 64)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = SocketRPCHandler(router: router, connectedClients: connectedClients)
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }

        let ch = try await bootstrap.bind(
            unixDomainSocketPath: socketPath
        ).get()

        // Set socket permissions so any local user can connect
        chmod(socketPath, 0o700)

        self.channel = ch
        print("[SocketServer] Listening on \(socketPath)")
    }

    /// Stop the server and clean up.
    public func stop() async {
        do {
            try await channel?.close()
        } catch {
            // Already closed
        }
        try? await group.shutdownGracefully()
        try? FileManager.default.removeItem(atPath: socketPath)
    }
}

// MARK: - Atomics helper

/// Simple atomic integer using os_unfair_lock for Swift 6 Sendable compliance.
private final class ManagedAtomic<Value: Sendable>: Sendable where Value: FixedWidthInteger {
    private nonisolated(unsafe) var _value: Value
    private let lock = NSLock()

    init(_ initialValue: Value) {
        self._value = initialValue
    }

    func load(ordering: AtomicOrdering = .relaxed) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    @discardableResult
    func wrappingIncrementThenLoad(ordering: AtomicOrdering = .relaxed) -> Value {
        lock.lock()
        defer { lock.unlock() }
        _value &+= 1
        return _value
    }

    @discardableResult
    func wrappingDecrementThenLoad(ordering: AtomicOrdering = .relaxed) -> Value {
        lock.lock()
        defer { lock.unlock() }
        _value &-= 1
        return _value
    }

    enum AtomicOrdering {
        case relaxed
    }
}

// MARK: - Sendable context wrapper

/// Wraps a ChannelHandlerContext for use across Task boundaries.
/// Safe because we always dispatch back to the event loop before using it.
private struct SendableContext: @unchecked Sendable {
    let context: ChannelHandlerContext
}

// MARK: - NIO Channel Handler

/// Handles individual socket connections. Reads newline-delimited JSON,
/// routes through RPCRouter, and writes back JSON + newline.
private final class SocketRPCHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let router: RPCRouter
    private let connectedClients: ManagedAtomic<Int>
    private var buffer: String = ""

    init(router: RPCRouter, connectedClients: ManagedAtomic<Int>) {
        self.router = router
        self.connectedClients = connectedClients
    }

    func channelActive(context: ChannelHandlerContext) {
        connectedClients.wrappingIncrementThenLoad()
    }

    func channelInactive(context: ChannelHandlerContext) {
        connectedClients.wrappingDecrementThenLoad()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var inBuffer = unwrapInboundIn(data)
        guard let received = inBuffer.readString(length: inBuffer.readableBytes) else { return }

        buffer.append(received)

        // Process complete lines (newline-delimited JSON)
        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newlineIndex])
            buffer = String(buffer[buffer.index(after: newlineIndex)...])

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let wrappedCtx = SendableContext(context: context)
            let router = self.router
            Task {
                await Self.processLine(trimmed, router: router, wrappedCtx: wrappedCtx)
            }
        }
    }

    private static func processLine(_ line: String, router: RPCRouter, wrappedCtx: SendableContext) async {
        guard let data = line.data(using: .utf8) else { return }

        let response = await router.handleRaw(data)

        do {
            let responseData = try JSONEncoder().encode(response)
            guard let responseString = String(data: responseData, encoding: .utf8) else { return }

            let context = wrappedCtx.context
            context.eventLoop.execute {
                guard context.channel.isActive else { return }
                var outBuffer = context.channel.allocator.buffer(capacity: responseString.utf8.count + 1)
                outBuffer.writeString(responseString)
                outBuffer.writeString("\n")
                context.writeAndFlush(Self.wrapOutboundOut(outBuffer), promise: nil)
            }
        } catch {
            // Encoding error - skip
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("[SocketServer] Error: \(error)")
        context.close(promise: nil)
    }
}
