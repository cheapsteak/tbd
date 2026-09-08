import CFNetwork
import Foundation
import os

/// One upstream leg of a forwarded request.
///
/// The contract is byte-transparency in both directions. Claude's retry and
/// capability-disable logic matches on the upstream's *error wording*, and
/// prompt caching depends on the `system` array reaching the API in the order
/// the client wrote it, so a proxy that re-serializes either body breaks both
/// silently. Nothing here parses a body; the request bytes go up as they came
/// in and the response bytes come back out as they arrive.
struct UpstreamForwarder: Sendable {
    /// Hop-by-hop headers plus the three the client's framing owns.
    ///
    /// `accept-encoding` is the only *content* header dropped, and it is
    /// dropped so the upstream sends the stream uncompressed and the tee can
    /// read it. `host` and `content-length` are re-derived by the upstream
    /// leg, and forwarding the client's would describe the wrong connection.
    /// Everything else — `anthropic-version`, `anthropic-beta`, every
    /// `x-claude-code-*` and `x-stainless-*` — passes verbatim, as an open
    /// list rather than an allowlist: Anthropic has refused new beta headers
    /// behind a custom base URL before, and the OAuth capability rides in
    /// `anthropic-beta`, so stripping an unrecognised one is a 401.
    static let droppedRequestHeaders: Set<String> = [
        "connection", "keep-alive", "proxy-connection", "transfer-encoding", "te", "trailer",
        "upgrade", "host", "content-length", "accept-encoding",
    ]

    /// Response headers the relay re-derives rather than copies. Every other
    /// response header passes untouched.
    static let droppedResponseHeaders: Set<String> = [
        "connection", "keep-alive", "transfer-encoding", "content-length",
    ]

    /// What the proxy asks the upstream to send.
    ///
    /// Not merely "no gzip": `URLSession` adds `Accept-Encoding: gzip, deflate,
    /// br` when a request does not set one and then *transparently
    /// decompresses* what comes back, which would leave the relay handing the
    /// client a body whose bytes and whose `Content-Encoding` header disagree.
    /// Asking for `identity` is what keeps the response bytes the upstream's
    /// own.
    static let requestedEncoding = "identity"

    private static let log = Logger(subsystem: "com.tbd.modelproxy", category: "upstream")

    private let session: URLSession
    /// The session's own delegate, which is where every callback for a task
    /// started on it arrives.
    private let registry: UpstreamSinkRegistry

    /// A session and the sink its callbacks reach are one thing, not two.
    ///
    /// A `URLSession` built without a `URLSessionDataDelegate` delivers a
    /// data task's bytes nowhere, and a forwarder holding such a session would
    /// wait on an `onEnd` that never comes — a hang with no timeout above it,
    /// because the *task* completes fine and it is only the notification that
    /// is lost. So a session that did not come from `makeSession` is not used
    /// bare: its configuration is reused behind a session that does have the
    /// sink.
    init(session: URLSession) {
        if let registry = session.delegate as? UpstreamSinkRegistry {
            self.session = session
            self.registry = registry
        } else {
            let registry = UpstreamSinkRegistry()
            self.session = URLSession(
                configuration: session.configuration, delegate: registry, delegateQueue: nil)
            self.registry = registry
        }
    }

    /// The session every production forward runs on.
    ///
    /// - No cookie or credential storage and no cache: the proxy holds no
    ///   state of its own between requests, and a cached model response would
    ///   be a correctness bug rather than an optimisation.
    /// - `timeoutIntervalForRequest = 600` and `timeoutIntervalForResource =
    ///   3600` by default — parameters only so a test can ask for a leg that
    ///   gives up in seconds — both far above the 300 seconds a stream may sit silent between
    ///   SSE pings. `URLSession`'s request timeout measures the gap between
    ///   *bytes*, not the whole call, so a long streamed turn is bounded by
    ///   the resource timeout alone.
    /// - `HTTPS_PROXY`/`NO_PROXY` from the environment, so a user behind a
    ///   corporate proxy keeps working. The environment is a parameter so a
    ///   test can prove loopback is never proxied.
    static func makeSession(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        requestTimeout: TimeInterval = 600,
        resourceTimeout: TimeInterval = 3600
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpAdditionalHeaders = nil
        configuration.httpMaximumConnectionsPerHost = 32
        configuration.waitsForConnectivity = false
        if let proxies = proxyDictionary(environment: environment) {
            configuration.connectionProxyDictionary = proxies
        }
        return URLSession(
            configuration: configuration,
            delegate: UpstreamSinkRegistry(),
            delegateQueue: nil)
    }

