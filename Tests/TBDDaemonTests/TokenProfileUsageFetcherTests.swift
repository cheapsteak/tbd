import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// MARK: - Header parsing (pure, no networking)

@Suite("Token usage header parsing")
struct TokenUsageHeaderParserTests {

    private func headers(_ pairs: [String: String]) -> [String: String] { pairs }

    @Test func parsesBothWindows() {
        let buckets = TokenUsageHeaderParser.buckets(from: headers([
            "anthropic-ratelimit-unified-5h-utilization": "0.61",
            "anthropic-ratelimit-unified-5h-reset": "1788000000",
            "anthropic-ratelimit-unified-5h-status": "allowed",
            "anthropic-ratelimit-unified-7d-utilization": "0.38",
            "anthropic-ratelimit-unified-7d-reset": "1788400000",
            "anthropic-ratelimit-unified-7d-status": "allowed",
        ]))

        #expect(buckets.count == 2)

        let session = buckets.first { $0.kind == "session" }
        #expect(session?.group == "session")
        #expect(session?.percent == 61)
        #expect(session?.severity == "normal")
        #expect(session?.resetsAt == Date(timeIntervalSince1970: 1_788_000_000))

        let weekly = buckets.first { $0.kind == "weekly_all" }
        #expect(weekly?.group == "weekly")
        #expect(weekly?.percent == 38)
        #expect(weekly?.resetsAt == Date(timeIntervalSince1970: 1_788_400_000))
    }

    /// HTTP header names are case-insensitive; a Swift dictionary lookup is
    /// not. A server that capitalises differently must still be read.
    @Test func headerLookupIsCaseInsensitive() {
        let buckets = TokenUsageHeaderParser.buckets(from: headers([
            "Anthropic-RateLimit-Unified-5h-Utilization": "0.5",
            "ANTHROPIC-RATELIMIT-UNIFIED-5H-STATUS": "allowed_warning",
        ]))
        #expect(buckets.count == 1)
        #expect(buckets[0].kind == "session")
        #expect(buckets[0].percent == 50)
        #expect(buckets[0].severity == "warning")
    }

    /// No per-model breakdown exists in headers — a token profile renders two
    /// bars, never a scoped one.
    @Test func neverProducesAScopedBucket() {
        let buckets = TokenUsageHeaderParser.buckets(from: headers([
            "anthropic-ratelimit-unified-5h-utilization": "0.1",
            "anthropic-ratelimit-unified-7d-utilization": "0.2",
        ]))
        #expect(buckets.count == 2)
        #expect(buckets.allSatisfy { $0.kind != "weekly_scoped" })
        #expect(buckets.allSatisfy { $0.modelDisplayName == nil })
    }

    @Test func mapsAllowedStatusToNormalSeverity() {
        let buckets = TokenUsageHeaderParser.buckets(from: headers([
            "anthropic-ratelimit-unified-5h-utilization": "0.2",
            "anthropic-ratelimit-unified-5h-status": "allowed",
        ]))
        #expect(buckets.first { $0.kind == "session" }?.severity == "normal")
    }

    @Test func mapsAllowedWarningToWarningSeverity() {
        let buckets = TokenUsageHeaderParser.buckets(from: headers([
            "anthropic-ratelimit-unified-7d-utilization": "0.80",
            "anthropic-ratelimit-unified-7d-status": "allowed_warning",
        ]))
        #expect(buckets.first { $0.kind == "weekly_all" }?.severity == "warning")
    }

    @Test func mapsRejectedStatusToCritical() {
        let buckets = TokenUsageHeaderParser.buckets(from: headers([
            "anthropic-ratelimit-unified-5h-utilization": "1.0",
            "anthropic-ratelimit-unified-5h-status": "rejected",
        ]))
        #expect(buckets.first { $0.kind == "session" }?.severity == "critical")
        #expect(buckets.first { $0.kind == "session" }?.percent == 100)
    }

    /// An absent status header yields nil rather than a guess — nil is what the
    /// usage endpoint's own parser produces for a bucket with no severity.
    @Test func missingStatusLeavesSeverityNil() {
        let buckets = TokenUsageHeaderParser.buckets(from: headers([
            "anthropic-ratelimit-unified-5h-utilization": "0.5",
        ]))
        #expect(buckets[0].severity == nil)
    }

    /// A window whose utilization header is missing contributes NO bucket — it
    /// must not become a 0% bar, which would read as "plenty of headroom" for a
    /// window that could not be measured at all.
    @Test func missingUtilizationYieldsNoBucketForThatWindow() {
        let buckets = TokenUsageHeaderParser.buckets(from: headers([
            "anthropic-ratelimit-unified-5h-utilization": "0.5",
            // 7d window present in name only: a reset with no utilization.
            "anthropic-ratelimit-unified-7d-reset": "1788400000",
            "anthropic-ratelimit-unified-7d-status": "allowed",
        ]))
        #expect(buckets.count == 1)
        #expect(buckets[0].kind == "session")
    }

