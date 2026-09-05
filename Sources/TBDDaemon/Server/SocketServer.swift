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

    /// Identity of the socket file this server actually bound, read from the
    /// path right after `bind(2)`. `nil` until a successful bind, and again
    /// once `stop()` has settled the file.
    ///
    /// This is what licenses the unlink in `stop()`. See
    /// `unlinkOwnedSocketFile()`.
    ///
    /// Only ever read through `takeBoundSocketIdentity()`, which reads and
    /// clears it under `identityLock`. `stop()` runs its body once, so in
    /// practice one shutdown reaches the claim — but the claim also races the
    /// tail of `start()`, which stores the identity from whichever task ran
    /// the bind. A plain read-then-nil would let a claimant see a half-written
    /// claim, and a claimant that comes away with an identity goes on to
    /// unlink against it. Reading and clearing under the lock keeps that
    /// atomic.
    private nonisolated(unsafe) var boundSocketIdentity: SocketFileIdentity?
    private let identityLock = NSLock()

    /// Keeps the shutdown to one run, however many `stop()` calls arrive. See
    /// `ShutdownLatch` for why a second run would hang rather than merely
    /// repeat itself.
    private let shutdownLatch = ShutdownLatch()

    /// Runs in `start()` between `bind(2)` and NIO adopting the bound
    /// descriptor, and may throw to fail the start from inside that window.
    /// `nil` in production, where the window holds nothing but the handover.
    ///
    /// The window is the one a successor daemon can bind the path in, so it is
    /// where a failed start can be caught deleting somebody else's socket. The
    /// failures that actually occur there are NIO refusing the descriptor —
    /// kernel-level refusals no in-process test can provoke without either
    /// hanging (a shut-down event loop drops the submitted task and the future
    /// never completes) or tripping NIO's own debug assertions on a
    /// half-constructed channel. So the seam exists to make that cleanup
    /// reachable, and it is handed the descriptor so a caller that fails the
    /// start can close it rather than leak it.
    private let beforeAdoptingBoundSocket: (@Sendable (Int32) async throws -> Void)?

    /// Runs inside `takeBoundSocketIdentity()`, after the identity is read and
    /// before it is cleared, and is handed what the claimant came away with.
    /// `nil` in production.
    ///
    /// It serves two tests. Counting the non-`nil` identities it is handed is
    /// how "the socket file was claimed exactly once" is observed from inside
    /// a real `stop()`, which has no other outward sign. And the read-and-clear
    /// window is a few instructions wide, so no test can land inside it by
    /// timing alone; blocking here holds it open so contention is reproducible.
    private let duringIdentityClaim: (@Sendable (SocketFileIdentity?) -> Void)?

    /// Number of currently connected clients. Updated atomically.
    private let _connectedClients = ManagedAtomic<Int>(0)

    /// Bounds the number of concurrently-running RPC handlers (and thus the
    /// concurrent git/gh subprocess fan-out) across all connections.
    private let limiter = RPCConcurrencyLimiter()

    public var connectedClients: Int {
        _connectedClients.load(ordering: .relaxed)
    }

    public convenience init(router: RPCRouter, socketPath: String? = nil) {
        self.init(router: router, socketPath: socketPath, beforeAdoptingBoundSocket: nil)
    }

    init(
        router: RPCRouter,
        socketPath: String?,
        beforeAdoptingBoundSocket: (@Sendable (Int32) async throws -> Void)?,
        duringIdentityClaim: (@Sendable (SocketFileIdentity?) -> Void)? = nil
    ) {
        self.router = router
        // See HookResolver — resolve here, not at the caller's site.
        self.socketPath = socketPath ?? TBDConstants.socketPath
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.beforeAdoptingBoundSocket = beforeAdoptingBoundSocket
        self.duringIdentityClaim = duringIdentityClaim
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

        // The backlog is deliberately not set here: this bootstrap is handed an
        // already-bound descriptor (below), and NIO listens on it while
        // constructing the channel — before any server-channel option is
        // applied — so the accept queue takes NIO's own default of 128. That is
        // strictly more forgiving than the 64 it replaces, which matters because
        // a full accept queue is indistinguishable from a dead socket at the
        // client's `connect(2)`.
        let bootstrap = ServerBootstrap(group: group)
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

        // Bind the socket here and hand NIO the descriptor, rather than calling
        // `bind(unixDomainSocketPath:)` and letting NIO do it.
        //
        // NIO's own bind marks the server socket `cleanupOnClose`, and that
        // cleanup runs `unlink(2)` on the *path* the socket was bound to when
        // the channel closes — its only check is that something at that path is
        // a socket, never that it is still the socket this process created. So
        // a daemon shutting down deletes the rendezvous file that a successor
        // daemon has since bound, and the successor keeps accepting on a
        // listener no client can reach. Handing NIO a descriptor that is
        // already bound sets `cleanupOnClose` to false — "socket already bound,
        // owner must clean up" — which is what puts the unlink under the
        // ownership check in `unlinkOwnedSocketFile()`.
        let boundFD = try Self.bindListeningSocket(at: socketPath)
        // Read the file's identity as close to `bind(2)` as possible, before
        // any await gives a successor the chance to replace it. A successor
        // daemon's `start()` unlinks whatever is at this path and binds a fresh
        // socket, so the inode is what separates our file from theirs.
        let identity = SocketFileIdentity(path: socketPath)
        let ch: Channel
        do {
            try await beforeAdoptingBoundSocket?(boundFD)
            ch = try await bootstrap.withBoundSocket(boundFD).get()
        } catch {
            // Do not close `boundFD` here: NIO takes ownership of the
            // descriptor as soon as it wraps it, and closing a descriptor
            // another layer already closed can later shut down an unrelated
            // reused one.
            //
            // Reclaim the socket file under the same ownership check the
            // shutdown path uses. `identity` was true of the path at the
            // instant it was read, and the `await` above is a suspension
            // point: a successor daemon's `start()` can run inside it,
            // unlinking our file and binding its own. Removing on existence
            // alone here would delete the successor's live socket — the bug
            // `unlinkOwnedSocketFile()` exists to prevent, reached through a
            // failed start instead of a shutdown.
            unlinkSocketFile(ifStillIdentity: identity)
            throw error
        }

        self.channel = ch
        storeBoundSocketIdentity(identity)
        logger.info("Listening on \(self.socketPath, privacy: .public)")
    }

    /// Stop the server and clean up. Safe to call any number of times, from
    /// any number of tasks at once: the body below runs once and every caller
    /// returns only when it has finished. See `ShutdownLatch`.
    public func stop() async {
        await shutdownLatch.run {
            do {
                try await self.channel?.close()
            } catch {
                // Already closed
            }
            try? await self.group.shutdownGracefully()
            self.unlinkOwnedSocketFile()
        }
    }

    /// Create an `AF_UNIX` stream socket and `bind(2)` it at `path`, returning
    /// the bound descriptor for NIO to adopt.
    ///
    /// Only creation and bind happen here. NIO sets the descriptor
    /// non-blocking and calls `listen(2)` on it while it builds the channel,
    /// exactly as it would for a socket it had made itself. What changes is
    /// ownership of the *file*: because NIO did not open the path, it will not
    /// unlink the path when the channel closes, and `stop()` decides that
    /// instead.
    private static func bindListeningSocket(at path: String) throws -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            throw SocketServerStartError.socketPathTooLong(path: path, limit: capacity - 1)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketServerStartError.socketCreationFailed(code: errno)
        }

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw SocketServerStartError.bindFailed(path: path, code: code)
        }

        // Restrict the socket before anything can connect to it. NIO's listen
        // comes later, so there is no window here where the file is reachable
        // at the old mode.
        chmod(path, 0o700)
        return fd
    }

    /// Reclaim the socket file this server bound, if it is still there and
    /// still ours. The claim is taken exactly once, so anything that reaches
    /// this a second time finds nothing to claim and does nothing.
    private func unlinkOwnedSocketFile() {
        guard let bound = takeBoundSocketIdentity() else {
            // Never bound, or already claimed by another shutdown. Nothing
            // here is ours.
            return
        }
        unlinkSocketFile(ifStillIdentity: bound)
    }

    /// Record the identity of the file this server just bound. Held under
    /// `identityLock` so a shutdown racing the tail of `start()` sees either
    /// the whole claim or none of it.
    private func storeBoundSocketIdentity(_ identity: SocketFileIdentity?) {
        identityLock.lock()
        defer { identityLock.unlock() }
        boundSocketIdentity = identity
    }

    /// Read and clear `boundSocketIdentity` in one step, so overlapping
    /// shutdowns cannot both come away holding the claim.
    ///
    /// Internal rather than private so a test can call it concurrently and
    /// count the claimants: "at most one" is the whole guarantee, and it is
    /// not observable from the outside once the losers have correctly done
    /// nothing. `stop()` no longer runs twice, so this lock is the second line
    /// of that defence rather than the first — it still stands between a
    /// shutdown and the `start()` that is storing the claim.
    func takeBoundSocketIdentity() -> SocketFileIdentity? {
        identityLock.lock()
        defer { identityLock.unlock() }
        let claimed = boundSocketIdentity
        duringIdentityClaim?(claimed)
        boundSocketIdentity = nil
        return claimed
    }

    /// Remove the file at `socketPath` **only if it is still the one whose
    /// identity is `identity`.**
    ///
    /// The socket path is a rendezvous every daemon generation binds in turn,
    /// so existence at that path proves nothing about who owns it. A successor
    /// that has already bound is the common case: it unlinked our file and
    /// created its own under the same name. Unlinking on existence alone
    /// deletes the successor's socket, and it never finds out — it keeps
    /// accepting on an open listener no client can reach any more, and every
    /// client fails against a path that is simply gone.
    ///
    /// The honest primitive is the file's identity, not its name: `(st_dev,
    /// st_ino)` captured immediately after `bind(2)` names one inode, and a
    /// successor's `bind(2)` always makes a different one. So the unlink is
    /// gated on that identity still being what sits at the path.
    ///
    /// A residual window of microseconds remains between the `lstat(2)` and the
    /// `unlink(2)`, lost only if a successor unlinks our file and binds its own
    /// inside it — darwin has no unlink-if-inode primitive to close it with. It
    /// is accepted on width; the unconditional unlink it replaces lost the same
    /// race for the whole of every shutdown.
    ///
    /// Both places that reclaim the file come through here — the shutdown in
    /// `stop()`, and the cleanup of a `start()` that failed after `bind(2)`.
    /// The hazard is the same either way: between capturing the identity and
    /// unlinking, a successor daemon may have taken the path over.
    private func unlinkSocketFile(ifStillIdentity identity: SocketFileIdentity?) {
        guard let bound = identity else {
            // The `lstat(2)` after `bind(2)` found nothing, so this server can
            // name no file as its own. Claim nothing.
            return
        }
        guard let current = SocketFileIdentity(path: socketPath) else {
            // Already gone — reclaimed by a successor's `start()`, or by hand.
            return
        }
        guard current == bound else {
            let boundInode = bound.inode
            let currentInode = current.inode
            logger.info(
                "Leaving socket at \(self.socketPath, privacy: .public) in place: it is now inode \(currentInode, privacy: .public), not the \(boundInode, privacy: .public) this server bound"
            )
            return
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }
}

