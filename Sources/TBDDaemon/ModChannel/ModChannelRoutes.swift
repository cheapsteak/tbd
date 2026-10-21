import Foundation
import os

/// One HTTP request as the mod channel's routes see it. `headers` may use any
/// case; the routes compare names case-insensitively.
struct ModChannelRequest: Sendable {
    let method: String
    /// Percent-decoded, without the query.
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
}

struct ModChannelResponse: Sendable, Equatable {
    let status: Int
    let body: Data
}

/// The session-mod channel's route table
/// (`docs/specs/2026-10-20-mod-channel-prompt-answer-design.md`, "The channel"
/// and "Answering prompts"). Transport-free: `ModChannelServer` parses HTTP
/// into a ``ModChannelRequest`` and writes the ``ModChannelResponse`` back.
///
/// Every route requires `Authorization: Bearer <token>`, `X-TBD-Terminal` and
/// `X-TBD-Incarnation`, and answers 401 unless the token verifies for that
/// incarnation and the terminal's row holds that incarnation — so a process
/// that outlived its row (a reused terminal's stale incarnation) is refused on
/// every route, poll included.
///
/// - `GET /v1/poll?after=<n>` → `{"items":[Item]}`
/// - `POST /v1/prompts/open` → `{}`, or 409 `{"error":"disabled"}` with the
///   feature off, or 409 `{"error":"payload differs"}` for a repeat whose
///   payload differs from the open prompt's (the first payload wins)
/// - `GET /v1/prompts/<toolUseID>/answer` → `{"state":"decision","decision":{…}}`,
///   `{"state":"pending"}` or `{"state":"resolved"}`
/// - `POST /v1/prompts/<toolUseID>/receipt` → `{}`
/// - `POST /v1/prompts/<toolUseID>/closed` → `{}`
/// - anything else → 404
struct ModChannelRoutes: Sendable {
    /// How long a poll or an answer wait is held.
    static let hold: Duration = .seconds(25)

    private static let log = Logger(subsystem: "com.tbd.daemon", category: "modChannel")

    private let channel: ModChannel
    private let store: PendingPromptStore
    private let token: ModChannelToken
    private let incarnationOf: @Sendable (UUID) async -> UUID?
    private let promptAnswerEnabled: @Sendable () async -> Bool
    private let broadcast: @Sendable (Set<UUID>) async -> Void

    init(
        channel: ModChannel,
        store: PendingPromptStore,
        token: ModChannelToken,
        incarnationOf: @escaping @Sendable (UUID) async -> UUID?,
        promptAnswerEnabled: @escaping @Sendable () async -> Bool,
        broadcast: @escaping @Sendable (Set<UUID>) async -> Void
    ) {
        self.channel = channel
        self.store = store
        self.token = token
        self.incarnationOf = incarnationOf
        self.promptAnswerEnabled = promptAnswerEnabled
        self.broadcast = broadcast
    }

    private enum Route {
        case poll
        case open
        case answer(toolUseID: String)
        case receipt(toolUseID: String)
        case closed(toolUseID: String)
    }

    /// Answers one request. `token` names the request's held poll or answer
    /// wait. Cancelling the calling task releases that hold, including one
    /// the request has not reached yet (see ``holdsConnection(method:path:)``).
    func handle(_ request: ModChannelRequest, token requestToken: UUID) async -> ModChannelResponse {
        guard let route = Self.route(method: request.method, path: request.path) else {
            return Self.error(404, "not found")
        }
        guard let terminalID = await authorizedTerminal(request) else {
            return Self.error(401, "unauthorized")
        }
        switch route {
        case .poll:
            return await poll(request, terminalID: terminalID, requestToken: requestToken)
        case .open:
            return await open(request, terminalID: terminalID)
        case .answer(let toolUseID):
            return await answer(terminalID: terminalID, toolUseID: toolUseID, requestToken: requestToken)
        case .receipt(let toolUseID):
            await broadcastIfChanged(await store.receipt(terminalID: terminalID, toolUseID: toolUseID))
            return Self.emptyObject
        case .closed(let toolUseID):
            await broadcastIfChanged(await store.closed(terminalID: terminalID, toolUseID: toolUseID))
            return Self.emptyObject
        }
    }

    /// Whether the request is a held poll or answer wait, which keeps its
    /// connection open until its reply. The server cancels such a request when its
    /// connection closes, which releases the hold whether or not it has
    /// attached yet. Every other route mutates the store and runs to
    /// completion even when its reply can no longer be delivered.
    static func holdsConnection(method: String, path: String) -> Bool {
        switch route(method: method, path: path) {
        case .poll, .answer: return true
        case .open, .receipt, .closed, nil: return false
        }
    }

    // MARK: - Routing and auth

