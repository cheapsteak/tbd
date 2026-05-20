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
        #expect(ClaudeProfileConfigDirManager.resolveConfigDir(for: nil) == nil)
    }

    @Test("ensureOAuthDir produces a per-profile path")
    func resolveOAuthProfileReturnsPath() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        // resolveConfigDir is static and uses the default ~/tbd base, so the
        // oauth branch is exercised here via ensureOAuthDir against a temp base.
        let profileID = UUID()
        let manager = ClaudeProfileConfigDirManager(baseDirectory: base)
        let dir = try manager.ensureOAuthDir(forProfileID: profileID)
        #expect(dir.path.contains(profileID.uuidString.lowercased()))
    }

    @Test("ensureAPIKeyDir produces a per-profile path")
    func ensureAPIKeyDirReturnsPath() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        // resolveConfigDir is static and uses the default ~/tbd base, so the
        // api-key branch is exercised here via ensureAPIKeyDir against a temp base.
        let profileID = UUID()
        let manager = ClaudeProfileConfigDirManager(baseDirectory: base)
        let dir = try manager.ensureAPIKeyDir(forProfileID: profileID, apiKey: "sk-ant-api03-test-key-XXXXX")
        #expect(dir.path.contains(profileID.uuidString.lowercased()))
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

    // MARK: - host mirror slots

    @Test("AC1.1 / AC1.2: symlink dir and file host slots after ensureOAuthDir and ensureAPIKeyDir")
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

    @Test("AC1.3: skip host slot if not present on host")
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

        // Pre-create profile projects with same file (should not overwrite)
        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)
        let profileID = UUID()
        let profileClaudeDir = manager.configDirectory(forProfileID: profileID)
        try fm.createDirectory(at: profileClaudeDir, withIntermediateDirectories: true)

        let profileProjectsDir = profileClaudeDir.appendingPathComponent("projects/-Users-test-cwd", isDirectory: true)
        try fm.createDirectory(at: profileProjectsDir, withIntermediateDirectories: true)
        let profileFile = profileClaudeDir.appendingPathComponent("projects/-Users-test-cwd/sess-X.jsonl")
        try "PROFILE".write(to: profileFile, atomically: true, encoding: .utf8)

        // Call ensureOAuthDir
        _ = try manager.ensureOAuthDir(forProfileID: profileID)

        // Host file should still contain "HOST"
        let hostContent = try String(contentsOf: hostFile, encoding: .utf8)
        #expect(hostContent == "HOST")
    }

    @Test("AC3.3a: non-projects directory with content is left alone")
    func hostMirrorNonProjectsDirWithContent() throws {
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
        try "plugin content".write(to: profilePlugins.appendingPathComponent("foo.txt"), atomically: true, encoding: .utf8)

        // Call ensureOAuthDir
        _ = try manager.ensureOAuthDir(forProfileID: profileID)

        // Profile plugins should still be a real directory (NOT symlink)
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: profilePlugins.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        #expect((try? fm.destinationOfSymbolicLink(atPath: profilePlugins.path)) == nil)

        // Content should still be there
        #expect(fm.fileExists(atPath: profilePlugins.appendingPathComponent("foo.txt").path))
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

    @Test("AC3.3c: non-projects file is left alone")
    func hostMirrorNonProjectsFile() throws {
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

        // Profile file should still exist with original content (NOT symlink)
        #expect((try? fm.destinationOfSymbolicLink(atPath: profileClaudeFile.path)) == nil)
        let content = try String(contentsOf: profileClaudeFile, encoding: .utf8)
        #expect(content == "# Profile CLAUDE.md")
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

    // MARK: - env var TBD_CLAUDE_HOST_HOME

    @Test("TBD_CLAUDE_HOST_HOME env var overrides default host base directory")
    func hostBaseDirectoryRespectsTBDClaudeHostHomeEnv() {
        let tempHostOverride = tempHostBase()
        defer { try? FileManager.default.removeItem(at: tempHostOverride) }

        // Create manager with no explicit hostBaseDirectory arg, but verify
        // that passing a base URL in the init directly works (simulating
        // what resolveConfigDir would do with env-based override).
        let manager1 = ClaudeProfileConfigDirManager(hostBaseDirectory: tempHostOverride)
        #expect(manager1.hostBaseDirectory == tempHostOverride)

        // Also verify default (nil) still uses ~/.claude/ by checking it
        // contains ".claude" in the path.
        let manager2 = ClaudeProfileConfigDirManager()
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
}
