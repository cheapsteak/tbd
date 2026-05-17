import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

@Suite("ClaudeProfileConfigDirManager")
struct ClaudeProfileConfigDirManagerTests {

    private func tempBase() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-profile-cfg-test-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - approvalToken

    @Test("approval token is last 20 chars of api key")
    func approvalTokenLast20() {
        let key = "sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA-BBBBBBBBBBBBBBBBBBBB"
        let token = ClaudeProfileConfigDirManager.approvalToken(forAPIKey: key)
        #expect(token.count == 20)
        #expect(token == String(key.suffix(20)))
    }

    @Test("approval token for short key returns full string")
    func approvalTokenShortKey() {
        let key = "shortkey"
        #expect(ClaudeProfileConfigDirManager.approvalToken(forAPIKey: key) == "shortkey")
    }

    // MARK: - ensureDir

    @Test("ensureDir creates the directory tree and writes pre-populated .claude.json")
    func ensureDirCreatesAndPopulates() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = ClaudeProfileConfigDirManager(baseDirectory: base)
        let profileID = UUID()
        let apiKey = "sk-ant-test-AAAAAAAAAAAAAAAAAAAAAAAAA-LASTTWENTYCHARSXXX1"

        let dir = try manager.ensureDir(forProfileID: profileID, apiKey: apiKey)

        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(dir.path.hasSuffix("/claude"))
        #expect(dir.path.contains(profileID.uuidString.lowercased()))

        let claudeJSON = dir.appendingPathComponent(".claude.json")
        let data = try Data(contentsOf: claudeJSON)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let responses = json?["customApiKeyResponses"] as? [String: Any]
        let approved = responses?["approved"] as? [String]
        let rejected = responses?["rejected"] as? [String]
        #expect(approved == [String(apiKey.suffix(20))])
        #expect(rejected == [])
        #expect(json?["hasCompletedOnboarding"] as? Bool == true)
    }

    @Test("ensureDir is idempotent — re-call with same key keeps single approval")
    func ensureDirIdempotent() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = ClaudeProfileConfigDirManager(baseDirectory: base)
        let profileID = UUID()
        let apiKey = "sk-ant-AAAAAAAAAAAAAAAAAAAAAAA-DUPLICATEKEYTEST123"

        let dir1 = try manager.ensureDir(forProfileID: profileID, apiKey: apiKey)
        let dir2 = try manager.ensureDir(forProfileID: profileID, apiKey: apiKey)
        #expect(dir1 == dir2)

        let data = try Data(contentsOf: dir2.appendingPathComponent(".claude.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let approved = (json?["customApiKeyResponses"] as? [String: Any])?["approved"] as? [String]
        #expect(approved?.count == 1)
        #expect(approved?.first == String(apiKey.suffix(20)))
    }

    @Test("ensureDir appends new approval if api key changed, preserving old ones")
    func ensureDirAppendsApproval() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = ClaudeProfileConfigDirManager(baseDirectory: base)
        let profileID = UUID()
        let oldKey = "sk-ant-OLDOLDOLDOLDOLDOLDOLDOLDOLD-OLDLASTTWENTYCHARS12"
        let newKey = "sk-ant-NEWNEWNEWNEWNEWNEWNEWNEW-NEWLASTTWENTYCHARS34"

        _ = try manager.ensureDir(forProfileID: profileID, apiKey: oldKey)
        let dir = try manager.ensureDir(forProfileID: profileID, apiKey: newKey)

        let data = try Data(contentsOf: dir.appendingPathComponent(".claude.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let approved = (json?["customApiKeyResponses"] as? [String: Any])?["approved"] as? [String]
        #expect(approved?.contains(String(oldKey.suffix(20))) == true)
        #expect(approved?.contains(String(newKey.suffix(20))) == true)
    }

    // MARK: - resolveConfigDir (the proxy-vs-direct gate)

    @Test("resolveConfigDir returns nil for direct-Claude profile (no baseURL)")
    func resolveDirectClaudeReturnsNil() {
        let profile = ResolvedModelProfile(
            profileID: UUID(),
            name: "Direct Claude",
            kind: .oauth,
            baseURL: nil,
            model: nil,
            secret: "oauth-token",
            awsRegion: nil,
            awsProfile: nil
        )
        #expect(ClaudeProfileConfigDirManager.resolveConfigDir(for: profile) == nil)
    }

    @Test("resolveConfigDir returns nil for nil profile")
    func resolveNilProfileReturnsNil() {
        #expect(ClaudeProfileConfigDirManager.resolveConfigDir(for: nil) == nil)
    }

    @Test("resolveConfigDir returns nil for OAuth-secret proxy profile (no API key to pre-approve)")
    func resolveOAuthProxyReturnsNil() {
        // Edge case: a proxy profile that's configured with an OAuth token
        // instead of an API key. In that case there's no API key to
        // pre-approve, AND Claude Code's auth-conflict check fires on
        // ANTHROPIC_API_KEY only — so the isolation isn't needed.
        let profile = ResolvedModelProfile(
            profileID: UUID(),
            name: "OAuth Proxy",
            kind: .oauth,
            baseURL: "http://127.0.0.1:3456",
            model: nil,
            secret: "oauth-token",
            awsRegion: nil,
            awsProfile: nil
        )
        #expect(ClaudeProfileConfigDirManager.resolveConfigDir(for: profile) == nil)
    }
}