    @Test func malformedUtilizationYieldsNoBucket() {
        let buckets = TokenUsageHeaderParser.buckets(from: headers([
            "anthropic-ratelimit-unified-5h-utilization": "not-a-number",
        ]))
        #expect(buckets.isEmpty)
    }

    @Test func missingResetLeavesResetsAtNil() {
        let buckets = TokenUsageHeaderParser.buckets(from: headers([
            "anthropic-ratelimit-unified-5h-utilization": "0.5",
        ]))
        #expect(buckets.count == 1)
        #expect(buckets[0].resetsAt == nil)
    }

    @Test func malformedResetLeavesResetsAtNilWithoutLosingTheBucket() {
        let buckets = TokenUsageHeaderParser.buckets(from: headers([
            "anthropic-ratelimit-unified-5h-utilization": "0.5",
            "anthropic-ratelimit-unified-5h-reset": "tomorrow",
        ]))
        #expect(buckets.count == 1)
        #expect(buckets[0].resetsAt == nil)
        #expect(buckets[0].percent == 50)
    }

    @Test func emptyHeadersYieldNoBuckets() {
        #expect(TokenUsageHeaderParser.buckets(from: [:]).isEmpty)
    }

    /// Buckets come back in a stable order (5-hour first), so the two-bar
    /// rendering does not depend on dictionary iteration order.
    @Test func bucketOrderIsSessionThenWeekly() {
        let buckets = TokenUsageHeaderParser.buckets(from: headers([
            "anthropic-ratelimit-unified-7d-utilization": "0.2",
            "anthropic-ratelimit-unified-5h-utilization": "0.1",
        ]))
        #expect(buckets.map(\.kind) == ["session", "weekly_all"])
    }
}

// MARK: - Probe fetcher over a mocked HTTP session

/// Private mock URLProtocol. Not shared with the other fetcher suites: suites
/// run in parallel across the module and a shared static handler would race.
private final class TokenProbeMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        // URLSession moves httpBody into a stream by the time the protocol sees
        // it, so read it back through the stream when the property is nil.
        Self.lastBody = request.httpBody ?? Self.drain(request.httpBodyStream)
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

    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }
}

