import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

@Suite("ClaudeSpawnCommandBuilder")
struct ClaudeSpawnCommandBuilderTests {

    private let fakeOauth = "sk-ant-oat01-fake"

    // MARK: - Fallback / non-token branches

    @Test("resume id only")
    func resumeOnly() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: "abc-123",
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        #expect(r.command == "claude --resume abc-123 --dangerously-skip-permissions")
        // Registry injects CLAUDE_CODE_NO_FLICKER=1 by default for all Claude spawns.
        #expect(r.sensitiveEnv == ["CLAUDE_CODE_NO_FLICKER": "1"])
    }

    @Test("fresh session id only")
    func freshOnly() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid-1",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        #expect(r.command == "claude --session-id sid-1 --dangerously-skip-permissions")
        // Registry injects CLAUDE_CODE_NO_FLICKER=1 by default for all Claude spawns.
        #expect(r.sensitiveEnv == ["CLAUDE_CODE_NO_FLICKER": "1"])
    }

    @Test("fresh + appendSystemPrompt")
    func freshWithAppend() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid",
            appendSystemPrompt: "hello world",
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: ""
        )
        #expect(r.command.contains("--append-system-prompt 'hello world'"))
    }

    @Test("fresh + initial prompt")
    func freshWithInitialPrompt() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid",
            appendSystemPrompt: nil,
            initialPrompt: "do the thing",
            profileSecret: nil,
            cmd: nil,
            shellFallback: ""
        )
        #expect(r.command.hasSuffix(" 'do the thing'"))
    }

    @Test("cmd path returns verbatim")
    func cmdVerbatim() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: "ls -la",
            shellFallback: "/bin/zsh"
        )
        #expect(r.command == "ls -la")
        #expect(r.sensitiveEnv.isEmpty)
    }

    @Test("all nil returns shell fallback")
    func shellFallback() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        #expect(r.command == "/bin/zsh")
        #expect(r.sensitiveEnv.isEmpty)
    }

    // MARK: - Token branches: secret returned via sensitiveEnv, NOT in command

    @Test("resume + oauth secret: token NOT injected (oauth profiles get config dir instead)")
    func resumeWithOAuthSecret() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: "abc",
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: fakeOauth,
            profileKind: .oauth,
            cmd: nil,
            shellFallback: ""
        )
        #expect(r.command == "claude --resume abc --dangerously-skip-permissions")
        #expect(!r.command.contains(fakeOauth))
        #expect(!r.command.contains("CLAUDE_CODE_OAUTH_TOKEN"))
        #expect(r.sensitiveEnv["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
    }

    @Test("fresh + api-key secret: uses ANTHROPIC_API_KEY in sensitiveEnv")
    func freshWithAPIKeySecret() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: fakeOauth,
            profileKind: .apiKey,
            cmd: nil,
            shellFallback: ""
        )
        #expect(r.command.hasPrefix("claude --session-id sid"))
        #expect(!r.command.contains(fakeOauth))
        #expect(r.sensitiveEnv["ANTHROPIC_API_KEY"] == fakeOauth)
        #expect(r.sensitiveEnv["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
    }

    @Test("api key kind uses ANTHROPIC_API_KEY")
    func apiKeyKind() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: "abc",
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: fakeOauth,
            profileKind: .apiKey,
            cmd: nil,
            shellFallback: ""
        )
        #expect(!r.command.contains(fakeOauth))
        // Registry injects CLAUDE_CODE_NO_FLICKER=1 by default for all Claude spawns.
        #expect(r.sensitiveEnv == ["ANTHROPIC_API_KEY": fakeOauth, "CLAUDE_CODE_NO_FLICKER": "1"])
    }

    @Test("cmd path ignores token (non-claude shell)")
    func cmdIgnoresToken() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: fakeOauth,
            cmd: "make test",
            shellFallback: ""
        )
        #expect(r.command == "make test")
        #expect(r.sensitiveEnv.isEmpty)
    }

    @Test("shell fallback ignores token")
    func shellFallbackIgnoresToken() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: fakeOauth,
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        #expect(r.command == "/bin/zsh")
        #expect(r.sensitiveEnv.isEmpty)
    }

    // MARK: - Profile baseURL / model injection

    @Test("base URL and model env vars set when profile has them")
    func profileWithProxyInjectsRoutingEnv() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "abc",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: "key",
            profileKind: .apiKey,
            profileBaseURL: "http://127.0.0.1:3456",
            profileModel: "gpt-5-codex",
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        #expect(r.sensitiveEnv["ANTHROPIC_API_KEY"] == "key")
        #expect(r.sensitiveEnv["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:3456")
        #expect(r.sensitiveEnv["ANTHROPIC_MODEL"] == "gpt-5-codex")
    }

    @Test("oauth profile without configDir → no token, no config dir")
    func oauthWithoutConfigDirInjectsNothing() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "abc",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: "tok",
            profileKind: .oauth,
            profileBaseURL: nil,
            profileModel: nil,
            profileConfigDir: nil,
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        // OAuth profiles don't inject tokens; they rely on CLAUDE_CONFIG_DIR
        #expect(r.sensitiveEnv["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(r.sensitiveEnv["CLAUDE_CONFIG_DIR"] == nil)
        #expect(r.sensitiveEnv["ANTHROPIC_BASE_URL"] == nil)
        #expect(r.sensitiveEnv["ANTHROPIC_MODEL"] == nil)
    }

    // MARK: - CLAUDE_CONFIG_DIR for all non-bedrock profiles

    @Test("oauth profile + profileConfigDir → CLAUDE_CONFIG_DIR injected, no token")
    func oauthProfileInjectsConfigDir() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "abc",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            profileKind: .oauth,
            profileBaseURL: nil,
            profileModel: nil,
            profileConfigDir: "/Users/me/tbd/profiles/abc/claude",
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        #expect(r.sensitiveEnv["CLAUDE_CONFIG_DIR"] == "/Users/me/tbd/profiles/abc/claude")
        #expect(r.sensitiveEnv["ANTHROPIC_API_KEY"] == nil)
        #expect(r.sensitiveEnv["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
    }

    @Test("api-key profile + profileConfigDir → CLAUDE_CONFIG_DIR + ANTHROPIC_API_KEY")
    func apiKeyProfileInjectsConfigDirAndKey() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "abc",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: "sk-proxy-key",
            profileKind: .apiKey,
            profileBaseURL: "http://127.0.0.1:3456",
            profileModel: "gpt-5-codex",
            profileConfigDir: "/Users/me/tbd/profiles/abc/claude",
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        #expect(r.sensitiveEnv["CLAUDE_CONFIG_DIR"] == "/Users/me/tbd/profiles/abc/claude")
        #expect(r.sensitiveEnv["ANTHROPIC_API_KEY"] == "sk-proxy-key")
        #expect(r.sensitiveEnv["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:3456")
        #expect(r.sensitiveEnv["ANTHROPIC_CONFIG_DIR"] == nil)
    }

    @Test("profile with no configDir → CLAUDE_CONFIG_DIR NOT injected")
    func profileWithoutConfigDirSkipsInjection() {
        // Builder is pure — if the caller failed to resolve a config dir
        // (e.g. mkdir errored), we still spawn rather than crash.
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "abc",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: "sk-proxy",
            profileKind: .apiKey,
            profileBaseURL: "http://127.0.0.1:3456",
            profileModel: nil,
            profileConfigDir: nil,
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        #expect(r.sensitiveEnv["CLAUDE_CONFIG_DIR"] == nil)
        #expect(r.sensitiveEnv["ANTHROPIC_API_KEY"] == "sk-proxy")
        #expect(r.sensitiveEnv["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:3456")
    }

    // MARK: - settingsOverlayPath branch

    @Test("settings overlay path absent → no --settings flag in command")
    func settingsOverlayNotPassed() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: "abc",
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh",
            settingsOverlayPath: nil
        )
        #expect(!r.command.contains("--settings"))
    }

    @Test("settings overlay path supplied but file missing → no --settings flag")
    func settingsOverlayMissingFile() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: "abc",
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh",
            settingsOverlayPath: "/tmp/this-path-cannot-possibly-exist-\(UUID().uuidString)/overlay.json"
        )
        #expect(!r.command.contains("--settings"))
    }

    @Test("settings overlay path with existing file → --settings flag emitted")
    func settingsOverlayWithExistingFile() throws {
        let tmpFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-overlay-test-\(UUID().uuidString).json")
        try "{}".data(using: .utf8)!.write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: "abc",
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh",
            settingsOverlayPath: tmpFile.path
        )
        #expect(r.command.contains("--settings"))
        #expect(r.command.contains(tmpFile.path))
    }

    @Test("--settings flag also applied to fresh-session spawns")
    func settingsOverlayOnFreshSession() throws {
        let tmpFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-overlay-fresh-\(UUID().uuidString).json")
        try "{}".data(using: .utf8)!.write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh",
            settingsOverlayPath: tmpFile.path
        )
        #expect(r.command.contains("--session-id sid"))
        #expect(r.command.contains("--settings"))
    }

    @Test("--settings is NOT emitted in cmd or shell-fallback branches")
    func settingsOverlayIgnoredForCmdBranch() throws {
        let tmpFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-overlay-cmd-\(UUID().uuidString).json")
        try "{}".data(using: .utf8)!.write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        // cmd path returns the verbatim cmd, no --settings injection
        let r1 = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: "codex --full-auto",
            shellFallback: "/bin/zsh",
            settingsOverlayPath: tmpFile.path
        )
        #expect(r1.command == "codex --full-auto")
        // shell fallback path likewise verbatim
        let r2 = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh",
            settingsOverlayPath: tmpFile.path
        )
        #expect(r2.command == "/bin/zsh")
    }

    // MARK: - pluginDirPath branch

    @Test("plugin dir path nil → no --plugin-dir flag")
    func pluginDirNotPassed() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: "abc",
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh",
            pluginDirPath: nil
        )
        #expect(!r.command.contains("--plugin-dir"))
    }

    @Test("plugin dir path supplied but missing → no --plugin-dir flag")
    func pluginDirMissing() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: "abc",
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh",
            pluginDirPath: "/tmp/this-path-cannot-possibly-exist-\(UUID().uuidString)/plugin"
        )
        #expect(!r.command.contains("--plugin-dir"))
    }

    @Test("plugin dir present + resume → --plugin-dir flag emitted")
    func pluginDirOnResume() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-plugin-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: "abc",
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh",
            pluginDirPath: tmpDir.path
        )
        #expect(r.command.contains("--plugin-dir"))
        #expect(r.command.contains(tmpDir.path))
    }

    @Test("plugin dir present + fresh session → --plugin-dir flag emitted")
    func pluginDirOnFresh() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-plugin-fresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh",
            pluginDirPath: tmpDir.path
        )
        #expect(r.command.contains("--session-id sid"))
        #expect(r.command.contains("--plugin-dir"))
    }

    @Test("plugin dir + settings overlay both present → both flags emitted")
    func pluginDirAndSettingsOverlay() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-plugin-both-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let tmpFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-overlay-both-\(UUID().uuidString).json")
        try "{}".data(using: .utf8)!.write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: "abc",
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh",
            settingsOverlayPath: tmpFile.path,
            pluginDirPath: tmpDir.path
        )
        #expect(r.command.contains("--settings"))
        #expect(r.command.contains("--plugin-dir"))
    }

    @Test("--plugin-dir is NOT emitted in cmd or shell-fallback branches")
    func pluginDirIgnoredForCmdBranch() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-plugin-cmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: "ls -la",
            shellFallback: "/bin/zsh",
            pluginDirPath: tmpDir.path
        )
        #expect(r.command == "ls -la")
        #expect(!r.command.contains("--plugin-dir"))
    }

    // MARK: - Bedrock

    @Test("bedrock: full env set with AWS_PROFILE")
    func bedrockFullEnv() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            profileKind: .bedrock,
            profileBaseURL: nil,
            profileModel: "anthropic.claude-sonnet-4-5",
            profileAwsRegion: "us-west-2",
            profileAwsProfile: "acme-prod",
            profileConfigDir: nil,
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        #expect(r.sensitiveEnv["CLAUDE_CODE_USE_BEDROCK"] == "1")
        #expect(r.sensitiveEnv["AWS_REGION"] == "us-west-2")
        #expect(r.sensitiveEnv["AWS_PROFILE"] == "acme-prod")
        #expect(r.sensitiveEnv["ANTHROPIC_MODEL"] == "anthropic.claude-sonnet-4-5")
        // Forbidden keys
        #expect(r.sensitiveEnv["ANTHROPIC_API_KEY"] == nil)
        #expect(r.sensitiveEnv["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(r.sensitiveEnv["ANTHROPIC_BASE_URL"] == nil)
        #expect(r.sensitiveEnv["CLAUDE_CONFIG_DIR"] == nil)
        #expect(r.sensitiveEnv["ANTHROPIC_CONFIG_DIR"] == nil)
        // Exactly these 5 keys (registry adds CLAUDE_CODE_NO_FLICKER=1 for all Claude spawns)
        #expect(r.sensitiveEnv.keys.sorted() == ["ANTHROPIC_MODEL", "AWS_PROFILE", "AWS_REGION", "CLAUDE_CODE_NO_FLICKER", "CLAUDE_CODE_USE_BEDROCK"])
    }

    @Test("bedrock: AWS_PROFILE omitted when nil")
    func bedrockNoAwsProfile() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            profileKind: .bedrock,
            profileBaseURL: nil,
            profileModel: "anthropic.claude-sonnet-4-5",
            profileAwsRegion: "us-east-1",
            profileAwsProfile: nil,
            profileConfigDir: nil,
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        #expect(r.sensitiveEnv["AWS_PROFILE"] == nil)
        #expect(r.sensitiveEnv["AWS_REGION"] == "us-east-1")
        #expect(r.sensitiveEnv["CLAUDE_CODE_USE_BEDROCK"] == "1")
        #expect(r.sensitiveEnv["ANTHROPIC_MODEL"] == "anthropic.claude-sonnet-4-5")
    }

    @Test("bedrock: stray profileSecret is ignored")
    func bedrockIgnoresStraySecret() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: "stray-secret",
            profileKind: .bedrock,
            profileBaseURL: nil,
            profileModel: "anthropic.claude-sonnet-4-5",
            profileAwsRegion: "us-west-2",
            profileAwsProfile: nil,
            profileConfigDir: nil,
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        #expect(r.sensitiveEnv["ANTHROPIC_API_KEY"] == nil)
        #expect(r.sensitiveEnv["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
    }

    @Test("oauth: ignores bedrock params and doesn't inject token without configDir")
    func oauthIgnoresBedrockParams() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: fakeOauth,
            profileKind: .oauth,
            profileBaseURL: nil,
            profileModel: nil,
            profileAwsRegion: "us-west-2",   // present but ignored
            profileAwsProfile: "foo",        // present but ignored
            profileConfigDir: nil,
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        // OAuth profiles don't inject tokens (they use config dir instead)
        #expect(r.sensitiveEnv["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(r.sensitiveEnv["AWS_REGION"] == nil)
        #expect(r.sensitiveEnv["CLAUDE_CODE_USE_BEDROCK"] == nil)
    }
}

