import Darwin
import Foundation
import TBDShared
import os

/// The daemon's end of one holder's Unix socket.
///
/// An `actor` because the holder enforces **one client at a time** and the
/// stream underneath is a single reader's to drain: two tasks interleaving
/// `recvmsg` on the same descriptor would split frames between them and, worse,
/// let an `SCM_RIGHTS` descriptor land on whichever one happened to read first.
/// Making the socket actor-isolated means the single-reader discipline is a
/// property of the type rather than of every call site's good manners.
///
/// The I/O here is deliberately blocking, bounded by `SO_RCVTIMEO`. Every verb
/// is a short request/response round trip against a process that is either
/// alive and answering in microseconds or wedged — and a wedged holder must
/// surface as a thrown error attributed to the caller, never as a task parked
/// forever. Draining the pty stream, which is unbounded and must not block
/// anything, is a different job and belongs to the reader, not here.
actor HolderClient {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "holder")

    /// How long a single request may wait for its answer before the holder is
    /// declared unresponsive.
    static let defaultReceiveTimeout: Duration = .seconds(10)

    enum Error: LocalizedError, Equatable {
        case socketPathTooLong(path: String, limit: Int)
        case cannotConnect(path: String, errno: Int32)
        case notConnected
        case peerClosed
        /// The holder answered with the busy sentinel: somebody else is already
        /// its one client.
        case rejected(version: Int)
        case unexpectedResponse(String)
        /// A `handedOverPTY` frame arrived with no descriptor attached.
        case noDescriptor
        case transportFailed(String)

        var errorDescription: String? {
            switch self {
            case .socketPathTooLong(let path, let limit):
                return "holder socket path is \(path.utf8.count) bytes, over the "
                    + "\(limit)-byte sun_path limit: \(path)"
            case .cannotConnect(let path, let code):
                return "could not connect to the holder socket at \(path): "
                    + "\(String(cString: strerror(code))) (errno \(code))"
            case .notConnected:
                return "the holder client has already been closed"
            case .peerClosed:
                return "the holder closed the connection without answering"
            case .rejected(let version):
                return "the holder rejected this connection (protocol version \(version)); "
                    + "another client is already attached"
            case .unexpectedResponse(let response):
                return "the holder answered with an unexpected response: \(response)"
            case .noDescriptor:
                return "the holder reported handing over the pty but sent no descriptor"
            case .transportFailed(let detail):
                return "holder socket transport failed: \(detail)"
            }
        }
    }

    let socketPath: String
    private let receiveTimeout: Duration
    private var fd: Int32 = -1
    /// Bytes read but not yet parsed into a whole frame.
    private var inbox = Data()
    /// Frames decoded but not yet returned to a caller.
    ///
    /// **This queue is the point.** One `recvmsg` routinely carries a response
    /// and the holder's unsolicited exit push together — the holder answers a
    /// request and reports a status microseconds apart, and the kernel
    /// coalesces them. A client that returned the first frame and dropped the
    /// tail would then read EOF on its next call, because the holder closes
    /// right after reporting an exit, and would report a closed peer for a
    /// message that did arrive. That was a real load-dependent flake in the
    /// holder's own harness, not a hypothetical.
    private var pending: [HolderResponse] = []
    /// Descriptors received but not yet handed to the frame they rode with.
    private var carriedFDs: [Int32] = []

    init(socketPath: String, receiveTimeout: Duration = HolderClient.defaultReceiveTimeout) {
        self.socketPath = socketPath
        self.receiveTimeout = receiveTimeout
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
        for descriptor in carriedFDs { Darwin.close(descriptor) }
    }

    // MARK: - Verbs

    /// Report the child without transferring anything. Doubles as the
    /// handshake: a holder that answers this is alive, speaking the protocol,
    /// and naming the installation that spawned it.
    @discardableResult
    func describe() async throws -> HolderChildDescription {
        try connectIfNeeded()
        try send(.describe)
        let (response, fds) = try receive()
        closeAll(fds)
        switch response {
        case .described(let description), .handedOverPTY(let description):
            return description
        case .rejected(let version):
            throw Error.rejected(version: version)
        case .forgotten:
            throw Error.unexpectedResponse("forgotten")
        }
    }

    /// Ask for a `dup` of the pty master. The returned descriptor is the
    /// caller's to close; nobody else will.
    func handOverPTY() async throws -> (HolderChildDescription, Int32) {
        try connectIfNeeded()
        try send(.handOverPTY)
        let (response, fds) = try receive()
        switch response {
        case .handedOverPTY(let description):
            guard let descriptor = fds.first else { throw Error.noDescriptor }
            // A second descriptor would be a duplicate reference to the same
            // open file and would keep the pty alive after the caller closed
            // the one it was given, so extras are closed rather than kept.
            closeAll(Array(fds.dropFirst()))
            return (description, descriptor)
        case .described(let description):
            // The holder answers with a plain description when it has nothing
            // to hand over — it was forgotten, or its `dup` failed. Saying so
            // is better than pretending a transfer happened.
            closeAll(fds)
            Self.logger.error(
                """
                holder at \(self.socketPath, privacy: .public) has no pty to hand over for \
                child \(description.childPID, privacy: .public)
                """)
            throw Error.noDescriptor
        case .rejected(let version):
            closeAll(fds)
            throw Error.rejected(version: version)
        case .forgotten:
            closeAll(fds)
            throw Error.unexpectedResponse("forgotten")
        }
    }

    /// Tell the holder to close the pty master and stop reporting, so a session
    /// TBD has deliberately killed cannot be resurrected by a later attach.
    func forget() async throws {
        try connectIfNeeded()
        try send(.forget)
        let (response, fds) = try receive()
        closeAll(fds)
        switch response {
        case .forgotten:
            return
        case .rejected(let version):
            throw Error.rejected(version: version)
        case .described, .handedOverPTY:
            throw Error.unexpectedResponse(String(describing: response))
        }
    }

    /// Drops the connection. Idempotent; the client reconnects on the next
    /// verb, which is what makes a `HolderClient` reusable across a holder's
    /// life without pinning its single client slot between requests.
    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        inbox = Data()
        pending = []
        closeAll(carriedFDs)
        carriedFDs = []
    }

    // MARK: - Transport

    private func connectIfNeeded() throws {
        guard fd < 0 else { return }
        guard socketPath.utf8.count < HolderRendezvous.sunPathLimit else {
            throw Error.socketPathTooLong(path: socketPath, limit: HolderRendezvous.sunPathLimit)
        }

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw Error.cannotConnect(path: socketPath, errno: errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: address.sun_path)
        socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { chars in
                    _ = strlcpy(chars, source, sunPathSize)
                }
            }
        }
        let connected = withUnsafePointer(to: &address) { addressPtr in
            addressPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(socketFD, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let saved = errno
            Darwin.close(socketFD)
            throw Error.cannotConnect(path: socketPath, errno: saved)
        }

        var timeout = Self.timeval(from: receiveTimeout)
        _ = setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // A holder that has already reported an exit closes as soon as it has,
        // so a write can legitimately land on a socket whose peer is gone.
        // Without this that write raises SIGPIPE, whose default disposition
        // would take the whole daemon down over one dead holder.
        var on: Int32 = 1
        _ = setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        fd = socketFD
    }

    private func send(_ request: HolderRequest) throws {
        guard fd >= 0 else { throw Error.notConnected }
        do {
            try FDChannel.sendData(HolderFraming.frame(request), over: fd)
        } catch {
            throw Error.transportFailed(error.localizedDescription)
        }
    }

    /// Returns the next decoded frame, reading only when the queue is empty.
    private func receive() throws -> (HolderResponse, [Int32]) {
        while true {
            if !pending.isEmpty {
                let response = pending.removeFirst()
                // Only a hand-over carries a descriptor, so anything queued now
                // belongs to this frame if it is one and stays queued if not.
                if case .handedOverPTY = response, !carriedFDs.isEmpty {
                    let fds = carriedFDs
                    carriedFDs = []
                    return (response, fds)
                }
                return (response, [])
            }

            guard fd >= 0 else { throw Error.notConnected }
            let message: (data: Data, fds: [Int32])
            do {
                message = try FDChannel.receiveMessage(from: fd, capacity: Self.readChunkSize)
            } catch FDChannelError.peerClosed {
                throw Error.peerClosed
            } catch {
                throw Error.transportFailed(error.localizedDescription)
            }
            carriedFDs.append(contentsOf: message.fds)
            inbox.append(message.data)
            do {
                pending = try HolderFraming.drainResponses(from: &inbox)
            } catch {
                throw Error.transportFailed(error.localizedDescription)
            }
        }
    }

    private func closeAll(_ fds: [Int32]) {
        for descriptor in fds { Darwin.close(descriptor) }
    }

    private static func timeval(from duration: Duration) -> timeval {
        let components = duration.components
        return Darwin.timeval(
            tv_sec: Int(components.seconds),
            tv_usec: suseconds_t(components.attoseconds / 1_000_000_000_000))
    }

    private static let readChunkSize = 4096
}
