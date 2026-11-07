import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "phone-bridge")

/// The answer of the relay check its owner runs before each connect attempt
/// (`GET /v1/info`).
enum RelayPreflight: Sendable, Equatable {
    /// Connect.
    case proceed
    /// Count this attempt as an ordinary failure, for this reason, and back
    /// off: the relay could not be reached.
    case retryLater(String)
    /// Stop for good, for this reason: the relay is not one this laptop can
    /// use.
    case refuse(String)
}

/// What a ``RelayLink`` reports, in order, on ``RelayLink/events``.
enum RelayLinkEvent: Sendable, Equatable {
    /// A socket opened. Sends work until the next `.closed`.
    case opened
    /// The open socket ended: a close from either end, an error, the
    /// keepalive watchdog, `restart()` or `stop()`.
    case closed
    /// An attempt failed before a socket opened; the link backs off and
    /// tries again.
    case connectFailed(String)
    /// The relay check refused the relay. The link has stopped for good and
    /// `events` is finished.
    case refused(String)
    /// The relay's `peer-joined`: a new phone socket is in the room, and any
    /// channel with an earlier one is over.
    case peerJoined
    /// The relay's `peer-left`: the room has no phone socket. It can repeat.
    case peerLeft
    /// The relay's `peer-absent`.
    case peerAbsent
    /// One binary frame from the phone, unchanged.
    case frame(Data)
}

enum RelayLinkError: Error, Equatable, LocalizedError {
    /// No socket is open: the link has not opened yet, is backing off, or
    /// has stopped.
    case notOpen

    var errorDescription: String? {
        switch self {
        case .notOpen:
            return "The phone relay connection is not open."
        }
    }
}

/// How long a ``RelayLink`` waits before the next attempt.
struct PhoneBackoff: Sendable {
    var initial: Duration = PhoneBridgeConstants.reconnectInitial
    var maximum: Duration = PhoneBridgeConstants.reconnectMaximum
    /// Turns the capped delay into the delay slept. Production draws equal
    /// jitter, so two laptops that dropped together do not retry together;
    /// tests pass `{ $0 }`.
    var jitter: @Sendable (Duration) -> Duration = { PhoneBackoff.equalJitter($0, unit: Double.random(in: 0...1)) }

    /// The wait after `failures` consecutive failures (at least 1): `initial`
    /// doubled for each failure after the first, capped at `maximum`, then
    /// jittered.
    func delay(afterFailures failures: Int) -> Duration {
        // A realistic `maximum` is reached long before the cap on the
        // exponent, which only keeps the shift inside `Int`.
        let doublings = min(max(failures - 1, 0), 30)
        return jitter(min(initial * (1 << doublings), maximum))
    }

    /// Equal jitter: half of `delay`, plus `unit` (0 to 1) of the other half.
    /// The result is never below half the delay, so jitter cannot turn a
    /// backoff into a tight loop.
    static func equalJitter(_ delay: Duration, unit: Double) -> Duration {
        let half = delay / 2
        return half + half * min(max(unit, 0), 1)
    }
}

