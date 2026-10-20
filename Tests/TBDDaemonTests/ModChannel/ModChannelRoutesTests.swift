import CryptoKit
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Tier 1 — the session-mod channel's route table driven directly through
/// `ModChannelRoutes.handle`, with no socket
/// (`docs/specs/2026-10-20-mod-channel-prompt-answer-design.md`, "Addressing
/// and trust" and "Answering prompts").
@Suite(.clockDriven)
struct ModChannelRoutesTests {

    /// Records every broadcast set, in order.
    private actor BroadcastLog {
        private(set) var sets: [Set<UUID>] = []
        func record(_ set: Set<UUID>) { sets.append(set) }
    }

    /// Mutable answers for the routes' `incarnationOf` and flag closures.
    private final class Fixture: @unchecked Sendable {
        private let lock = NSLock()
        private var _incarnations: [UUID: UUID] = [:]
        private var _enabled = true

        var enabled: Bool {
            get { lock.withLock { _enabled } }
            set { lock.withLock { _enabled = newValue } }
        }

        func setIncarnation(_ incarnation: UUID?, for terminal: UUID) {
            lock.withLock { _incarnations[terminal] = incarnation }
        }

        func incarnation(of terminal: UUID) -> UUID? {
            lock.withLock { _incarnations[terminal] }
        }
    }

    private struct Harness {
        let routes: ModChannelRoutes
        let channel: ModChannel
        let store: PendingPromptStore
        let token: ModChannelToken
        let fixture: Fixture
        let broadcasts: BroadcastLog
        let clock: EventDrivenTestClock
        let terminal: UUID
        let incarnation: UUID

        func request(
            _ method: String, _ path: String, query: [String: String] = [:],
            body: Any? = nil, incarnation override: UUID? = nil, bearer: String? = nil
        ) -> ModChannelRequest {
            let presented = override ?? incarnation
            let data = body.map { (try? JSONSerialization.data(withJSONObject: $0)) ?? Data() } ?? Data()
            return ModChannelRequest(
                method: method, path: path, query: query,
                headers: [
                    "Authorization": "Bearer \(bearer ?? token.token(incarnationID: presented))",
                    "X-TBD-Terminal": terminal.uuidString,
                    "X-TBD-Incarnation": presented.uuidString,
                ],
                body: data)
        }
    }

    private func makeHarness() -> Harness {
        let clock = EventDrivenTestClock()
        let channel = ModChannel(clock: clock)
        let store = PendingPromptStore(clock: clock)
        let token = ModChannelToken(key: SymmetricKey(size: .bits256))
        let fixture = Fixture()
        let broadcasts = BroadcastLog()
        let terminal = UUID()
        let incarnation = UUID()
        fixture.setIncarnation(incarnation, for: terminal)
        let routes = ModChannelRoutes(
            channel: channel, store: store, token: token,
            incarnationOf: { fixture.incarnation(of: $0) },
            promptAnswerEnabled: { fixture.enabled },
            broadcast: { await broadcasts.record($0) })
        return Harness(
            routes: routes, channel: channel, store: store, token: token, fixture: fixture,
            broadcasts: broadcasts, clock: clock, terminal: terminal, incarnation: incarnation)
    }

    private static func openBody(toolUseID: String = "toolu_1") -> [String: Any] {
        [
            "toolUseID": toolUseID,
            "sessionID": "s1",
            "toolName": "Bash",
            "toolInput": ["command": "ls", "description": "list"],
            "suggestions": NSNull(),
        ]
    }

    private static func json(_ response: ModChannelResponse) -> NSDictionary? {
        (try? JSONSerialization.jsonObject(with: response.body)) as? NSDictionary
    }

    private static let unauthorized: NSDictionary = ["error": "unauthorized"]

    // MARK: Auth

