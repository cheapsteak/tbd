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
    /// Mutable because a connection can outlive the budget it was made under:
    /// `HolderSpawner` handshakes on a short handshake timeout and then hands
    /// the same connection on as a session's long-lived one. See
    /// `adoptReceiveTimeout`.
    private var receiveTimeout: Duration
    private var fd: Int32 = -1
    /// Bytes read but not yet parsed into a whole frame.
    private var inbox = Data()
    /// Frames decoded but not yet returned to a caller.
    ///
    /// **The queue exists because one `recvmsg` routinely carries two frames.**
    /// The holder answers a request and reports a status microseconds apart,
    /// and the kernel coalesces them; a client that decoded the first and threw
    /// the rest of the buffer away would lose a message that did arrive, then
    /// read EOF looking for it, because the holder closes right after reporting
    /// an exit. That was a real load-dependent flake in the holder's own
    /// harness, not a hypothetical.
    ///
    /// What the queue must never do is hand one request's tail to the *next*
    /// request as its answer. Whatever is in it when a request goes out
    /// therefore arrived before that request existed and is retired as an
    /// unsolicited push rather than served — see `raiseBarrier`.
    private var pending: [HolderResponse] = []
    /// Descriptors received but not yet handed to the frame they rode with.
    private var carriedFDs: [Int32] = []
    /// The most recent description the holder sent **without being asked**.
    ///
    /// The holder pushes a `.described` frame carrying the terminal status when
    /// the child exits while a client is connected, and the kernel routinely
    /// delivers that push in the same read as the answer it trails. Such a
    /// frame answers nobody's request, so it is retired from the queue rather
    /// than handed to whoever asks next — and kept here, because it is the one
    /// place a child's exit status arrives unsolicited and throwing it away
    /// silently would lose the fact entirely.
    ///
    /// Deliberately survives `close()`: it is an observation about the child,
    /// not connection state.
    private(set) var lastPushedDescription: HolderChildDescription?
    /// The busy sentinel this connection was refused with, if it has arrived.
    ///
    /// **`.rejected` is the other frame the holder writes without being asked**,
    /// and unlike an exit push it is not noise: the holder writes it the moment
    /// it accepts a connection it cannot serve, and then hangs up. So it
    /// routinely lands *before* the first request is even written, where the
    /// barrier finds it — and a barrier that discarded it left the following
    /// write to fail with `EPIPE`, reporting a perfectly ordinary busy holder
    /// as `transportFailed("Broken pipe")`. Which of the two a caller saw was
    /// decided by microseconds.
    ///
    /// Kept, so the verb that was about to go out fails with the refusal the
    /// holder actually gave. Cleared by `close()`: it is a fact about one
    /// connection, and the next one gets its own answer.
    private var refusal: Int?

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
        let (response, fds) = try receive(answering: .describe)
        closeAll(fds)
        switch response {
        case .described(let description), .handedOverPTY(let description):
            return description
        case .rejected(let version):
            throw Error.rejected(version: version)
        case .forgotten:
            throw unexpected(response)
        }
    }

    /// Ask for a `dup` of the pty master. The returned descriptor is the
    /// caller's to close; nobody else will.
    func handOverPTY() async throws -> (HolderChildDescription, Int32) {
        try connectIfNeeded()
        try send(.handOverPTY)
        let (response, fds) = try receive(answering: .handOverPTY)
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
            throw unexpected(response)
        }
    }

    /// Tell the holder to close the pty master and stop reporting, so a session
    /// TBD has deliberately killed cannot be resurrected by a later attach.
    func forget() async throws {
        try connectIfNeeded()
        try send(.forget)
        let (response, fds) = try receive(answering: .forget)
        closeAll(fds)
        switch response {
        case .forgotten:
            return
        case .rejected(let version):
            throw Error.rejected(version: version)
        case .described, .handedOverPTY:
            throw unexpected(response)
        }
    }

    /// Re-times an already-open connection, and every later one.
    ///
    /// Exists because `HolderSpawner` connects under a deliberately short
    /// handshake budget — a holder that connects and then goes quiet must not
    /// spend the whole startup budget on one attempt — and then hands that same
    /// connection to the daemon to keep for the session's life. Leaving the
    /// handshake budget on it would silently apply a startup-shaped deadline to
    /// every later verb.
    func adoptReceiveTimeout(_ timeout: Duration) {
        receiveTimeout = timeout
        guard fd >= 0 else { return }
        var value = Self.timeval(from: timeout)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// The pid at the other end of this connection, or `nil` when there is no
    /// connection or the kernel would not say.
    ///
    /// `LOCAL_PEERPID` is a property of the **socket**, not of the path, so it
    /// can only be read while the connection is open — and it is the only way a
    /// reconciler can learn a holder's pid without a session row to read it
    /// from, since the handshake deliberately does not carry one (the holder is
    /// kept small enough to essentially never change, and this needs no protocol
    /// version).
    ///
    /// Read it *after* a verb has been answered, so the pid belongs to a peer
    /// that has provably spoken the protocol rather than to whatever happened to
    /// own the path at connect time.
    func peerPID() -> Int32? {
        guard fd >= 0 else { return nil }
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else {
            return nil
        }
        return pid
    }

    /// Drops the connection. Idempotent; the client reconnects on the next
    /// verb, which is what makes a `HolderClient` reusable across a holder's
    /// life without pinning its single client slot between requests.
    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        inbox = Data()
        // Anything still queued at close is by definition nobody's answer, so
        // it is retired the same way a send retires it: the status it may carry
        // is remembered, and its descriptors are closed rather than leaked.
        retireQueuedFrames()
        // A refusal belongs to the connection that was refused, not to the
        // client. Carrying one across a reconnect would fail the next verb with
        // an answer a holder gave about a socket that no longer exists.
        refusal = nil
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

    /// **A refusal outranks whatever else went wrong on the way to noticing
    /// it**, which is why every failure path here consults it first.
    ///
    /// A holder refuses and hangs up in one breath, so the refusal is always
    /// chased by an EOF and, if the write lost the race, an `EPIPE`. Those are
    /// the same event seen from further away: reporting `peerClosed` or
    /// `transportFailed("Broken pipe")` would name the symptom and lose the
    /// reason, and which of the three a caller saw was decided by microseconds.
    /// Reporting `.rejected` in all of them is what makes "somebody else is
    /// already attached" a fact a caller can act on rather than a coin toss.
    private func send(_ request: HolderRequest) throws {
        guard fd >= 0 else { throw Error.notConnected }
        do {
            try raiseBarrier()
        } catch {
            throw refusalError() ?? error
        }
        if let refused = refusalError() { throw refused }
        do {
            try FDChannel.sendData(HolderFraming.frame(request), over: fd)
        } catch {
            // The refusal can still be sitting unread in the receive buffer
            // when the write fails. The barrier's own throw says nothing this
            // does not already know — the refusal, if there was one, is
            // recorded on its way out.
            try? raiseBarrier()
            throw refusalError() ?? Error.transportFailed(error.localizedDescription)
        }
    }

    /// Consumes a recorded refusal, dropping the connection it belongs to.
    ///
    /// Dropping is what makes the client reusable: the holder closes every
    /// connection it refuses, so the socket is already dead, and a caller that
    /// backs off and retries reconnects on its next verb rather than writing
    /// into a corpse.
    private func refusalError() -> Error? {
        guard let version = refusal else { return nil }
        close()
        return .rejected(version: version)
    }

    /// Separates everything the holder has already said from the answer to the
    /// request about to be written.
    ///
    /// **This is the request/response correlation**, and the wire carries no
    /// identifier that could provide one: the holder's frames are anonymous, so
    /// "which request does this answer" can only be decided by *when* it
    /// arrived. Drawing the line at send time makes the next frame this
    /// request's answer by construction.
    ///
    /// It has to reach the socket, not just the decoded queue. A coalesced
    /// exit push lands in the queue, but a push written a moment after the
    /// answer it followed is still sitting in the kernel's receive buffer —
    /// unread and indistinguishable, later, from an answer. Both are taken here.
    ///
    /// Without it a `handOverPTY` that leaves a `.described(exited)` behind
    /// makes the next `forget` fail with `unexpectedResponse` for a verb the
    /// holder performed correctly, and leaves that verb's real answer to be
    /// misattributed to the one after it — a desync that never heals.
    private func raiseBarrier() throws {
        guard fd >= 0 else { return }
        // Retired on the way out **however the barrier ends**, because the
        // commonest shape of a pushed exit is a push immediately followed by
        // the holder's own shutdown: the first read decodes the push, the next
        // one is the EOF behind it, and a barrier that only retired on the
        // success path threw that EOF with the exit still sitting undelivered
        // in the queue. `lastPushedDescription` then stayed nil until somebody
        // called `close()`, so a poller doing `describe()` and reading the
        // pushed status never saw how the child ended. Everything queued when
        // the barrier ran arrived before this request existed and is nobody's
        // answer, which is exactly as true when the read after it fails.
        defer { retireQueuedFrames() }
        while hasBufferedInput() {
            try readMoreFrames()
        }
        // A frame still arriving when the barrier ran was written before the
        // request, so it is read to completion rather than left to finish
        // arriving behind the answer and be mistaken for it. Bounded by
        // `SO_RCVTIMEO` like every other read here.
        while !inbox.isEmpty {
            try readMoreFrames()
        }
    }

    /// Whether the socket has something to deliver right now.
    private func hasBufferedInput() -> Bool {
        guard fd >= 0 else { return false }
        var watched = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let ready = poll(&watched, 1, 0)
            if ready < 0 {
                if errno == EINTR { continue }
                return false
            }
            return ready > 0 && watched.revents & Int16(POLLIN) != 0
        }
    }

    /// Retires everything decoded but unclaimed.
    ///
    /// In practice these are the holder's unsolicited exit pushes, which
    /// **trail** the answer they were coalesced with: the holder pushes only
    /// from its reaping branch, only at a client that is already connected, and
    /// only after that client's previous request was answered in an earlier
    /// pass of its loop.
    private func retireQueuedFrames() {
        for response in pending {
            switch response {
            case .described(let description), .handedOverPTY(let description):
                lastPushedDescription = description
                Self.logger.debug(
                    """
                    holder at \(self.socketPath, privacy: .public) pushed an unsolicited status for \
                    child \(description.childPID, privacy: .public): \
                    \(String(describing: description.status), privacy: .public)
                    """)
            case .rejected(let version):
                refusal = version
                Self.logger.debug(
                    """
                    the holder at \(self.socketPath, privacy: .public) refused this connection \
                    before it was asked anything (protocol version \(version, privacy: .public))
                    """)
            case .forgotten:
                Self.logger.debug(
                    """
                    discarding an unsolicited \(String(describing: response), privacy: .public) frame \
                    from the holder at \(self.socketPath, privacy: .public)
                    """)
            }
        }
        pending = []
        // A descriptor still carried here rode with a frame nobody is waiting
        // for. Nothing will ever come to collect it, so it is closed rather
        // than attached to an unrelated later hand-over.
        closeAll(carriedFDs)
        carriedFDs = []
    }

    /// Returns the frame that answers `request`, reading only when the queue is
    /// empty.
    ///
    /// The barrier `send` raised is what makes the first frame here this
    /// request's answer. The shape check is the backstop: a frame that could
    /// not answer what was just asked means the stream is no longer understood,
    /// so the connection is dropped and the desync cannot outlive the call —
    /// the next verb reconnects and starts from a known state.
    private func receive(answering request: HolderRequest) throws -> (HolderResponse, [Int32]) {
        while true {
            if !pending.isEmpty {
                let response = pending.removeFirst()
                // Only a hand-over carries a descriptor, so anything queued now
                // belongs to this frame if it is one and stays queued if not.
                var fds: [Int32] = []
                if case .handedOverPTY = response, !carriedFDs.isEmpty {
                    fds = carriedFDs
                    carriedFDs = []
                }
                guard Self.response(response, answers: request) else {
                    closeAll(fds)
                    throw unexpected(response)
                }
                return (response, fds)
            }

            try readMoreFrames()
        }
    }

    /// One bounded `recvmsg`, decoded into the queue.
    private func readMoreFrames() throws {
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
            // Appended, never assigned: a read that completes a frame while
            // others are already queued must not drop the ones in front of it.
            pending.append(contentsOf: try HolderFraming.drainResponses(from: &inbox))
        } catch {
            throw Error.transportFailed(error.localizedDescription)
        }
    }

    private func closeAll(_ fds: [Int32]) {
        for descriptor in fds { Darwin.close(descriptor) }
    }

    /// Whether `response` is a shape the holder can legitimately answer
    /// `request` with.
    ///
    /// `.rejected` answers everything — a busy holder refuses the connection
    /// itself, whatever was asked. `.described` answers `handOverPTY` because
    /// that is how a forgotten holder, or one whose `dup` failed, says it has
    /// nothing to transfer.
    private static func response(_ response: HolderResponse, answers request: HolderRequest) -> Bool {
        if case .rejected = response { return true }
        switch request {
        case .describe, .handOverPTY:
            if case .forgotten = response { return false }
            return true
        case .forget:
            if case .forgotten = response { return true }
            return false
        }
    }

    /// Drops the connection and reports the frame that did not belong.
    ///
    /// Closing is the point: a client that keeps a stream it has stopped
    /// understanding attributes every later answer to the wrong request
    /// forever, so the one recoverable move is to start over.
    private func unexpected(_ response: HolderResponse) -> Error {
        Self.logger.error(
            """
            holder at \(self.socketPath, privacy: .public) answered with an unexpected \
            \(String(describing: response), privacy: .public); dropping the connection
            """)
        close()
        return Error.unexpectedResponse(String(describing: response))
    }

    private static func timeval(from duration: Duration) -> timeval {
        let components = duration.components
        return Darwin.timeval(
            tv_sec: Int(components.seconds),
            tv_usec: suseconds_t(components.attoseconds / 1_000_000_000_000))
    }

    private static let readChunkSize = 4096
}
