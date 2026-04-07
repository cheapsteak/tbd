import Testing
import Foundation
@testable import TBDShared

@Suite("Claude Token Models")
struct ClaudeTokenModelTests {
    @Test func decodeClaudeToken() throws {
        let json = #"{"id":"11111111-1111-1111-1111-111111111111","name":"Personal","kind":"oauth","createdAt":"2026-04-06T00:00:00Z"}"#.data(using: .utf8)!
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let tok = try dec.decode(ClaudeToken.self, from: json)
        #expect(tok.name == "Personal")
        #expect(tok.kind == .oauth)
        #expect(tok.lastUsedAt == nil)
    }

    @Test func decodeClaudeTokenKindApiKey() throws {
        let json = #"{"id":"11111111-1111-1111-1111-111111111111","name":"Work","kind":"apiKey","createdAt":"2026-04-06T00:00:00Z"}"#.data(using: .utf8)!
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let tok = try dec.decode(ClaudeToken.self, from: json)
        #expect(tok.kind == .apiKey)
    }

    @Test func decodeClaudeTokenUsage() throws {
        let json = #"{"tokenID":"11111111-1111-1111-1111-111111111111","fiveHourPct":0.42,"sevenDayPct":0.18,"lastStatus":"ok"}"#.data(using: .utf8)!
        let u = try JSONDecoder().decode(ClaudeTokenUsage.self, from: json)
        #expect(u.fiveHourPct == 0.42)
        #expect(u.sevenDayPct == 0.18)
        #expect(u.lastStatus == "ok")
    }

    @Test func decodeConfigEmpty() throws {
        let u = try JSONDecoder().decode(Config.self, from: "{}".data(using: .utf8)!)
        #expect(u.defaultClaudeTokenID == nil)
    }

    @Test func repoDecodesWithoutOverride() throws {
        let json = #"{"id":"11111111-1111-1111-1111-111111111111","path":"/tmp/x","displayName":"x","defaultBranch":"main","createdAt":"2026-04-06T00:00:00Z"}"#.data(using: .utf8)!
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let r = try dec.decode(Repo.self, from: json)
        #expect(r.claudeTokenOverrideID == nil)
    }

    @Test func terminalDecodesWithoutTokenID() throws {
        let json = #"{"id":"11111111-1111-1111-1111-111111111111","worktreeID":"22222222-2222-2222-2222-222222222222","tmuxWindowID":"@1","tmuxPaneID":"%0","createdAt":"2026-04-06T00:00:00Z"}"#.data(using: .utf8)!
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let t = try dec.decode(Terminal.self, from: json)
        #expect(t.claudeTokenID == nil)
    }
}
