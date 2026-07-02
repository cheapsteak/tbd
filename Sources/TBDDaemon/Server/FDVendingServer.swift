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
/// **fd ownership with a reader thread.** Each adopted connection gets a
/// receive thread that OWNS closing that connection's fd: it `close()`s on exit.
/// `adoptConnection`/`disconnect`/`stop` only `shutdown(fd, SHUT_RDWR)` to signal
/// the reader — on Darwin, `close()`ing a socket out from under a thread blocked
/// in `read()` does NOT wake it, but `shutdown()` does. Because the reader owns
/// the final close, the fd number can never be reused while a stale reader is
/// still parked on it. Sends run on the actor and target the same fd; sending
/// on a shut-down fd returns `EPIPE`, which `send()` surfaces as an error.
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

    /// Test seam: invoked (off the actor) when a receive loop exits, so tests
    /// can await deterministic thread teardown instead of sleeping.
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
            shutdown(clientFD, SHUT_RDWR)   // wake the old reader; it owns the close
            clientFD = -1
        }
        clientFD = fd
        startReceiveThread(fd: fd, sink: onInput, onExit: onReceiveLoopExit)
        logger.info("FD vending client connected (fd \(fd, privacy: .public))")
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
    /// bytes, decodes `.input` frames to `onInput`, and OWNS closing `fd` on
    /// exit (EOF, read error, or scanner desync).
    private nonisolated func startReceiveThread(
        fd: Int32,
        sink: (@Sendable (SidecarInputHeader, Data) -> Void)?,
        onExit: (@Sendable () -> Void)?
    ) {
        let logger = self.logger
        let thread = Thread {
            let scanner = SidecarFrameScanner()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            readLoop: while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count <= 0 { break }   // 0 = EOF, <0 = error
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
            Darwin.close(fd)   // reader owns the close
            onExit?()
        }
        thread.name = "fd-vending-receive"
        thread.stackSize = 256 * 1024
        thread.start()
    }
}