// MARK: - Start errors

/// Why binding the RPC socket failed. These are all fatal to daemon startup;
/// they exist so the failure names itself instead of arriving as a bare errno.
public enum SocketServerStartError: Error, LocalizedError, CustomStringConvertible {
    case socketPathTooLong(path: String, limit: Int)
    case socketCreationFailed(code: Int32)
    case bindFailed(path: String, code: Int32)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .socketPathTooLong(let path, let limit):
            return "socket path is \(path.utf8.count) bytes, over the \(limit)-byte sun_path limit: \(path)"
        case .socketCreationFailed(let code):
            return "socket(AF_UNIX, SOCK_STREAM): \(String(cString: strerror(code)))"
        case .bindFailed(let path, let code):
            return "bind(2) on \(path): \(String(cString: strerror(code)))"
        }
    }
}

// MARK: - Socket file identity

/// The identity of a file on disk — `(st_dev, st_ino)` — as distinct from its
/// path. Two sockets bound in turn at one path are two different inodes, and
/// that is the only thing that tells them apart.
struct SocketFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    /// Reads the identity of whatever is at `path`, or `nil` if nothing is.
    ///
    /// `lstat` rather than `stat`: a symlink swapped in at the path is not the
    /// socket we bound, and must not be mistaken for it.
    ///
    /// By the path, and not by `fstat(2)` on the bound descriptor, however
    /// tempting the tighter window looks: on darwin the two do not name the
    /// same thing. `fstat(2)` on a bound `AF_UNIX` descriptor reports the
    /// socket's own in-kernel vnode — a different inode, with `st_dev` of -1 —
    /// not the filesystem entry `bind(2)` created. Measured on darwin 25.1:
    /// `fstat` answered `dev=-1 ino=15302332` for a socket whose path
    /// `lstat`ed as `dev=16777235 ino=863366896`. An identity captured that
    /// way could never equal the one read back from the path, so every
    /// ownership check would fail closed and the socket file would never be
    /// reclaimed at all.
    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        self.device = info.st_dev
        self.inode = info.st_ino
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
                // EventLoop is Sendable; .eventLoop is the one property NIO
                // permits off-loop. Unwrap the context INSIDE the closure so
                // all channel access stays on the loop.
                let eventLoop = sendableCtx.context.eventLoop
                eventLoop.execute {
                    let context = sendableCtx.context
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
            let eventLoop = sendableCtx.context.eventLoop
            eventLoop.execute {
                let context = sendableCtx.context
                context.channel.closeFuture.whenComplete { _ in
                    router.removeSubscription(id: subID)
                }
            }

            // Send initial ack so the client knows subscription is active
            let ack = RPCResponse.ok()
            if let ackData = try? JSONEncoder().encode(ack),
               let ackString = String(data: ackData, encoding: .utf8) {
                eventLoop.execute {
                    let context = sendableCtx.context
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

            let eventLoop = wrappedCtx.context.eventLoop
            eventLoop.execute {
                let context = wrappedCtx.context
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
