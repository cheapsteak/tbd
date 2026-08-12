import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
import TBDShared

@Suite("ClaudeProfileConfigDirManager")
struct ClaudeProfileConfigDirManagerTests {

    private func tempBase() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-profile-cfg-test-\(UUID().uuidString)", isDirectory: true)
    }

    private func tempHostBase() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-host-cfg-test-\(UUID().uuidString)", isDirectory: true)
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

    @Test("ensureAPIKeyDir preserves unknown top-level keys from existing .claude.json")
    func ensureAPIKeyDirPreservesUnknownKeys() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = ClaudeProfileConfigDirManager(baseDirectory: base)
        let profileID = UUID()
        let apiKey = "sk-ant-test-AAAAAAAAAAAAAAAAAAAAAAAAA-LASTTWENTYCHARSXXX1"

        // Manually write a .claude.json with an unknown top-level key
        let dir = manager.configDirectory(forProfileID: profileID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let initialPayload: [String: Any] = [
            "customApiKeyResponses": [
                "approved": [],
                "rejected": [],
            ],
            "hasCompletedOnboarding": true,
            "someClaudeCodeKey": "value",
            "anotherCustomKey": 42,
        ]
        let initialData = try JSONSerialization.data(withJSONObject: initialPayload, options: [.prettyPrinted, .sortedKeys])
        try initialData.write(to: dir.appendingPathComponent(".claude.json"), options: [.atomic])

        // Call ensureAPIKeyDir and verify unknown keys survive
        _ = try manager.ensureAPIKeyDir(forProfileID: profileID, apiKey: apiKey)

        let claudeJSON = dir.appendingPathComponent(".claude.json")
        let finalData = try Data(contentsOf: claudeJSON)
        let finalJson = try JSONSerialization.jsonObject(with: finalData) as? [String: Any]

        // Verify TBD keys are correct
        let responses = finalJson?["customApiKeyResponses"] as? [String: Any]
        let approved = responses?["approved"] as? [String]
        #expect(approved?.contains(String(apiKey.suffix(20))) == true)
        #expect(finalJson?["hasCompletedOnboarding"] as? Bool == true)

        // Verify unknown keys are preserved
        #expect(finalJson?["someClaudeCodeKey"] as? String == "value")
        #expect(finalJson?["anotherCustomKey"] as? Int == 42)
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
        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase())
        #expect(manager.resolveConfigDir(for: nil) == nil)
    }

    /// `resolveConfigDir` is an instance method precisely so this assertion is
    /// possible: the dir it creates lands under the injected base, not under
    /// the ambient `~/tbd/profiles`.
    @Test("resolveConfigDir creates the oauth dir under the manager's own base")
    func resolveOAuthProfileReturnsPath() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let profileID = UUID()
        let manager = ClaudeProfileConfigDirManager(
            baseDirectory: base, hostBaseDirectory: tempHostBase())
        let profile = ResolvedModelProfile(
            profileID: profileID,
            name: "OAuth",
            kind: .oauth,
            baseURL: nil,
            model: nil,
            secret: nil,
            awsRegion: nil,
            awsProfile: nil,
            fallbackModels: nil,
            envOverrides: [:]
        )
        let path = try #require(manager.resolveConfigDir(for: profile))
        #expect(path.contains(profileID.uuidString.lowercased()))
        #expect(path.hasPrefix(base.path))
    }

    @Test("resolveConfigDir creates the api-key dir under the manager's own base")
    func ensureAPIKeyDirReturnsPath() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let profileID = UUID()
        let manager = ClaudeProfileConfigDirManager(
            baseDirectory: base, hostBaseDirectory: tempHostBase())
        let profile = ResolvedModelProfile(
            profileID: profileID,
            name: "API Key",
            kind: .apiKey,
            baseURL: nil,
            model: nil,
            secret: "sk-ant-api03-test-key-XXXXX",
            awsRegion: nil,
            awsProfile: nil,
            fallbackModels: nil,
            envOverrides: [:]
        )
        let path = try #require(manager.resolveConfigDir(for: profile))
        #expect(path.contains(profileID.uuidString.lowercased()))
        #expect(path.hasPrefix(base.path))
    }

    @Test("resolveConfigDir returns nil for .bedrock profile")
    func resolveBedrockReturnsNil() {
        let profile = ResolvedModelProfile(
            profileID: UUID(),
            name: "Bedrock",
            kind: .bedrock,
            baseURL: nil,
            model: "anthropic.claude-sonnet-4-5",
            secret: nil,
            awsRegion: "us-west-2",
            awsProfile: nil,
            fallbackModels: nil,
            envOverrides: [:]
        )
        #expect(ClaudeProfileConfigDirManager(baseDirectory: tempBase()).resolveConfigDir(for: profile) == nil)
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
            awsProfile: nil,
            fallbackModels: nil,
            envOverrides: [:]
        )
        #expect(ClaudeProfileConfigDirManager(baseDirectory: tempBase()).resolveConfigDir(for: profile) == nil)
    }

    // MARK: - host mirror slots

    @Test("shared-claude-projects.AC1.1/AC1.2: symlink dir and file host slots after ensureOAuthDir and ensureAPIKeyDir")
    func hostMirrorSymlinksOAuthAndAPIKey() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)

        // Pre-create host slots: plugins (dir) and CLAUDE.md (file)
        try fm.createDirectory(at: tempHost.appendingPathComponent("plugins", isDirectory: true), withIntermediateDirectories: true)
        try "# Host CLAUDE.md".write(to: tempHost.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)

        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()

        // Test ensureOAuthDir
        let oauthDir = try manager.ensureOAuthDir(forProfileID: profileID)

        // Check plugins symlink
        let pluginsLink = oauthDir.appendingPathComponent("plugins")
        let pluginsDest = try fm.destinationOfSymbolicLink(atPath: pluginsLink.path)
        let pluginsResolved = URL(fileURLWithPath: pluginsDest, relativeTo: pluginsLink.deletingLastPathComponent()).standardizedFileURL
        #expect(pluginsResolved == tempHost.appendingPathComponent("plugins").standardizedFileURL)

        // Check CLAUDE.md symlink
        let claudeLink = oauthDir.appendingPathComponent("CLAUDE.md")
        let claudeDest = try fm.destinationOfSymbolicLink(atPath: claudeLink.path)
        let claudeResolved = URL(fileURLWithPath: claudeDest, relativeTo: claudeLink.deletingLastPathComponent()).standardizedFileURL
        #expect(claudeResolved == tempHost.appendingPathComponent("CLAUDE.md").standardizedFileURL)

        // Test ensureAPIKeyDir with same profile
        let apiKey = "sk-ant-test-AAAAAAAAAAAAAAAAAAAAAAAAA-LASTTWENTYCHARSXXX1"
        _ = try manager.ensureAPIKeyDir(forProfileID: profileID, apiKey: apiKey)

        // Symlinks should still be there
        #expect((try? fm.destinationOfSymbolicLink(atPath: pluginsLink.path)) != nil)
        #expect((try? fm.destinationOfSymbolicLink(atPath: claudeLink.path)) != nil)
    }

    @Test("shared-claude-projects.AC1.3: skip host slot if not present on host")
    func hostMirrorSkipsAbsentSlot() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)

        // Pre-create only plugins; skills is absent
        try fm.createDirectory(at: tempHost.appendingPathComponent("plugins", isDirectory: true), withIntermediateDirectories: true)

        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()

        let dir = try manager.ensureOAuthDir(forProfileID: profileID)

        // plugins should be symlinked
        #expect((try? fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("plugins").path)) != nil)

        // skills should NOT exist
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("skills").path))
    }

    @Test("AC2.1: idempotent — calling ensureOAuthDir twice leaves symlink intact")
    func hostMirrorIdempotentOAuth() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)
        try fm.createDirectory(at: tempHost.appendingPathComponent("plugins", isDirectory: true), withIntermediateDirectories: true)

        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()

        let dir1 = try manager.ensureOAuthDir(forProfileID: profileID)
        let pluginsLink = dir1.appendingPathComponent("plugins")
        let dest1 = try fm.destinationOfSymbolicLink(atPath: pluginsLink.path)

        let dir2 = try manager.ensureOAuthDir(forProfileID: profileID)
        let dest2 = try fm.destinationOfSymbolicLink(atPath: pluginsLink.path)

        #expect(dir1 == dir2)
        #expect(dest1 == dest2)
    }

    @Test("Issue 1 regression: ensureOAuthDir sets up mirrors when .claude.json already exists")
    func ensureOAuthDirSetsUpMirrorsWhenClaudeJSONAlreadyExists() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)

        // Pre-create host plugins so there's a slot to mirror
        try fm.createDirectory(at: tempHost.appendingPathComponent("plugins", isDirectory: true), withIntermediateDirectories: true)

        // Pre-create profile dir with existing .claude.json (simulating a profile
        // created before mirror support was added)
        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()
        let profileClaudeDir = manager.configDirectory(forProfileID: profileID)
        try fm.createDirectory(at: profileClaudeDir, withIntermediateDirectories: true)

        let claudeJSONPath = profileClaudeDir.appendingPathComponent(".claude.json")
        let existingJSON: [String: Any] = ["hasCompletedOnboarding": true]
        let existingData = try JSONSerialization.data(withJSONObject: existingJSON, options: [.prettyPrinted, .sortedKeys])
        try existingData.write(to: claudeJSONPath, options: [.atomic])

        // Call ensureOAuthDir on a profile that already has .claude.json
        _ = try manager.ensureOAuthDir(forProfileID: profileID)

        // Assert that plugins symlink was created (the early-return bug would skip this)
        let pluginsLink = profileClaudeDir.appendingPathComponent("plugins")
        #expect((try? fm.destinationOfSymbolicLink(atPath: pluginsLink.path)) != nil)

        // Verify the symlink points to the host plugins
        let dest = try fm.destinationOfSymbolicLink(atPath: pluginsLink.path)
        let resolved = URL(fileURLWithPath: dest, relativeTo: pluginsLink.deletingLastPathComponent()).standardizedFileURL
        #expect(resolved == tempHost.appendingPathComponent("plugins").standardizedFileURL)
    }

    @Test("AC3.1: migrate projects directory content to host before symlinking")
    func hostMirrorMigrateProjectsDir() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)
        try fm.createDirectory(at: tempHost.appendingPathComponent("projects", isDirectory: true), withIntermediateDirectories: true)

        // Pre-create profile projects dir with content
        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()
        let profileClaudeDir = manager.configDirectory(forProfileID: profileID)
        try fm.createDirectory(at: profileClaudeDir, withIntermediateDirectories: true)

        let projectsDir = profileClaudeDir.appendingPathComponent("projects")
        try fm.createDirectory(at: projectsDir.appendingPathComponent("-Users-test-cwd", isDirectory: true), withIntermediateDirectories: true)
        let sessionFile = projectsDir.appendingPathComponent("-Users-test-cwd/sess-1.jsonl")
        try "PROFILE CONTENT".write(to: sessionFile, atomically: true, encoding: .utf8)

        // Call ensureOAuthDir
        _ = try manager.ensureOAuthDir(forProfileID: profileID)

        // Verify profile projects is now a symlink
        #expect((try? fm.destinationOfSymbolicLink(atPath: projectsDir.path)) != nil)

        // Verify content was migrated to host
        let hostSessionFile = tempHost.appendingPathComponent("projects/-Users-test-cwd/sess-1.jsonl")
        #expect(fm.fileExists(atPath: hostSessionFile.path))
        let migrated = try String(contentsOf: hostSessionFile, encoding: .utf8)
        #expect(migrated == "PROFILE CONTENT")
    }

    @Test("AC3.2: collision skip during projects migration")
    func hostMirrorProjectsMigrationCollisionSkip() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)

        // Pre-create host projects with a collision file
        try fm.createDirectory(at: tempHost.appendingPathComponent("projects/-Users-test-cwd", isDirectory: true), withIntermediateDirectories: true)
        let hostFile = tempHost.appendingPathComponent("projects/-Users-test-cwd/sess-X.jsonl")
        try "HOST".write(to: hostFile, atomically: true, encoding: .utf8)

        // Pre-create profile projects with same cwd-hash dir but different session files:
        // - sess-X.jsonl (collides with host, should not be migrated)
        // - profile-unique-sess.jsonl (unique to profile, should be preserved)
        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()
        let profileClaudeDir = manager.configDirectory(forProfileID: profileID)
        try fm.createDirectory(at: profileClaudeDir, withIntermediateDirectories: true)

        let profileProjectsDir = profileClaudeDir.appendingPathComponent("projects/-Users-test-cwd", isDirectory: true)
        try fm.createDirectory(at: profileProjectsDir, withIntermediateDirectories: true)
        let profileFile = profileClaudeDir.appendingPathComponent("projects/-Users-test-cwd/sess-X.jsonl")
        try "PROFILE".write(to: profileFile, atomically: true, encoding: .utf8)
        let profileUniqueFile = profileClaudeDir.appendingPathComponent("projects/-Users-test-cwd/profile-unique-sess.jsonl")
        try "PROFILE UNIQUE".write(to: profileUniqueFile, atomically: true, encoding: .utf8)

        // Call ensureOAuthDir
        _ = try manager.ensureOAuthDir(forProfileID: profileID)

        // Host file should still contain "HOST" (collision not overwritten)
        let hostContent = try String(contentsOf: hostFile, encoding: .utf8)
        #expect(hostContent == "HOST")

        // Issue 2 regression: Profile-unique session file should still exist.
        // When a collision occurs, the profile-side projects/ dir is preserved
        // (not deleted), so the unique session is not lost.
        #expect(fm.fileExists(atPath: profileUniqueFile.path), "profile-unique session was destroyed during migration collision")
        let profileUniqueContent = try String(contentsOf: profileUniqueFile, encoding: .utf8)
        #expect(profileUniqueContent == "PROFILE UNIQUE")
    }

    @Test("AC1.1: overlapping cwd-hash dirs with disjoint files merge successfully")
    func hostMirrorProjectsMigrationMergesDisjointFiles() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)

        // Pre-create host projects with cwd-hash A, one session file
        try fm.createDirectory(at: tempHost.appendingPathComponent("projects/-cwd-A", isDirectory: true), withIntermediateDirectories: true)
        let hostFileA = tempHost.appendingPathComponent("projects/-cwd-A/sess-host.jsonl")
        try "HOST".write(to: hostFileA, atomically: true, encoding: .utf8)

        // Pre-create profile projects with same cwd-hash A but different session file
        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()
        let profileClaudeDir = manager.configDirectory(forProfileID: profileID)
        try fm.createDirectory(at: profileClaudeDir, withIntermediateDirectories: true)

        let profileProjectsBaseDir = profileClaudeDir.appendingPathComponent("projects", isDirectory: true)
        try fm.createDirectory(at: profileProjectsBaseDir.appendingPathComponent("-cwd-A", isDirectory: true), withIntermediateDirectories: true)
        let profileFileA = profileProjectsBaseDir.appendingPathComponent("-cwd-A/sess-profile.jsonl")
        try "PROFILE".write(to: profileFileA, atomically: true, encoding: .utf8)

        // Call ensureOAuthDir
        _ = try manager.ensureOAuthDir(forProfileID: profileID)

        // Verify: host file still has original content (untouched)
        let hostContent = try String(contentsOf: hostFileA, encoding: .utf8)
        #expect(hostContent == "HOST")

        // Verify: profile file was migrated to host
        let migratedFile = tempHost.appendingPathComponent("projects/-cwd-A/sess-profile.jsonl")
        #expect(fm.fileExists(atPath: migratedFile.path))
        let migratedContent = try String(contentsOf: migratedFile, encoding: .utf8)
        #expect(migratedContent == "PROFILE")

        // Verify: profile projects/ is now a symlink to host
        let profileProjectsLink = profileClaudeDir.appendingPathComponent("projects")
        #expect((try? fm.destinationOfSymbolicLink(atPath: profileProjectsLink.path)) != nil)
    }

    @Test("AC1.2: cwd-hash dir only in profile is moved to host intact")
    func hostMirrorProjectsMigrationMovesProfileOnlyDir() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)
        try fm.createDirectory(at: tempHost.appendingPathComponent("projects", isDirectory: true), withIntermediateDirectories: true)

        // Pre-create profile projects with a cwd-hash dir that doesn't exist on host
        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()
        let profileClaudeDir = manager.configDirectory(forProfileID: profileID)
        try fm.createDirectory(at: profileClaudeDir, withIntermediateDirectories: true)

        let profileProjectsBaseDir = profileClaudeDir.appendingPathComponent("projects", isDirectory: true)
        try fm.createDirectory(at: profileProjectsBaseDir.appendingPathComponent("-cwd-only-profile", isDirectory: true), withIntermediateDirectories: true)
        let profileFile = profileProjectsBaseDir.appendingPathComponent("-cwd-only-profile/sess-X.jsonl")
        try "PROFILE ONLY".write(to: profileFile, atomically: true, encoding: .utf8)

        // Call ensureOAuthDir
        _ = try manager.ensureOAuthDir(forProfileID: profileID)

        // Verify: profile-only dir was moved to host intact
        let hostFile = tempHost.appendingPathComponent("projects/-cwd-only-profile/sess-X.jsonl")
        #expect(fm.fileExists(atPath: hostFile.path))
        let content = try String(contentsOf: hostFile, encoding: .utf8)
        #expect(content == "PROFILE ONLY")

        // Verify: profile projects/ is now a symlink
        let profileProjectsLink = profileClaudeDir.appendingPathComponent("projects")
        #expect((try? fm.destinationOfSymbolicLink(atPath: profileProjectsLink.path)) != nil)
    }

    @Test("AC1.3: actual file-level collision aborts migration atomically")
    func hostMirrorProjectsMigrationFileCollisionAbortsAtomically() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)

        // Pre-create host projects with cwd-hash A with a specific session file (collision point)
        try fm.createDirectory(at: tempHost.appendingPathComponent("projects/-cwd-A", isDirectory: true), withIntermediateDirectories: true)
        let hostFileCollide = tempHost.appendingPathComponent("projects/-cwd-A/sess-collide.jsonl")
        try "HOST".write(to: hostFileCollide, atomically: true, encoding: .utf8)

        // Pre-create profile projects with:
        // - cwd-hash A with same session file (file-level collision)
        // - cwd-hash B with unique content (should NOT be migrated due to atomic abort)
        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()
        let profileClaudeDir = manager.configDirectory(forProfileID: profileID)
        try fm.createDirectory(at: profileClaudeDir, withIntermediateDirectories: true)

        let profileProjectsBaseDir = profileClaudeDir.appendingPathComponent("projects", isDirectory: true)
        try fm.createDirectory(at: profileProjectsBaseDir, withIntermediateDirectories: true)

        // cwd-hash A with collision file
        try fm.createDirectory(at: profileProjectsBaseDir.appendingPathComponent("-cwd-A", isDirectory: true), withIntermediateDirectories: true)
        let profileFileCollide = profileProjectsBaseDir.appendingPathComponent("-cwd-A/sess-collide.jsonl")
        try "PROFILE".write(to: profileFileCollide, atomically: true, encoding: .utf8)

        // cwd-hash B with clean content (but should not be migrated due to atomic abort)
        try fm.createDirectory(at: profileProjectsBaseDir.appendingPathComponent("-cwd-B", isDirectory: true), withIntermediateDirectories: true)
        let profileFileClean = profileProjectsBaseDir.appendingPathComponent("-cwd-B/sess-clean.jsonl")
        try "PROFILE B".write(to: profileFileClean, atomically: true, encoding: .utf8)

        // Call ensureOAuthDir
        _ = try manager.ensureOAuthDir(forProfileID: profileID)

        // Verify: host file still has original content (collision not overwritten)
        let hostContent = try String(contentsOf: hostFileCollide, encoding: .utf8)
        #expect(hostContent == "HOST")

        // Verify: profile collision file was NOT migrated (atomic abort)
        #expect(fm.fileExists(atPath: profileFileCollide.path))
        let profileContent = try String(contentsOf: profileFileCollide, encoding: .utf8)
        #expect(profileContent == "PROFILE")

        // Verify: profile clean file was NOT migrated (atomic abort)
        #expect(fm.fileExists(atPath: profileFileClean.path))
        let profileCleanContent = try String(contentsOf: profileFileClean, encoding: .utf8)
        #expect(profileCleanContent == "PROFILE B")

        // Verify: host cwd-hash B was NOT created (atomic abort)
        #expect(!fm.fileExists(atPath: tempHost.appendingPathComponent("projects/-cwd-B").path))

        // Verify: profile projects/ is still a real directory (NOT a symlink)
        #expect((try? fm.destinationOfSymbolicLink(atPath: profileProjectsBaseDir.path)) == nil)
    }

    @Test("AC2.1: non-projects directory with content gets sidecar + symlink")
    func hostMirrorNonProjectsDirWithContentGetsSidecar() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)
        try fm.createDirectory(at: tempHost.appendingPathComponent("plugins", isDirectory: true), withIntermediateDirectories: true)

        // Pre-create profile plugins with content
        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()
        let profileClaudeDir = manager.configDirectory(forProfileID: profileID)
        try fm.createDirectory(at: profileClaudeDir, withIntermediateDirectories: true)

        let profilePlugins = profileClaudeDir.appendingPathComponent("plugins")
        try fm.createDirectory(at: profilePlugins, withIntermediateDirectories: true)
        try "plugin content".write(to: profilePlugins.appendingPathComponent("profile-only.txt"), atomically: true, encoding: .utf8)

        // Call ensureOAuthDir
        _ = try manager.ensureOAuthDir(forProfileID: profileID)

        // Profile plugins should now be a symlink to host
        #expect((try? fm.destinationOfSymbolicLink(atPath: profilePlugins.path)) != nil)

        // Sidecar should exist with original content
        let sidecar = profileClaudeDir.appendingPathComponent("plugins.profile-local")
        #expect(fm.fileExists(atPath: sidecar.path))
        let sidecarContent = try String(contentsOf: sidecar.appendingPathComponent("profile-only.txt"), encoding: .utf8)
        #expect(sidecarContent == "plugin content")
    }

    @Test("AC3.3b: non-projects empty directory is replaced with symlink")
    func hostMirrorNonProjectsEmptyDir() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)
        try fm.createDirectory(at: tempHost.appendingPathComponent("plugins", isDirectory: true), withIntermediateDirectories: true)

        // Pre-create empty profile plugins dir
        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()
        let profileClaudeDir = manager.configDirectory(forProfileID: profileID)
        try fm.createDirectory(at: profileClaudeDir, withIntermediateDirectories: true)

        let profilePlugins = profileClaudeDir.appendingPathComponent("plugins")
        try fm.createDirectory(at: profilePlugins, withIntermediateDirectories: true)

        // Call ensureOAuthDir
        _ = try manager.ensureOAuthDir(forProfileID: profileID)

        // Profile plugins should now be a symlink
        #expect((try? fm.destinationOfSymbolicLink(atPath: profilePlugins.path)) != nil)
    }

    @Test("AC2.1 file variant: non-projects file gets sidecar + symlink")
    func hostMirrorNonProjectsFileGetsSidecar() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)
        try "# Host CLAUDE.md".write(to: tempHost.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)

        // Pre-create profile CLAUDE.md with different content
        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()
        let profileClaudeDir = manager.configDirectory(forProfileID: profileID)
        try fm.createDirectory(at: profileClaudeDir, withIntermediateDirectories: true)

        let profileClaudeFile = profileClaudeDir.appendingPathComponent("CLAUDE.md")
        try "# Profile CLAUDE.md".write(to: profileClaudeFile, atomically: true, encoding: .utf8)

        // Call ensureOAuthDir
        _ = try manager.ensureOAuthDir(forProfileID: profileID)

        // Profile CLAUDE.md should now be a symlink to host
        #expect((try? fm.destinationOfSymbolicLink(atPath: profileClaudeFile.path)) != nil)

        // Sidecar should exist with original profile content
        let sidecar = profileClaudeDir.appendingPathComponent("CLAUDE.md.profile-local")
        #expect(fm.fileExists(atPath: sidecar.path))
        let sidecarContent = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(sidecarContent == "# Profile CLAUDE.md")
    }

    @Test("AC2.2: pre-existing sidecar is not overwritten")
    func hostMirrorSidecarNotOverwritten() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)
        try "# Host CLAUDE.md".write(to: tempHost.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)

        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()
        let profileClaudeDir = manager.configDirectory(forProfileID: profileID)
        try fm.createDirectory(at: profileClaudeDir, withIntermediateDirectories: true)

        let profileClaudeFile = profileClaudeDir.appendingPathComponent("CLAUDE.md")
        let sidecar = profileClaudeDir.appendingPathComponent("CLAUDE.md.profile-local")

        // Run 1: Create the file and sidecar
        try "# Profile CLAUDE.md Run 1".write(to: profileClaudeFile, atomically: true, encoding: .utf8)
        _ = try manager.ensureOAuthDir(forProfileID: profileID)

        // Verify sidecar was created with Run 1 content
        #expect(fm.fileExists(atPath: sidecar.path))
        var sidecarContent = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(sidecarContent == "# Profile CLAUDE.md Run 1")

        // Run 2: Simulate Claude writing new content to the profile-side file
        // (this could happen if someone edits CLAUDE.md after the first mirror, before the second)
        // Note: String.write(to:atomically:true) uses rename(2) under the hood, which replaces
        // the symlink with a real file rather than writing through it. So at the start of the
        // second ensureOAuthDir, profileClaudeFile is a real file with "Run 2" content.
        // This documents that the "skip if sidecar exists" code path is genuinely exercised.
        try "# Profile CLAUDE.md Run 2".write(to: profileClaudeFile, atomically: true, encoding: .utf8)
        _ = try manager.ensureOAuthDir(forProfileID: profileID)

        // Verify full post-Run-2 state:
        // 1. Sidecar still has Run 1 content (not overwritten)
        sidecarContent = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(sidecarContent == "# Profile CLAUDE.md Run 1")

        // 2. Profile-side CLAUDE.md is a real file (not a symlink) containing "Run 2"
        let isSidecarSymlink = (try? fm.destinationOfSymbolicLink(atPath: profileClaudeFile.path)) != nil
        #expect(!isSidecarSymlink, "profile-side CLAUDE.md should be a real file, not a symlink after atomic write")
        let profileContent = try String(contentsOf: profileClaudeFile, encoding: .utf8)
        #expect(profileContent == "# Profile CLAUDE.md Run 2")

        // 3. Host CLAUDE.md is unchanged
        let hostContent = try String(contentsOf: tempHost.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        #expect(hostContent == "# Host CLAUDE.md")
    }

    @Test("AC2.3: empty real directory becomes symlink without sidecar")
    func hostMirrorEmptyDirNoSidecar() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)
        try fm.createDirectory(at: tempHost.appendingPathComponent("skills", isDirectory: true), withIntermediateDirectories: true)

        // Pre-create empty profile skills dir
        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()
        let profileClaudeDir = manager.configDirectory(forProfileID: profileID)
        try fm.createDirectory(at: profileClaudeDir, withIntermediateDirectories: true)

        let profileSkills = profileClaudeDir.appendingPathComponent("skills")
        try fm.createDirectory(at: profileSkills, withIntermediateDirectories: true)

        // Call ensureOAuthDir
        _ = try manager.ensureOAuthDir(forProfileID: profileID)

        // Profile skills should now be a symlink
        #expect((try? fm.destinationOfSymbolicLink(atPath: profileSkills.path)) != nil)

        // No sidecar should exist
        let sidecar = profileClaudeDir.appendingPathComponent("skills.profile-local")
        #expect(!fm.fileExists(atPath: sidecar.path))
    }

    @Test("AC3.3c variant: symlink with wrong target is left alone")
    func hostMirrorSymlinkWrongTarget() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)
        try fm.createDirectory(at: tempHost.appendingPathComponent("plugins", isDirectory: true), withIntermediateDirectories: true)

        // Pre-create profile plugins as a symlink to a junk dir
        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()
        let profileClaudeDir = manager.configDirectory(forProfileID: profileID)
        try fm.createDirectory(at: profileClaudeDir, withIntermediateDirectories: true)

        let junkDir = profileClaudeDir.appendingPathComponent("junk-plugins", isDirectory: true)
        try fm.createDirectory(at: junkDir, withIntermediateDirectories: true)
        let profilePlugins = profileClaudeDir.appendingPathComponent("plugins")
        try fm.createSymbolicLink(at: profilePlugins, withDestinationURL: junkDir)

        // Call ensureOAuthDir
        _ = try manager.ensureOAuthDir(forProfileID: profileID)

        // Profile plugins symlink should still point to junk (unchanged)
        let dest = try fm.destinationOfSymbolicLink(atPath: profilePlugins.path)
        #expect(dest.contains("junk-plugins"))
    }

    // MARK: - hostBaseDirectory constructor and default

    @Test("hostBaseDirectory constructor arg and default")
    func hostBaseDirectoryConstructorArgAndDefault() {
        let tempHostOverride = tempHostBase()
        defer { try? FileManager.default.removeItem(at: tempHostOverride) }

        // Verify that passing a base URL in the init directly works.
        let manager1 = ClaudeProfileConfigDirManager(hostBaseDirectory: tempHostOverride)
        #expect(manager1.hostBaseDirectory == tempHostOverride)

        // Also verify default (nil) still uses ~/.claude/ by checking it
        // contains ".claude" in the path. Through the environment seam, not the
        // process environment: `scripts/test.sh` fences the whole run behind a
        // scratch `TBD_CLAUDE_HOST_HOME`, and reading the process env here
        // would assert the fence instead of the production fallback.
        let manager2 = ClaudeProfileConfigDirManager(hostEnvironment: [:])
        #expect(manager2.hostBaseDirectory.path.contains(".claude"))
        #expect(manager2.hostBaseDirectory.path.contains(NSHomeDirectory()))
    }

    @Test("symlink resolution handles paths through symlinks (e.g. /var -> /private/var)")
    func hostMirrorSymlinkResolutionThroughPathSymlinks() throws {
        let tempBase = tempBase()
        let tempHostBase = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHostBase)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHostBase, withIntermediateDirectories: true)
        try fm.createDirectory(at: tempHostBase.appendingPathComponent("plugins", isDirectory: true), withIntermediateDirectories: true)

        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHostBase)
        let profileID = UUID()

        // Create host slot and then profile slot with symlink
        let dir = try manager.ensureOAuthDir(forProfileID: profileID)
        let pluginsLink = dir.appendingPathComponent("plugins")

        // Verify the symlink was created and points to the right place
        #expect((try? fm.destinationOfSymbolicLink(atPath: pluginsLink.path)) != nil)

        // Re-calling should be idempotent
        _ = try manager.ensureOAuthDir(forProfileID: profileID)
        #expect((try? fm.destinationOfSymbolicLink(atPath: pluginsLink.path)) != nil)
    }

    // MARK: - recursive-projects-merge.AC1: same-name directories merge by recursing

    @Test("recursive-projects-merge.AC1.1: nested dir-vs-dir with disjoint files merges successfully")
    func hostMirrorProjectsMigrationNestedDirMerges() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)

        // Pre-create host projects with cwd-A/sub/ containing one file
        try fm.createDirectory(at: tempHost.appendingPathComponent("projects/-cwd-A/sub", isDirectory: true), withIntermediateDirectories: true)
        let hostLeaf = tempHost.appendingPathComponent("projects/-cwd-A/sub/host-leaf.md")
        try "HOST".write(to: hostLeaf, atomically: true, encoding: .utf8)

        // Pre-create profile projects with cwd-A/sub/ containing a different file
        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()
        let profileClaudeDir = manager.configDirectory(forProfileID: profileID)
        try fm.createDirectory(at: profileClaudeDir, withIntermediateDirectories: true)

        let profileProjectsBase = profileClaudeDir.appendingPathComponent("projects", isDirectory: true)
        try fm.createDirectory(at: profileProjectsBase.appendingPathComponent("-cwd-A/sub", isDirectory: true), withIntermediateDirectories: true)
        let profileLeaf = profileProjectsBase.appendingPathComponent("-cwd-A/sub/profile-leaf.md")
        try "PROFILE".write(to: profileLeaf, atomically: true, encoding: .utf8)

        // Call ensureOAuthDir
        _ = try manager.ensureOAuthDir(forProfileID: profileID)

        // Verify: host file untouched
        #expect(try String(contentsOf: hostLeaf, encoding: .utf8) == "HOST")

        // Verify: profile file migrated into host tree
        let migratedLeaf = tempHost.appendingPathComponent("projects/-cwd-A/sub/profile-leaf.md")
        #expect(fm.fileExists(atPath: migratedLeaf.path))
        #expect(try String(contentsOf: migratedLeaf, encoding: .utf8) == "PROFILE")

        // Verify: profile projects/ is now a symlink
        #expect((try? fm.destinationOfSymbolicLink(atPath: profileProjectsBase.path)) != nil)
    }

    @Test("recursive-projects-merge.AC1.2: empty profile-side memory/ merges (the real bug)")
    func hostMirrorProjectsMigrationEmptyProfileMemory() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)

        // Pre-create host projects with cwd-A/memory/ containing one file
        try fm.createDirectory(at: tempHost.appendingPathComponent("projects/-cwd-A/memory", isDirectory: true), withIntermediateDirectories: true)
        let hostMemNote = tempHost.appendingPathComponent("projects/-cwd-A/memory/note.md")
        try "HOST NOTE".write(to: hostMemNote, atomically: true, encoding: .utf8)

        // Pre-create profile projects with an empty cwd-A/memory/ directory
        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()
        let profileClaudeDir = manager.configDirectory(forProfileID: profileID)
        try fm.createDirectory(at: profileClaudeDir, withIntermediateDirectories: true)

        let profileProjectsBase = profileClaudeDir.appendingPathComponent("projects", isDirectory: true)
        try fm.createDirectory(at: profileProjectsBase.appendingPathComponent("-cwd-A/memory", isDirectory: true), withIntermediateDirectories: true)

        // Call ensureOAuthDir
        _ = try manager.ensureOAuthDir(forProfileID: profileID)

        // Verify: host memory/note.md still has original content
        #expect(try String(contentsOf: hostMemNote, encoding: .utf8) == "HOST NOTE")

        // Verify: profile projects/ is now a symlink (recursive merge removed the empty memory dir)
        #expect((try? fm.destinationOfSymbolicLink(atPath: profileProjectsBase.path)) != nil)
    }

    // MARK: - recursive-projects-merge.AC2: real collisions still abort atomically

    @Test("recursive-projects-merge.AC2.1: nested file-vs-file collision aborts atomically")
    func hostMirrorProjectsMigrationNestedFileCollisionAbortsAtomically() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)

        // Pre-create host projects with cwd-A/sub/leaf.md (collision point)
        try fm.createDirectory(at: tempHost.appendingPathComponent("projects/-cwd-A/sub", isDirectory: true), withIntermediateDirectories: true)
        let hostLeaf = tempHost.appendingPathComponent("projects/-cwd-A/sub/leaf.md")
        try "HOST LEAF".write(to: hostLeaf, atomically: true, encoding: .utf8)

        // Pre-create profile projects with cwd-A/sub/leaf.md (collision) and cwd-B/x.md (clean, non-colliding)
        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()
        let profileClaudeDir = manager.configDirectory(forProfileID: profileID)
        try fm.createDirectory(at: profileClaudeDir, withIntermediateDirectories: true)

        let profileProjectsBase = profileClaudeDir.appendingPathComponent("projects", isDirectory: true)
        try fm.createDirectory(at: profileProjectsBase, withIntermediateDirectories: true)

        // cwd-A with collision file
        try fm.createDirectory(at: profileProjectsBase.appendingPathComponent("-cwd-A/sub", isDirectory: true), withIntermediateDirectories: true)
        let profileLeaf = profileProjectsBase.appendingPathComponent("-cwd-A/sub/leaf.md")
        try "PROFILE LEAF".write(to: profileLeaf, atomically: true, encoding: .utf8)

        // cwd-B with non-colliding file (to verify atomic abort)
        try fm.createDirectory(at: profileProjectsBase.appendingPathComponent("-cwd-B", isDirectory: true), withIntermediateDirectories: true)
        let profileX = profileProjectsBase.appendingPathComponent("-cwd-B/x.md")
        try "PROFILE X".write(to: profileX, atomically: true, encoding: .utf8)

        // Call ensureOAuthDir
        _ = try manager.ensureOAuthDir(forProfileID: profileID)

        // Verify: host leaf still has original content (collision not overwritten)
        #expect(try String(contentsOf: hostLeaf, encoding: .utf8) == "HOST LEAF")

        // Verify: profile collision file was NOT migrated (atomic abort)
        #expect(fm.fileExists(atPath: profileLeaf.path))
        #expect(try String(contentsOf: profileLeaf, encoding: .utf8) == "PROFILE LEAF")

        // Verify: profile non-colliding file was NOT migrated (atomic abort)
        #expect(fm.fileExists(atPath: profileX.path))
        #expect(try String(contentsOf: profileX, encoding: .utf8) == "PROFILE X")

        // Verify: host cwd-B was NOT created (atomic abort)
        #expect(!fm.fileExists(atPath: tempHost.appendingPathComponent("projects/-cwd-B").path))

        // Verify: profile projects/ is still a real directory (NOT a symlink)
        #expect((try? fm.destinationOfSymbolicLink(atPath: profileProjectsBase.path)) == nil)
    }

    @Test("recursive-projects-merge.AC2.2: type-mismatch collision (directory vs file) aborts atomically")
    func hostMirrorProjectsMigrationTypeCollisionAbortsAtomically() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)

        // Pre-create host projects with cwd-A/foo as a directory containing a file
        try fm.createDirectory(at: tempHost.appendingPathComponent("projects/-cwd-A/foo", isDirectory: true), withIntermediateDirectories: true)
        let hostFooFile = tempHost.appendingPathComponent("projects/-cwd-A/foo/content.txt")
        try "HOST FOO CONTENT".write(to: hostFooFile, atomically: true, encoding: .utf8)

        // Pre-create profile projects with cwd-A/foo as a file
        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()
        let profileClaudeDir = manager.configDirectory(forProfileID: profileID)
        try fm.createDirectory(at: profileClaudeDir, withIntermediateDirectories: true)

        let profileProjectsBase = profileClaudeDir.appendingPathComponent("projects", isDirectory: true)
        try fm.createDirectory(at: profileProjectsBase.appendingPathComponent("-cwd-A", isDirectory: true), withIntermediateDirectories: true)
        let profileFooFile = profileProjectsBase.appendingPathComponent("-cwd-A/foo")
        try "PROFILE FOO FILE".write(to: profileFooFile, atomically: true, encoding: .utf8)

        // Call ensureOAuthDir
        _ = try manager.ensureOAuthDir(forProfileID: profileID)

        // Verify: host foo is still a directory with original content
        #expect(fm.fileExists(atPath: hostFooFile.path))
        #expect(try String(contentsOf: hostFooFile, encoding: .utf8) == "HOST FOO CONTENT")

        // Verify: profile foo is still a file with original content
        #expect(fm.fileExists(atPath: profileFooFile.path))
        var profileIsDir: ObjCBool = false
        fm.fileExists(atPath: profileFooFile.path, isDirectory: &profileIsDir)
        #expect(!profileIsDir.boolValue, "profile foo should be a file, not a directory")
        #expect(try String(contentsOf: profileFooFile, encoding: .utf8) == "PROFILE FOO FILE")

        // Verify: profile projects/ is still a real directory (NOT a symlink)
        #expect((try? fm.destinationOfSymbolicLink(atPath: profileProjectsBase.path)) == nil)
    }

    // MARK: - sessions/ mirror slot (cross-session peer registry)
    //
    // Claude Code registers each live session as one JSON row under
    // `$CLAUDE_CONFIG_DIR/sessions/`, so without this slot two TBD profiles
    // cannot see each other's sessions in `ListAgents`. It differs from the
    // other eight slots twice over: an absent host `sessions/` is the ordinary
    // first-run state, so it is created rather than skipped; and pre-existing
    // profile-side rows are live process state, so they are merged into the
    // host registry rather than parked in a sidecar nothing reads.

    /// Resolve the symlink at `link` and compare it to `expected`.
    private func symlinkPoints(_ link: URL, to expected: URL) throws -> Bool {
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        let resolved = URL(fileURLWithPath: dest, relativeTo: link.deletingLastPathComponent())
            .standardizedFileURL
        return resolved == expected.standardizedFileURL
    }

    @Test("sessions/ is symlinked to the host registry when the host slot already exists")
    func sessionsSlotSymlinkedWhenHostSlotExists() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        let hostSessions = tempHost.appendingPathComponent("sessions", isDirectory: true)
        try fm.createDirectory(at: hostSessions, withIntermediateDirectories: true)
        // A peer row already registered by some other session must remain
        // visible through the profile's symlink.
        try #"{"pid":1}"#.write(to: hostSessions.appendingPathComponent("1.json"),
                                atomically: true, encoding: .utf8)

        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let dir = try manager.ensureOAuthDir(forProfileID: UUID())

        let link = dir.appendingPathComponent("sessions")
        #expect(try symlinkPoints(link, to: hostSessions))
        #expect(fm.fileExists(atPath: link.appendingPathComponent("1.json").path))
    }

    @Test("sessions/ host dir is created 0700 and symlinked when the host lacks it")
    func sessionsSlotCreatesHostDirWhenMissing() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        // Host store exists but has never run a session — no sessions/ yet.
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)

        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let dir = try manager.ensureOAuthDir(forProfileID: UUID())

        let hostSessions = tempHost.appendingPathComponent("sessions", isDirectory: true)
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: hostSessions.path, isDirectory: &isDir))
        #expect(isDir.boolValue)

        // 0700 matches how Claude Code creates the registry itself — peer rows
        // carry inbox socket paths and should not be world-readable.
        let mode = try fm.attributesOfItem(atPath: hostSessions.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o700)

        #expect(try symlinkPoints(dir.appendingPathComponent("sessions"), to: hostSessions))
    }

    @Test("sessions/ slot is idempotent — a second ensure leaves the same symlink")
    func sessionsSlotIdempotent() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)

        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()

        let dir1 = try manager.ensureOAuthDir(forProfileID: profileID)
        let link = dir1.appendingPathComponent("sessions")
        let dest1 = try fm.destinationOfSymbolicLink(atPath: link.path)

        let dir2 = try manager.ensureOAuthDir(forProfileID: profileID)
        let dest2 = try fm.destinationOfSymbolicLink(atPath: link.path)

        #expect(dir1 == dir2)
        #expect(dest1 == dest2)
        // No `sessions.profile-local` invented on the idempotent pass.
        #expect(!fm.fileExists(atPath: dir2.appendingPathComponent("sessions.profile-local").path))
    }

    /// Seed a profile-side real `sessions/` directory with rows, before any
    /// `ensure…` call has had a chance to symlink it.
    private func seedProfileSessions(
        _ manager: ClaudeProfileConfigDirManager,
        profileID: UUID,
        rows: [String: String],
        modified: Date? = nil
    ) throws -> URL {
        let fm = FileManager.default
        let profileSessions = manager.configDirectory(forProfileID: profileID)
            .appendingPathComponent("sessions", isDirectory: true)
        try fm.createDirectory(at: profileSessions, withIntermediateDirectories: true)
        for (rowName, contents) in rows {
            let row = profileSessions.appendingPathComponent(rowName)
            try contents.write(to: row, atomically: true, encoding: .utf8)
            if let modified {
                try fm.setAttributes([.modificationDate: modified], ofItemAtPath: row.path)
            }
        }
        return profileSessions
    }

    /// The merge, not the sidecar: a `sessions/` row is live process state, and
    /// the row's owner unlinks the *host* path when it exits — so a sidecar
    /// move would orphan a running session's row where nothing ever reads it.
    @Test("pre-existing profile sessions/ rows are merged into the host registry")
    func sessionsSlotMergesProfileRowsIntoHost() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        let hostSessions = tempHost.appendingPathComponent("sessions", isDirectory: true)
        try fm.createDirectory(at: hostSessions, withIntermediateDirectories: true)
        try #"{"pid":1}"#.write(to: hostSessions.appendingPathComponent("1.json"),
                                atomically: true, encoding: .utf8)

        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()
        let profileSessions = try seedProfileSessions(
            manager, profileID: profileID,
            rows: ["4242.json": #"{"pid":4242}"#, "77.json": #"{"pid":77}"#]
        )

        let dir = try manager.ensureOAuthDir(forProfileID: profileID)

        // Both profile rows now live in the host registry, contents intact.
        #expect(try String(contentsOf: hostSessions.appendingPathComponent("4242.json"),
                           encoding: .utf8) == #"{"pid":4242}"#)
        #expect(try String(contentsOf: hostSessions.appendingPathComponent("77.json"),
                           encoding: .utf8) == #"{"pid":77}"#)
        // The row that was already host-side is untouched.
        #expect(fm.fileExists(atPath: hostSessions.appendingPathComponent("1.json").path))

        // The emptied profile directory is gone, replaced by the symlink — and
        // no sidecar was invented on the way.
        #expect(try symlinkPoints(dir.appendingPathComponent("sessions"), to: hostSessions))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("sessions.profile-local").path))
        // Reachable through the link the spawned session will actually use.
        #expect(fm.fileExists(atPath: profileSessions.appendingPathComponent("4242.json").path))
    }

    /// A duplicate `<pid>.json` across two profiles means one row is stale —
    /// a dead process whose PID was reused. Newest modification time wins,
    /// in both directions.
    @Test("a same-named row on both sides keeps the newer copy")
    func sessionsSlotMergeKeepsNewerRow() throws {
        let fm = FileManager.default
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)

        // Arm 1: the profile copy is newer and must replace the host copy.
        // Arm 2: the host copy is newer and the profile copy is discarded.
        for profileIsNewer in [true, false] {
            let tempBase = tempBase()
            let tempHost = tempHostBase()
            defer {
                try? fm.removeItem(at: tempBase)
                try? fm.removeItem(at: tempHost)
            }

            let hostSessions = tempHost.appendingPathComponent("sessions", isDirectory: true)
            try fm.createDirectory(at: hostSessions, withIntermediateDirectories: true)
            let hostRow = hostSessions.appendingPathComponent("500.json")
            try #"{"pid":500,"side":"host"}"#.write(to: hostRow, atomically: true, encoding: .utf8)
            try fm.setAttributes([.modificationDate: profileIsNewer ? old : new],
                                 ofItemAtPath: hostRow.path)

            let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
            let profileID = UUID()
            _ = try seedProfileSessions(
                manager, profileID: profileID,
                rows: ["500.json": #"{"pid":500,"side":"profile"}"#],
                modified: profileIsNewer ? new : old
            )

            let dir = try manager.ensureOAuthDir(forProfileID: profileID)

            let surviving = try String(contentsOf: hostRow, encoding: .utf8)
            #expect(surviving == (profileIsNewer ? #"{"pid":500,"side":"profile"}"#
                                                 : #"{"pid":500,"side":"host"}"#),
                    "newer row must win (profileIsNewer=\(profileIsNewer))")
            // Exactly one copy survives, and the profile dir is a symlink.
            #expect(try fm.contentsOfDirectory(atPath: hostSessions.path) == ["500.json"])
            #expect(try symlinkPoints(dir.appendingPathComponent("sessions"), to: hostSessions))
            #expect(!fm.fileExists(atPath: dir.appendingPathComponent("sessions.profile-local").path))
        }
    }

    @Test("an empty profile sessions/ dir is just replaced by the symlink")
    func sessionsSlotEmptyProfileDirJustSymlinks() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        let hostSessions = tempHost.appendingPathComponent("sessions", isDirectory: true)
        try fm.createDirectory(at: hostSessions, withIntermediateDirectories: true)
        try #"{"pid":9}"#.write(to: hostSessions.appendingPathComponent("9.json"),
                                atomically: true, encoding: .utf8)

        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()
        _ = try seedProfileSessions(manager, profileID: profileID, rows: [:])

        let dir = try manager.ensureOAuthDir(forProfileID: profileID)

        #expect(try symlinkPoints(dir.appendingPathComponent("sessions"), to: hostSessions))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("sessions.profile-local").path))
        #expect(try fm.contentsOfDirectory(atPath: hostSessions.path) == ["9.json"])
    }

    /// The merge is scoped to `sessions`. Every other slot still parks
    /// pre-existing profile content in a `<slot>.profile-local` sidecar — if
    /// the merge leaked, the profile's file would have landed in the host store
    /// instead, silently overwriting nothing but destroying the isolation.
    @Test("merge does not leak — a non-sessions slot still uses the sidecar")
    func mergeIsScopedToSessionsSlot() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        let hostCommands = tempHost.appendingPathComponent("commands", isDirectory: true)
        try fm.createDirectory(at: hostCommands, withIntermediateDirectories: true)

        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()
        let profileCommands = manager.configDirectory(forProfileID: profileID)
            .appendingPathComponent("commands", isDirectory: true)
        try fm.createDirectory(at: profileCommands, withIntermediateDirectories: true)
        try "profile-only".write(to: profileCommands.appendingPathComponent("mine.md"),
                                 atomically: true, encoding: .utf8)

        let dir = try manager.ensureOAuthDir(forProfileID: profileID)

        let sidecarEntry = dir.appendingPathComponent("commands.profile-local")
            .appendingPathComponent("mine.md")
        #expect(try String(contentsOf: sidecarEntry, encoding: .utf8) == "profile-only")
        // The merge must NOT have moved it into the host store.
        #expect(try fm.contentsOfDirectory(atPath: hostCommands.path).isEmpty)
        #expect(try symlinkPoints(dir.appendingPathComponent("commands"), to: hostCommands))
    }

    /// `fileExists` says "true" for a regular file, so an unvalidated guard
    /// would symlink every profile at it and fail every registry write.
    @Test("a host sessions/ that is a regular file is left alone, not symlinked at")
    func hostSessionsRegularFileIsLeftAlone() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)
        let hostSessions = tempHost.appendingPathComponent("sessions")
        try "not a directory".write(to: hostSessions, atomically: true, encoding: .utf8)

        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let dir = try manager.ensureOAuthDir(forProfileID: UUID())

        #expect((try? fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("sessions").path)) == nil)
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("sessions").path))
        // The host file is untouched — TBD does not clobber what it cannot use.
        #expect(try String(contentsOf: hostSessions, encoding: .utf8) == "not a directory")
    }

    /// `fileExists` says "false" for a *dangling* symlink, so an unvalidated
    /// guard would take the create branch, hit EEXIST, log, and return — every
    /// spawn, forever.
    @Test("a host sessions/ that is a dangling symlink is left alone")
    func hostSessionsDanglingSymlinkIsLeftAlone() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)
        let hostSessions = tempHost.appendingPathComponent("sessions")
        let missingTarget = tempHost.appendingPathComponent("gone", isDirectory: true)
        try fm.createSymbolicLink(at: hostSessions, withDestinationURL: missingTarget)

        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let dir = try manager.ensureOAuthDir(forProfileID: UUID())

        #expect((try? fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("sessions").path)) == nil)
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("sessions").path))
        // Still dangling: nothing was created behind it either.
        #expect(try fm.destinationOfSymbolicLink(atPath: hostSessions.path) == missingTarget.path)
        #expect(!fm.fileExists(atPath: missingTarget.path))
    }

    /// Creating the slot must never conjure the host store itself. On a machine
    /// with no `~/.claude` at all there is nothing to mirror, and inventing one
    /// (0700, owned by TBD) is exactly the host state the other slots take care
    /// not to fabricate.
    @Test("an absent host base directory is never created for the sessions slot")
    func absentHostBaseDirectoryIsNeverCreated() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        // Deliberately NOT created: the host store does not exist.
        #expect(!fm.fileExists(atPath: tempHost.path))

        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let dir = try manager.ensureOAuthDir(forProfileID: UUID())

        #expect(!fm.fileExists(atPath: tempHost.path), "host store must not be conjured")
        #expect(!fm.fileExists(atPath: tempHost.appendingPathComponent("sessions").path))
        #expect((try? fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("sessions").path)) == nil)
    }

    @Test("create-on-missing does not leak to the other slots — absent host slots still skip")
    func createOnMissingIsScopedToSessionsSlot() throws {
        let tempBase = tempBase()
        let tempHost = tempHostBase()
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: tempHost)
        }

        let fm = FileManager.default
        // Host store is entirely empty: only `sessions` may be conjured.
        try fm.createDirectory(at: tempHost, withIntermediateDirectories: true)

        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let dir = try manager.ensureOAuthDir(forProfileID: UUID())

        for slot in ["projects", "plugins", "skills", "agents", "commands", "hooks", "CLAUDE.md", "settings.json"] {
            #expect(!fm.fileExists(atPath: tempHost.appendingPathComponent(slot).path),
                    "host slot \(slot) must not be created")
            #expect((try? fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent(slot).path)) == nil,
                    "profile slot \(slot) must not be symlinked")
        }
        #expect(fm.fileExists(atPath: tempHost.appendingPathComponent("sessions").path))
    }
}

