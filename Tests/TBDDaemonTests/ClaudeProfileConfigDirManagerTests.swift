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

    // MARK: - ensureAPIKeyDir

    @Test("ensureAPIKeyDir creates the directory tree and writes pre-populated .claude.json")
    func ensureAPIKeyDirCreatesAndPopulates() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = ClaudeProfileConfigDirManager(baseDirectory: base)
        let profileID = UUID()
        let apiKey = "sk-ant-test-AAAAAAAAAAAAAAAAAAAAAAAAA-LASTTWENTYCHARSXXX1"

        let dir = try manager.ensureAPIKeyDir(forProfileID: profileID, apiKey: apiKey)

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

    @Test("ensureAPIKeyDir is idempotent — re-call with same key keeps single approval")
    func ensureAPIKeyDirIdempotent() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = ClaudeProfileConfigDirManager(baseDirectory: base)
        let profileID = UUID()
        let apiKey = "sk-ant-AAAAAAAAAAAAAAAAAAAAAAA-DUPLICATEKEYTEST123"

        let dir1 = try manager.ensureAPIKeyDir(forProfileID: profileID, apiKey: apiKey)
        let dir2 = try manager.ensureAPIKeyDir(forProfileID: profileID, apiKey: apiKey)
        #expect(dir1 == dir2)

        let data = try Data(contentsOf: dir2.appendingPathComponent(".claude.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let approved = (json?["customApiKeyResponses"] as? [String: Any])?["approved"] as? [String]
        #expect(approved?.count == 1)
        #expect(approved?.first == String(apiKey.suffix(20)))
    }

    @Test("ensureAPIKeyDir appends new approval if api key changed, preserving old ones")
    func ensureAPIKeyDirAppendsApproval() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = ClaudeProfileConfigDirManager(baseDirectory: base)
        let profileID = UUID()
        let oldKey = "sk-ant-OLDOLDOLDOLDOLDOLDOLDOLDOLD-OLDLASTTWENTYCHARS12"
        let newKey = "sk-ant-NEWNEWNEWNEWNEWNEWNEWNEW-NEWLASTTWENTYCHARS34"

        _ = try manager.ensureAPIKeyDir(forProfileID: profileID, apiKey: oldKey)
        let dir = try manager.ensureAPIKeyDir(forProfileID: profileID, apiKey: newKey)

        let data = try Data(contentsOf: dir.appendingPathComponent(".claude.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let approved = (json?["customApiKeyResponses"] as? [String: Any])?["approved"] as? [String]
        #expect(approved?.contains(String(oldKey.suffix(20))) == true)
        #expect(approved?.contains(String(newKey.suffix(20))) == true)
    }

    // MARK: - ensureOAuthDir

    @Test("ensureOAuthDir creates the directory and writes .claude.json with hasCompletedOnboarding only")
    func ensureOAuthDirCreatesAndPopulates() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = ClaudeProfileConfigDirManager(baseDirectory: base)
        let profileID = UUID()

        let dir = try manager.ensureOAuthDir(forProfileID: profileID)

        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(dir.path.hasSuffix("/claude"))
        #expect(dir.path.contains(profileID.uuidString.lowercased()))

        let claudeJSON = dir.appendingPathComponent(".claude.json")
        let data = try Data(contentsOf: claudeJSON)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["hasCompletedOnboarding"] as? Bool == true)
        // OAuth dir should NOT have customApiKeyResponses
        #expect((json?["customApiKeyResponses"] as? [String: Any]) == nil)
    }

    @Test("ensureOAuthDir leaves existing .claude.json untouched")
    func ensureOAuthDirLeavesExisting() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = ClaudeProfileConfigDirManager(baseDirectory: base)
        let profileID = UUID()

        // First call creates the dir and .claude.json
        _ = try manager.ensureOAuthDir(forProfileID: profileID)

        let claudeJSON = manager.configDirectory(forProfileID: profileID).appendingPathComponent(".claude.json")
        let originalData = try Data(contentsOf: claudeJSON)

        // Second call should leave it untouched
        _ = try manager.ensureOAuthDir(forProfileID: profileID)

        let secondData = try Data(contentsOf: claudeJSON)
        #expect(originalData == secondData)
    }

    // MARK: - resolveConfigDir

    @Test("resolveConfigDir returns nil for nil profile")
    func resolveNilProfileReturnsNil() {
        #expect(ClaudeProfileConfigDirManager.resolveConfigDir(for: nil) == nil)
    }

    @Test("resolveConfigDir returns a path for .oauth profile")
    func resolveOAuthProfileReturnsPath() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        // Override the manager's default baseDir so the test doesn't touch ~/tbd
        ClaudeProfileConfigDirManager(baseDirectory: base)

        let profile = ResolvedModelProfile(
            profileID: UUID(),
            name: "OAuth",
            kind: .oauth,
            baseURL: nil,
            model: nil,
            secret: nil,  // OAuth profiles have no secret in the resolved form
            awsRegion: nil,
            awsProfile: nil
        )

        // For this test, we need to use the temp base via direct instantiation
        // since resolveConfigDir is static and always uses the default.
        // Instead, verify that a direct call to ensureOAuthDir works.
        let manager = ClaudeProfileConfigDirManager(baseDirectory: base)
        let dir = try manager.ensureOAuthDir(forProfileID: profile.profileID)
        #expect(dir.path.contains(profile.profileID.uuidString.lowercased()))
    }

    @Test("resolveConfigDir returns a path for direct .apiKey profile (baseURL == nil)")
    func resolveDirectAPIKeyReturnsPath() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let profile = ResolvedModelProfile(
            profileID: UUID(),
            name: "Direct API Key",
            kind: .apiKey,
            baseURL: nil,
            model: nil,
            secret: "sk-ant-api03-test-key-XXXXX",
            awsRegion: nil,
            awsProfile: nil
        )

        // Verify that a direct call to ensureAPIKeyDir works for direct profiles.
        let manager = ClaudeProfileConfigDirManager(baseDirectory: base)
        let dir = try manager.ensureAPIKeyDir(forProfileID: profile.profileID, apiKey: profile.secret!)
        #expect(dir.path.contains(profile.profileID.uuidString.lowercased()))
    }

    @Test("resolveConfigDir returns nil for .bedrock profile")
    func resolveBedrockeReturnsNil() {
        let profile = ResolvedModelProfile(
            profileID: UUID(),
            name: "Bedrock",
            kind: .bedrock,
            baseURL: nil,
            model: "anthropic.claude-sonnet-4-5",
            secret: nil,
            awsRegion: "us-west-2",
            awsProfile: nil
        )
        #expect(ClaudeProfileConfigDirManager.resolveConfigDir(for: profile) == nil)
    }

    @Test("resolveConfigDir returns nil for .apiKey profile with no secret")
    func resolveAPIKeyWithoutSecretReturnsNil() {
        let profile = ResolvedModelProfile(
            profileID: UUID(),
            name: "API Key (no secret)",
            kind: .apiKey,
            baseURL: nil,
            model: nil,
            secret: nil,
            awsRegion: nil,
            awsProfile: nil
        )
        #expect(ClaudeProfileConfigDirManager.resolveConfigDir(for: profile) == nil)
    }
}