    private static func route(method: String, path: String) -> Route? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // A leading "/" yields an empty first component.
        guard parts.first == "", parts.count >= 3, parts[1] == "v1" else { return nil }
        let rest = Array(parts.dropFirst(2))
        switch (method.uppercased(), rest.count) {
        case ("GET", 1) where rest[0] == "poll":
            return .poll
        case ("POST", 2) where rest == ["prompts", "open"]:
            return .open
        case (let verb, 3) where rest[0] == "prompts" && !rest[1].isEmpty:
            let toolUseID = rest[1]
            switch (verb, rest[2]) {
            case ("GET", "answer"): return .answer(toolUseID: toolUseID)
            case ("POST", "receipt"): return .receipt(toolUseID: toolUseID)
            case ("POST", "closed"): return .closed(toolUseID: toolUseID)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// The request's terminal when its credentials hold, else nil. Never logs
    /// the token.
    private func authorizedTerminal(_ request: ModChannelRequest) async -> UUID? {
        let headers = Dictionary(
            request.headers.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { _, last in last })
        guard let authorization = headers["authorization"],
              let terminalID = headers["x-tbd-terminal"].flatMap({ UUID(uuidString: $0.withoutSurroundingSpaces) }),
              let incarnationID = headers["x-tbd-incarnation"].flatMap({ UUID(uuidString: $0.withoutSurroundingSpaces) })
        else { return nil }
        let scheme = "bearer "
        let value = authorization.withoutSurroundingSpaces
        guard value.lowercased().hasPrefix(scheme) else { return nil }
        let presented = String(value.dropFirst(scheme.count)).withoutSurroundingSpaces
        guard token.verify(presented, incarnationID: incarnationID) else {
            Self.log.debug(
                "mod channel refused a bad token terminal=\(terminalID.uuidString, privacy: .public)")
            return nil
        }
        guard await incarnationOf(terminalID) == incarnationID else {
            Self.log.debug(
                "mod channel refused a stale incarnation terminal=\(terminalID.uuidString, privacy: .public) incarnation=\(incarnationID.uuidString, privacy: .public)")
            return nil
        }
        return terminalID
    }

    // MARK: - Handlers

    private func poll(_ request: ModChannelRequest, terminalID: UUID, requestToken: UUID) async -> ModChannelResponse {
        let after: UInt64
        if let raw = request.query["after"] {
            guard let parsed = UInt64(raw) else { return Self.error(400, "bad request") }
            after = parsed
        } else {
            after = 0
        }
        let items = await channel.poll(
            terminalID: terminalID, after: after, token: requestToken, hold: Self.hold)
        struct Reply: Encodable { let items: [ModChannel.Item] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Reply(items: items)) else {
            return Self.error(500, "encoding failed")
        }
        return ModChannelResponse(status: 200, body: data)
    }

    private func open(_ request: ModChannelRequest, terminalID: UUID) async -> ModChannelResponse {
        guard await promptAnswerEnabled() else { return Self.error(409, "disabled") }
        guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
              let toolUseID = object["toolUseID"] as? String, !toolUseID.isEmpty,
              let toolName = object["toolName"] as? String,
              let toolInput = object["toolInput"],
              let toolInputJSON = Self.canonicalJSON(toolInput)
        else { return Self.error(400, "bad request") }
        // Informational only (the log): prompts are keyed by terminal, so an
        // open without a session ID is still a valid open.
        let sessionID = object["sessionID"] as? String
        var suggestionsJSON: String?
        if let suggestions = object["suggestions"], !(suggestions is NSNull) {
            guard let encoded = Self.canonicalJSON(suggestions) else { return Self.error(400, "bad request") }
            suggestionsJSON = encoded
        }
        let outcome = await store.open(
            terminalID: terminalID, sessionID: sessionID, toolUseID: toolUseID, toolName: toolName,
            toolInputJSON: toolInputJSON, suggestionsJSON: suggestionsJSON)
        switch outcome {
        case .opened(let changed):
            await broadcastIfChanged(changed)
            return Self.emptyObject
        case .conflict:
            // The store logged it. The mod takes any 4xx as final and does
            // not retry.
            return Self.error(409, "payload differs")
        }
    }

    private func answer(terminalID: UUID, toolUseID: String, requestToken: UUID) async -> ModChannelResponse {
        let result = await store.waitForAnswer(
            terminalID: terminalID, toolUseID: toolUseID, token: requestToken, hold: Self.hold)
        let reply: [String: Any]
        switch result {
        case .decision(let decisionJSON):
            guard let decision = try? JSONSerialization.jsonObject(with: Data(decisionJSON.utf8)) else {
                Self.log.error(
                    "mod channel decision is not JSON id=\(toolUseID, privacy: .public)")
                return Self.error(500, "decision is not JSON")
            }
            reply = ["state": "decision", "decision": decision]
        case .pending:
            reply = ["state": "pending"]
        case .resolved:
            reply = ["state": "resolved"]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: reply, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return Self.error(500, "encoding failed")
        }
        return ModChannelResponse(status: 200, body: data)
    }

    private func broadcastIfChanged(_ changed: Set<UUID>) async {
        guard !changed.isEmpty else { return }
        await broadcast(changed)
    }

    // MARK: - JSON

    static let emptyObject = ModChannelResponse(status: 200, body: Data("{}".utf8))

    static func error(_ status: Int, _ message: String) -> ModChannelResponse {
        let data = (try? JSONSerialization.data(withJSONObject: ["error": message], options: [.sortedKeys]))
            ?? Data(#"{"error":"internal"}"#.utf8)
        return ModChannelResponse(status: status, body: data)
    }

    /// `value` re-serialized with sorted keys and unescaped slashes — the form
    /// `PendingPromptPayload` stores tool input and suggestions in.
    private static func canonicalJSON(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return nil }
        return String(bytes: data, encoding: .utf8)
    }
}

private extension String {
    var withoutSurroundingSpaces: String { trimmingCharacters(in: .whitespaces) }
}