@Suite("ClaudeSpawnCommandBuilder env settings")
struct ClaudeSpawnCommandBuilderEnvTests {
    @Test("fresh Claude spawn with no overrides emits CLAUDE_CODE_NO_FLICKER=1")
    func defaultOnFresh() {
        let result = ClaudeSpawnCommandBuilder.build(
            resumeID: nil, freshSessionID: "S1", appendSystemPrompt: nil,
            initialPrompt: nil, profileSecret: nil,
            cmd: nil, shellFallback: "/bin/zsh",
            envSettingOverrides: [:])
        #expect(result.sensitiveEnv["CLAUDE_CODE_NO_FLICKER"] == "1")
    }

    @Test("explicit false override omits CLAUDE_CODE_NO_FLICKER")
    func falseOverrideOmits() {
        let result = ClaudeSpawnCommandBuilder.build(
            resumeID: nil, freshSessionID: "S1", appendSystemPrompt: nil,
            initialPrompt: nil, profileSecret: nil,
            cmd: nil, shellFallback: "/bin/zsh",
            envSettingOverrides: ["fullscreenRendering": .bool(false)])
        #expect(result.sensitiveEnv["CLAUDE_CODE_NO_FLICKER"] == nil)
    }

    @Test("resume Claude spawn also emits the env var")
    func defaultOnResume() {
        let result = ClaudeSpawnCommandBuilder.build(
            resumeID: "R1", freshSessionID: nil, appendSystemPrompt: nil,
            initialPrompt: nil, profileSecret: nil,
            cmd: nil, shellFallback: "/bin/zsh",
            envSettingOverrides: [:])
        #expect(result.sensitiveEnv["CLAUDE_CODE_NO_FLICKER"] == "1")
    }

    @Test("non-Claude (cmd) spawn never emits the env var")
    func cmdSpawnNoEnv() {
        let result = ClaudeSpawnCommandBuilder.build(
            resumeID: nil, freshSessionID: nil, appendSystemPrompt: nil,
            initialPrompt: nil, profileSecret: nil,
            cmd: "codex", shellFallback: "/bin/zsh",
            envSettingOverrides: [:])
        #expect(result.sensitiveEnv["CLAUDE_CODE_NO_FLICKER"] == nil)
    }
}
