import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("Codex usage app-server parsing")
struct CodexUsageParserTests {
    @Test func resolverPrefersCurrentPathThenUserFallbacks() {
        let available: Set<String> = [
            "/custom/bin/codex",
            "/Users/test/.local/bin/codex",
        ]
        let fromPath = CodexExecutableResolver.resolveIfAvailable(
            environment: ["PATH": "/custom/bin:/usr/bin"],
            homeDirectory: "/Users/test",
            isExecutable: { available.contains($0) }
        )
        #expect(fromPath == "/custom/bin/codex")

        let fromFallback = CodexExecutableResolver.resolveIfAvailable(
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: "/Users/test",
            isExecutable: { available.contains($0) }
        )
        #expect(fromFallback == "/Users/test/.local/bin/codex")
    }

    @Test func resolverCoversVoltaAndHomebrewAndReturnsNilWhenMissing() {
        #expect(CodexExecutableResolver.resolveIfAvailable(
            environment: [:],
            homeDirectory: "/Users/test",
            isExecutable: { $0 == "/Users/test/.volta/bin/codex" }
        ) == "/Users/test/.volta/bin/codex")
        #expect(CodexExecutableResolver.resolveIfAvailable(
            environment: [:],
            homeDirectory: "/Users/test",
            isExecutable: { $0 == "/opt/homebrew/bin/codex" }
        ) == "/opt/homebrew/bin/codex")
        #expect(CodexExecutableResolver.resolveIfAvailable(
            environment: [:],
            homeDirectory: "/Users/test",
            isExecutable: { _ in false }
        ) == nil)
    }

    @Test func parsesChatGPTAccount() throws {
        let data = Data(#"""
        {"id":2,"result":{"account":{"type":"chatgpt","email":"person@example.com","planType":"pro"},"requiresOpenaiAuth":true}}
        """#.utf8)
        let parsed = try CodexUsageParser.account(from: data)
        let account = try #require(parsed)
        #expect(account.type == "chatgpt")
        #expect(account.email == "person@example.com")
        #expect(account.planType == "pro")
    }

    @Test func parsesLoggedOutAccount() throws {
        let data = Data(#"{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}"#.utf8)
        let account = try CodexUsageParser.account(from: data)
        #expect(account == nil)
    }

    @Test func prefersNamedRateLimitBuckets() throws {
        let data = Data(#"""
        {"id":3,"result":{
          "rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":123}},
          "rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":"Codex","planType":"pro","rateLimitReachedType":"rate_limit_reached","spendControlReached":true,
            "primary":{"usedPercent":8,"windowDurationMins":300,"resetsAt":123},
            "secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":456}}}
        }}
        """#.utf8)
        let limits = try CodexUsageParser.rateLimits(from: data)
        let bucket = try #require(limits.first)
        #expect(bucket.limitId == "codex")
        #expect(bucket.primary?.usedPercent == 8)
        #expect(bucket.secondary?.windowDurationMins == 10_080)
        #expect(bucket.rateLimitReachedType == "rate_limit_reached")
        #expect(bucket.spendControlReached == true)
    }

    @Test func fallsBackToBaseRateLimitBucket() throws {
        let data = Data(#"""
        {"id":3,"result":{"rateLimits":{"primary":{"usedPercent":42,"windowDurationMins":300,"resetsAt":123}},"rateLimitsByLimitId":null}}
        """#.utf8)
        let limits = try CodexUsageParser.rateLimits(from: data)
        #expect(limits.first?.primary?.usedPercent == 42)
    }

    @Test func surfacesAppServerErrors() {
        let data = Data(#"{"id":2,"error":{"code":-32600,"message":"not initialized"}}"#.utf8)
        #expect(throws: CodexUsageFetchError.self) {
            try CodexUsageParser.account(from: data)
        }
    }
}
