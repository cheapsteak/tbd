import Testing
@testable import TBDDaemonLib

@Test func idleWithBarePromptAndStatusBar() {
    let lines = "some output above\n\n─────────\n❯\u{00a0}\n─────────\n  ⏵⏵ bypass permissions on (shift+tab to cycle)"
    #expect(ClaudeStateDetector.checkIdle(output: lines) == true)
}

@Test func notIdleWithUserInput() {
    let lines = "─────────\n❯ fix the bug\n─────────\n  ⏵⏵ bypass permissions on (shift+tab to cycle)"
    #expect(ClaudeStateDetector.checkIdle(output: lines) == false)
}

@Test func notIdleNoPrompt() {
    let lines = "⏺ Working on something...\n  Reading file.swift\n─────────\n  ⏵⏵ bypass permissions on (shift+tab to cycle)"
    #expect(ClaudeStateDetector.checkIdle(output: lines) == false)
}

@Test func notIdleNoStatusBar() {
    let lines = "─────────\n❯\u{00a0}\n─────────\nEnter to select · ↑/↓ to navigate · Esc to cancel"
    #expect(ClaudeStateDetector.checkIdle(output: lines) == false)
}

@Test func idleWithQuestionForShortcuts() {
    let lines = "─────────\n❯\n─────────\n  ? for shortcuts"
    #expect(ClaudeStateDetector.checkIdle(output: lines) == true)
}

@Test func idleWithAutoMode() {
    let lines = "─────────\n❯\n─────────\n  ⏵⏵ auto mode (shift+tab to cycle)"
    #expect(ClaudeStateDetector.checkIdle(output: lines) == true)
}

@Test func notIdleWhenThinking() {
    // Claude shows bare prompt during thinking phase, but status bar has "esc to interrupt"
    let lines = "✻ Thinking… (3s · ↑ 200 tokens · thinking)\n─────────\n❯\u{00a0}\n─────────\n  1 shell · ⏵⏵ bypass permissions on · esc to interrupt · ↓ to manage"
    #expect(ClaudeStateDetector.checkIdle(output: lines) == false)
}

@Test func notIdleWhenGenerating() {
    // Claude is streaming output, status bar has "esc to interrupt"
    let lines = "⏺ Writing file...\n─────────\n❯\u{00a0}\n─────────\n  ⏵⏵ auto mode · esc to interrupt"
    #expect(ClaudeStateDetector.checkIdle(output: lines) == false)
}

@Test func claudeProcessPatternMatchesSemver() {
    #expect(ClaudeStateDetector.isClaudeProcess("2.1.86") == true)
    #expect(ClaudeStateDetector.isClaudeProcess("2.1.85") == true)
    #expect(ClaudeStateDetector.isClaudeProcess("10.0.1") == true)
    #expect(ClaudeStateDetector.isClaudeProcess("zsh") == false)
    #expect(ClaudeStateDetector.isClaudeProcess("bash") == false)
    #expect(ClaudeStateDetector.isClaudeProcess("node") == false)
    #expect(ClaudeStateDetector.isClaudeProcess("git") == false)
    #expect(ClaudeStateDetector.isClaudeProcess("") == false)
}

@Test func parseSessionFile() {
    let json = """
    {"pid": 12345, "sessionId": "abc-def-123", "cwd": "/tmp", "startedAt": 1000, "kind": "interactive", "entrypoint": "cli"}
    """
    #expect(ClaudeStateDetector.parseSessionID(from: json) == "abc-def-123")
}

@Test func parseSessionFileBadJSON() {
    #expect(ClaudeStateDetector.parseSessionID(from: "not json") == nil)
}

@Test func parseSessionFilePartialJSON() {
    #expect(ClaudeStateDetector.parseSessionID(from: "{\"pid\": 123") == nil)
}
