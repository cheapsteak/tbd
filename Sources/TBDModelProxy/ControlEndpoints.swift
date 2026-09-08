import Darwin
import Foundation
import NIOCore
import NIOHTTP1
import TBDShared
import os

/// The `/tbd/...` verbs the daemon drives the proxy with.
///
/// They are deliberately not part of the forwarding path: everything under
/// `/r/<token>/` belongs to a session and is relayed byte for byte, and
/// everything under `/tbd/` belongs to whoever supervises this process. The
/// split is also what makes "is this our proxy?" answerable — the daemon
/// probes `GET /tbd/status` on a port it cannot bind and adopts the process
/// only if a TBD proxy answers.
///
/// A type of its own rather than a branch in the request handler, because two
/// of the three verbs do real work — `retire` closes the listener and then
/// waits out the streams still running on it, `routes` reads and unlinks files
/// — and because a handler on an event loop is the wrong place to await an
/// actor.
final class ControlEndpoints: Sendable {
    static let log = Logger(subsystem: "com.tbd.modelproxy", category: "control")

    /// One answer. Always JSON, always with a status: a supervisor reading
    /// these is a program, not a person.
    struct Response: Sendable {
        let status: HTTPResponseStatus
        let body: String
        /// Work that may only begin once this answer is on the wire.
        ///
        /// Retire is the reason it exists, and the reason it is a callback
        /// rather than something the endpoint just does before returning: the
        /// drain ends in `onRetire`, which in production is `exit(0)`. An idle
        /// proxy drains on its first sample, so starting the drain before the
        /// 200 has been written races the process's own exit against its
        /// answer — and a supervisor that gets a connection reset instead of
        /// the handshake has no way to tell a retiring proxy from a crashed
        /// one. The caller invokes this from the write's completion.
        let afterAnswer: (@Sendable () -> Void)?

        init(
            _ status: HTTPResponseStatus, _ body: String,
            afterAnswer: (@Sendable () -> Void)? = nil
        ) {
            self.status = status
            self.body = body
            self.afterAnswer = afterAnswer
        }
    }

    static let forbiddenBody = #"{"error":"loopback only"}"#
    static let unknownEndpointBody = #"{"error":"unknown control endpoint"}"#
    static let methodNotAllowedBody = #"{"error":"method not allowed"}"#
    static let retiringBody = #"{"retiring":true}"#
    static let removedBody = #"{"removed":true}"#
    static let statusUnreadableBody = #"{"error":"status could not be encoded"}"#

    private let routes: RouteTable
    /// When a daemon last spoke to this proxy. Every `/tbd/…` call from
    /// loopback stamps it, and the retention watch reads it; see
    /// `LastDaemonContact`.
    private let contact: LastDaemonContact
    private let status: @Sendable () -> ModelProxyStatus
    /// Called once the retire drain finishes. Production passes `exit(0)`; a
    /// test passes a recorder, which is the only reason the process's own exit
    /// is injectable at all.
    private let onRetire: @Sendable () -> Void
    /// Closes the listening socket. In production it also releases the
    /// process's rendezvous lock, which is why retire waits for it before
    /// answering rather than starting it alongside the drain.
    private let closeListener: @Sendable () async -> Void
    private let streamsInFlight: @Sendable () -> Int
    private let pollInterval: Duration
    private let drainCap: Duration
    private let clock: any Clock<Duration>
    /// Whether a drain has already been started. Two retires — a supervisor
    /// that retried, or two of them — must not run two drains, because each
    /// one ends in `onRetire` and `exit(0)` is not a thing to call twice.
    private let drainStarted = DrainLatch()

    init(
        routes: RouteTable,
        status: @escaping @Sendable () -> ModelProxyStatus,
        onRetire: @escaping @Sendable () -> Void,
        closeListener: @escaping @Sendable () async -> Void,
        streamsInFlight: @escaping @Sendable () -> Int,
        contact: LastDaemonContact = LastDaemonContact(),
        pollInterval: Duration = .milliseconds(250),
        drainCap: Duration = .seconds(600),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.routes = routes
        self.contact = contact
        self.status = status
        self.onRetire = onRetire
        self.closeListener = closeListener
        self.streamsInFlight = streamsInFlight
        self.pollInterval = pollInterval
        self.drainCap = drainCap
        self.clock = clock
    }

    /// When a daemon last drove one of these verbs, readable without awaiting
    /// anything — the retention watch samples it on a timer.
    var lastDaemonContact: Date { contact.value }

    // MARK: - Dispatch

