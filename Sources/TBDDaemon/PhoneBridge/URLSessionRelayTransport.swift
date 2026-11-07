import Foundation

/// The production ``RelayTransport``: one `URLSessionWebSocketTask` per relay
/// socket.
///
/// **Lifetimes.** Each `connect` makes its own `URLSession`, with its own
/// delegate, and that session belongs to the one socket it opens.
///
/// - A `URLSession` holds its delegate strongly until it is invalidated. A
///   session shared by every socket would keep itself and its delegate alive
///   until some owner remembered to invalidate it; a session per socket ends
///   with its socket, and the transport itself owns nothing that needs
///   tearing down. A WebSocket never goes back to a connection pool, so a
///   session per socket gives up no connection reuse.
/// - A connect that fails, is refused or is cancelled invalidates its session
///   with `invalidateAndCancel()` before it throws, which also cancels the
///   task, so nothing outlives the attempt.
/// - An open socket invalidates its session in `close(code:)`, with
///   `finishTasksAndInvalidate()` so the close frame still goes out, and, if
///   nobody closed it, when it is deallocated, with `invalidateAndCancel()`.
/// - The delegate holds only the connection's state, never the socket, so a
///   socket nobody holds is deallocated even while its session lives.
///
/// The delegate's callbacks arrive on the session's own serial queue; every
/// piece of state they share with the socket sits behind one lock.
final class URLSessionRelayTransport: RelayTransport, @unchecked Sendable {
    // @unchecked: `configuration` is a private copy that nothing mutates;
    // each session copies it again when it is made.

    /// The largest message a socket accepts: the relay's 65,536-byte frame
    /// limit with room to spare, so the limit the relay enforces is the one
    /// that applies.
    static let maximumMessageSize = 65_536 + 1024

    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = (configuration.copy() as? URLSessionConfiguration) ?? configuration
    }

    /// Opens a WebSocket to `url`, a `ws` or `wss` URL, sending `userAgent`
    /// as the `User-Agent` header.
    ///
    /// Returns once the delegate reports the socket open
    /// (`didOpenWithProtocol`). Throws the task's error when it completes
    /// first (`didCompleteWithError`): a refused connection, a failed TLS
    /// handshake, or an answer other than `101 Switching Protocols`. Throws
    /// `CancellationError` when the calling task is cancelled first. Exactly
    /// one of the three ends the wait.
    func connect(url: URL, userAgent: String) async throws -> any RelaySocket {
        // `webSocketTask(with:)` raises an Objective-C exception for any
        // other scheme, which would end the daemon.
        guard let scheme = url.scheme?.lowercased(), scheme == "ws" || scheme == "wss" else {
            throw URLError(.unsupportedURL)
        }
        try Task.checkCancellation()

        let state = URLSessionRelaySocketState()
        let session = URLSession(
            configuration: configuration,
            delegate: URLSessionRelayDelegate(state: state),
            delegateQueue: nil)
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumMessageSize

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if state.awaitOpen(continuation) {
                        task.resume()
                    }
                }
            } onCancel: {
                state.failOpen(CancellationError())
            }
        } catch {
            session.invalidateAndCancel()
            throw error
        }
        return URLSessionRelaySocket(session: session, task: task, state: state)
    }
}

// MARK: - The socket

/// One open relay socket over a `URLSessionWebSocketTask`.
///
/// - `.data` messages are `.binary` frames and `.string` messages are `.text`
///   frames.
/// - `receive()` keeps at most one task receive in flight. A receive
///   cancelled while one is in flight leaves it running, and the frame it
///   brings is kept for the next `receive()`, so cancelling never drops or
///   reorders a frame.
/// - Once the socket has closed, from either end, every `receive()` and
///   `send(_:)` throws ``RelaySocketClosed`` without touching the task again.
private final class URLSessionRelaySocket: RelaySocket, @unchecked Sendable {
    // @unchecked: `session` and `task` are immutable references to objects
    // URLSession makes safe to use from any thread, and every mutable piece
    // of state lives in `state`, behind its lock.

    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let state: URLSessionRelaySocketState

    init(session: URLSession, task: URLSessionWebSocketTask, state: URLSessionRelaySocketState) {
        self.session = session
        self.task = task
        self.state = state
    }

    deinit {
        // A socket dropped without `close(code:)` still releases its session
        // and, through it, the delegate.
        if state.claimClose() {
            session.invalidateAndCancel()
        }
    }

    func send(_ frame: RelayFrame) async throws {
        if let closed = state.closedError() {
            throw closed
        }
        let message: URLSessionWebSocketTask.Message
        switch frame {
        case .binary(let bytes):
            message = .data(bytes)
        case .text(let text):
            message = .string(text)
        }
        do {
            try await task.send(message)
        } catch {
            throw state.closedError() ?? RelaySocketClosed(code: state.closeCode(reportedByTask: task.closeCode))
        }
    }

