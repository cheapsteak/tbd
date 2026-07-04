import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// MARK: - Fixtures

/// Real response captured from `GET https://api.anthropic.com/api/oauth/usage`
/// on 2026-07-03 (Claude Max account, trimmed of the `extra_usage`/`spend`
/// blocks we don't parse — top-level unknown keys are exercised by keeping
/// several of the null experiment fields verbatim).
private let capturedUsageJSON = """
{
    "five_hour": {
        "utilization": 96.0,
        "resets_at": "2026-07-04T01:10:00.245613+00:00",
        "limit_dollars": null,
        "used_dollars": null,
        "remaining_dollars": null
    },
    "seven_day": {
        "utilization": 76.0,
        "resets_at": "2026-07-07T22:00:00.245628+00:00",
        "limit_dollars": null,
        "used_dollars": null,
        "remaining_dollars": null
    },
    "seven_day_oauth_apps": null,
    "seven_day_opus": null,
    "seven_day_sonnet": null,
    "tangelo": null,
    "iguana_necktie": null,
    "extra_usage": {
        "is_enabled": false,
        "monthly_limit": 40000,
        "used_credits": 0.0,
        "utilization": 0.0,
        "currency": "USD",
        "decimal_places": 2,
        "disabled_reason": "out_of_credits",
        "daily": null,
        "weekly": null
    },
    "limits": [
        {
            "kind": "session",
            "group": "session",
            "percent": 96,
            "severity": "critical",
            "resets_at": "2026-07-04T01:10:00.245613+00:00",
            "scope": null,
            "is_active": false
        },
        {
            "kind": "weekly_all",
            "group": "weekly",
            "percent": 76,
            "severity": "warning",
            "resets_at": "2026-07-07T22:00:00.245628+00:00",
            "scope": null,
            "is_active": false
        },
        {
            "kind": "weekly_scoped",
            "group": "weekly",
            "percent": 100,
            "severity": "critical",
            "resets_at": "2026-07-07T22:00:00.245838+00:00",
            "scope": {
                "model": {
                    "id": null,
                    "display_name": "Fable"
                },
                "surface": null
            },
            "is_active": true
        }
    ],
    "member_dashboard_available": false
}
""".data(using: .utf8)!

// MARK: - Payload parser

struct ClaudeUsagePayloadParserTests {

    @Test func capturedResponseParsesAllBuckets() throws {
        let buckets = try ClaudeUsagePayloadParser.parseBuckets(from: capturedUsageJSON)
        #expect(buckets.count == 3)

        let session = try #require(buckets.first { $0.kind == "session" })
        #expect(session.percent == 96)
        #expect(session.group == "session")
        #expect(session.severity == "critical")
        #expect(session.modelDisplayName == nil)
        #expect(session.isActive == false)
        let sessionReset = try #require(session.resetsAt)
        // 2026-07-04T01:10:00.245613+00:00
        #expect(abs(sessionReset.timeIntervalSince1970 - 1783127400.245613) < 0.01)

        let weeklyAll = try #require(buckets.first { $0.kind == "weekly_all" })
        #expect(weeklyAll.percent == 76)
        #expect(weeklyAll.group == "weekly")

        let scoped = try #require(buckets.first { $0.kind == "weekly_scoped" })
        #expect(scoped.percent == 100)
        #expect(scoped.modelDisplayName == "Fable")
        #expect(scoped.isActive == true)
    }

