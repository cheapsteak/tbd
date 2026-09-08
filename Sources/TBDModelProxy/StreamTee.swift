import Darwin
import Foundation
import TBDShared
import os

/// The copy of a forwarded response that becomes a terminal's stream file.
///
/// The tee exists so the app can render assistant text as it is generated
/// rather than when Claude Code finally writes its transcript JSONL. It is
/// deliberately *downstream* of the forward: `ProxyServer` hands it copies of
/// chunks through an `AsyncStream` and never waits for it, so a slow disk, a
/// full filesystem, or a parser that gives up costs the turn the user is
/// watching nothing at all. Everything here is best effort; nothing here can
/// fail a request.
///
/// An actor because two decisions have to be serialized against each other
/// across concurrent requests on one route: whether a `message_start`
/// truncates the file or appends to it, and the count of messages in flight
/// that answers it. A lock would do for the count alone, but the count is read
/// and then acted on, and the window between those two is exactly the race
/// that would let two parent turns clobber each other's text.
actor StreamTee: StreamTeeing {
    static let log = Logger(subsystem: "com.tbd.modelproxy", category: "tee")

    /// The most an unterminated SSE event may buffer before the tee gives up on
    /// the message.
    ///
    /// `SSEEventParser` retains everything since the last blank line, so an
    /// upstream that never sends one — a wrong content type, a proxy in the
    /// middle that mangles framing, a hostile route — would grow that buffer
    /// for the life of the stream. One mebibyte is far past any real event
    /// (the largest a Messages stream sends is a `message_start` a few
    /// kilobytes long) and far below anything that matters to this process.
    static let maxPendingEventBytes = 1 << 20

    /// The reason written when the cap above is hit.
    static let oversizedEventReason = "oversized event"
    /// The reason written when a stream ends with no `message_stop` and the
    /// upstream leg reported no error of its own.
    static let endedWithoutStopReason = "stream ended"

    private let streamsDir: URL
    /// A date seam rather than a clock: `at` on a `start` line is persisted
    /// data, and `Duration` is behaviour (CLAUDE.md, "New delays and timers
    /// take an injected clock").
    private let now: @Sendable () -> Date
    /// Held because every timed subsystem in this repo takes the seam and the
    /// tee is the one place a retention pass would land. Nothing in the tee
    /// sleeps today, which is why nothing reads it yet.
    private let clock: any Clock<Duration>
    private let fileManager: FileManager

    /// Messages that have written a `start` line and not yet written a
    /// terminal one, per terminal. This is what decides truncation.
    private var inFlight: [UUID: Int] = [:]
    private var sessions: [UUID: SessionState] = [:]

    init(
        streamsDir: URL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.streamsDir = streamsDir
        self.fileManager = fileManager
        self.now = now
        self.clock = clock
    }

    /// Number of messages currently between their `start` line and their
    /// terminal one for `terminalID`. Zero at a `message_start` is what makes
    /// that message truncate the file rather than append to it.
    func inFlightCount(terminalID: UUID) -> Int {
        inFlight[terminalID] ?? 0
    }

    // MARK: - The decision

    /// Whether this response is a parent conversation's event stream.
    ///
    /// The first three conditions say it is a stream worth reading at all; the
    /// last two say it is the parent conversation rather than a subagent or the
    /// title request, which is the distinction that keeps a terminal's stream
    /// file showing the turn the user is watching. `tools` is read from a
    /// parsed *copy* of the body — the bytes forwarded upstream are never
    /// touched — and it is checked last, because it is the only condition that
    /// costs a JSON parse of a few hundred kilobytes.
    static func shouldTee(
        route: ModelProxyRoute,
        method: String,
        pathSuffix: String,
        requestHeaders: [(String, String)],
        requestBody: [UInt8],
        responseStatus: Int,
        responseHeaders: [(String, String)]
    ) -> Bool {
        guard route.streamingEnabled else { return false }
        guard method.uppercased() == "POST" else { return false }
        let path = String(pathSuffix.prefix(while: { $0 != "?" }))
        guard path.hasSuffix("/v1/messages") else { return false }
        guard responseStatus == 200 else { return false }
        guard let contentType = headerValue("content-type", in: responseHeaders),
            contentType.lowercased().hasPrefix("text/event-stream")
        else { return false }
        guard headerValue("x-claude-code-agent-id", in: requestHeaders) == nil else { return false }
        return hasNonEmptyTools(requestBody)
    }

    private static func headerValue(_ name: String, in headers: [(String, String)]) -> String? {
        headers.first { $0.0.lowercased() == name }?.1
    }

    /// True when the request body is a JSON object whose `tools` is a non-empty
    /// array. Anything else — a body that is not JSON, a missing key, an empty
    /// array — is false, because the tee's job is to recognise a parent
    /// conversation and an unrecognisable body is not one.
    private static func hasNonEmptyTools(_ body: [UInt8]) -> Bool {
        guard !body.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
            let tools = object["tools"] as? [Any]
        else { return false }
        return !tools.isEmpty
    }

    // MARK: - Sessions

    /// Opens a tee for one forwarded response, or returns nil when the
    /// response is not one worth teeing.
    ///
    /// The concrete return type, for the callers that hold a `StreamTee`
    /// directly; `begin` below is the same thing behind the protocol the
    /// server routes through.
    func beginSession(
        route: ModelProxyRoute,
        method: String,
        pathSuffix: String,
        requestHeaders: [(String, String)],
        requestBody: [UInt8],
        responseStatus: Int,
        responseHeaders: [(String, String)]
    ) -> TeeSession? {
        guard
            Self.shouldTee(
                route: route, method: method, pathSuffix: pathSuffix,
                requestHeaders: requestHeaders, requestBody: requestBody,
                responseStatus: responseStatus, responseHeaders: responseHeaders)
        else { return nil }

        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: TeeSessionItem.self)
        sessions[id] = SessionState(terminalID: route.terminalID)
        Task { await self.drain(id: id, stream: stream) }
        return TeeSession(continuation: continuation)
    }

    func begin(
        route: ModelProxyRoute,
        method: String,
        pathSuffix: String,
        requestHeaders: [(String, String)],
        requestBody: [UInt8],
        responseStatus: Int,
        responseHeaders: [(String, String)]
    ) async -> (any TeeSessionHandle)? {
        beginSession(
            route: route, method: method, pathSuffix: pathSuffix,
            requestHeaders: requestHeaders, requestBody: requestBody,
            responseStatus: responseStatus, responseHeaders: responseHeaders)
    }

    /// Consumes one session's chunks in wire order.
    ///
    /// The loop is the whole reason `feed` never blocks: the forwarding task
    /// yields into the stream and returns, and every parse and every write
    /// happens here, on the tee's own isolation.
    private func drain(id: UUID, stream: AsyncStream<TeeSessionItem>) async {
        for await item in stream {
            switch item {
            case .chunk(let bytes):
                consume(id: id, bytes: bytes)
            case .end(let error):
                finish(id: id, error: error)
            }
        }
        // The stream can also finish without an `.end` — a relay that dropped
        // its continuation. The message would otherwise stay counted in flight
        // forever and hold off every later truncation on that terminal.
        finish(id: id, error: nil)
    }

    private func consume(id: UUID, bytes: [UInt8]) {
        guard let state = sessions[id], !state.abandoned else { return }
        for event in state.parser.feed(bytes) {
            handle(event, state: state)
            if state.abandoned { return }
        }
        // The parser holds everything since the last blank line, so an upstream
        // that sends no terminator would grow it without bound. The message is
        // abandoned rather than the process: forwarding is untouched either
        // way, and the client keeps receiving every byte.
        if state.parser.pendingByteCount > Self.maxPendingEventBytes {
            abandon(state, reason: Self.oversizedEventReason)
        }
    }

    private func finish(id: UUID, error: Error?) {
        guard let state = sessions.removeValue(forKey: id) else { return }
        defer { close(state) }
        guard !state.abandoned, let message = state.openMessage else { return }
        // The rule is deliberately "no stop line" rather than "an error
        // arrived": measured on CI, an upstream that truncates a chunked body
        // reaches `URLSession` as a *clean* completion, so a message the model
        // never finished would otherwise be recorded as complete.
        let reason = error.map { describe($0) } ?? Self.endedWithoutStopReason
        write(.aborted(message: message, reason: reason), state: state)
        release(state)
    }

    /// A cut client is a `CancellationError`, whose `localizedDescription` is
    /// the generic "The operation couldn't be completed"; the type name says
    /// more and stays stable.
    private func describe(_ error: Error) -> String {
        if error is CancellationError { return "the client disconnected" }
        return error.localizedDescription
    }

    // MARK: - Events

    private func handle(_ event: SSEEvent, state: SessionState) {
        // A `: ping` keepalive carries no fields; an event with fields but no
        // `data:` decodes to the empty string and is equally nothing to parse.
        guard !event.isComment, !event.data.isEmpty else { return }
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8))
                as? [String: Any]
        else { return }
        // The payload's own `type` is authoritative; the `event:` field is the
        // fallback for a stream that omits it.
        let type = (object["type"] as? String) ?? event.name

        switch type {
        case "message_start":
            guard let message = (object["message"] as? [String: Any])?["id"] as? String else {
                return
            }
            start(message: message, state: state)

        case "content_block_start":
            guard let message = state.openMessage,
                let index = object["index"] as? Int,
                let block = object["content_block"] as? [String: Any],
                block["type"] as? String == "text"
            else { return }
            write(.block(message: message, index: index), state: state)

        case "content_block_delta":
            // `thinking_delta`, `signature_delta` and `input_json_delta` all
            // arrive on this event and none of them is assistant text.
            guard let message = state.openMessage,
                let index = object["index"] as? Int,
                let delta = object["delta"] as? [String: Any],
                delta["type"] as? String == "text_delta",
                let text = delta["text"] as? String
            else { return }
            write(.text(message: message, index: index, text: text), state: state)

        case "message_stop":
            guard let message = state.openMessage else { return }
            write(.stop(message: message), state: state)
            release(state)
            close(state)

        case "error":
            // The upstream's own error shape: `{"type":"error","error":{"type":…}}`.
            let reason = (object["error"] as? [String: Any])?["type"] as? String ?? "error"
            guard state.openMessage != nil else { return }
            abandon(state, reason: reason)

        default:
            return
        }
    }

    private func start(message: String, state: SessionState) {
        if let previous = state.openMessage {
            // One request carries one message, so this is defensive: a stream
            // that starts a second message without stopping the first would
            // otherwise leave the first counted in flight forever.
            write(
                .aborted(message: previous, reason: "a new message began before this one stopped"),
                state: state)
            release(state)
        }

        let truncating = inFlightCount(terminalID: state.terminalID) == 0
        guard state.descriptor >= 0 || openFile(truncating: truncating, state: state) else {
            return
        }
        state.openMessage = message
        inFlight[state.terminalID, default: 0] += 1
        state.counted = true
        write(.start(message: message, at: now()), state: state)
    }

    /// Drops the message's claim on the terminal's in-flight count. Idempotent,
    /// because the terminal line and `finish` can both reach it.
    private func release(_ state: SessionState) {
        state.openMessage = nil
        guard state.counted else { return }
        state.counted = false
        let remaining = (inFlight[state.terminalID] ?? 1) - 1
        if remaining <= 0 {
            inFlight.removeValue(forKey: state.terminalID)
        } else {
            inFlight[state.terminalID] = remaining
        }
    }

    /// Ends this message with an `aborted` line and stops reading the stream.
    private func abandon(_ state: SessionState, reason: String) {
        if let message = state.openMessage {
            write(.aborted(message: message, reason: reason), state: state)
        }
        release(state)
        state.abandoned = true
        close(state)
    }

    // MARK: - The file

    /// Opens `streamsDir/<terminal>.jsonl`, creating the directory if it is
    /// missing. Returns false when the tee cannot write at all, which is a
    /// condition it reports once and then ignores for the life of the message.
    private func openFile(truncating: Bool, state: SessionState) -> Bool {
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: streamsDir.path, isDirectory: &isDirectory) {
            // 0700: the directory holds model output for one user's sessions.
            try? fileManager.createDirectory(
                at: streamsDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }

        let path = streamsDir.appendingPathComponent(
            TBDConstants.streamFileName(terminalID: state.terminalID)
        ).path
        // Every descriptor is `O_APPEND`, and the one that starts a message
        // with nothing else in flight additionally truncates. Both halves are
        // load-bearing and the second is the one that is easy to get wrong:
        // two concurrent turns hold two descriptors on one file, and a
        // descriptor opened *without* `O_APPEND` writes at its own offset, so
        // its later lines land on top of whatever the appending session wrote
        // in between. Measured on CI before the fix: the second turn's `start`,
        // `block` and text lines were overwritten by the first turn's, and only
        // its `stop` — written after the first turn had finished — survived.
        let flags = O_WRONLY | O_CREAT | O_CLOEXEC | O_APPEND | (truncating ? O_TRUNC : 0)
        let descriptor = Darwin.open(path, flags, mode_t(0o600))
        guard descriptor >= 0 else {
            let code = errno
            Self.log.error(
                "stream file could not be opened (errno \(code, privacy: .public)); tee off for this message"
            )
            state.abandoned = true
            return false
        }
        // A file that already existed keeps whatever mode it was created with,
        // so the 0600 the design promises is set explicitly rather than left to
        // the create mode.
        _ = fchmod(descriptor, mode_t(0o600))
        state.descriptor = descriptor
        return true
    }

    /// Writes one line, newline included. Never throws: a write that fails
    /// closes this message's tee and logs once, and forwarding — which never
    /// awaits any of this — is untouched.
    private func write(_ line: ModelProxyStreamLine, state: SessionState) {
        guard state.descriptor >= 0 else { return }
        guard let encoded = try? line.encodedLine() else {
            Self.log.error("a stream line could not be encoded; tee off for this message")
            state.abandoned = true
            close(state)
            return
        }
        let bytes = Array("\(encoded)\n".utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.write(
                    state.descriptor, base.advanced(by: written), bytes.count - written)
            }
            if count > 0 {
                written += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            let code = errno
            Self.log.error(
                "stream file write failed (errno \(code, privacy: .public)); tee off for this message"
            )
            state.abandoned = true
            close(state)
            return
        }
    }

    /// Closes the descriptor. No `fsync`: the reader is a tailer on the same
    /// machine, which sees a written byte through the page cache, and an fsync
    /// per delta would put a disk flush on every token.
    private func close(_ state: SessionState) {
        guard state.descriptor >= 0 else { return }
        _ = Darwin.close(state.descriptor)
        state.descriptor = -1
    }
}