    @Test func missingOrWrongTokenIs401() async {
        let h = makeHarness()
        let path = "/v1/prompts/open"

        var cases: [(String, ModChannelRequest)] = []
        cases.append(("no headers", ModChannelRequest(
            method: "POST", path: path, query: [:], headers: [:], body: Data())))
        var noAuth = h.request("POST", path, body: Self.openBody()).headers
        noAuth["Authorization"] = nil
        cases.append(("no Authorization", ModChannelRequest(
            method: "POST", path: path, query: [:], headers: noAuth, body: Data())))
        cases.append(("garbage token", h.request("POST", path, body: Self.openBody(), bearer: "nope")))
        cases.append(("another incarnation's token", h.request(
            "POST", path, body: Self.openBody(), bearer: h.token.token(incarnationID: UUID()))))
        cases.append(("another key's token", h.request(
            "POST", path, body: Self.openBody(),
            bearer: ModChannelToken(key: SymmetricKey(size: .bits256)).token(incarnationID: h.incarnation))))
        var badTerminal = h.request("POST", path, body: Self.openBody()).headers
        badTerminal["X-TBD-Terminal"] = "not-a-uuid"
        cases.append(("malformed terminal", ModChannelRequest(
            method: "POST", path: path, query: [:], headers: badTerminal, body: Data())))
        var basic = h.request("POST", path, body: Self.openBody()).headers
        basic["Authorization"] = "Basic \(h.token.token(incarnationID: h.incarnation))"
        cases.append(("wrong scheme", ModChannelRequest(
            method: "POST", path: path, query: [:], headers: basic, body: Data())))

        for (name, request) in cases {
            let response = await h.routes.handle(request, token: UUID())
            #expect(response.status == 401, "\(name)")
            #expect(Self.json(response) == Self.unauthorized, "\(name)")
        }
        #expect(await h.store.prompts(forTerminal: h.terminal).isEmpty)

        // Header names are case-insensitive: the same request in lower case
        // goes through.
        let good = h.request("POST", path, body: Self.openBody())
        let lowered = ModChannelRequest(
            method: good.method, path: good.path, query: [:],
            headers: Dictionary(uniqueKeysWithValues: good.headers.map { ($0.key.lowercased(), $0.value) }),
            body: good.body)
        #expect(await h.routes.handle(lowered, token: UUID()).status == 200)
    }

    /// Review Focus 2: a stale process for a reused terminal — its token is
    /// genuine for its own incarnation, but the terminal's row now holds a
    /// newer one — is refused on every route, poll included.
    @Test func staleIncarnationIs401OnEveryRoute() async {
        let h = makeHarness()
        await h.store.open(
            terminalID: h.terminal, sessionID: "s1", toolUseID: "toolu_1", toolName: "Bash",
            toolInputJSON: #"{"command":"ls"}"#, suggestionsJSON: nil)
        let stale = UUID()
        let routes: [(String, String, [String: String], Any?)] = [
            ("GET", "/v1/poll", ["after": "0"], nil),
            ("POST", "/v1/prompts/open", [:], Self.openBody(toolUseID: "toolu_2")),
            ("GET", "/v1/prompts/toolu_1/answer", [:], nil),
            ("POST", "/v1/prompts/toolu_1/receipt", [:], nil),
            ("POST", "/v1/prompts/toolu_1/closed", [:], nil),
        ]
        for (method, path, query, body) in routes {
            let request = h.request(method, path, query: query, body: body, incarnation: stale)
            let response = await h.routes.handle(request, token: UUID())
            #expect(response.status == 401, "\(method) \(path)")
            #expect(Self.json(response) == Self.unauthorized, "\(method) \(path)")
        }
        // Nothing the stale process sent took effect.
        #expect(await h.store.prompts(forTerminal: h.terminal).map(\.toolUseID) == ["toolu_1"])
        #expect(await h.channel.lastPollAt(terminalID: h.terminal) == nil)
        #expect(await h.broadcasts.sets.isEmpty)

        // A terminal with no row at all is refused the same way.
        h.fixture.setIncarnation(nil, for: h.terminal)
        let orphan = await h.routes.handle(h.request("GET", "/v1/poll"), token: UUID())
        #expect(orphan.status == 401)
    }

    // MARK: Open

    @Test func openWhenFlagOffIs409() async {
        let h = makeHarness()
        h.fixture.enabled = false
        let response = await h.routes.handle(
            h.request("POST", "/v1/prompts/open", body: Self.openBody()), token: UUID())
        #expect(response.status == 409)
        #expect(Self.json(response) == ["error": "disabled"])
        #expect(await h.store.prompts(forTerminal: h.terminal).isEmpty)
        #expect(await h.broadcasts.sets.isEmpty)
    }

    @Test func openThenAnswerRoundTrip() async throws {
        let h = makeHarness()
        let opened = await h.routes.handle(
            h.request("POST", "/v1/prompts/open", body: Self.openBody()), token: UUID())
        #expect(opened.status == 200)
        #expect(Self.json(opened) == [:])
        #expect(await h.broadcasts.sets == [[h.terminal]])

        let prompts = await h.store.prompts(forTerminal: h.terminal)
        let prompt = try #require(prompts.first)
        #expect(prompts.count == 1)
        #expect(prompt.toolUseID == "toolu_1")
        #expect(prompt.kind == .permission)
        // Stored re-serialized with sorted keys.
        #expect(prompt.toolInputJSON == #"{"command":"ls","description":"list"}"#)
        #expect(prompt.suggestionsJSON == nil)

        let answer = PromptAnswer.permission(decision: .deny, message: "no thanks")
        let expectedJSON = try PromptDecisionEncoder.decisionJSON(
            answer: answer, kind: .permission,
            toolInputJSON: prompt.toolInputJSON, suggestionsJSON: nil)
        let answering = Task {
            await h.store.answer(terminalID: h.terminal, promptID: "toolu_1", answer: answer)
        }

        let reply = await h.routes.handle(h.request("GET", "/v1/prompts/toolu_1/answer"), token: UUID())
        #expect(reply.status == 200)
        let body = try #require(Self.json(reply))
        #expect(body["state"] as? String == "decision")
        // Embedded as an object, not a string.
        let decision = try #require(body["decision"] as? NSDictionary)
        let expected = try #require(
            (try JSONSerialization.jsonObject(with: Data(expectedJSON.utf8))) as? NSDictionary)
        #expect(decision == expected)

        let receipt = await h.routes.handle(
            h.request("POST", "/v1/prompts/toolu_1/receipt"), token: UUID())
        #expect(receipt.status == 200)
        #expect(await answering.value.outcome == .delivered)

        // Resolved: a further wait is told to stop.
        let after = await h.routes.handle(h.request("GET", "/v1/prompts/toolu_1/answer"), token: UUID())
        #expect(Self.json(after) == ["state": "resolved"])
    }