    func receive() async throws -> RelayFrame {
        let receiveID = state.nextReceiveID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RelayFrame, any Error>) in
                switch state.parkReceive(continuation, id: receiveID) {
                case .answered:
                    break
                case .parked(let startsTaskReceive):
                    if startsTaskReceive {
                        startTaskReceive()
                    }
                }
            }
        } onCancel: {
            state.cancelReceive(id: receiveID)
        }
    }

    func close(code: Int) async {
        guard state.closeLocally(code: code) else { return }
        task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
    }

    /// Starts the one task receive. Its result goes to the parked
    /// `receive()`, or waits for the next one.
    ///
    /// The completion holds the socket weakly: a completion that arrives
    /// after the socket is gone has nobody to deliver to.
    private func startTaskReceive() {
        task.receive { [weak self] result in
            guard let self else { return }
            let reported: Int?
            if case .failure = result {
                reported = self.state.closeCode(reportedByTask: self.task.closeCode)
            } else {
                reported = nil
            }
            self.state.finishReceive(result, closeCode: reported)
        }
    }
}

// MARK: - The delegate

/// The session delegate of one relay socket. It reports the opening
/// handshake's outcome and the peer's close code to the socket's state.
private final class URLSessionRelayDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    private let state: URLSessionRelaySocketState

    init(state: URLSessionRelaySocketState) {
        self.state = state
        super.init()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol negotiated: String?) {
        state.opened()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        state.peerClosed(code: closeCode == .invalid ? nil : closeCode.rawValue)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        // Before the socket opened, this is the connect failing. After, the
        // socket's receive learns of the end from its own completion.
        state.failOpen(error ?? URLError(.badServerResponse))
    }
}

// MARK: - Shared state

/// Everything the connect, the socket and the delegate share, behind one
/// lock. Continuations are always resumed after the lock is released.
private final class URLSessionRelaySocketState: @unchecked Sendable {
    // @unchecked: every stored property is read and written only under `lock`.

    enum ParkOutcome {
        /// The continuation was resumed already: with a kept frame, the close,
        /// a cancellation, or a second concurrent receive.
        case answered
        /// The continuation waits. `startsTaskReceive` says whether the caller
        /// must start the task receive; false when one is already in flight.
        case parked(startsTaskReceive: Bool)
    }

    private enum OpenPhase {
        case waiting
        case opened
        case failed(any Error)
    }

    private let lock = NSLock()

    // Opening.
    private var openPhase = OpenPhase.waiting
    private var openWaiter: CheckedContinuation<Void, any Error>?

    // Receiving.
    private var receiveCounter = 0
    private var receiveWaiter: (id: Int, continuation: CheckedContinuation<RelayFrame, any Error>)?
    private var taskReceiveInFlight = false
    /// A frame that arrived after the receive that asked for it was
    /// cancelled, kept for the next receive.
    private var keptFrame: RelayFrame?
    /// Set once the socket has closed from either end. Every receive and
    /// send after that throws it.
    private var closed: RelaySocketClosed?
    /// The code from the delegate's `didCloseWith`, a fallback for when the
    /// task's own `closeCode` is not set yet.
    private var peerCloseCode: Int?
    /// Set by the first `close(code:)` or by `deinit`, whichever invalidates
    /// the session.
    private var closeClaimed = false

    // MARK: Opening

    /// Parks the connect until the socket opens or fails. Returns whether the
    /// caller should start the task; false when the connect already ended
    /// (cancelled before it parked), in which case `continuation` has been
    /// resumed.
    func awaitOpen(_ continuation: CheckedContinuation<Void, any Error>) -> Bool {
        let failure: (any Error)? = lock.withLock {
            switch openPhase {
            case .waiting:
                openWaiter = continuation
                return nil
            case .failed(let error):
                return error
            case .opened:
                // The task starts only after this call, so it cannot have
                // opened yet.
                return URLError(.unknown)
            }
        }
        guard let failure else { return true }
        continuation.resume(throwing: failure)
        return false
    }

    func opened() {
        let waiter: CheckedContinuation<Void, any Error>? = lock.withLock {
            guard case .waiting = openPhase else { return nil }
            openPhase = .opened
            defer { openWaiter = nil }
            return openWaiter
        }
        waiter?.resume()
    }

    /// Ends the connect with `error`. Does nothing once the socket opened or
    /// the connect already failed, so the connect resumes exactly once.
    func failOpen(_ error: any Error) {
        let waiter: CheckedContinuation<Void, any Error>? = lock.withLock {
            guard case .waiting = openPhase else { return nil }
            openPhase = .failed(error)
            defer { openWaiter = nil }
            return openWaiter
        }
        waiter?.resume(throwing: error)
    }

