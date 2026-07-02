import Darwin
import Foundation
import TBDShared
import os

enum FDVendingServerError: Error, Equatable {
    case notConnected
    case bindFailed(Int32)
    case listenFailed(Int32)
}

/// A tiny per-daemon service that holds the sidecar socket the app connects to
/// for receiving file descriptors. Phase 2 has exactly one client (the app), so
/// at most one connection is adopted at a time; a new adoption replaces the
/// old one.
///
/// Phase 2's uses: after the attach orchestrator gets a per-pane pipe read end
/// from the supervisor, it calls `send(fd:header:)` here to hand it to the app.
///
/// The accept loop runs on a dedicated `Thread` — the house pattern for
/// indefinitely-blocking syscalls (see `TmuxControlConnection`'s reader).
/// Parking a cooperative-pool task in blocking `accept()` would permanently
/// eat one of the pool's threads.
actor FDVendingServer {
    private let logger = Logger(subsystem: "com.tbd.daemon", category: "fdVending")
    private var clientFD: Int32 = -1
    /// Path of the listening socket, when one is bound. Nil when the server is
    /// running purely off adopted fds (unit tests).
    private var socketPath: String?
    private var listenerFD: Int32 = -1

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

    /// Adopt a pre-connected socket fd. Ownership transfers here — do not
    /// close it in the caller. Replaces any prior connection.
    func adoptConnection(fd: Int32) {
        if clientFD >= 0 { Darwin.close(clientFD) }
        clientFD = fd
        logger.info("FD vending client connected (fd \(fd))")
    }

    /// Close the current client connection (if any) without stopping the
    /// listener.
    func disconnect() {
        if clientFD >= 0 {
            Darwin.close(clientFD)
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

    /// Send `fd` plus `header` to the currently connected app client. Retries
    /// briefly while no client is adopted — the app connects eagerly at
    /// startup, so this only papers over a connect-vs-accept race measured in
    /// milliseconds.
    func send(fd: Int32, header: Data) async throws {
        for attempt in 0..<10 {
            if clientFD >= 0 {
                try FDChannel.sendFD(fd, over: clientFD, header: header)
                return
            }
            if attempt < 9 { try? await Task.sleep(for: .milliseconds(50)) }
        }
        throw FDVendingServerError.notConnected
    }
}
