import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("ClaudeSpawnCommandBuilder")
struct ClaudeSpawnCommandBuilderTests {

    private let fakeOauth = "sk-ant-oat01-fake"

    // MARK: - Fallback / non-token branches

    @Test("resume id only")
    func resumeOnly() {
        let cmd = ClaudeSpawnCommandBuilder.build(
            resumeID: "abc-123",
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            tokenSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        #expect(cmd == "claude --resume abc-123 --dangerously-skip-permissions")
    }

    @Test("fresh session id only")
    func freshOnly() {
        let cmd = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid-1",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            tokenSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        #expect(cmd == "claude --session-id sid-1 --dangerously-skip-permissions")
    }

    @Test("fresh + appendSystemPrompt")
    func freshWithAppend() {
        let cmd = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid",
            appendSystemPrompt: "hello world",
            initialPrompt: nil,
            tokenSecret: nil,
            cmd: nil,
            shellFallback: ""
        )
        #expect(cmd.contains("--append-system-prompt 'hello world'"))
    }

    @Test("fresh + initial prompt")
    func freshWithInitialPrompt() {
        let cmd = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid",
            appendSystemPrompt: nil,
            initialPrompt: "do the thing",
            tokenSecret: nil,
            cmd: nil,
            shellFallback: ""
        )
        #expect(cmd.hasSuffix(" 'do the thing'"))
    }

    @Test("cmd path returns verbatim")
    func cmdVerbatim() {
        let cmd = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            tokenSecret: nil,
            cmd: "ls -la",
            shellFallback: "/bin/zsh"
        )
        #expect(cmd == "ls -la")
    }

    @Test("all nil returns shell fallback")
    func shellFallback() {
        let cmd = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            tokenSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        #expect(cmd == "/bin/zsh")
    }

    // MARK: - Token-prefix branches

    @Test("resume + token prefixes env var")
    func resumeWithToken() {
        let cmd = ClaudeSpawnCommandBuilder.build(
            resumeID: "abc",
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            tokenSecret: fakeOauth,
            cmd: nil,
            shellFallback: ""
        )
        #expect(cmd == "CLAUDE_CODE_OAUTH_TOKEN='sk-ant-oat01-fake' claude --resume abc --dangerously-skip-permissions")
    }

    @Test("fresh + token prefixes env var")
    func freshWithToken() {
        let cmd = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            tokenSecret: fakeOauth,
            cmd: nil,
            shellFallback: ""
        )
        #expect(cmd.hasPrefix("CLAUDE_CODE_OAUTH_TOKEN='sk-ant-oat01-fake' claude --session-id sid"))
    }

    @Test("cmd path ignores token (non-claude shell)")
    func cmdIgnoresToken() {
        let cmd = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            tokenSecret: fakeOauth,
            cmd: "make test",
            shellFallback: ""
        )
        #expect(cmd == "make test")
        #expect(!cmd.contains("CLAUDE_CODE_OAUTH_TOKEN"))
    }

    @Test("shell fallback ignores token")
    func shellFallbackIgnoresToken() {
        let cmd = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            tokenSecret: fakeOauth,
            cmd: nil,
            shellFallback: "/bin/zsh"
        )
        #expect(cmd == "/bin/zsh")
    }
}