// MARK: - Per-session state

/// One teed response's state. A reference type stored in the actor's table and
/// touched only from actor-isolated code, so its mutability never crosses an
/// isolation boundary.
private final class SessionState {
    let terminalID: UUID
    var parser = SSEEventParser()
    var descriptor: Int32 = -1
    /// The message id between its `start` line and its terminal one. Nil means
    /// nothing is open, so nothing needs an `aborted` line.
    var openMessage: String?
    /// Whether this session currently holds a slot in the terminal's in-flight
    /// count.
    var counted = false
    /// Set when the tee gave up on this message — an unwritable file, an
    /// oversized event, an upstream `error` event. Nothing more is parsed or
    /// written.
    var abandoned = false

    init(terminalID: UUID) {
        self.terminalID = terminalID
    }
}

/// What a `TeeSession` hands the actor, in wire order.
private enum TeeSessionItem: @unchecked Sendable {
    case chunk([UInt8])
    case end(Error?)
}

/// One teed response, from the forwarding task's side.
///
/// Both calls do exactly one thing: put a value in an unbounded queue and
/// return. No parse, no write, and no `await` sits between the relay and the
/// client's socket.
final class TeeSession: TeeSessionHandle, Sendable {
    private let continuation: AsyncStream<TeeSessionItem>.Continuation

    fileprivate init(continuation: AsyncStream<TeeSessionItem>.Continuation) {
        self.continuation = continuation
    }

    func feed(_ chunk: [UInt8]) {
        guard !chunk.isEmpty else { return }
        continuation.yield(.chunk(chunk))
    }

    func end(error: Error?) {
        continuation.yield(.end(error))
        continuation.finish()
    }
}
