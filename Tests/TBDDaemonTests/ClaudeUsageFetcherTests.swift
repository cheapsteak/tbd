import Foundation
import Testing
@testable import TBDDaemonLib

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.lastRequest = request
        guard let handler = MockURLProtocol.handler else {
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

private func makeFetcher() -> LiveClaudeUsageFetcher {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return LiveClaudeUsageFetcher(session: URLSession(configuration: config))
}

private func httpResponse(_ url: URL, _ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
}

private let testToken = "sk-ant-oat01-SECRETSECRETSECRET"

@Suite(.serialized)
struct ClaudeUsageFetcherTests {
    init() {
        MockURLProtocol.handler = nil
        MockURLProtocol.lastRequest = nil
    }

    @Test func happyPath200() async throws {
        let json = """
        {
          "five_hour": { "utilization": 0.42, "resets_at": "2026-04-06T15:00:00Z" },
          "seven_day": { "utilization": 0.18, "resets_at": "2026-04-13T00:00:00Z" }
        }
        """.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, 200), json)
        }
        let result = await makeFetcher().fetchUsage(token: testToken)
        guard case .ok(let usage) = result else {
            Issue.record("expected .ok, got \(result)")
            return
        }
        #expect(usage.fiveHourPct == 0.42)
        #expect(usage.sevenDayPct == 0.18)
        let fiveH = ISO8601DateFormatter().date(from: "2026-04-06T15:00:00Z")!
        let sevenD = ISO8601DateFormatter().date(from: "2026-04-13T00:00:00Z")!
        #expect(usage.fiveHourResetsAt == fiveH)
        #expect(usage.sevenDayResetsAt == sevenD)
    }

    @Test func unauthorized401() async {
        MockURLProtocol.handler = { req in (httpResponse(req.url!, 401), Data()) }
        let result = await makeFetcher().fetchUsage(token: testToken)
        #expect(result == .http401)
    }

    @Test func rateLimited429() async {
        MockURLProtocol.handler = { req in (httpResponse(req.url!, 429), Data()) }
        let result = await makeFetcher().fetchUsage(token: testToken)
        #expect(result == .http429)
    }

    @Test func serverError500() async {
        MockURLProtocol.handler = { req in (httpResponse(req.url!, 500), Data()) }
        let result = await makeFetcher().fetchUsage(token: testToken)
        guard case .networkError(let msg) = result else {
            Issue.record("expected .networkError, got \(result)")
            return
        }
        #expect(msg.contains("500"))
        #expect(!msg.contains(testToken))
    }

    @Test func networkFailure() async {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let result = await makeFetcher().fetchUsage(token: testToken)
        guard case .networkError = result else {
            Issue.record("expected .networkError, got \(result)")
            return
        }
    }

    @Test func decodeFailure() async {
        let bad = "{ not json".data(using: .utf8)!
        MockURLProtocol.handler = { req in (httpResponse(req.url!, 200), bad) }
        let result = await makeFetcher().fetchUsage(token: testToken)
        guard case .decodeError(let msg) = result else {
            Issue.record("expected .decodeError, got \(result)")
            return
        }
        #expect(!msg.contains(testToken))
    }

    @Test func requestShape() async {
        let json = """
        {
          "five_hour": { "utilization": 0.0, "resets_at": "2026-04-06T15:00:00Z" },
          "seven_day": { "utilization": 0.0, "resets_at": "2026-04-13T00:00:00Z" }
        }
        """.data(using: .utf8)!
        MockURLProtocol.handler = { req in (httpResponse(req.url!, 200), json) }
        _ = await makeFetcher().fetchUsage(token: testToken)
        let req = MockURLProtocol.lastRequest
        #expect(req?.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(req?.value(forHTTPHeaderField: "Authorization") == "Bearer \(testToken)")
        #expect(req?.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }
}
