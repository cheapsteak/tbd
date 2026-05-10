import Foundation
import Testing
@testable import TBDDaemonLib

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
        #expect(r.sensitiveEnv.isEmpty)
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
        #expect(r.sensitiveEnv.isEmpty)
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

    @Test("resume + token: token in sensitiveEnv, not command")
    func resumeWithToken() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: "abc",
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: fakeOauth,
            cmd: nil,
            shellFallback: ""
        )
        #expect(r.command == "claude --resume abc --dangerously-skip-permissions")
        #expect(!r.command.contains(fakeOauth))
        #expect(!r.command.contains("CLAUDE_CODE_OAUTH_TOKEN"))
        #expect(r.sensitiveEnv == ["CLAUDE_CODE_OAUTH_TOKEN": fakeOauth])
    }

    @Test("fresh + token: token in sensitiveEnv, not command")
    func freshWithToken() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: fakeOauth,
            cmd: nil,
            shellFallback: ""
        )
        #expect(r.command.hasPrefix("claude --session-id sid"))
        #expect(!r.command.contains(fakeOauth))
        #expect(r.sensitiveEnv["CLAUDE_CODE_OAUTH_TOKEN"] == fakeOauth)
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
        #expect(r.sensitiveEnv == ["ANTHROPIC_API_KEY": fakeOauth])
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

    @Test("no base URL or model means env stays auth-only (today's behavior)")
    func profileWithoutProxyOnlyInjectsAuth() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "abc",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: "tok",
            profileKind: .oauth,
            profileBaseURL: nil,
            profileModel: nil,
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        #expect(r.sensitiveEnv["CLAUDE_CODE_OAUTH_TOKEN"] == "tok")
        #expect(r.sensitiveEnv["ANTHROPIC_BASE_URL"] == nil)
        #expect(r.sensitiveEnv["ANTHROPIC_MODEL"] == nil)
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
}
