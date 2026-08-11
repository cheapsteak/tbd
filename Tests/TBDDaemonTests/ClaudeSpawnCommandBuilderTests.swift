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
        // Registry injects CLAUDE_CODE_NO_FLICKER=1 by default for all Claude
        // spawns; DISABLE_AUTO_UPDATE=true suppresses the omz update prompt
        // that would otherwise block the agent command.
        #expect(r.sensitiveEnv == ["CLAUDE_CODE_NO_FLICKER": "1", "DISABLE_AUTO_UPDATE": "true"])
    }

    @Test("resume + forkSession appends --fork-session (fork needs a new session ID)")
    func resumeWithForkSession() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: "abc-123",
            forkSession: true,
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        #expect(r.command == "claude --resume abc-123 --fork-session --dangerously-skip-permissions")
    }

    @Test("resume default (forkSession false) omits --fork-session")
    func resumeDefaultOmitsForkSession() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: "abc-123",
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        #expect(!r.command.contains("--fork-session"))
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
        // Registry injects CLAUDE_CODE_NO_FLICKER=1 by default for all Claude
        // spawns; DISABLE_AUTO_UPDATE=true suppresses the omz update prompt
        // that would otherwise block the agent command.
        #expect(r.sensitiveEnv == ["CLAUDE_CODE_NO_FLICKER": "1", "DISABLE_AUTO_UPDATE": "true"])
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

    @Test("resume + initial prompt — argv delivery is atomic with the respawn")
    func resumeWithInitialPrompt() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: "abc-123",
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: "wake: don't trust the snapshot",
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        // Exact-match including the single-quote escaping: this argv is the
        // mechanism nightwatch wake.py relies on to never paste into a live
        // session, so the shape (and shellEscape) must not silently change.
        #expect(r.command == "claude --resume abc-123 --dangerously-skip-permissions 'wake: don'\\''t trust the snapshot'")
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

    // MARK: - omz update-prompt suppression (agent tabs only)

    @Test("claude branches suppress the omz update prompt; shell branches keep it")
    func omzUpdateSuppressionScopedToAgentBranches() {
        func build(resumeID: String?, freshSessionID: String?, cmd: String?) -> ClaudeSpawnCommandBuilder.Result {
            ClaudeSpawnCommandBuilder.build(
                resumeID: resumeID, freshSessionID: freshSessionID,
                appendSystemPrompt: nil, initialPrompt: nil, profileSecret: nil,
                cmd: cmd, shellFallback: "/bin/zsh"
            )
        }
        // Agent (claude) branches: the spawned command must never block on
        // oh-my-zsh's interactive update prompt, so it rides sensitiveEnv
        // (tmux -e → process env before .zshrc). Never inlined in the command:
        // an inline export runs after rc files and would be useless.
        for r in [build(resumeID: "abc", freshSessionID: nil, cmd: nil),
                  build(resumeID: nil, freshSessionID: "sid", cmd: nil)] {
            #expect(r.sensitiveEnv["DISABLE_AUTO_UPDATE"] == "true")
            #expect(!r.command.contains("DISABLE_AUTO_UPDATE"))
        }
        // Plain shell branches: a human is present, keep omz update checks.
        #expect(build(resumeID: nil, freshSessionID: nil, cmd: "ls -la").sensitiveEnv["DISABLE_AUTO_UPDATE"] == nil)
        #expect(build(resumeID: nil, freshSessionID: nil, cmd: nil).sensitiveEnv["DISABLE_AUTO_UPDATE"] == nil)
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
        #expect(r.sensitiveEnv == [
            "ANTHROPIC_API_KEY": fakeOauth,
            "CLAUDE_CODE_NO_FLICKER": "1",
            "DISABLE_AUTO_UPDATE": "true",
        ])
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

    @Test("oauth profile with model emits ANTHROPIC_MODEL")
    func oauthProfileWithModelEmitsModel() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "abc",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            profileKind: .oauth,
            profileBaseURL: nil,
            profileModel: "opus",
            profileConfigDir: "/Users/me/tbd/profiles/abc/claude",
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        #expect(r.sensitiveEnv["ANTHROPIC_MODEL"] == "opus")
    }

    @Test("oauth profile without model does not emit ANTHROPIC_MODEL")
    func oauthProfileWithoutModelOmitsModel() {
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
        #expect(r.sensitiveEnv["ANTHROPIC_MODEL"] == nil)
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

    // MARK: - sessionName / --name (cross-session peer registry)

    // Field-measured on CLI 2.1.227: `claude --name "TBD Name Probe"` writes
    // `"name": "TBD Name Probe"` verbatim into its peer-registry row and omits
    // the `"nameSource": "derived"` marker the cwd-slug default carries. So the
    // string TBD passes here is exactly the address peers see in `ListAgents`.

    @Test("resume branch emits --name after --dangerously-skip-permissions")
    func resumeEmitsSessionName() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: "abc-123",
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh",
            sessionName: "acme-worker"
        )
        #expect(r.command == "claude --resume abc-123 --dangerously-skip-permissions --name 'acme-worker'")
    }

    @Test("fresh branch emits --name after --dangerously-skip-permissions")
    func freshEmitsSessionName() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid-1",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh",
            sessionName: "acme-worker"
        )
        #expect(r.command == "claude --session-id sid-1 --dangerously-skip-permissions --name 'acme-worker'")
    }

    @Test("nil sessionName emits no --name")
    func nilSessionNameEmitsNothing() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid-1",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh",
            sessionName: nil
        )
        #expect(r.command == "claude --session-id sid-1 --dangerously-skip-permissions")
    }

    @Test("empty sessionName emits no --name")
    func emptySessionNameEmitsNothing() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid-1",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh",
            sessionName: ""
        )
        #expect(r.command == "claude --session-id sid-1 --dangerously-skip-permissions")
    }

    @Test("whitespace-only sessionName emits no --name")
    func whitespaceSessionNameEmitsNothing() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: "abc-123",
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh",
            sessionName: "  \n\t "
        )
        #expect(r.command == "claude --resume abc-123 --dangerously-skip-permissions")
    }

    @Test("sessionName with spaces, a single quote and a $ is shell-escaped")
    func sessionNameIsShellEscaped() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid-1",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh",
            sessionName: "acme's $HOME fix"
        )
        // Single-quoting keeps `$HOME` literal; the embedded quote closes,
        // escapes, and reopens — the same shape the initial-prompt argv uses.
        #expect(r.command == "claude --session-id sid-1 --dangerously-skip-permissions --name 'acme'\\''s $HOME fix'")
    }

    // MARK: - sessionName sanitizing
    //
    // Display names are unvalidated free text and now flow into the tmux
    // command string. `shellEscape` single-quotes them, but a single-quoted
    // newline is still a newline: it would split `#{pane_start_command}`.

    @Test("an embedded newline is stripped, not escaped into the command")
    func sessionNameNewlineIsStripped() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid-1",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh",
            sessionName: "acme\nworker"
        )
        #expect(r.command == "claude --session-id sid-1 --dangerously-skip-permissions --name 'acmeworker'")
        #expect(!r.command.contains("\n"))
    }

    @Test("control characters are stripped from the name")
    func sessionNameControlCharactersAreStripped() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid-1",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh",
            sessionName: "a\u{0007}b\u{001B}c\u{007F}d\r"
        )
        #expect(r.command == "claude --session-id sid-1 --dangerously-skip-permissions --name 'abcd'")
    }

    @Test("the name is surrounded-whitespace-trimmed but keeps its inner spaces")
    func sessionNameIsTrimmed() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid-1",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh",
            sessionName: "  acme worker  "
        )
        #expect(r.command == "claude --session-id sid-1 --dangerously-skip-permissions --name 'acme worker'")
    }

    @Test("an over-long name is capped, and the cap never leaves a trailing space")
    func sessionNameIsLengthCapped() {
        let cap = ClaudeSpawnCommandBuilder.maxSessionNameLength
        // One char past the cap, with a space exactly at the boundary so a
        // naive prefix would emit `--name 'aaa… '`.
        let raw = String(repeating: "a", count: cap - 1) + " tail"
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid-1",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh",
            sessionName: raw
        )
        let expected = String(repeating: "a", count: cap - 1)
        #expect(r.command == "claude --session-id sid-1 --dangerously-skip-permissions --name '\(expected)'")
    }

    @Test("a name made only of control characters emits no flag")
    func sessionNameOfOnlyControlCharactersEmitsNothing() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid-1",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh",
            sessionName: "\u{0001}\u{0002}\n\r\t"
        )
        #expect(r.command == "claude --session-id sid-1 --dangerously-skip-permissions")
    }

    @Test("cmd branch is unchanged when sessionName is passed")
    func cmdBranchIgnoresSessionName() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: "ls -la",
            shellFallback: "/bin/zsh",
            sessionName: "acme-worker"
        )
        #expect(r.command == "ls -la")
        #expect(r.sensitiveEnv.isEmpty)
    }

    @Test("shell-fallback branch is unchanged when sessionName is passed")
    func shellFallbackBranchIgnoresSessionName() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh",
            sessionName: "acme-worker"
        )
        #expect(r.command == "/bin/zsh")
        #expect(r.sensitiveEnv.isEmpty)
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
        #expect(r.sensitiveEnv.keys.sorted() == ["ANTHROPIC_MODEL", "AWS_PROFILE", "AWS_REGION", "CLAUDE_CODE_NO_FLICKER", "CLAUDE_CODE_USE_BEDROCK", "DISABLE_AUTO_UPDATE"])
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

    // MARK: - Inline re-export of profile routing env (rc-clobber defense)

    /// REGRESSION: tmux `-e CLAUDE_CONFIG_DIR=...` is clobbered by shell rc
    /// files (`zsh -ic` sources ~/.zshenv BEFORE the -c command — a
    /// `export CLAUDE_CONFIG_DIR=...` account switcher there silently
    /// redirected every "isolated" profile session to the rc's config dir).
    /// The builder must ALSO re-export the routing env inline in the command,
    /// which runs after rc files and therefore wins.
    @Test("profile config dir is re-exported inline so rc files cannot clobber it")
    func configDirInlineExported() {
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
        #expect(r.command.hasPrefix("export CLAUDE_CONFIG_DIR='/Users/me/tbd/profiles/abc/claude';"))
        #expect(r.command.contains("claude --session-id abc"))
        // Still in -e env too (visible during rc execution).
        #expect(r.sensitiveEnv["CLAUDE_CONFIG_DIR"] == "/Users/me/tbd/profiles/abc/claude")
    }

    @Test("proxy routing env (base URL + model) is re-exported inline")
    func proxyRoutingInlineExported() {
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
        #expect(r.command.contains("export ANTHROPIC_BASE_URL='http://127.0.0.1:3456';"))
        #expect(r.command.contains("export ANTHROPIC_MODEL='gpt-5-codex';"))
        #expect(r.command.contains("export CLAUDE_CONFIG_DIR="))
    }

    @Test("secrets are NEVER inlined into the command string")
    func secretNeverInlined() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "abc",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: "sk-super-secret",
            profileKind: .apiKey,
            profileBaseURL: "http://127.0.0.1:3456",
            profileModel: nil,
            profileConfigDir: "/Users/me/tbd/profiles/abc/claude",
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        #expect(!r.command.contains("sk-super-secret"))
        #expect(!r.command.contains("ANTHROPIC_API_KEY"))
        #expect(r.sensitiveEnv["ANTHROPIC_API_KEY"] == "sk-super-secret")
    }

    @Test("bedrock routing env is re-exported inline")
    func bedrockRoutingInlineExported() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "abc",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            profileKind: .bedrock,
            profileBaseURL: nil,
            profileModel: "anthropic.claude-3-7",
            profileAwsRegion: "us-east-1",
            profileAwsProfile: "work",
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        #expect(r.command.contains("export CLAUDE_CODE_USE_BEDROCK='1';"))
        #expect(r.command.contains("export AWS_REGION='us-east-1';"))
        #expect(r.command.contains("export AWS_PROFILE='work';"))
        #expect(r.command.contains("export ANTHROPIC_MODEL='anthropic.claude-3-7';"))
    }

    @Test("no profile routing env → command has no inline exports (unchanged shape)")
    func noRoutingNoInlineExports() {
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
    }
}
