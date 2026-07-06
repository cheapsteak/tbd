import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// MARK: - Credential blob parse + rewrite round-trip

@Suite("ClaudeOAuthCredentials parse")
struct ClaudeCredentialsParseTests {
    /// The live-verified blob shape (top-level mcpOAuth + claudeAiOauth with the
    /// six oauth fields).
    private let blob = """
    {
      "mcpOAuth": {"some": "thing"},
      "claudeAiOauth": {
        "accessToken": "at-abc",
        "refreshToken": "rt-xyz",
        "expiresAt": 1783155405362,
        "scopes": ["user:inference", "user:profile"],
        "subscriptionType": "max",
        "rateLimitTier": "default_claude_max_20x"
      }
    }
    """.data(using: .utf8)!

    @Test func parsesAllFields() throws {
        let creds = try #require(parseClaudeCredentials(blob))
        #expect(creds.accessToken == "at-abc")
        #expect(creds.refreshToken == "rt-xyz")
        #expect(creds.expiresAtMillis == 1783155405362)
        #expect(creds.scopes == ["user:inference", "user:profile"])
    }

    @Test func missingAccessTokenYieldsNil() {
        let bad = #"{"claudeAiOauth": {"refreshToken": "x"}}"#.data(using: .utf8)!
        #expect(parseClaudeCredentials(bad) == nil)
    }

    @Test func expiryDetection() throws {
        let creds = try #require(parseClaudeCredentials(blob))
        // expiresAt = 1783155405362 ms → 2026-07-03ish.
        let after = Date(timeIntervalSince1970: 1783155405362 / 1000 + 3600)
        let before = Date(timeIntervalSince1970: 1783155405362 / 1000 - 3600)
        #expect(creds.isExpired(now: after))
        #expect(creds.isExpired(now: before) == false)
    }

    @Test func nilExpiryIsNeverExpired() {
        let creds = ClaudeOAuthCredentials(accessToken: "a", refreshToken: "r",
                                           expiresAtMillis: nil, scopes: [])
        #expect(creds.isExpired(now: Date()) == false)
    }
}

@Suite("rewriteClaudeCredentials round-trip fidelity")
struct RewriteCredentialsTests {
    private let original = """
    {
      "mcpOAuth": {"server": {"token": "keep-me"}},
      "claudeAiOauth": {
        "accessToken": "old-at",
        "refreshToken": "old-rt",
        "expiresAt": 1000,
        "scopes": ["user:inference"],
        "subscriptionType": "max",
        "rateLimitTier": "default_claude_max_20x"
      }
    }
    """.data(using: .utf8)!

    @Test func rewritesOnlyRotatingFieldsAndPreservesEverythingElse() throws {
        let rewritten = try #require(rewriteClaudeCredentials(
            original: original,
            newAccessToken: "new-at",
            newRefreshToken: "new-rt",
            newExpiresAtMillis: 2_000_000
        ))
        let root = try #require(
            try JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
        let oauth = try #require(root["claudeAiOauth"] as? [String: Any])

        // Rotated fields updated.
        #expect(oauth["accessToken"] as? String == "new-at")
        #expect(oauth["refreshToken"] as? String == "new-rt")
        #expect((oauth["expiresAt"] as? NSNumber)?.intValue == 2_000_000)

        // Sibling oauth fields preserved verbatim.
        #expect(oauth["subscriptionType"] as? String == "max")
        #expect(oauth["rateLimitTier"] as? String == "default_claude_max_20x")
        #expect(oauth["scopes"] as? [String] == ["user:inference"])

        // Top-level siblings preserved (mcpOAuth untouched).
        let mcp = try #require(root["mcpOAuth"] as? [String: Any])
        let server = try #require(mcp["server"] as? [String: Any])
        #expect(server["token"] as? String == "keep-me")
    }

    @Test func rewrittenBlobParsesBackToTheNewCredentials() throws {
        // Full round-trip: rewrite, then re-parse with the fetcher's own parser.
        let rewritten = try #require(rewriteClaudeCredentials(
            original: original, newAccessToken: "at2", newRefreshToken: "rt2",
            newExpiresAtMillis: 5_000_000))
        let reparsed = try #require(parseClaudeCredentials(rewritten))
        #expect(reparsed.accessToken == "at2")
        #expect(reparsed.refreshToken == "rt2")
        #expect(reparsed.expiresAtMillis == 5_000_000)
    }

    @Test func nonMatchingShapeYieldsNil() {
        let noOauth = #"{"something": 1}"#.data(using: .utf8)!
        #expect(rewriteClaudeCredentials(original: noOauth, newAccessToken: "a",
                                         newRefreshToken: "b", newExpiresAtMillis: 1) == nil)
    }
}

// MARK: - Refresh response parsing

@Suite("LiveClaudeOAuthRefresher.parseSuccess")
struct RefreshSuccessParseTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func extractsRotatedPairAndComputesExpiry() {
        let body = """
        {"token_type":"Bearer","access_token":"new-at","refresh_token":"new-rt","expires_in":28800}
        """.data(using: .utf8)!
        let result = LiveClaudeOAuthRefresher.parseSuccess(
            data: body, refreshTokenFallback: "old-rt", now: now)
        guard case .success(let token) = result else {
            Issue.record("expected success"); return
        }
        #expect(token.accessToken == "new-at")
        #expect(token.refreshToken == "new-rt")
        // now (1_000_000s) + 28800s → millis
        #expect(token.expiresAtMillis == (1_000_000 + 28800) * 1000)
    }

    @Test func fallsBackToOldRefreshTokenWhenServerOmitsIt() {
        let body = #"{"access_token":"a","expires_in":100}"#.data(using: .utf8)!
        let result = LiveClaudeOAuthRefresher.parseSuccess(
            data: body, refreshTokenFallback: "old-rt", now: now)
        guard case .success(let token) = result else {
            Issue.record("expected success"); return
        }
        #expect(token.refreshToken == "old-rt")
    }

    @Test func missingAccessTokenIsBadResponse() {
        let body = #"{"expires_in":100}"#.data(using: .utf8)!
        let result = LiveClaudeOAuthRefresher.parseSuccess(
            data: body, refreshTokenFallback: "old", now: now)
        guard case .failure(.badResponse) = result else {
            Issue.record("expected badResponse"); return
        }
    }
}
