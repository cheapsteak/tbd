import Darwin
import Foundation
import TBDShared
import os

enum FDVendingServerError: Error, Equatable {
    case notConnected
    case bindFailed(Int32)
    case listenFailed(Int32)
}

/// A tiny per-daemon service that holds the sidecar socket the app connects to.
/// Phase 2 has exactly one client (the app), so at most one connection is
/// adopted at a time; a new adoption replaces the old one.
///
/// M2.1 promotes the sidecar to a **bidirectional framed data channel**:
/// - daemon → app: `send(fd:header:)` vends a pane read fd wrapped in a
///   length-prefixed `.fdVend` frame (unchanged semantics, now framed).
/// - app → daemon: keystroke/paste `.input` frames, decoded on a dedicated
///   receive `Thread` and delivered via `onInput`.
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
    /// Path of the listening socket, when one is bound. Nil when the server is
    /// running purely off adopted fds (unit tests).
    private var socketPath: String?
    private var listenerFD: Int32 = -1

    /// Sink for app → daemon input frames. Set once by the daemon wiring BEFORE
    /// `listen`/`adoptConnection` (M2.2 delivers keystrokes here). Captured per
    /// connection at adopt time. When nil, input frames are logged and dropped.
    var onInput: (@Sendable (SidecarInputHeader, Data) -> Void)?

    /// Test seam: invoked from `receiveLoopExited` (on the actor) AFTER `clientFD`
    /// is cleared and the fd closed, so once it fires the stale fd is fully gone —
    /// tests can await deterministic post-cleanup state instead of sleeping.
    var onReceiveLoopExit: (@Sendable () -> Void)?

    /// Install the input sink. Must be called BEFORE `listen`/`adoptConnection`
    /// — each connection captures the current sink at adopt time.
    func setOnInput(_ handler: (@Sendable (SidecarInputHeader, Data) -> Void)?) {
        onInput = handler
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
        _ = path.withCString { src in
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
        // freshly-adopted `clientFD` (different fd number).
        startReceiveThread(fd: fd, sink: onInput)
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
    /// race measured in milliseconds.
    func send(fd: Int32, header: Data) async throws {
        let frame = SidecarFrameCodec.encode(type: .fdVend, payload: header)
        for attempt in 0..<10 {
            if clientFD >= 0 {
                try FDChannel.sendFD(fd, over: clientFD, frame: frame)
                return
            }
            if attempt < 9 { try? await Task.sleep(for: .milliseconds(50)) }
        }
        throw FDVendingServerError.notConnected
    }

    /// Spawn the receive thread for one connection. The thread reads framed
    /// bytes, decodes `.input` frames to `onInput`, and on exit (EOF, read error,
    /// or scanner desync) signals `receiveLoopExited(fd:)` — it never closes `fd`
    /// itself. The actor is the sole closer (see the type doc).
    private nonisolated func startReceiveThread(
        fd: Int32,
        sink: (@Sendable (SidecarInputHeader, Data) -> Void)?
    ) {
        let logger = self.logger
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
                    guard let type = SidecarFrameType(rawValue: frame.type) else {
                        logger.error("sidecar: unknown frame type \(frame.type, privacy: .public) from app, skipping")
                        continue
                    }
                    switch type {
                    case .input:
                        guard let (header, bytes) = try? SidecarFrameCodec.decodeInput(payload: frame.payload) else {
                            logger.error("sidecar: undecodable input frame, dropping")
                            continue
                        }
                        if let sink {
                            sink(header, bytes)
                        } else {
                            logger.debug("sidecar: input frame with no onInput handler, dropping \(bytes.count, privacy: .public) bytes")
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