/// The laptop's socket in one relay room, kept open until `stop()`.
///
/// `start()` runs one loop:
///
/// 1. After a failure, it sleeps `backoff.delay(afterFailures:)` on the
///    injected clock.
/// 2. It awaits `preflight`. `.refuse` emits `.refused`, finishes `events`
///    and ends the link for good. `.retryLater` emits `.connectFailed` and
///    counts a failure.
/// 3. It connects. A throw emits `.connectFailed` and counts a failure.
/// 4. It emits `.opened` and runs a receive loop and a keepalive loop on the
///    socket. Whichever ends first closes the socket.
/// 5. It emits `.closed`. A stable connection (below) restarts the count at
///    one failure; any other adds one, so a socket that keeps dropping soon
///    after it opens waits longer each time. Close code 4000, another laptop
///    socket replacing this one, is such a drop: two laptops in one room back
///    off instead of knocking each other off in a tight loop.
///
/// The keepalive sends text `ping` every `keepalive`. A socket that has
/// received nothing since the last `ping` when the next one is due is dead:
/// after a laptop sleeps or changes networks the socket can stay half open
/// and report nothing, so the watchdog closes it and the loop reconnects.
/// A connection is stable once a frame arrives after its first `ping`, so it
/// has lasted a full keepalive interval and still carries traffic.
///
/// No task outlives `stop()`, which waits for the loop to end.
actor RelayLink {
    /// Every event, in order. Finished by `stop()` or a refusal, and never
    /// otherwise.
    nonisolated let events: AsyncStream<RelayLinkEvent>

    private static let normalClosure = 1000

    private let continuation: AsyncStream<RelayLinkEvent>.Continuation
    private let url: URL
    private let transport: any RelayTransport
    private let userAgent: String
    private let keepalive: Duration
    private let backoff: PhoneBackoff
    private let preflight: @Sendable () async -> RelayPreflight
    private let clock: any Clock<Duration>

    private var loopTask: Task<Void, Never>?
    /// Set by `stop()` or a refusal. A finished link never connects again.
    private var isFinished = false
    /// The open socket; nil while the link is down.
    private var socket: (any RelaySocket)?

    // The open socket's keepalive state, reset each time a socket opens.
    /// Whether a `ping` has gone out on this socket.
    private var sentPing = false
    /// Whether any frame has arrived since the last `ping` went out.
    private var receivedSincePing = false
    /// Whether a frame has arrived after the first `ping`.
    private var isStable = false
    /// The close code the open socket ended with, when it reported one.
    private var closeCode: Int?

    init(url: URL, transport: any RelayTransport, userAgent: String = PhoneBridgeConstants.userAgent,
         keepalive: Duration = PhoneBridgeConstants.keepaliveInterval, backoff: PhoneBackoff = PhoneBackoff(),
         preflight: @escaping @Sendable () async -> RelayPreflight = { .proceed },
         clock: any Clock<Duration> = ContinuousClock()) {
        let (stream, continuation) = AsyncStream.makeStream(of: RelayLinkEvent.self)
        self.events = stream
        self.continuation = continuation
        self.url = url
        self.transport = transport
        self.userAgent = userAgent
        self.keepalive = keepalive
        self.backoff = backoff
        self.preflight = preflight
        self.clock = clock
    }

    /// Whether a socket is open, so that `send` reaches the relay.
    var isOpen: Bool {
        socket != nil
    }

    /// Starts the loop. Does nothing once started, stopped or refused.
    func start() {
        guard loopTask == nil, !isFinished else { return }
        loopTask = Task { await self.run() }
    }

    /// Sends one binary frame on the open socket. Throws
    /// `RelayLinkError.notOpen` while the link is down.
    ///
    /// The socket is read once, before the send starts, so a frame goes out
    /// on the socket that was open when it was sent or not at all, never on
    /// a socket that a reconnect opened while it was in flight.
    func send(_ frame: Data) async throws {
        guard let open = socket else { throw RelayLinkError.notOpen }
        try await open.send(.binary(frame))
    }

    /// Closes the open socket now. The loop emits `.closed` and reconnects
    /// through the backoff. Does nothing while the link is down.
    func restart() async {
        guard let open = socket else { return }
        socket = nil
        await open.close(code: Self.normalClosure)
    }

    /// Closes the open socket with code 1000, ends the loop, waits for it,
    /// and finishes `events`. The link never connects again.
    func stop() async {
        isFinished = true
        let running = loopTask
        running?.cancel()
        if let open = socket {
            socket = nil
            await open.close(code: Self.normalClosure)
        }
        if let running {
            await running.value
        }
        continuation.finish()
    }

    // MARK: - The loop

    private func run() async {
        var failures = 0
        while !isFinished {
            if failures > 0 {
                do {
                    try await clock.sleep(for: backoff.delay(afterFailures: failures))
                } catch {
                    // Only `stop()` cancels the wait.
                    return
                }
                guard !isFinished else { return }
            }

            let verdict = await preflight()
            guard !isFinished else { return }
            switch verdict {
            case .proceed:
                break
            case .retryLater(let reason):
                logger.debug("relay check failed, backing off: \(reason, privacy: .public)")
                emit(.connectFailed(reason))
                failures += 1
                continue
            case .refuse(let reason):
                logger.notice("relay refused; the link stops: \(reason, privacy: .public)")
                isFinished = true
                emit(.refused(reason))
                continuation.finish()
                return
            }

            let opened: any RelaySocket
            do {
                opened = try await transport.connect(url: url, userAgent: userAgent)
            } catch {
                guard !isFinished else { return }
                let reason = error.localizedDescription
                logger.debug("relay connect failed, backing off: \(reason, privacy: .public)")
                emit(.connectFailed(reason))
                failures += 1
                continue
            }
            // `stop()` may have run while the connect was in flight.
            guard !isFinished else {
                await opened.close(code: Self.normalClosure)
                return
            }
            let wasStable = await serve(opened)
            failures = wasStable ? 1 : failures + 1
        }
    }

    /// Runs one open socket until it ends, and returns whether it was stable.
    private func serve(_ opened: any RelaySocket) async -> Bool {
        socket = opened
        sentPing = false
        receivedSincePing = false
        isStable = false
        closeCode = nil
        logger.debug("relay socket open")
        emit(.opened)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.receiveFrames(from: opened) }
            group.addTask { await self.keepAlive(on: opened) }
            // Whichever loop ends first ends the connection. Closing the
            // socket wakes a receive parked on it, and cancelling wakes the
            // keepalive's sleep, so the group's wait for its children ends.
            _ = await group.next()
            await opened.close(code: Self.normalClosure)
            group.cancelAll()
        }

        socket = nil
        let code = closeCode.map(String.init) ?? "none"
        logger.debug("relay socket closed, code \(code, privacy: .public), stable \(self.isStable, privacy: .public)")
        emit(.closed)
        return isStable
    }

    private func receiveFrames(from opened: any RelaySocket) async {
        while true {
            let frame: RelayFrame
            do {
                frame = try await opened.receive()
            } catch {
                closeCode = (error as? RelaySocketClosed)?.code
                return
            }
            receivedSincePing = true
            if sentPing {
                isStable = true
            }
            switch frame {
            case .binary(let bytes):
                emit(.frame(bytes))
            case .text("peer-joined"):
                emit(.peerJoined)
            case .text("peer-left"):
                emit(.peerLeft)
            case .text("peer-absent"):
                emit(.peerAbsent)
            case .text("pong"):
                break
            case .text(let other):
                logger.debug("ignored unknown relay text of \(other.utf8.count, privacy: .public) bytes")
            }
        }
    }

    private func keepAlive(on opened: any RelaySocket) async {
        while true {
            do {
                try await clock.sleep(for: keepalive)
            } catch {
                // The receive loop ended first, or `stop()`.
                return
            }
            if sentPing && !receivedSincePing {
                logger.notice("relay socket silent for a full keepalive interval after a ping; closing it")
                return
            }
            // Marked before the send, so an answer that arrives while the
            // send is in flight still counts.
            sentPing = true
            receivedSincePing = false
            do {
                try await opened.send(.text("ping"))
            } catch {
                return
            }
        }
    }

    private func emit(_ event: RelayLinkEvent) {
        continuation.yield(event)
    }
}