    @Test func unknownBucketKindsFlowThroughAsData() throws {
        let json = """
        { "limits": [
            { "kind": "monthly_lunar", "group": "lunar", "percent": 7,
              "resets_at": null, "scope": null, "is_active": false }
        ] }
        """.data(using: .utf8)!
        let buckets = try ClaudeUsagePayloadParser.parseBuckets(from: json)
        #expect(buckets == [ClaudeUsageLimitBucket(
            kind: "monthly_lunar", group: "lunar", percent: 7, isActive: false)])
    }

    @Test func nullResetsAtYieldsNilDate() throws {
        let json = """
        { "limits": [
            { "kind": "weekly_scoped", "group": "weekly", "percent": 0,
              "severity": "normal", "resets_at": null,
              "scope": { "model": { "id": null, "display_name": "Fable" } },
              "is_active": false }
        ] }
        """.data(using: .utf8)!
        let buckets = try ClaudeUsagePayloadParser.parseBuckets(from: json)
        #expect(buckets.count == 1)
        #expect(buckets[0].resetsAt == nil)
        #expect(buckets[0].modelDisplayName == "Fable")
    }

    @Test func malformedLimitEntriesAreSkipped() throws {
        // First entry has no kind, second no percent — both dropped; the
        // valid third survives.
        let json = """
        { "limits": [
            { "percent": 50 },
            { "kind": "session" },
            { "kind": "weekly_all", "percent": 10 }
        ] }
        """.data(using: .utf8)!
        let buckets = try ClaudeUsagePayloadParser.parseBuckets(from: json)
        #expect(buckets.map(\.kind) == ["weekly_all"])
    }

    @Test func missingLimitsFallsBackToLegacyWindows() throws {
        let json = """
        {
            "five_hour": { "utilization": 42.0, "resets_at": "2026-04-06T15:00:00Z" },
            "seven_day": { "utilization": 18.0, "resets_at": "2026-04-13T00:00:00Z" }
        }
        """.data(using: .utf8)!
        let buckets = try ClaudeUsagePayloadParser.parseBuckets(from: json)
        #expect(buckets.count == 2)
        #expect(buckets[0].kind == "session")
        #expect(buckets[0].percent == 42.0)
        #expect(buckets[0].resetsAt != nil)
        #expect(buckets[1].kind == "weekly_all")
        #expect(buckets[1].percent == 18.0)
    }

    @Test func absentBucketsSimplyDoNotAppear() throws {
        // Account without any scoped weekly bucket: only what the API sent.
        let json = """
        { "limits": [ { "kind": "session", "group": "session", "percent": 5 } ] }
        """.data(using: .utf8)!
        let buckets = try ClaudeUsagePayloadParser.parseBuckets(from: json)
        #expect(buckets.map(\.kind) == ["session"])
        #expect(buckets.first { $0.kind == "weekly_scoped" } == nil)
    }

    @Test func garbageJSONThrows() {
        let garbage = Data("not json at all".utf8)
        #expect(throws: ClaudeUsagePayloadParser.ParseError.self) {
            try ClaudeUsagePayloadParser.parseBuckets(from: garbage)
        }
    }

    @Test func emptyPayloadThrows() {
        let empty = Data("{}".utf8)
        #expect(throws: ClaudeUsagePayloadParser.ParseError.self) {
            try ClaudeUsagePayloadParser.parseBuckets(from: empty)
        }
    }

    @Test func fractionalAndPlainISO8601DatesBothParse() {
        #expect(ClaudeUsagePayloadParser.parseResetDate("2026-07-04T01:10:00.245613+00:00") != nil)
        #expect(ClaudeUsagePayloadParser.parseResetDate("2026-07-04T01:10:00Z") != nil)
        #expect(ClaudeUsagePayloadParser.parseResetDate("yesterday-ish") == nil)
        #expect(ClaudeUsagePayloadParser.parseResetDate(nil) == nil)
    }
}

// MARK: - Credentials JSON parsing

struct ClaudeCredentialsParsingTests {

    @Test func extractsAccessTokenFromCredentialsJSON() {
        // Same shape as the "Claude Code-credentials-<hash>" keychain item /
        // .credentials.json file (token value is fake).
        let json = """
        {
            "mcpOAuth": { "some-server": { "accessToken": "not-this-one" } },
            "claudeAiOauth": {
                "accessToken": "sk-ant-oat01-FAKEFAKEFAKE",
                "refreshToken": "sk-ant-ort01-FAKEFAKEFAKE",
                "expiresAt": 1783155405362,
                "scopes": ["user:inference", "user:profile"],
                "subscriptionType": "max",
                "rateLimitTier": "default_claude_max_20x"
            }
        }
        """.data(using: .utf8)!
        #expect(parseClaudeCredentialsAccessToken(json) == "sk-ant-oat01-FAKEFAKEFAKE")
    }

    @Test func missingOAuthSectionYieldsNil() {
        #expect(parseClaudeCredentialsAccessToken(Data("{\"mcpOAuth\":{}}".utf8)) == nil)
        #expect(parseClaudeCredentialsAccessToken(Data("{}".utf8)) == nil)
        #expect(parseClaudeCredentialsAccessToken(Data("garbage".utf8)) == nil)
        #expect(parseClaudeCredentialsAccessToken(
            Data("{\"claudeAiOauth\":{\"accessToken\":\"\"}}".utf8)) == nil)
    }
}