    /// `connectionProxyDictionary` for `HTTPS_PROXY`, or nil when the process
    /// names no proxy.
    ///
    /// Loopback is always in the exception list, whatever `NO_PROXY` says. A
    /// route's upstream is normally `https://api.anthropic.com`, but the
    /// proxy's own tests point it at a loopback fake, and a developer with
    /// `HTTPS_PROXY` set in their shell would otherwise send those requests
    /// through a corporate proxy that cannot reach 127.0.0.1.
    static func proxyDictionary(environment: [String: String]) -> [AnyHashable: Any]? {
        let noProxy = (environment["NO_PROXY"] ?? environment["no_proxy"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // `NO_PROXY=*` is the conventional "never proxy anything"; honoring it
        // by returning no dictionary is simpler than an exception list that
        // has to match every host.
        guard !noProxy.contains("*") else { return nil }

        let raw = (environment["HTTPS_PROXY"] ?? environment["https_proxy"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }

        // A bare `host:port` is as common in these variables as a URL, and
        // `URLComponents` reads the host of one as the *scheme* of the other.
        let normalized = raw.contains("://") ? raw : "http://\(raw)"
        guard let components = URLComponents(string: normalized),
            let host = components.host, !host.isEmpty
        else {
            log.error("ignoring unparseable HTTPS_PROXY")
            return nil
        }
        let port = components.port ?? (components.scheme?.lowercased() == "https" ? 443 : 80)

        // A `NO_PROXY` entry conventionally suffix-matches on a leading dot;
        // CFNetwork's exception list is glob-shaped, so `.acme.com` becomes
        // `*.acme.com` and a bare `acme.com` is left as the exact host it is.
        var exceptions = noProxy.map { $0.hasPrefix(".") ? "*\($0)" : $0 }
        exceptions.append(contentsOf: ["127.0.0.1", "localhost", "::1", "*.local"])

        return [
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: host,
            kCFNetworkProxiesHTTPSPort as String: port,
            kCFNetworkProxiesExceptionsList as String: exceptions,
            kCFNetworkProxiesExcludeSimpleHostnames as String: true,
        ]
    }

    /// Streams one request upstream.
    ///
    /// `onHead` fires once when the response head arrives, `onChunk` once per
    /// slice the upstream delivered — never accumulated to a size, because
    /// Claude counts SSE pings and aborts a stream that has been silent for
    /// 300 seconds — and `onEnd` exactly once. `onEnd`'s error is whatever the
    /// upstream leg failed with, including a failure *after* the head; the
    /// caller knows whether it has already relayed a head and is the only one
    /// that can decide between a 502 and a truncated body.
    ///
    /// `onEnd` fires exactly once on **every** exit, cancellation included —
    /// with a `CancellationError` when this task was cancelled before the
    /// upstream reported, which is what a client hanging up mid-turn looks
    /// like. The caller's in-flight accounting and its tee both close on that
    /// call and on nothing else.
    func forward(
        method: String,
        url: URL,
        headers: [(String, String)],
        body: [UInt8],
        onHead: @Sendable (Int, [(String, String)]) -> Void,
        onChunk: @Sendable ([UInt8]) -> Void,
        onEnd: @Sendable (Error?) -> Void
    ) async {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpShouldHandleCookies = false
        // `addValue`, not `setValue`: a client may send the same header twice
        // (`anthropic-beta` is the one that does), and `setValue` would keep
        // only the last. `addValue` does not put a second header *line* on the
        // wire — `URLRequest` joins repeats of one field name with a comma —
        // but for the list-valued headers Claude repeats, `a, b` and two `a` /
        // `b` lines are the same field value (RFC 9110 §5.3), so no value is
        // lost. A header whose repeats are *not* list-valued would be
        // corrupted by this, and no such header exists on this path.
        for (name, value) in headers
        where !Self.droppedRequestHeaders.contains(name.lowercased()) {
            request.addValue(value, forHTTPHeaderField: name)
        }
        request.setValue(Self.requestedEncoding, forHTTPHeaderField: "Accept-Encoding")
        if !body.isEmpty {
            request.httpBody = Data(body)
        }

        let (events, continuation) = AsyncStream.makeStream(of: UpstreamEvent.self)
        let task = session.dataTask(with: request)
        // Registered before `resume`, because the first callback can arrive on
        // the delegate queue the moment the task starts.
        registry.register(task: task) { event in
            continuation.yield(event)
            if case .end = event { continuation.finish() }
        }
        let boxed = SendableURLSessionTask(task: task)
        task.resume()

        await withTaskCancellationHandler {
            var sawEnd = false
            for await event in events {
                switch event {
                case .head(let status, let responseHeaders):
                    onHead(status, responseHeaders)
                case .chunk(let bytes):
                    onChunk(bytes)
                case .end(let error):
                    sawEnd = true
                    onEnd(error)
                }
            }
            // A cancelled `AsyncStream` iterator finishes *immediately*: the
            // `.end` the delegate is about to yield lands in a stream nobody
            // reads. So the loop exiting is not proof the upstream leg
            // reported, and `onEnd` is this call's only promise — the caller
            // hangs its in-flight count, its tee's `end(error:)` and its
            // channel teardown on it. The ordinary way to get here is the
            // user pressing Esc: the client hangs up, the handler cancels this
            // task, and the turn is an aborted one.
            if !sawEnd { onEnd(CancellationError()) }
        } onCancel: {
            // The client hung up. Nothing downstream will read the rest of
            // this response, and an abandoned upstream connection would hold a
            // model request open for its full budget.
            boxed.task.cancel()
        }
    }
}

// MARK: - Delegate plumbing

/// What the upstream leg produces, in wire order.
enum UpstreamEvent: @unchecked Sendable {
    case head(Int, [(String, String)])
    case chunk([UInt8])
    case end(Error?)
}

/// `URLSessionTask` is not `Sendable`, but `cancel()` is documented as safe
/// from any thread; this box carries exactly that one use into a cancellation
/// handler.
private struct SendableURLSessionTask: @unchecked Sendable {
    let task: URLSessionTask
}

/// Routes `URLSession` delegate callbacks to the `forward` call that started
/// each task.
///
/// A delegate rather than `URLSession.bytes(for:)`. `AsyncBytes` is an
/// `AsyncSequence` of `UInt8`: the chunk boundaries the OS delivered are gone
/// by the time a caller sees the bytes, so relaying "each chunk as it arrives"
/// on top of it means either one `writeAndFlush` per byte or a timer-driven
/// flush that guesses where a chunk ended. `urlSession(_:dataTask:didReceive:)`
/// hands over exactly the slices the network produced, which is what the
/// per-event flush rule asks for and what makes the relay's timing the
/// upstream's timing.
///
/// `@unchecked Sendable`: the sink table is guarded by a lock, and the
/// callbacks arrive on the session's serial delegate queue.
final class UpstreamSinkRegistry: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [ObjectIdentifier: @Sendable (UpstreamEvent) -> Void] = [:]

    /// Keyed by object identity rather than `taskIdentifier`, which is only
    /// unique within one session — and this registry may serve two.
    func register(task: URLSessionTask, sink: @escaping @Sendable (UpstreamEvent) -> Void) {
        lock.withLock { sinks[ObjectIdentifier(task)] = sink }
    }

    private func sink(for task: URLSessionTask) -> (@Sendable (UpstreamEvent) -> Void)? {
        lock.withLock { sinks[ObjectIdentifier(task)] }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            var headers: [(String, String)] = []
            for (name, value) in http.allHeaderFields {
                guard let name = name as? String else { continue }
                headers.append((name, String(describing: value)))
            }
            sink(for: dataTask)?(.head(http.statusCode, headers))
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        sink(for: dataTask)?(.chunk([UInt8](data)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let sink = lock.withLock { sinks.removeValue(forKey: ObjectIdentifier(task)) }
        sink?(.end(error))
    }
}
