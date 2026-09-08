import Foundation
import TBDShared
import os

/// The daemon's half of the proxy's control endpoint (spec, "Control
/// endpoint").
///
/// Four verbs, all on `127.0.0.1` and all short: `GET /tbd/status` is the
/// probe every adoption and every watch poll runs, `POST /tbd/retire` hands a
/// port over to a successor, and the two route verbs tell a proxy that a route
/// file appeared or should be dropped.
///
/// **The host is not a parameter.** A client is constructed from a port and
/// composes `http://127.0.0.1:<port>` itself, because every one of these verbs
/// is an actuation on a process this daemon supervises — retiring it,
/// enumerating what it serves — and a host that could come from a config row
/// or a config file is a host that could point them at somebody else's
/// machine. The proxy refuses non-loopback callers on its side for the same
/// reason (`ControlEndpoints.isLoopback`); this is the other half.
///
/// **Two seconds, and no retry.** Every caller is a supervisor with its own
/// loop: the watch polls again on its next tick and the spawn path fails a
/// spawn rather than hanging one. A control verb that has not answered in two
/// seconds is answering a different question — the process is wedged, gone, or
/// not ours — and waiting longer only delays that verdict. The timeout is a
/// `URLSession` deadline rather than an injected clock because there is no
/// sleep here to fake: the request either lands or it does not.
struct ModelProxyClient: Sendable {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "model-proxy")

    /// How long one control request may take before it is a failure.
    static let defaultRequestTimeout: TimeInterval = 2

    enum Error: LocalizedError, Equatable {
        /// Nothing answered, or the answer never finished. The detail is the
        /// transport's own description and carries no request body.
        case unreachable(detail: String)
        /// Something answered with a status this verb does not accept. The
        /// body is truncated because a supervisor logs this and an unbounded
        /// body from an unknown process on that port is not something to put
        /// in a log line whole.
        case unexpectedStatus(code: Int, body: String)
        /// The answer was not the document this verb expects — which is how a
        /// non-TBD process holding the port is told apart from a proxy.
        case malformedResponse(detail: String)
        /// A token that is not 32 lowercase hex characters. Refused here,
        /// before it can compose a URL path, for the same reason
        /// `RouteTable` refuses one before it can compose a file path.
        case invalidToken(String)

        var errorDescription: String? {
            switch self {
            case .unreachable(let detail):
                return "the model proxy did not answer: \(detail)"
            case .unexpectedStatus(let code, let body):
                return "the model proxy answered \(code): \(body)"
            case .malformedResponse(let detail):
                return "the model proxy's answer could not be read: \(detail)"
            case .invalidToken(let token):
                return "refusing to name \(token) in a control request: not a route token"
            }
        }
    }

    let port: Int
    private let session: URLSession
    private let requestTimeout: TimeInterval

    init(
        port: Int,
        session: URLSession = ModelProxyClient.makeSession(),
        requestTimeout: TimeInterval = ModelProxyClient.defaultRequestTimeout
    ) {
        self.port = port
        self.session = session
        self.requestTimeout = requestTimeout
    }

    /// The session a client gets when nobody injects one.
    ///
    /// Ephemeral so nothing about a control call is cached or written to disk,
    /// and with an **empty proxy dictionary**: a developer's system-wide HTTP
    /// proxy would otherwise be consulted for `127.0.0.1`, and a supervisor
    /// probing its own proxy through somebody else's is a failure mode with no
    /// upside. One connection is enough — these verbs are never concurrent per
    /// proxy.
    static func makeSession(requestTimeout: TimeInterval = defaultRequestTimeout) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.waitsForConnectivity = false
        configuration.httpShouldUsePipelining = false
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }

    // MARK: - Verbs

    /// `GET /tbd/status`.
    ///
    /// Decoded through `ModelProxyStatus.decodeStatusResponse`, which pins the
    /// date strategy on both sides: adoption compares `processStartTime`
    /// against the process table, and a decoder that rounded the fraction away
    /// would make a live proxy look like somebody else's process.
    func status() async throws -> ModelProxyStatus {
        let data = try await send(operation: "status", method: "GET", path: "/tbd/status", body: nil)
        do {
            return try ModelProxyStatus.decodeStatusResponse(data)
        } catch {
            throw Error.malformedResponse(detail: "\(error)")
        }
    }

    /// `POST /tbd/retire`. Returns once the proxy says its listener is closed,
    /// which is the moment a successor may bind.
    func retire() async throws {
        _ = try await send(operation: "retire", method: "POST", path: "/tbd/retire", body: nil)
    }

    /// `POST /tbd/routes` — "a route file for this token is on disk now".
    ///
    /// The body names the token and nothing else. Every fact the proxy acts on
    /// comes off the file the daemon wrote, so a request cannot introduce an
    /// upstream or a terminal id.
    func addRoute(token: String) async throws {
        guard ModelProxyRoute.isValidToken(token) else { throw Error.invalidToken(token) }
        let body = try JSONSerialization.data(withJSONObject: ["token": token])
        _ = try await send(operation: "registerRoute", method: "POST", path: "/tbd/routes", body: body)
    }

    /// `DELETE /tbd/routes/<token>`. Idempotent by the proxy's contract: a
    /// route already gone is a 200, so a supervisor's cleanup pass may run
    /// twice.
    func removeRoute(token: String) async throws {
        guard ModelProxyRoute.isValidToken(token) else { throw Error.invalidToken(token) }
        _ = try await send(
            operation: "removeRoute", method: "DELETE", path: "/tbd/routes/\(token)", body: nil)
    }

    // MARK: - Transport

    /// The message logged when a control request could not reach the proxy at
    /// all.
    ///
    /// Deliberately built from `operation` — one of the fixed labels each verb
    /// above passes in — and never from the request `path`: `removeRoute`
    /// composes its path as `/tbd/routes/<token>`, and a live bearer token has
    /// no business in the system log at any privacy level this daemon does not
    /// control. Pulled out as a pure function, rather than inlined in the
    /// `logger.debug` call, so a test can pin that its output can never carry
    /// a token without needing to observe the logger itself.
    static func unreachableLogMessage(operation: String, port: Int, detail: String) -> String {
        "model proxy control \(operation) on port \(port) did not answer: \(detail)"
    }

    private func send(operation: String, method: String, path: String, body: Data?) async throws -> Data {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            // `detail` reaches `Error.errorDescription` and from there a
            // caller's log line at `.public` (e.g. `ModelProxySupervisor`'s
            // `makeRoute`/`retireRoute`), so it names the operation rather
            // than `path` — `removeRoute`'s path is `/tbd/routes/<token>`.
            // Unreachable in practice: every path above is composed from a
            // literal or a token already validated as 32 lowercase hex, which
            // can never fail to parse as a URL path component.
            throw Error.unreachable(detail: "could not compose a URL for \(operation) on port \(port)")
        }
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: requestTimeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let message = Self.unreachableLogMessage(
                operation: operation, port: port, detail: error.localizedDescription)
            Self.logger.debug("\(message, privacy: .public)")
            throw Error.unreachable(detail: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Error.malformedResponse(detail: "not an HTTP response")
        }
        guard http.statusCode == 200 else {
            throw Error.unexpectedStatus(code: http.statusCode, body: Self.excerpt(data))
        }
        return data
    }

    /// At most 200 bytes of whatever answered, rendered as text. A process
    /// that is not a proxy can put anything on that port, and the excerpt is
    /// the diagnostic that says what it was without pasting it whole into a
    /// log.
    static func excerpt(_ data: Data) -> String {
        // Failable, and the fallback is the point: a process that is not a
        // proxy can answer with anything, including bytes that are not text,
        // and a 200-byte cut can land mid-character in an answer that is. The
        // byte count is the honest diagnostic for both.
        guard let text = String(bytes: data.prefix(200), encoding: .utf8) else {
            return "<\(data.count) bytes that are not UTF-8 text>"
        }
        return data.count > 200 ? text + "…" : text
    }
}