// MARK: - Live fetcher over a mocked HTTP session

/// Private mock URLProtocol (not the shared `MockURLProtocol` from
/// ClaudeUsageFetcherTests — suites run in parallel across the module, and
/// sharing its static handler would race).
private final class ProfileUsageMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Token reader stub — never touches the keychain.
private struct StubTokenReader: ClaudeOAuthTokenReading {
    enum Behavior {
        case token(String)
        case absent
        case failure(String)
    }
    let behavior: Behavior

    func accessToken(forConfigDirPath path: String) async throws -> String? {
        switch behavior {
        case .token(let token): return token
        case .absent: return nil
        case .failure(let message): throw ClaudeOAuthTokenReadError(message)
        }
    }
}

private func makeProfileFetcher(_ behavior: StubTokenReader.Behavior) -> LiveProfileUsageFetcher {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ProfileUsageMockURLProtocol.self]
    return LiveProfileUsageFetcher(
        tokenReader: StubTokenReader(behavior: behavior),
        session: URLSession(configuration: config)
    )
}

@Suite(.serialized)
struct LiveProfileUsageFetcherTests {
    init() {
        ProfileUsageMockURLProtocol.handler = nil
        ProfileUsageMockURLProtocol.lastRequest = nil
    }

    @Test func happyPathSendsBearerTokenAndParsesBuckets() async throws {
        ProfileUsageMockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
             capturedUsageJSON)
        }
        let status = await makeProfileFetcher(.token("sk-ant-oat01-TEST")).fetchUsage(configDirPath: "/tmp/x")
        guard case .ok(let buckets) = status else {
            Issue.record("expected .ok, got \(status)")
            return
        }
        #expect(buckets.count == 3)
        let request = try #require(ProfileUsageMockURLProtocol.lastRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ant-oat01-TEST")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
    }

    @Test func missingCredentialShortCircuitsWithoutHTTP() async {
        ProfileUsageMockURLProtocol.handler = { _ in
            Issue.record("no HTTP call expected when credentials are absent")
            throw URLError(.badServerResponse)
        }
        let status = await makeProfileFetcher(.absent).fetchUsage(configDirPath: "/tmp/x")
        guard case .noCredentials = status else {
            Issue.record("expected .noCredentials, got \(status)")
            return
        }
    }

    @Test func tokenReadErrorMapsToNoCredentials() async {
        let status = await makeProfileFetcher(.failure("security exited 51")).fetchUsage(configDirPath: "/tmp/x")
        guard case .noCredentials(let reason) = status else {
            Issue.record("expected .noCredentials, got \(status)")
            return
        }
        #expect(reason.contains("security exited 51"))
    }

    @Test func http401MapsToHTTPError() async {
        ProfileUsageMockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!,
             Data())
        }
        let status = await makeProfileFetcher(.token("sk-ant-oat01-TEST")).fetchUsage(configDirPath: "/tmp/x")
        #expect(status == .httpError(401))
    }

    @Test func malformedBodyMapsToDecodeError() async {
        ProfileUsageMockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
             Data("<!doctype html>".utf8))
        }
        let status = await makeProfileFetcher(.token("sk-ant-oat01-TEST")).fetchUsage(configDirPath: "/tmp/x")
        guard case .decodeError = status else {
            Issue.record("expected .decodeError, got \(status)")
            return
        }
    }
}

// MARK: - Keychain service derivation (per-profile isolation sanity)

struct ProfileUsageKeychainDerivationTests {

    /// The token reader must target the config-dir-derived item, never the
    /// bare "Claude Code-credentials" item of the user's default ~/.claude.
    @Test func serviceNameIsAlwaysSuffixed() {
        let service = ClaudeCodeCredentialsKeychain.serviceName(
            forConfigDirPath: "/Users/zionts/tbd/profiles/abc/claude")
        #expect(service.hasPrefix("Claude Code-credentials-"))
        #expect(service != "Claude Code-credentials")
    }

    /// Known vector from the class doc comment, verified empirically.
    @Test func knownSHA256Vector() {
        #expect(ClaudeCodeCredentialsKeychain.serviceSuffix(
            forConfigDirPath: "/Users/zionts/.claude-profiles/zadam") == "db64a81f")
    }
}
