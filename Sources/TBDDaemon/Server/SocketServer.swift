import Foundation
import NIOCore
import NIOPosix
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "socket")
private let perfLogger = Logger(subsystem: "com.tbd.daemon", category: "perf-rpc")

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

    /// Bounds the number of concurrently-running RPC handlers (and thus the
    /// concurrent git/gh subprocess fan-out) across all connections.
    private let limiter = RPCConcurrencyLimiter()

    public var connectedClients: Int {
        _connectedClients.load(ordering: .relaxed)
    }

    public init(router: RPCRouter, socketPath: String? = nil) {
        self.router = router
        // See HookResolver — resolve here, not at the caller's site.
        self.socketPath = socketPath ?? TBDConstants.socketPath
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
        let limiter = self.limiter

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 64)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = SocketRPCHandler(
                        router: router,
                        connectedClients: connectedClients,
                        limiter: limiter
                    )
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }

        let ch = try await bootstrap.bind(
            unixDomainSocketPath: socketPath
        ).get()

        // Set socket permissions so any local user can connect
        chmod(socketPath, 0o700)

        self.channel = ch
        logger.info("Listening on \(self.socketPath, privacy: .public)")
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
    private let limiter: RPCConcurrencyLimiter
    private var buffer: String = ""

    init(router: RPCRouter, connectedClients: ManagedAtomic<Int>, limiter: RPCConcurrencyLimiter) {
        self.router = router
        self.connectedClients = connectedClients
        self.limiter = limiter
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
            let limiter = self.limiter
            Task {
                await Self.processLine(trimmed, router: router, limiter: limiter, wrappedCtx: wrappedCtx)
            }
        }
    }

    private static func processLine(
        _ line: String,
        router: RPCRouter,
        limiter: RPCConcurrencyLimiter,
        wrappedCtx: SendableContext
    ) async {
        guard let data = line.data(using: .utf8) else { return }

        // Decode once: the subscribe check needs the method, and the normal
        // path reuses it for the signpost label + in-flight gauge.
        let request = try? JSONDecoder().decode(RPCRequest.self, from: data)

        // Check for state.subscribe — handle as a streaming subscription.
        // This path BYPASSES the concurrency limiter: it holds its socket open
        // indefinitely and must never occupy a limiter slot.
        if request?.method == RPCMethod.stateSubscribe {
            let sendableCtx = wrappedCtx

            // Register subscriber; callback streams deltas as newline-delimited JSON.
            // The callback may be invoked from any thread (via broadcast), so all
            // ChannelHandlerContext access must be dispatched to the event loop.
            // Accessing context.channel off the event loop hits a NIO precondition.
            let subID = router.registerSubscription { deltaData in
                let context = sendableCtx.context
                context.eventLoop.execute {
                    guard context.channel.isActive else { return }
                    guard let deltaString = String(data: deltaData, encoding: .utf8) else { return }
                    var outBuffer = context.channel.allocator.buffer(capacity: deltaString.utf8.count + 1)
                    outBuffer.writeString(deltaString)
                    outBuffer.writeString("\n")
                    context.writeAndFlush(Self.wrapOutboundOut(outBuffer), promise: nil)
                }
                // Always return true; closeFuture handler does definitive cleanup
                return true
            }

            // Clean up subscription when the channel closes.
            // Must access context.channel on the event loop.
            let context = sendableCtx.context
            context.eventLoop.execute {
                context.channel.closeFuture.whenComplete { _ in
                    router.removeSubscription(id: subID)
                }
            }

            // Send initial ack so the client knows subscription is active
            let ack = RPCResponse.ok()
            if let ackData = try? JSONEncoder().encode(ack),
               let ackString = String(data: ackData, encoding: .utf8) {
                context.eventLoop.execute {
                    guard context.channel.isActive else { return }
                    var outBuffer = context.channel.allocator.buffer(capacity: ackString.utf8.count + 1)
                    outBuffer.writeString(ackString)
                    outBuffer.writeString("\n")
                    context.writeAndFlush(Self.wrapOutboundOut(outBuffer), promise: nil)
                }
            }

            // Return WITHOUT closing — this is a long-lived streaming connection
            return
        }

        // Normal (non-subscribe) request path. Gate on the concurrency limiter
        // so a connection burst can't spawn unbounded concurrent handlers (and
        // their git/gh subprocesses). The expensive work is `handleRaw`; the
        // slot is released as soon as it returns (response encoding below does
        // no subprocess fan-out). `release()` is an actor method and so cannot
        // run from a `defer`, but there is no throwing/early-exit point between
        // acquire and release, so the slot is always returned.
        let method = request?.method ?? "unknown"
        let inFlight = await limiter.acquire()
        // Cheap in-flight gauge: only log when contention is notable, never at
        // info on every request.
        if inFlight > RPCConcurrencyLimiter.maxConcurrentRPCs / 2 {
            perfLogger.debug("rpc in-flight high: \(inFlight, privacy: .public)")
        }

        let signposter = RPCSignposts.signposter
        let signpostID = signposter.makeSignpostID()
        let intervalState = signposter.beginInterval("rpc.handle", id: signpostID, "\(method, privacy: .public)")
        let response = await router.handleRaw(data)
        signposter.endInterval("rpc.handle", intervalState)

        await limiter.release()

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
        logger.error("Error: \(error.localizedDescription, privacy: .public)")
        context.close(promise: nil)
    }
}