// Nested under TBDHomeSerialized: mutates a process-global environment
// variable. `@Suite(.serialized)` alone was NOT enough — it orders tests only
// within this suite and does nothing against the ~520 other suites Swift
// Testing runs concurrently in the same process, which is the documented root
// cause of the `ConstantsTests.derivedPathsFollowTBDHome` flake.
// See TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {
    @Suite("ClaudeProfileConfigDirManager env vars")
    struct ClaudeProfileConfigDirManagerEnvVarTests {
        private func tempHostBase() -> URL {
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tbd-host-cfg-test-\(UUID().uuidString)", isDirectory: true)
        }

        @Test("TBD_CLAUDE_HOST_HOME env var is honored in default init")
        func hostBaseDirectoryRespectsTBDClaudeHostHomeEnvVar() {
            let tempHostOverride = tempHostBase()
            defer { try? FileManager.default.removeItem(at: tempHostOverride) }

            // Save/restore via the shared helpers rather than by hand: the run is
            // fenced behind a scratch `TBD_CLAUDE_HOST_HOME`, and a teardown that
            // unsets exposes the real `~/.claude` to every concurrent suite.
            let priorValue = setClaudeHostHome(tempHostOverride.path)
            defer { restoreClaudeHostHome(priorValue) }

            let manager = ClaudeProfileConfigDirManager()
            #expect(manager.hostBaseDirectory.resolvingSymlinksInPath()
                    == tempHostOverride.resolvingSymlinksInPath())
        }
    }
}
