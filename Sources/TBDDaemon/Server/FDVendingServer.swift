import Darwin
import Foundation
import TBDShared
import os

enum FDVendingServerError: Error, Equatable {
    case notConnected
    case bindFailed(Int32)
    case listenFailed(Int32)
}

/// Lock-protected connection-epoch counter, readable off-actor (R5-M2). Each
/// `adoptConnection` advances the epoch and stamps its receive thread with the
/// new value; a receive thread checks its stamp against `current()` before
/// EVERY frame delivery. The sinks run synchronously on the reader thread, so
/// the check must not hop to the actor — the same lock-boxed nonisolated
/// pattern as the supervisor's layout-change filter. This closes the reconnect
/// interleave hole: an old thread past its `read()` and mid-loop over buffered
/// frames could otherwise keep delivering into the SAME `onInput`/`onPaste`
/// sinks concurrently with the new thread, breaking wire order == stream order.
private final class ConnectionEpochBox: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    /// Advance to (and return) the next epoch — one per adopted connection.
    func advance() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        epoch += 1
        return epoch
    }
    func current() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return epoch
    }
}

/// A tiny per-daemon service that holds the sidecar socket the app connects to.
/// Phase 2 has exactly one client (the app), so at most one connection is
/// adopted at a time; a new adoption replaces the old one.
///
/// M2.1 promotes the sidecar to a **bidirectional framed data channel**:
/// - daemon → app: `send(fd:header:)` vends a pane read fd wrapped in a
///   length-prefixed `.fdVend` frame (unchanged semantics, now framed).
/// - app → daemon: keystroke `.input` and bulk `.paste` frames, decoded on a
///   dedicated receive `Thread` and delivered via `onInput`/`onPaste`.
///
/// **fd ownership: readers signal, the actor closes.** Each adopted connection
/// gets a receive thread, but the thread NEVER closes the connection fd. On loop
/// exit (EOF, read error, or scanner desync) it hops back onto the actor via
/// `receiveLoopExited(fd:)`, which clears `clientFD` (if it still names this fd)
/// and performs the sole `Darwin.close(fd)`. `adoptConnection`/`disconnect`/`stop`
/// only `shutdown(fd, SHUT_RDWR)` to wake the reader — on Darwin, `close()`ing a
/// socket out from under a thread blocked in `read()` does NOT wake it, but
/// `shutdown()` does; the reader then unblocks and signals its own exit.
///
/// Making the actor the sole closer closes a stale-fd hole: if the reader closed
/// the fd on EOF while `clientFD` still held that number, the kernel could recycle
/// the number for an unrelated pipe/accept/open, and a later `send(fd:header:)`
/// would `sendmsg()` a vend frame into that UNRELATED fd (cross-fd corruption).
/// By clearing `clientFD` before/with the close, `send()` sees `clientFD < 0` and
/// refuses with `.notConnected` instead of writing into a recycled fd.
///
/// The accept loop and each receive loop run on dedicated `Thread`s — the house
/// pattern for indefinitely-blocking syscalls (see `TmuxControlConnection`).
actor FDVendingServer {
    private let logger = Logger(subsystem: "com.tbd.daemon", category: "fdVending")
    private var clientFD: Int32 = -1
    /// Per-connection epoch (see `ConnectionEpochBox`): advanced by every
    /// `adoptConnection`, so a superseded receive thread detects — before each
    /// frame delivery — that a newer connection owns the sinks, and drops out.
    private let epochBox = ConnectionEpochBox()
    /// Path of the listening socket, when one is bound. Nil when the server is
    /// running purely off adopted fds (unit tests).
    private var socketPath: String?
    private var listenerFD: Int32 = -1

    /// How many times `send(fd:header:)` checks for an adopted client before
    /// giving up, and how long it waits between checks. `retryAttempts` checks
    /// are separated by `retryAttempts - 1` waits, so the default 10/50 ms pair
    /// is a 450 ms window — the pre-seam behaviour, unchanged.
    private let retryAttempts: Int
    private let retryInterval: Duration
    /// Delay seam (`docs/specs/2026-07-24-test-hardening-design.md` §5).
    /// Existential, not generic: this is an `actor` carrying `Sendable`
    /// conformances, and a generic parameter would infect its type.
    private let clock: any Clock<Duration>

    init(retryAttempts: Int = 10,
         retryInterval: Duration = .milliseconds(50),
         clock: any Clock<Duration> = ContinuousClock()) {
        self.retryAttempts = retryAttempts
        self.retryInterval = retryInterval
        self.clock = clock
    }

    /// Sink for app → daemon input frames. Set once by the daemon wiring BEFORE
    /// `listen`/`adoptConnection` (M2.2 delivers keystrokes here). Captured per
    /// connection at adopt time. When nil, input frames are logged and dropped.
    var onInput: (@Sendable (SidecarInputHeader, Data) -> Void)?

    /// Sink for app → daemon bulk `.paste` frames (the M2 paste ruling). Same
    /// contract as `onInput`: set once by the daemon wiring BEFORE
    /// `listen`/`adoptConnection`, captured per connection at adopt time. When
    /// nil, paste frames are logged and dropped. Delivered from the SAME receive
    /// thread as `onInput`, so wire order is preserved into the sinks.
    var onPaste: (@Sendable (SidecarInputHeader, Data) -> Void)?

    /// Test seam: invoked from `receiveLoopExited` (on the actor) AFTER `clientFD`
    /// is cleared and the fd closed, so once it fires the stale fd is fully gone —
    /// tests can await deterministic post-cleanup state instead of sleeping.
    var onReceiveLoopExit: (@Sendable () -> Void)?

    /// Install the input sink. Must be called BEFORE `listen`/`adoptConnection`
    /// — each connection captures the current sink at adopt time.
    func setOnInput(_ handler: (@Sendable (SidecarInputHeader, Data) -> Void)?) {
        onInput = handler
    }

    /// Install the paste sink. Must be called BEFORE `listen`/`adoptConnection`
    /// — each connection captures the current sink at adopt time.
    func setOnPaste(_ handler: (@Sendable (SidecarInputHeader, Data) -> Void)?) {
        onPaste = handler
    }

    /// Install the receive-loop-exit test hook (see `onReceiveLoopExit`).
    func setOnReceiveLoopExit(_ handler: (@Sendable () -> Void)?) {
        onReceiveLoopExit = handler
    }

    /// Start listening on `path`. Any existing file at `path` is removed first.
    /// Only meaningful in the live daemon; tests should call `adoptConnection`
    /// directly.
    func listen(on path: String) throws {
        precondition(listenerFD == -1, "listen called twice")
        _ = unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw FDVendingServerError.bindFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { dstChars in
                    _ = strlcpy(dstChars, src, sunPathSize)
                }
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(fd, generic, addrLen)
            }
        }
        if bindResult < 0 {
            Darwin.close(fd)
            throw FDVendingServerError.bindFailed(errno)
        }
        if Darwin.listen(fd, 1) < 0 {
            Darwin.close(fd)
            throw FDVendingServerError.listenFailed(errno)
        }
        listenerFD = fd
        socketPath = path
        logger.info("FD vending sidecar listening at \(path, privacy: .public)")

        // Dedicated accept thread: blocks in accept(); hands each connection
        // back into the actor. Exits when the listener fd is closed (accept
        // returns -1/EBADF after stop()).
        let listener = fd
        let thread = Thread { [weak self] in
            while true {
                var peer = sockaddr()
                var len = socklen_t(MemoryLayout<sockaddr>.size)
                let accepted = accept(listener, &peer, &len)
                guard accepted >= 0 else { return }   // listener closed (stop) or fatal
                Task { [weak self] in await self?.adoptConnection(fd: accepted) }
            }
        }
        thread.name = "fd-vending-accept"
        thread.stackSize = 256 * 1024
        thread.start()
    }

    /// Adopt a pre-connected socket fd. Ownership transfers here — do not close
    /// it in the caller. Replaces (and signals teardown of) any prior
    /// connection, then starts this connection's receive thread.
    func adoptConnection(fd: Int32) {
        if clientFD >= 0 {
            shutdown(clientFD, SHUT_RDWR)   // wake the old reader; it will close its own fd
            clientFD = -1
        }
        clientFD = fd
        // The old reader will later call `receiveLoopExited(oldFD)`; its
        // `clientFD == fd` guard ensures that stale signal does NOT clear this
        // freshly-adopted `clientFD` (different fd number). Advancing the epoch
        // BEFORE the new thread starts supersedes the old thread's deliveries:
        // even if it is past its read() with frames still buffered, its next
        // per-frame epoch check fails and it drops out (R5-M2).
        let epoch = epochBox.advance()
        startReceiveThread(fd: fd, epoch: epoch, inputSink: onInput, pasteSink: onPaste)
        logger.info("FD vending client connected (fd \(fd, privacy: .public))")
    }

    /// Sole close path for a connection fd. Invoked (on the actor) by a receive
    /// thread after its read loop exits. The reader has already left `read()`, so
    /// closing here is safe. Clearing `clientFD` first is what stops a later
    /// `send()` from writing a vend frame into a recycled fd number.
    func receiveLoopExited(fd: Int32) {
        if clientFD == fd { clientFD = -1 }   // guard: a newer adopt may own a different fd now
        Darwin.close(fd)
        onReceiveLoopExit?()
    }

    /// Close the current client connection (if any) without stopping the
    /// listener. Signals the reader, which performs the actual `close()`.
    func disconnect() {
        if clientFD >= 0 {
            shutdown(clientFD, SHUT_RDWR)
            clientFD = -1
        }
    }

    /// Stop the listener and drop any active client. Idempotent. Closing the
    /// listener fd makes the accept thread's blocked `accept()` return -1,
    /// which exits the thread.
    func stop() {
        if listenerFD >= 0 { Darwin.close(listenerFD); listenerFD = -1 }
        if let path = socketPath { _ = unlink(path); socketPath = nil }
        disconnect()
    }

    /// Send `fd` plus `header` to the currently connected app client, wrapped in
    /// a `.fdVend` frame. Retries briefly while no client is adopted — the app
    /// connects eagerly at startup, so this only papers over a connect-vs-accept
    /// race measured in milliseconds. `retryAttempts` connection checks spaced
    /// by `retryInterval` (see those properties for the window arithmetic).
    ///
    /// `clientFD` is re-read on EVERY iteration, never captured before the
    /// loop, so a client adopted mid-window is picked up and — just as
    /// importantly — a connection torn down mid-window is NOT vended into after
    /// its fd number was closed and possibly recycled. The frame is encoded once
    /// up front because it depends only on `header`, not on the connection.
    func send(fd: Int32, header: Data) async throws {
        let frame = SidecarFrameCodec.encode(type: .fdVend, payload: header)
        for attempt in 0..<retryAttempts {
            if clientFD >= 0 {
                try FDChannel.sendFD(fd, over: clientFD, frame: frame)
                return
            }
            // No cancellation check, deliberately: `try?` swallows the
            // `CancellationError`, the remaining attempts then burn instantly
            // and the loop throws `.notConnected` — the same outcome, which the
            // sole caller already handles by undoing the attach. That
            // equivalence holds only because the post-wait step is a pure
            // re-check that either sends or gives up; it stops being safe if
            // this loop ever grows a side effect that must not run after
            // cancellation, at which point it needs a real
            // `Task.checkCancellation()`.
            if attempt < retryAttempts - 1 { try? await clock.sleep(for: retryInterval) }
        }
        throw FDVendingServerError.notConnected
    }

    /// Spawn the receive thread for one connection. The thread reads framed
    /// bytes, decodes `.input` frames to `inputSink` and `.paste` frames to
    /// `pasteSink`, and on exit (EOF, read error, scanner desync, or a stale
    /// epoch) signals `receiveLoopExited(fd:)` — it never closes `fd` itself.
    /// The actor is the sole closer (see the type doc). Both sinks are driven
    /// from THIS one thread, so `.input`/`.paste` frames reach their sinks in
    /// wire order — and the per-frame epoch check guarantees at most one
    /// LIVE thread ever delivers, so a reconnect cannot interleave a
    /// superseded thread's buffered frames with the successor's (R5-M2).
    private nonisolated func startReceiveThread(
        fd: Int32,
        epoch: UInt64,
        inputSink: (@Sendable (SidecarInputHeader, Data) -> Void)?,
        pasteSink: (@Sendable (SidecarInputHeader, Data) -> Void)?
    ) {
        let logger = self.logger
        let epochBox = self.epochBox
        let thread = Thread { [weak self] in
            let scanner = SidecarFrameScanner()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            readLoop: while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count <= 0 { break }   // 0 = EOF, <0 = error
                // Process the frames `append` returned FIRST, THEN check
                // isDesynced (below). A desync-tripping tail can share a read
                // with the last valid frames, so draining before the break
                // avoids discarding them. Must stay in lockstep with the app's
                // receive loop in FDSidecarClient.receiveLoop, which mirrors
                // this order.
                for frame in scanner.append(Data(buffer[0..<count])) {
                    // Superseded mid-loop by a newer adoption: drop the frame
                    // and drop out — the successor thread owns the sinks now.
                    guard epoch == epochBox.current() else {
                        logger.debug("sidecar: dropping frame from superseded connection (fd \(fd, privacy: .public))")
                        break readLoop
                    }
                    guard let type = SidecarFrameType(rawValue: frame.type) else {
                        logger.error("sidecar: unknown frame type \(frame.type, privacy: .public) from app, skipping")
                        continue
                    }
                    switch type {
                    case .input:
                        guard let (header, bytes) = try? SidecarFrameCodec.decodeTagged(payload: frame.payload) else {
                            logger.error("sidecar: undecodable input frame, dropping")
                            continue
                        }
                        if let inputSink {
                            inputSink(header, bytes)
                        } else {
                            logger.debug("sidecar: input frame with no onInput handler, dropping \(bytes.count, privacy: .public) bytes")
                        }
                    case .paste:
                        guard let (header, bytes) = try? SidecarFrameCodec.decodeTagged(payload: frame.payload) else {
                            logger.error("sidecar: undecodable paste frame, dropping")
                            continue
                        }
                        if let pasteSink {
                            pasteSink(header, bytes)
                        } else {
                            logger.debug("sidecar: paste frame with no onPaste handler, dropping \(bytes.count, privacy: .public) bytes")
                        }
                    case .fdVend:
                        // The app must never send fd vends — that direction is
                        // daemon → app only.
                        logger.error("sidecar: received fdVend frame from app (protocol violation), dropping")
                    }
                }
                if scanner.isDesynced {
                    logger.fault("sidecar: frame scanner desynced (oversized length), closing connection")
                    break readLoop
                }
            }
            // Reader never closes: hop onto the actor, which clears clientFD (if
            // still this fd) and performs the sole close, then fires the test hook.
            Task { await self?.receiveLoopExited(fd: fd) }
        }
        thread.name = "fd-vending-receive"
        thread.stackSize = 256 * 1024
        thread.start()
    }
}