private func tokenProbeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [TokenProbeMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeTokenFetcher() -> TokenProfileUsageFetcher {
    TokenProfileUsageFetcher(session: tokenProbeSession())
}

private let successHeaders = [
    "anthropic-ratelimit-unified-5h-utilization": "0.61",
    "anthropic-ratelimit-unified-5h-status": "allowed",
    "anthropic-ratelimit-unified-7d-utilization": "0.38",
    "anthropic-ratelimit-unified-7d-status": "allowed_warning",
]

@Suite(.serialized)
struct TokenProfileUsageFetcherTests {
    init() {
        TokenProbeMockURLProtocol.handler = nil
        TokenProbeMockURLProtocol.lastRequest = nil
        TokenProbeMockURLProtocol.lastBody = nil
    }

    @Test func successfulProbeSendsBearerTokenAndParsesHeaderBuckets() async throws {
        TokenProbeMockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                             headerFields: successHeaders)!, Data("{}".utf8))
        }
        let status = await makeTokenFetcher()
            .fetchUsage(credential: .token("sk-ant-oat01-TEST"))

        guard case .ok(let buckets, _) = status else {
            Issue.record("expected .ok, got \(status)"); return
        }
        #expect(buckets.count == 2)
        #expect(buckets.first { $0.kind == "session" }?.percent == 61)
        #expect(buckets.first { $0.kind == "weekly_all" }?.severity == "warning")

        let request = try #require(TokenProbeMockURLProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ant-oat01-TEST")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    /// `max_tokens: 0` is what makes the probe cheap: it returns 200 with the
    /// rate-limit headers and generates no output.
    @Test func probeBodyRequestsZeroOutputTokens() async throws {
        TokenProbeMockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                             headerFields: successHeaders)!, Data("{}".utf8))
        }
        _ = await makeTokenFetcher().fetchUsage(credential: .token("sk-ant-oat01-TEST"))

        let body = try #require(TokenProbeMockURLProtocol.lastBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["max_tokens"] as? Int == 0)
        #expect(json["model"] as? String == TokenProfileUsageFetcher.probeModel)
    }

    @Test func capturesOrganizationIDHeader() async {
        let headers = successHeaders.merging(
            ["anthropic-organization-id": "org_abc123"]) { _, new in new }
        TokenProbeMockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                             headerFields: headers)!, Data("{}".utf8))
        }
        let status = await makeTokenFetcher()
            .fetchUsage(credential: .token("sk-ant-oat01-TEST"))
        guard case .ok(_, let organizationID) = status else {
            Issue.record("expected .ok, got \(status)"); return
        }
        #expect(organizationID == "org_abc123")
    }

    @Test func reportsNilOrganizationIDWhenHeaderAbsent() async {
        TokenProbeMockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                             headerFields: successHeaders)!, Data("{}".utf8))
        }
        let status = await makeTokenFetcher()
            .fetchUsage(credential: .token("sk-ant-oat01-TEST"))
        guard case .ok(_, let organizationID) = status else {
            Issue.record("expected .ok, got \(status)"); return
        }
        #expect(organizationID == nil)
    }

    /// A 200 that carries no usable rate-limit headers yields zero buckets, not
    /// two 0% bars. The status is still `.ok`: the probe worked, there was just
    /// nothing to read.
    @Test func successWithNoRateLimitHeadersYieldsNoBuckets() async {
        TokenProbeMockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                             headerFields: [:])!, Data("{}".utf8))
        }
        let status = await makeTokenFetcher()
            .fetchUsage(credential: .token("sk-ant-oat01-TEST"))
        guard case .ok(let buckets, _) = status else {
            Issue.record("expected .ok, got \(status)"); return
        }
        #expect(buckets.isEmpty)
    }

    /// A rejected token reuses `.needsLogin` rather than getting a new
    /// `ProfileUsageStatusKind` case: widening that enum would break snapshot
    /// decode on older apps, because `decodeIfPresent` THROWS on an unknown raw
    /// value rather than returning nil.
    @Test(arguments: [401, 403])
    func rejectedTokenMapsToNeedsLoginWithoutEchoingTheToken(code: Int) async {
        TokenProbeMockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: "HTTP/1.1",
                             headerFields: nil)!, Data())
        }
        let status = await makeTokenFetcher()
            .fetchUsage(credential: .token("sk-ant-oat01-SECRET"))
        guard case .needsLogin(let reason) = status else {
            Issue.record("expected .needsLogin, got \(status)"); return
        }
        #expect(reason.contains("\(code)"))
        #expect(!reason.contains("sk-ant-oat01-SECRET"))
        #expect(status.kind == .needsLogin)
    }

    @Test func rateLimitedProbeCarriesRetryAfter() async {
        TokenProbeMockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: "HTTP/1.1",
                             headerFields: ["Retry-After": "120"])!, Data())
        }
        let status = await makeTokenFetcher()
            .fetchUsage(credential: .token("sk-ant-oat01-TEST"))
        #expect(status == .rateLimited(retryAfter: 120))
    }

    @Test func rateLimitedProbeWithoutRetryAfterStillMapsToRateLimited() async {
        TokenProbeMockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: "HTTP/1.1",
                             headerFields: nil)!, Data())
        }
        let status = await makeTokenFetcher()
            .fetchUsage(credential: .token("sk-ant-oat01-TEST"))
        #expect(status == .rateLimited(retryAfter: nil))
    }

    @Test func otherHTTPStatusesMapToNetworkError() async {
        TokenProbeMockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: "HTTP/1.1",
                             headerFields: nil)!, Data())
        }
        let status = await makeTokenFetcher()
            .fetchUsage(credential: .token("sk-ant-oat01-TEST"))
        guard case .networkError(let message) = status else {
            Issue.record("expected .networkError, got \(status)"); return
        }
        #expect(message.contains("500"))
        #expect(!message.contains("sk-ant-oat01-TEST"))
    }

    /// A config-dir credential belongs to `LiveProfileUsageFetcher`. This
    /// fetcher must refuse it without reaching the network, not trap.
    @Test func configDirCredentialIsRefusedWithoutAnyHTTPCall() async {
        TokenProbeMockURLProtocol.handler = { _ in
            Issue.record("no HTTP call expected for a config-dir credential")
            throw URLError(.badServerResponse)
        }
        let status = await makeTokenFetcher()
            .fetchUsage(credential: .configDir("/tmp/profiles/abc/claude"))
        guard case .noCredentials = status else {
            Issue.record("expected .noCredentials, got \(status)"); return
        }
        #expect(TokenProbeMockURLProtocol.lastRequest == nil)
    }

    /// The secret file was removed out from under the profile: `.noCredentials`,
    /// not a rejected token, and no billed request.
    @Test func emptyTokenIsNoCredentialsAndIssuesNoRequest() async {
        TokenProbeMockURLProtocol.handler = { _ in
            Issue.record("no HTTP call expected for an empty token")
            throw URLError(.badServerResponse)
        }
        let status = await makeTokenFetcher().fetchUsage(credential: .token(""))
        guard case .noCredentials = status else {
            Issue.record("expected .noCredentials, got \(status)"); return
        }
        #expect(TokenProbeMockURLProtocol.lastRequest == nil)
    }

    @Test func transportFailureMapsToNetworkError() async {
        TokenProbeMockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let status = await makeTokenFetcher()
            .fetchUsage(credential: .token("sk-ant-oat01-SECRET"))
        guard case .networkError(let message) = status else {
            Issue.record("expected .networkError, got \(status)"); return
        }
        #expect(!message.contains("sk-ant-oat01-SECRET"))
    }
}
