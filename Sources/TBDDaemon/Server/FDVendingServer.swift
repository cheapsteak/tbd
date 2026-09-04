import Darwin
import Foundation
import TBDShared
import os

enum FDVendingServerError: LocalizedError, Equatable {
    case notConnected
    case bindFailed(Int32)
    case listenFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "No sidecar connection is adopted"
        case .bindFailed(let code):
            return "bind(2) on the sidecar socket failed: \(String(cString: strerror(code))) (errno \(code))"
        case .listenFailed(let code):
            return "listen(2) on the sidecar socket failed: \(String(cString: strerror(code))) (errno \(code))"
        }
    }
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
    /// Who was at the other end of `clientFD`, recorded at adopt time.
    ///
    /// Recorded rather than looked up on demand for the reason
    /// `ProcessIdentity.ofPeer` gives: `LOCAL_PEERPID` is a property of the
    /// **socket**, so once the connection is gone the pid is unrecoverable —
    /// and the pid alone would not be enough anyway. The start time and command
    /// line beside it are what let a later liveness check tell this process
    /// from a stranger that inherited its pid.
    private var clientIdentity: ProcessIdentity?
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
    /// Reads the identity of the process at the other end of an adopted socket.
    /// An injection seam: tests adopt `socketpair` ends, whose peer is the test
    /// process itself.
    private let peerIdentity: @Sendable (Int32) -> ProcessIdentity?
    /// Delay seam (`docs/specs/2026-07-24-test-hardening-design.md` §5).
    /// Existential, not generic: this is an `actor` carrying `Sendable`
    /// conformances, and a generic parameter would infect its type.
    private let clock: any Clock<Duration>

    init(retryAttempts: Int = 10,
         retryInterval: Duration = .milliseconds(50),
         peerIdentity: @escaping @Sendable (Int32) -> ProcessIdentity? = {
             ProcessIdentity.ofPeer(onSocket: $0, signaller: ProductionProcessSignaller())
         },
         clock: any Clock<Duration> = ContinuousClock()) {
        self.retryAttempts = retryAttempts
        self.retryInterval = retryInterval
        self.peerIdentity = peerIdentity
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

    /// Sink for app → daemon `.injectionAck` frames: the app's answer to one
    /// daemon injection for a holder-backed session whose pty it owns. Same
    /// contract as `onInput` — set once by the daemon wiring BEFORE
    /// `listen`/`adoptConnection`, captured per connection at adopt time. When
    /// nil, acks are logged and dropped, which is survivable rather than fatal:
    /// an unanswered injection reaches the courier's deadline and is written
    /// directly (see `HolderInjectionCourier`).
    var onInjectionAck: (@Sendable (SidecarInjectionAck) -> Void)?

    /// Sink for "the app's connection went away", carrying the identity
    /// recorded for it at adopt time (nil when the peer could not be
    /// identified).
    ///
    /// **A disconnect is not a death**, and this sink must not be read as one:
    /// the app reconnects, so the drop is only the prompt to ask whether that
    /// process is still there. `SidecarDisconnectArbiter` is what answers, and
    /// only its verdict licenses taking any pty back.
    ///
    /// Fired only for the connection that was still current when its receive
    /// loop exited. A **superseded** connection's exit is the ordinary shape of
    /// a reconnect — `adoptConnection` shut it down itself — and arbitrating on
    /// it would ask whether an app that has just connected again is alive.
    var onClientDisconnect: (@Sendable (ProcessIdentity?) -> Void)?

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

    /// Install the injection-ack sink. Must be called BEFORE
    /// `listen`/`adoptConnection` — each connection captures the current sink
    /// at adopt time.
    func setOnInjectionAck(_ handler: (@Sendable (SidecarInjectionAck) -> Void)?) {
        onInjectionAck = handler
    }

    /// Install the disconnect sink (see `onClientDisconnect`). Like the other
    /// sinks, install it before `listen`/`adoptConnection`.
    func setOnClientDisconnect(_ handler: (@Sendable (ProcessIdentity?) -> Void)?) {
        onClientDisconnect = handler
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
        // Read here, while the socket exists: `LOCAL_PEERPID` is a property of
        // the connection, so after it closes there is nothing left to ask.
        clientIdentity = peerIdentity(fd)
        // The old reader will later call `receiveLoopExited(oldFD)`; its
        // `clientFD == fd` guard ensures that stale signal does NOT clear this
        // freshly-adopted `clientFD` (different fd number). Advancing the epoch
        // BEFORE the new thread starts supersedes the old thread's deliveries:
        // even if it is past its read() with frames still buffered, its next
        // per-frame epoch check fails and it drops out (R5-M2).
        let epoch = epochBox.advance()
        startReceiveThread(
            fd: fd, epoch: epoch, inputSink: onInput, pasteSink: onPaste,
            injectionAckSink: onInjectionAck)
        logger.info("FD vending client connected (fd \(fd, privacy: .public))")
    }

    /// Sole close path for a connection fd. Invoked (on the actor) by a receive
    /// thread after its read loop exits. The reader has already left `read()`, so
    /// closing here is safe. Clearing `clientFD` first is what stops a later
    /// `send()` from writing a vend frame into a recycled fd number.
    func receiveLoopExited(fd: Int32) {
        // A newer adopt may own a different fd now, in which case this thread
        // belongs to a superseded connection: its exit is a reconnect's
        // ordinary teardown, not the app going away, and the identity in
        // `clientIdentity` belongs to the connection that replaced it.
        let wasCurrent = clientFD == fd
        var departed: ProcessIdentity?
        if wasCurrent {
            clientFD = -1
            departed = clientIdentity
            clientIdentity = nil
        }
        Darwin.close(fd)
        if wasCurrent { onClientDisconnect?(departed) }
        onReceiveLoopExit?()
    }

    /// Close the current client connection (if any) without stopping the
    /// listener. Signals the reader, which performs the actual `close()`.
    /// Deliberately does **not** fire `onClientDisconnect`: this is the daemon
    /// dropping the app, not the app going away, and its only caller is `stop`.
    /// Clearing `clientFD` here also means the woken reader sees itself as
    /// superseded and stays quiet too.
    func disconnect() {
        if clientFD >= 0 {
            shutdown(clientFD, SHUT_RDWR)
            clientFD = -1
        }
        clientIdentity = nil
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

    /// Send one already-encoded frame to the connected app client, with no
    /// descriptor attached and no retry.
    ///
    /// No retry, unlike `send(fd:header:)`, and the difference is deliberate:
    /// that one papers over a connect-vs-accept race at app startup, while this
    /// one is only ever called for a session a viewer is already attached to —
    /// which means the app connected long ago. A throw here says the sidecar is
    /// gone, and the caller (`HolderInjectionCourier`) answers it by writing
    /// the bytes itself rather than by waiting.
    func sendFrame(_ frame: Data) throws {
        guard clientFD >= 0 else { throw FDVendingServerError.notConnected }
        try FDChannel.sendData(frame, over: clientFD)
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
        pasteSink: (@Sendable (SidecarInputHeader, Data) -> Void)?,
        injectionAckSink: (@Sendable (SidecarInjectionAck) -> Void)?
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
                    case .injectionAck:
                        guard let ack = try? SidecarFrameCodec.decodeInjectionAck(
                            payload: frame.payload) else {
                            logger.error("sidecar: undecodable injection ack, dropping")
                            continue
                        }
                        if let injectionAckSink {
                            injectionAckSink(ack)
                        } else {
                            logger.debug("sidecar: injection ack with no handler, dropping")
                        }
                    case .fdVend, .injection:
                        // The app must never send fd vends or injections —
                        // both directions are daemon → app only.
                        logger.error("sidecar: received \(frame.type, privacy: .public) frame from app (protocol violation), dropping")
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