    /// Answers one `/tbd/...` request.
    ///
    /// `remoteAddress` must be read on the channel's event loop by the caller
    /// and handed in; nothing here touches a NIO channel.
    func handle(
        method: String, path: String, body: [UInt8], remoteAddress: SocketAddress?
    ) async -> Response {
        // Defense in depth: the listener only ever binds 127.0.0.1, so a
        // connection from anywhere else should be unreachable. It is checked
        // anyway because the cost of being wrong is a local-network process
        // retiring a proxy or enumerating a route, and because a future change
        // to the bind address must not silently open these verbs.
        guard Self.isLoopback(remoteAddress) else {
            Self.log.error("refused a control request from a non-loopback address")
            return Response(.forbidden, Self.forbiddenBody)
        }

        // Stamped for every `/tbd/…` verb, including the ones that end in 404
        // or 405: what the retention watch asks is "has anybody been
        // supervising this proxy", and a daemon that asked for an endpoint
        // this image does not have is still a daemon that is there. Stamped
        // after the loopback guard and not before, because a refused caller is
        // by definition not the daemon.
        contact.stamp()

        let verb = method.uppercased()
        switch path {
        case "/tbd/status":
            guard verb == "GET" else { return Response(.methodNotAllowed, Self.methodNotAllowedBody) }
            return statusResponse()

        case "/tbd/retire":
            guard verb == "POST" else { return Response(.methodNotAllowed, Self.methodNotAllowedBody) }
            return await retire()

        case "/tbd/routes":
            guard verb == "POST" else { return Response(.methodNotAllowed, Self.methodNotAllowedBody) }
            return await addRoute(body: body)

        default:
            guard let token = Self.routesToken(path: path) else {
                return Response(.notFound, Self.unknownEndpointBody)
            }
            guard verb == "DELETE" else {
                return Response(.methodNotAllowed, Self.methodNotAllowedBody)
            }
            // Idempotent by contract: the daemon retires a route it may have
            // already retired, and a 404 there would make a supervisor's
            // cleanup pass look like a failure.
            await routes.remove(token: token)
            return Response(.ok, Self.removedBody)
        }
    }

    /// The token in `/tbd/routes/<token>`, or nil for anything else under
    /// `/tbd/`. The token is *not* validated here — `RouteTable.remove`
    /// whitelists it before it can compose a path, and a malformed one is
    /// still a 200 because removing something that cannot exist has succeeded.
    static func routesToken(path: String) -> String? {
        let prefix = "/tbd/routes/"
        guard path.hasPrefix(prefix) else { return nil }
        let token = String(path.dropFirst(prefix.count))
        guard !token.isEmpty, !token.contains("/") else { return nil }
        return token
    }

    // MARK: - Status

    /// The proxy's identity and its live counters.
    ///
    /// The injected closure supplies what only the process knows — its build
    /// identity, pid, start time and port — and the two counters are read here,
    /// at the moment of the request, from the server's own in-flight counter
    /// and the route table's cached count. The closure is synchronous by
    /// contract and cannot await an actor, and a status reporting a count
    /// somebody had cached at start-up would be worse than no count at all.
    private func statusResponse() -> Response {
        let identity = status()
        let live = ModelProxyStatus(
            version: identity.version,
            pid: identity.pid,
            processStartTime: identity.processStartTime,
            port: identity.port,
            streamsInFlight: streamsInFlight(),
            routeCount: routes.currentCount)
        guard let encoded = try? live.encodedForStatusResponse(),
            let text = String(data: encoded, encoding: .utf8)
        else {
            return Response(.internalServerError, Self.statusUnreadableBody)
        }
        return Response(.ok, text)
    }

    // MARK: - Retire

    /// Closes the listener, answers, and drains afterwards.
    ///
    /// The order is the whole point (spec, "Control endpoint"): the successor
    /// binds the moment this answer arrives, so the no-listener gap is the
    /// successor's bind time rather than the length of whatever turn is still
    /// running. The streams already open keep flowing on the connections they
    /// are already on — closing a listening socket does not touch them.
    ///
    /// The drain is handed back rather than started here. On an idle proxy the
    /// drain finishes on its first sample and calls `onRetire`, which is
    /// `exit(0)`; started before the answer was written, it would race the
    /// process's own exit against its 200.
    ///
    /// `closeListener` is also where the process drops its rendezvous lock, so
    /// by the time this answers, the successor's spawner can take the lock as
    /// well as the port. Holding it through the drain would block that spawn
    /// for as long as the drain runs — up to the cap — with nothing listening
    /// on the port meanwhile.
    private func retire() async -> Response {
        await closeListener()
        return Response(.ok, Self.retiringBody, afterAnswer: { [self] in startDrain() })
    }

    /// Waits for the last in-flight stream and then hands over to `onRetire`.
    ///
    /// A poll rather than a completion, because a stream ends on an event loop
    /// with nothing to await, and because the count is the same number the
    /// status endpoint reports — one source of truth for "is this proxy still
    /// carrying a turn". The cap exists so a stream that never ends cannot
    /// leave a retired proxy running forever; 10 minutes is far past Claude's
    /// own 183-second retry budget.
    private func startDrain() {
        guard drainStarted.claim() else {
            Self.log.debug("retire drain already running; not starting a second")
            return
        }
        let onRetire = self.onRetire
        let streamsInFlight = self.streamsInFlight
        let clock = self.clock
        let interval = pollInterval
        let polls = Self.pollCount(cap: drainCap, interval: pollInterval)

        Task {
            for _ in 0..<polls {
                if streamsInFlight() == 0 {
                    Self.log.debug("retire drain finished with no streams in flight")
                    onRetire()
                    return
                }
                try? await clock.sleep(for: interval)
            }
            Self.log.error(
                "retire drain hit its cap with \(streamsInFlight(), privacy: .public) stream(s) still in flight"
            )
            onRetire()
        }
    }

