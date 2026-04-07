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
            tokenSecret: nil,
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
            tokenSecret: nil,
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
            tokenSecret: nil,
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
            tokenSecret: nil,
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
            tokenSecret: nil,
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
            tokenSecret: nil,
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
            tokenSecret: fakeOauth,
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
            tokenSecret: fakeOauth,
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
            tokenSecret: fakeOauth,
            tokenKind: .apiKey,
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
            tokenSecret: fakeOauth,
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
            tokenSecret: fakeOauth,
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        #expect(r.command == "/bin/zsh")
        #expect(r.sensitiveEnv.isEmpty)
    }
}