    // MARK: Closing

    func peerClosed(code: Int?) {
        lock.withLock {
            if peerCloseCode == nil {
                peerCloseCode = code
            }
        }
    }

    /// The close code to report: the task's, when it has one, else the one
    /// the delegate saw.
    func closeCode(reportedByTask taskCode: URLSessionWebSocketTask.CloseCode) -> Int? {
        if taskCode != .invalid {
            return taskCode.rawValue
        }
        return lock.withLock { peerCloseCode }
    }

    func closedError() -> RelaySocketClosed? {
        lock.withLock { closed }
    }

    /// Records a local close with `code`, drops a kept frame and fails a
    /// parked receive. Returns true only the first time, when the caller must
    /// close the task and invalidate the session.
    func closeLocally(code: Int) -> Bool {
        let claim: (waiter: CheckedContinuation<RelayFrame, any Error>?, error: RelaySocketClosed)? = lock.withLock {
            guard !closeClaimed else { return nil }
            closeClaimed = true
            let error = closed ?? RelaySocketClosed(code: code)
            closed = error
            keptFrame = nil
            defer { receiveWaiter = nil }
            return (receiveWaiter?.continuation, error)
        }
        guard let claim else { return false }
        claim.waiter?.resume(throwing: claim.error)
        return true
    }

    /// Claims the session's invalidation for `deinit`. False when
    /// `close(code:)` already invalidated it.
    func claimClose() -> Bool {
        lock.withLock {
            guard !closeClaimed else { return false }
            closeClaimed = true
            return true
        }
    }

    // MARK: Receiving

    func nextReceiveID() -> Int {
        lock.withLock {
            receiveCounter += 1
            return receiveCounter
        }
    }

    func parkReceive(_ continuation: CheckedContinuation<RelayFrame, any Error>, id: Int) -> ParkOutcome {
        let outcome: (ParkOutcome, Result<RelayFrame, any Error>?) = lock.withLock {
            if let frame = keptFrame {
                keptFrame = nil
                return (.answered, .success(frame))
            }
            if let closed {
                return (.answered, .failure(closed))
            }
            // Read under the lock: a cancellation that lands after this read
            // finds the continuation parked and resumes it.
            if Task.isCancelled {
                return (.answered, .failure(CancellationError()))
            }
            if receiveWaiter != nil {
                return (.answered, .failure(URLSessionRelayConcurrentReceive()))
            }
            receiveWaiter = (id, continuation)
            guard !taskReceiveInFlight else { return (.parked(startsTaskReceive: false), nil) }
            taskReceiveInFlight = true
            return (.parked(startsTaskReceive: true), nil)
        }
        if let answer = outcome.1 {
            continuation.resume(with: answer)
        }
        return outcome.0
    }

    func cancelReceive(id: Int) {
        let waiter: CheckedContinuation<RelayFrame, any Error>? = lock.withLock {
            guard let parked = receiveWaiter, parked.id == id else { return nil }
            receiveWaiter = nil
            return parked.continuation
        }
        waiter?.resume(throwing: CancellationError())
    }

    /// Delivers the task receive's result. A failure closes the socket with
    /// `closeCode`. With no receive parked, a frame is kept for the next one.
    func finishReceive(_ result: Result<URLSessionWebSocketTask.Message, any Error>, closeCode: Int?) {
        let delivery: (CheckedContinuation<RelayFrame, any Error>, Result<RelayFrame, any Error>)? = lock.withLock {
            taskReceiveInFlight = false
            let answer: Result<RelayFrame, any Error>
            if let closed {
                // Closed locally while the receive was in flight.
                answer = .failure(closed)
            } else {
                switch result {
                case .success(.data(let bytes)):
                    answer = .success(.binary(bytes))
                case .success(.string(let text)):
                    answer = .success(.text(text))
                case .success:
                    // A message kind this SDK does not know; the socket
                    // cannot carry the relay protocol any further.
                    let error = RelaySocketClosed(code: nil)
                    closed = error
                    answer = .failure(error)
                case .failure:
                    let error = RelaySocketClosed(code: closeCode)
                    closed = error
                    answer = .failure(error)
                }
            }
            guard let parked = receiveWaiter else {
                if case .success(let frame) = answer {
                    keptFrame = frame
                }
                return nil
            }
            receiveWaiter = nil
            return (parked.continuation, answer)
        }
        if let delivery {
            delivery.0.resume(with: delivery.1)
        }
    }
}

/// Thrown by a second `receive()` while one is parked on the same socket,
/// which no caller should do.
private struct URLSessionRelayConcurrentReceive: Error, LocalizedError {
    var errorDescription: String? {
        "Two receives were parked on one relay socket at once."
    }
}