    /// How many times the drain samples before it gives up. At least one, so a
    /// cap shorter than an interval still checks once rather than exiting
    /// immediately.
    static func pollCount(cap: Duration, interval: Duration) -> Int {
        let capMillis = milliseconds(cap)
        let intervalMillis = max(1, milliseconds(interval))
        return max(1, Int(capMillis / intervalMillis))
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
    }

    // MARK: - Routes

    /// Takes the route the daemon just wrote.
    ///
    /// The proxy reads the file rather than the request: the body names a
    /// token and nothing else, and every fact the proxy will act on — the
    /// upstream, the terminal, the streaming decision — comes off disk, where
    /// only the daemon can have put it.
    private func addRoute(body: [UInt8]) async -> Response {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
            let token = object["token"] as? String
        else {
            return Response(.badRequest, Self.errorBody("body must be {\"token\":\"…\"}"))
        }

        do {
            let route = try await routes.add(token: token)
            guard let encoded = try? route.encodedForRouteFile(),
                let text = String(data: encoded, encoding: .utf8)
            else {
                return Response(.internalServerError, Self.errorBody("route could not be encoded"))
            }
            return Response(.ok, text)
        } catch let error as RouteTable.RouteError {
            switch error {
            case .unreadable:
                // The daemon writes the file before it calls this, so a
                // missing one means the two disagree about what exists —
                // reported as 404 rather than folded into the 400s, because
                // "you never wrote it" and "what you wrote is wrong" call for
                // different fixes.
                return Response(.notFound, Self.errorBody(error.reason))
            default:
                return Response(.badRequest, Self.errorBody(error.reason))
            }
        } catch {
            return Response(.badRequest, Self.errorBody("route could not be taken"))
        }
    }

    /// `{"error":"…"}` with the message JSON-escaped through a real encoder, so
    /// a reason carrying a quote stays a JSON document.
    static func errorBody(_ message: String) -> String {
        let escaped =
            (try? JSONEncoder().encode([message]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { text -> String? in
                guard text.count > 2 else { return nil }
                return String(text.dropFirst().dropLast())
            } ?? "\"control request refused\""
        return #"{"error":\#(escaped)}"#
    }

    // MARK: - Loopback

    /// True for 127.0.0.0/8, `::1`, and an IPv4-mapped loopback address.
    ///
    /// Compared as bytes rather than as text: a string form has several
    /// spellings per address (`::1`, `0:0:0:0:0:0:0:1`, `::ffff:127.0.0.1`),
    /// and a prefix test over any of them is a check that can be written to
    /// pass by a caller who chooses the spelling.
    static func isLoopback(_ address: SocketAddress?) -> Bool {
        switch address {
        case .some(.v4(let v4)):
            return UInt32(bigEndian: v4.address.sin_addr.s_addr) >> 24 == 127
        case .some(.v6(let v6)):
            var raw = v6.address.sin6_addr
            let bytes = withUnsafeBytes(of: &raw) { Array($0) }
            guard bytes.count == 16 else { return false }
            if bytes == Self.loopbackV6 { return true }
            // `::ffff:a.b.c.d` — an IPv4 address reached over an IPv6 socket.
            guard bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff
            else { return false }
            return bytes[12] == 127
        case .some(.unixDomainSocket), .none:
            // The proxy binds TCP loopback and nothing else, so neither shape
            // is a connection it can serve. A missing address is refused
            // rather than trusted: it is the one case where the check has
            // learned nothing.
            return false
        }
    }

    private static let loopbackV6: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
}

/// The moment a daemon last spoke to this proxy.
///
/// Seeded at construction rather than at the epoch: a proxy that has never
/// been contacted has still only just started, and seeding at zero would make
/// every fresh proxy instantly eligible to retire itself. The 24-hour window
/// (spec, "Retention") therefore runs from start-up until the first `/tbd/…`
/// call and from that call afterwards.
///
/// A `Date` rather than a `Clock` instant, per the repo's clock/date split:
/// this is *data* being compared against a wall-clock window, while the watch's
/// polling interval is *behavior* and takes the injected `Clock`. The `now`
/// seam is here so a test can move the stamp without moving the machine.
final class LastDaemonContact: Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private nonisolated(unsafe) var stamped: Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        self.stamped = now()
    }

    var value: Date { lock.withLock { stamped } }

    func stamp() {
        // Read the clock outside the lock: `now` is injected, and a test's
        // closure has no business running under a lock this process's control
        // path also takes.
        let moment = now()
        lock.withLock { stamped = moment }
    }
}

/// A one-shot claim. The first caller wins and every later one is told so.
private final class DrainLatch: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
