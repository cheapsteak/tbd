import Foundation
import Testing
import TBDShared

@testable import TBDCLI

@Suite("StopRenameCheckCore")
struct StopRenameCheckCommandTests {

    /// Build a stdin JSON payload matching the common Stop hook shape.
    private static func payload(
        sessionID: String = "test-session",
        cwd: String = "/tmp/worktree",
        stopHookActive: Bool = false
    ) -> Data {
        let dict: [String: Any] = [
            "session_id": sessionID,
            "cwd": cwd,
            "hook_event_name": "Stop",
            "stop_hook_active": stopHookActive,
            "last_assistant_message": "ok"
        ]
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    /// Build a stdin JSON payload matching Codex's documented Stop hook fields.
    private static func codexPayload(
        sessionID: String = "codex-session",
        cwd: String = "/tmp/worktree"
    ) -> Data {
        let dict: [String: Any] = [
            "session_id": sessionID,
            "cwd": cwd,
            "hook_event_name": "Stop",
            "last_assistant_message": "done"
        ]
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    /// Build an injectable Dependencies value with sensible defaults. Tests
    /// override only the bits they care about.
    private static func deps(
        worktree: StopRenameCheckCore.WorktreeSummary? = .init(
            name: "20260515-surprised-giraffe",
            displayName: "20260515-surprised-giraffe",
            status: .active
        ),
        branch: String? = "tbd/20260515-surprised-giraffe",
        folder: String? = "20260515-surprised-giraffe",
        counterDirectory: URL
    ) -> StopRenameCheckCore.Dependencies {
        StopRenameCheckCore.Dependencies(
            fetchWorktree: { _ in worktree },
            fetchBranch: { _ in branch },
            fetchFolder: { _ in folder },
            counterPath: { sid in counterDirectory.appendingPathComponent("counter-\(sid)").path }
        )
    }

    /// Create a unique temp directory the test owns for its counter file.
    private static func tempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-stop-rename-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Branches

    @Test func invalidJSON_returnsNil() {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = StopRenameCheckCore.decide(
            stdinData: Data("not json".utf8),
            dependencies: Self.deps(counterDirectory: dir)
        )
        #expect(out == nil)
    }

    @Test func missingSessionID_returnsNil() {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = try! JSONSerialization.data(withJSONObject: ["cwd": "/tmp/x"])
        let out = StopRenameCheckCore.decide(
            stdinData: bad,
            dependencies: Self.deps(counterDirectory: dir)
        )
        #expect(out == nil)
    }

    @Test func daemonReturnsNoWorktree_returnsNil() {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = StopRenameCheckCore.decide(
            stdinData: Self.payload(),
            dependencies: Self.deps(worktree: nil, counterDirectory: dir)
        )
        #expect(out == nil)
    }

    @Test func mainWorktree_returnsNil() {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = StopRenameCheckCore.decide(
            stdinData: Self.payload(),
            dependencies: Self.deps(
                worktree: .init(name: "main", displayName: "main", status: .main),
                counterDirectory: dir
            )
        )
        #expect(out == nil)
    }

    @Test func displayNameDiffersFromName_returnsNil() {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = StopRenameCheckCore.decide(
            stdinData: Self.payload(),
            dependencies: Self.deps(
                worktree: .init(name: "raw-folder", displayName: "🦒 My Cool Feature", status: .active),
                counterDirectory: dir
            )
        )
        #expect(out == nil)
    }

    @Test func branchMissingTbdPrefix_returnsNil() {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = StopRenameCheckCore.decide(
            stdinData: Self.payload(),
            dependencies: Self.deps(branch: "main", counterDirectory: dir)
        )
        #expect(out == nil)
    }

    @Test func counterAtCap_returnsNil() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Pre-seed the counter at the cap so the next bump exceeds it.
        let sessionID = "session-cap"
        let counterPath = dir.appendingPathComponent("counter-\(sessionID)").path
        try "\(StopRenameCheckCore.maxFireCount)".write(toFile: counterPath, atomically: true, encoding: .utf8)
        let out = StopRenameCheckCore.decide(
            stdinData: Self.payload(sessionID: sessionID),
            dependencies: Self.deps(counterDirectory: dir)
        )
        #expect(out == nil)
    }

    @Test func happyPath_emitsBlockWithBranchAndFolder() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = StopRenameCheckCore.decide(
            stdinData: Self.payload(),
            dependencies: Self.deps(
                branch: "tbd/20260515-surprised-giraffe",
                folder: "20260515-surprised-giraffe",
                counterDirectory: dir
            )
        )
        let raw = try #require(out)
        let parsed = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        #expect(parsed?["decision"] as? String == "block")
        let reason = try #require(parsed?["reason"] as? String)
        #expect(reason.contains("tbd/20260515-surprised-giraffe"))
        #expect(reason.contains("20260515-surprised-giraffe"))
        #expect(reason.contains("git branch -m"))
        #expect(reason.contains("tbd worktree rename"))
    }

    @Test func codexStopPayload_happyPath_emitsBlockWithBranchAndFolder() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = StopRenameCheckCore.decide(
            stdinData: Self.codexPayload(),
            dependencies: Self.deps(
                branch: "tbd/20260515-surprised-giraffe",
                folder: "20260515-surprised-giraffe",
                counterDirectory: dir
            )
        )
        let raw = try #require(out)
        let parsed = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        #expect(parsed?["decision"] as? String == "block")
        let reason = try #require(parsed?["reason"] as? String)
        #expect(reason.contains("tbd/20260515-surprised-giraffe"))
        #expect(reason.contains("20260515-surprised-giraffe"))
        #expect(reason.contains("git branch -m"))
        #expect(reason.contains("tbd worktree rename"))
    }

    @Test func counterIncrementsAcrossInvocations() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = "session-increments"

        // First fire: counter becomes 1, block emitted.
        let first = StopRenameCheckCore.decide(
            stdinData: Self.payload(sessionID: sessionID),
            dependencies: Self.deps(counterDirectory: dir)
        )
        #expect(first != nil)

        // Second fire: counter becomes 2, still emits (cap is 2, not >2).
        let second = StopRenameCheckCore.decide(
            stdinData: Self.payload(sessionID: sessionID),
            dependencies: Self.deps(counterDirectory: dir)
        )
        #expect(second != nil)

        // Third fire: counter becomes 3, silent exit.
        let third = StopRenameCheckCore.decide(
            stdinData: Self.payload(sessionID: sessionID),
            dependencies: Self.deps(counterDirectory: dir)
        )
        #expect(third == nil)
    }

    @Test func bumpCounter_absentFileTreatsAsZero() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("absent").path
        let next = StopRenameCheckCore.bumpCounter(at: path)
        #expect(next == 1)
        let read = try String(contentsOfFile: path, encoding: .utf8)
        #expect(read.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }
}
