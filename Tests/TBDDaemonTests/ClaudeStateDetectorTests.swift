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

    /// Pins the coupling between the session-file read and the profile
    /// `sessions/` mirror slot, which is otherwise invisible from either side.
    ///
    /// A profile-spawned terminal runs with `CLAUDE_CONFIG_DIR` pointing at
    /// `~/tbd/profiles/<id>/claude`, so it writes its registry row there — and
    /// this detector reads the **host** store. That read missed for every
    /// profile terminal until `ClaudeProfileConfigDirManager` began mirroring
    /// the slot; now the profile's `sessions/` is a symlink to the host one and
    /// the row lands where the detector looks. Post-`--fork-session` session-ID
    /// recapture (`HibernationCoordinator`, `SessionRecaptureScheduler`)
    /// depends on that, so deleting the mirror slot must red this test rather
    /// than silently regress recapture.
    @Test("a profile session's row is readable through the mirrored host registry")
    func profileSessionRowIsReadableThroughTheHostMirror() throws {
        let fm = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-detector-mirror-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let hostBase = tempRoot.appendingPathComponent("claude", isDirectory: true)
        try fm.createDirectory(at: hostBase, withIntermediateDirectories: true)

        let manager = ClaudeProfileConfigDirManager(
            baseDirectory: tempRoot.appendingPathComponent("profiles", isDirectory: true),
            hostBaseDirectory: hostBase
        )
        let profileDir = try manager.ensureOAuthDir(forProfileID: UUID())

        // The row is written the way a profile-spawned session writes it:
        // through `$CLAUDE_CONFIG_DIR/sessions/`, not to the host path.
        try #"{"pid":31337,"sessionId":"mirrored-session"}"#.write(
            to: profileDir.appendingPathComponent("sessions").appendingPathComponent("31337.json"),
            atomically: true,
            encoding: .utf8
        )

        let detector = self.detector(environment: ["TBD_CLAUDE_HOST_HOME": hostBase.path])
        #expect(detector.sessionFilePath(forPID: 31337).path
            == hostBase.appendingPathComponent("sessions/31337.json").path)
        #expect(detector.readSessionID(forPID: 31337) == "mirrored-session")
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
