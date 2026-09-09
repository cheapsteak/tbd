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
    func profileSessionRowIsReadableThroughTheHostMirror() async throws {
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
        let profileDir = try await manager.ensureOAuthDir(forProfileID: UUID())

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

/// The two shapes a recapture target can take, resolved through the one ladder
/// that serves both transports.
///
/// The holder arm is the new half: a holder-backed session has no pane, so its
/// recapture addresses the pid the holder recorded for the job it forked, and
/// the read has to land in the same host store the tmux arm reads. The tmux arm
/// runs beside it in this suite so a resolver that answered only for holders —
/// or ignored the target's payload entirely — cannot pass.
///
/// Both arms are asserted positively. A pane target on a dry-run manager
/// answers `0` unless a test says otherwise, and `0` names no session file and
/// no `claude` child, so a "returns nil" tmux test passes for a detector that
/// resolves nothing at all — including one that never consulted its target. The
/// pid hook is therefore injected and its answer is what the assertion is built
/// on, with the failure to read a pane pid as the separate negative case.
///
/// Explicit environment dictionaries, never `setenv`: this suite is not nested
/// under `TBDHomeSerialized`, and mutating the process-global variable would
/// hand every concurrently running suite the real `~/.claude`.
@Suite("ClaudeStateDetector recapture targets")
struct ClaudeStateDetectorTargetTests {

    /// A pane-pid query that cannot be answered — what a `list-panes` against a
    /// pane that is gone amounts to.
    private struct PaneQueryFailed: Error {}

    /// Thread-safe tally of the pane-pid queries a dry-run manager was asked
    /// for. The hook is a `@Sendable` closure called from whatever executor the
    /// detector happens to be on.
    ///
    /// It counts the query `panePID` itself makes, which is the only tmux call
    /// either arm of this resolution can produce — `dryRunRecorder` cannot see
    /// it, because `panePID` answers from this hook in dry run without
    /// recording any argv, so a recorder-based assertion here is vacuous.
    private final class PanePIDProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        func record(server: String, paneID: String) {
            lock.lock(); defer { lock.unlock() }
            recorded.append([server, paneID])
        }
        /// Every `(server, paneID)` the manager was asked about, in order.
        /// Asserted whole rather than counted, so a query that reached tmux
        /// with the wrong coordinate fails here rather than passing a tally.
        var queries: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }
    }

    /// A host store with one session file in it, written the way Claude writes
    /// one for the process at `pid`.
    private static func makeHostStore(
        pid: Int32, sessionID: String
    ) throws -> URL {
        let host = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-detector-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: host.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true)
        try #"{"pid":\#(pid),"sessionId":"\#(sessionID)"}"#.write(
            to: host.appendingPathComponent("sessions/\(pid).json"),
            atomically: true, encoding: .utf8)
        return host
    }

    @Test("a holder-child target reads the job's own session file, without tmux")
    func holderChildTargetReadsTheSessionFile() async throws {
        // A pid the holder would have recorded for the job it forked. Nothing
        // is signalled or inspected — only the file at its path is read.
        let childPID: Int32 = 424242
        let host = try Self.makeHostStore(pid: childPID, sessionID: "holder-child-session")
        defer { try? FileManager.default.removeItem(at: host) }

        let probe = PanePIDProbe()
        let detector = ClaudeStateDetector(
            tmux: TmuxManager(dryRun: true, dryRunPanePID: { server, paneID in
                probe.record(server: server, paneID: paneID)
                return "0"
            }),
            environment: ["TBD_CLAUDE_HOST_HOME": host.path])

        let captured = await detector.captureSessionID(target: .holderChild(pid: childPID))

        #expect(captured == "holder-child-session")
        #expect(
            probe.queries.isEmpty,
            "a holder recapture resolved a tmux pane pid: \(probe.queries)")
    }

    /// The other arm, on the same detector shape: a pane target resolves the
    /// pane's pid first and reads the session file of whatever that names.
    @Test("a tmux-pane target resolves through the pane's own pid")
    func tmuxPaneTargetResolvesThroughThePanePID() async throws {
        let panePID: Int32 = 515151
        let host = try Self.makeHostStore(pid: panePID, sessionID: "pane-session")
        defer { try? FileManager.default.removeItem(at: host) }

        let probe = PanePIDProbe()
        let detector = ClaudeStateDetector(
            tmux: TmuxManager(dryRun: true, dryRunPanePID: { server, paneID in
                probe.record(server: server, paneID: paneID)
                return String(panePID)
            }),
            environment: ["TBD_CLAUDE_HOST_HOME": host.path])

        let captured = await detector.captureSessionID(
            target: .tmuxPane(server: "tbd-detector", paneID: "%7"))

        #expect(captured == "pane-session")
        // The target's payload has to reach the query, or the pid above says
        // nothing about which pane was asked for.
        #expect(probe.queries == [["tbd-detector", "%7"]])
    }

    /// And the failure this arm has to answer for: a pane whose pid cannot be
    /// read at all resolves to nil rather than to a session id borrowed from
    /// somewhere else.
    @Test("a tmux-pane target whose pane pid cannot be read is nil")
    func tmuxPaneTargetWithoutAPanePIDIsNil() async throws {
        // The same store as the positive case, so a detector that answered from
        // anything other than the pane's pid would still find a file to read.
        let host = try Self.makeHostStore(pid: 515151, sessionID: "pane-session")
        defer { try? FileManager.default.removeItem(at: host) }

        let detector = ClaudeStateDetector(
            tmux: TmuxManager(dryRun: true, dryRunPanePID: { _, _ in
                throw PaneQueryFailed()
            }),
            environment: ["TBD_CLAUDE_HOST_HOME": host.path])

        let captured = await detector.captureSessionID(
            target: .tmuxPane(server: "tbd-detector", paneID: "%7"))

        #expect(captured == nil)
    }
}