    @Test func answerHoldsThenReportsPending() async throws {
        let h = makeHarness()
        await h.store.open(
            terminalID: h.terminal, sessionID: "s1", toolUseID: "toolu_1", toolName: "Bash",
            toolInputJSON: #"{"command":"ls"}"#, suggestionsJSON: nil)
        let routes = h.routes
        let request = h.request("GET", "/v1/prompts/toolu_1/answer")
        let waiting = Task { await routes.handle(request, token: UUID()) }
        try await h.clock.requireAdvanceWhenArmed(by: .seconds(25))
        let reply = await waiting.value
        #expect(reply.status == 200)
        #expect(Self.json(reply) == ["state": "pending"])
    }

    // MARK: Receipt and closed

    @Test func receiptAndClosedResolveAndBroadcast() async {
        let h = makeHarness()
        for id in ["toolu_1", "toolu_2"] {
            await h.store.open(
                terminalID: h.terminal, sessionID: "s1", toolUseID: id, toolName: "Bash",
                toolInputJSON: #"{"command":"ls"}"#, suggestionsJSON: nil)
        }

        let receipt = await h.routes.handle(
            h.request("POST", "/v1/prompts/toolu_1/receipt"), token: UUID())
        #expect(receipt.status == 200)
        #expect(Self.json(receipt) == [:])
        #expect(await h.store.prompts(forTerminal: h.terminal).map(\.toolUseID) == ["toolu_2"])
        #expect(await h.broadcasts.sets == [[h.terminal]])

        let closed = await h.routes.handle(
            h.request("POST", "/v1/prompts/toolu_2/closed"), token: UUID())
        #expect(closed.status == 200)
        #expect(await h.store.prompts(forTerminal: h.terminal).isEmpty)
        #expect(await h.broadcasts.sets == [[h.terminal], [h.terminal]])

        // A repeat changes nothing and broadcasts nothing.
        let repeated = await h.routes.handle(
            h.request("POST", "/v1/prompts/toolu_2/closed"), token: UUID())
        #expect(repeated.status == 200)
        #expect(await h.broadcasts.sets.count == 2)
    }

    // MARK: Poll

    @Test func pollRouteReturnsQueuedItems() async {
        let h = makeHarness()
        await h.channel.enqueue(terminalID: h.terminal, kind: "message", body: #"{"text":"hi"}"#) {}
        let reply = await h.routes.handle(
            h.request("GET", "/v1/poll", query: ["after": "0"]), token: UUID())
        #expect(reply.status == 200)
        let items = (Self.json(reply)?["items"] as? [NSDictionary]) ?? []
        #expect(items == [["seq": 1, "kind": "message", "body": #"{"text":"hi"}"#]])

        let bad = await h.routes.handle(
            h.request("GET", "/v1/poll", query: ["after": "-1"]), token: UUID())
        #expect(bad.status == 400)
    }

    // MARK: Unknown

    @Test func unknownPathIs404() async {
        let h = makeHarness()
        let requests: [(String, String)] = [
            ("GET", "/"),
            ("GET", "/v1"),
            ("GET", "/v2/poll"),
            ("POST", "/v1/poll"),
            ("GET", "/v1/prompts/open"),
            ("POST", "/v1/prompts/toolu_1/answer"),
            ("GET", "/v1/prompts/toolu_1/receipt"),
            ("POST", "/v1/prompts/toolu_1/other"),
            ("POST", "/v1/prompts//closed"),
            ("GET", "/v1/poll/extra"),
        ]
        for (method, path) in requests {
            let response = await h.routes.handle(h.request(method, path), token: UUID())
            #expect(response.status == 404, "\(method) \(path)")
        }
    }
}
