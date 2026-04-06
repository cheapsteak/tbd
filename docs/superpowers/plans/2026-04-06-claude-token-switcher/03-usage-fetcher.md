# Phase 03: Usage Fetcher

> **Parent plan:** [../2026-04-06-claude-token-switcher.md](../2026-04-06-claude-token-switcher.md)
> **Depends on:** nothing
> **Unblocks:** Phase 05 (used to validate pasted tokens), Phase 07 (background poll)

**Scope:** A `ClaudeUsageFetcher` protocol + `LiveClaudeUsageFetcher` implementation that hits the undocumented `/api/oauth/usage` endpoint and returns 5h/7d utilization with reset timestamps. HTTP status mapping, decode error mapping, token never leaked into errors. Fully unit-tested via `URLProtocol` mock.

## Tasks

### 1. Create `Sources/TBDDaemon/Claude/ClaudeUsageFetcher.swift`

- [ ] Create directory if needed: `mkdir -p Sources/TBDDaemon/Claude`
- [ ] Write the file with public types, protocol, and live implementation:

```swift
import Foundation

public struct ClaudeUsageResult: Equatable, Sendable {
    public var fiveHourPct: Double       // 0.0 ... 1.0 (utilization from the API)
    public var sevenDayPct: Double
    public var fiveHourResetsAt: Date
    public var sevenDayResetsAt: Date

    public init(
        fiveHourPct: Double,
        sevenDayPct: Double,
        fiveHourResetsAt: Date,
        sevenDayResetsAt: Date
    ) {
        self.fiveHourPct = fiveHourPct
        self.sevenDayPct = sevenDayPct
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayResetsAt = sevenDayResetsAt
    }
}

public enum ClaudeUsageStatus: Equatable, Sendable {
    case ok(ClaudeUsageResult)
    case http429
    case http401
    case networkError(String)  // human-readable; MUST NOT contain token bytes
    case decodeError(String)
}

public protocol ClaudeUsageFetcher: Sendable {
    func fetchUsage(token: String) async -> ClaudeUsageStatus
}

public struct LiveClaudeUsageFetcher: ClaudeUsageFetcher {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchUsage(token: String) async -> ClaudeUsageStatus {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return .networkError("invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            return .networkError(urlError.localizedDescription)
        } catch {
            return .networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            return .networkError("non-HTTP response")
        }

        switch http.statusCode {
        case 200:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            do {
                let payload = try decoder.decode(UsagePayload.self, from: data)
                return .ok(ClaudeUsageResult(
                    fiveHourPct: payload.fiveHour.utilization,
                    sevenDayPct: payload.sevenDay.utilization,
                    fiveHourResetsAt: payload.fiveHour.resetsAt,
                    sevenDayResetsAt: payload.sevenDay.resetsAt
                ))
            } catch {
                return .decodeError(error.localizedDescription)
            }
        case 401:
            return .http401
        case 429:
            return .http429
        default:
            return .networkError("HTTP \(http.statusCode)")
        }
    }

    private struct UsagePayload: Decodable {
        struct Window: Decodable {
            let utilization: Double
            let resetsAt: Date
        }
        let fiveHour: Window
        let sevenDay: Window
    }
}
```

### 2. Build

- [ ] `swift build`

### 3. Create `Tests/TBDDaemonTests/ClaudeUsageFetcherTests.swift`

- [ ] Add the test file with a `MockURLProtocol` helper and Swift Testing cases:

```swift
import Foundation
import Testing
@testable import TBDDaemon

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
        // URLProtocol may strip headers from request.allHTTPHeaderFields; check via value(forHTTPHeaderField:)
        #expect(req?.value(forHTTPHeaderField: "Authorization") == "Bearer \(testToken)")
        #expect(req?.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }
}
```

### 4. Run tests

- [ ] `swift test --filter ClaudeUsageFetcherTests`

### 5. Verify token-leak guarantees

- [ ] Re-read `LiveClaudeUsageFetcher.fetchUsage`. Confirm no code path interpolates `token` into a returned string. The only use of `token` is in the `Authorization` header.

### 6. Verify build is clean

- [ ] `swift build` exits 0 with no warnings introduced by the new file.

### 7. Commit

- [ ] `git add Sources/TBDDaemon/Claude/ClaudeUsageFetcher.swift Tests/TBDDaemonTests/ClaudeUsageFetcherTests.swift`
- [ ] Commit with message: `feat: add ClaudeUsageFetcher for /api/oauth/usage`

### 8. Mark phase complete

- [ ] Update parent plan checkbox for Phase 03.
