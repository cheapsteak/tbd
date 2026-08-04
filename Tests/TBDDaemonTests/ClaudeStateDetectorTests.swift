import Foundation
import Testing
@testable import TBDDaemonLib

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

/// Both branches of the host-store resolution the session-file read goes
/// through. It used to hand-build `homeDirectoryForCurrentUser/.claude/…`,
/// which is the exact shape of the leaks this fence was built for: silent on a
/// developer box, and under `scripts/test.sh` a read of the mode-000 decoy
/// rather than of the scratch store the run was pointed at.
///
/// Explicit dictionaries, never `setenv`: this suite is not nested under
/// `TBDHomeSerialized`, and mutating the process-global variable would hand
/// every concurrently running suite the real `~/.claude` (see Tests/CLAUDE.md).
@Suite("ClaudeStateDetector session-file path")
struct ClaudeStateDetectorSessionPathTests {
    private func detector(environment: [String: String]) -> ClaudeStateDetector {
        ClaudeStateDetector(tmux: TmuxManager(dryRun: true), environment: environment)
    }

    @Test("an override relocates the session file to the fenced host store")
    func overrideRelocatesSessionFile() {
        let host = "/tmp/tbd-claude-host-\(UUID().uuidString)"
        let path = detector(environment: ["TBD_CLAUDE_HOST_HOME": host])
            .sessionFilePath(forPID: 4242).path

        #expect(path == "\(host)/sessions/4242.json")
    }

    /// The branch that must not change: with no override, the resolver has to
    /// return the very path the hand-built version produced, or this fix would
    /// have moved where production looks for its session files.
    @Test("with no override the path is unchanged from the hand-built one")
    func noOverrideMatchesProductionPath() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions/99.json").path

        #expect(detector(environment: [:]).sessionFilePath(forPID: 99).path == expected)
    }

    /// An empty value is not an override — `TBDConstants.claudeHostHome`
    /// treats it as absent, and a detector that read it literally would resolve
    /// session files under `/sessions/…` at the filesystem root.
    @Test("an empty override falls back rather than resolving at the root")
    func emptyOverrideFallsBack() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions/7.json").path

        #expect(
            detector(environment: ["TBD_CLAUDE_HOST_HOME": ""])
                .sessionFilePath(forPID: 7).path == expected)
    }
}
