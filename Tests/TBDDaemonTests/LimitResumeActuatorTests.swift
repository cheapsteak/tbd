import Foundation
import os
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Records every tmux call; scriptable pane state.
final class FakeResumeTmux: ResumeSendingTmux, @unchecked Sendable {
    private let queue = DispatchQueue(label: "FakeResumeTmux")
    var windowAlive = true
    var inMode = false
    var panePIDValue = "4242"
    private var _sends: [String] = []
    var sends: [String] { queue.sync { _sends } }

    func windowExists(server: String, windowID: String) async -> Bool { windowAlive }
    func paneInMode(server: String, paneID: String) async throws -> Bool { inMode }
    func panePID(server: String, paneID: String) async throws -> String { panePIDValue }
    func sendKeys(server: String, paneID: String, text: String) async throws {
        queue.sync { _sends.append("text:\(text)") }
    }
    func sendKey(server: String, paneID: String, key: String) async throws {
        queue.sync { _sends.append("key:\(key)") }
    }
}

struct FakeInspector: PaneProcessInspecting {
    var claudePID: Int32?
    func foregroundClaudePID(panePID: Int32) -> Int32? { claudePID }
}

@Suite struct LimitResumeActuatorTests {
    let db: TBDDatabase
    let tmux = FakeResumeTmux()
    let terminalID: UUID
    let worktreeID: UUID
    let row: ScheduledResume

    init() async throws {
        db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/act-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/act-wt-\(UUID().uuidString)", tmuxServer: "tbd-act")
        worktreeID = wt.id
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1")
        terminalID = terminal.id
        try await db.terminals.updateSession(
            id: terminal.id, sessionID: "sess", transcriptPath: "/tmp/act-transcript.jsonl")
        row = ScheduledResume(
            terminalID: terminal.id, worktreeID: wt.id, claudeSessionID: "sess",
            resetsAt: Date().addingTimeInterval(-120), fireAt: Date().addingTimeInterval(-60),
            limitType: "session", rawMessage: "m", createdAt: Date().addingTimeInterval(-3600))
    }

    private func makeActuator(
        inspector: FakeInspector = FakeInspector(claudePID: 4242),
        transcript: Data? = Data("{}\n".utf8)
    ) -> LimitResumeActuator {
        LimitResumeActuator(
            db: db, tmux: tmux, inspector: inspector,
            readTranscript: { _ in transcript },
            waiter: { _ in })   // no real sleeping in unit tests
    }

    @Test func missingTerminalIsTerminalGone() async throws {
        let orphan = ScheduledResume(
            terminalID: UUID(), worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: row.resetsAt, fireAt: row.fireAt,
            limitType: "session", rawMessage: "m")
        let outcome = await makeActuator().actuate(orphan)
        #expect(outcome == .terminalGone)
        #expect(tmux.sends.isEmpty)
    }

    @Test func suspendedTerminalIsTerminalGone() async throws {
        try await db.terminals.setSuspended(id: terminalID, sessionID: "sess", snapshot: nil)
        let outcome = await makeActuator().actuate(row)
        #expect(outcome == .terminalGone)
        #expect(tmux.sends.isEmpty)
    }

    @Test func deadWindowIsTerminalGone() async throws {
        tmux.windowAlive = false
        let outcome = await makeActuator().actuate(row)
        #expect(outcome == .terminalGone)
    }

    @Test func newerTranscriptRecordCancels() async throws {
        // Record timestamped AFTER the limit was detected (createdAt is 1h ago).
        let line = #"{"type":"user","timestamp":"2099-01-01T00:00:00.000Z"}"#
        let outcome = await makeActuator(transcript: Data((line + "\n").utf8)).actuate(row)
        #expect(outcome == .userAlreadyContinued)
        #expect(tmux.sends.isEmpty)
    }

    @Test func copyModeReschedules() async throws {
        tmux.inMode = true
        let outcome = await makeActuator().actuate(row)
        #expect(outcome == .paneInCopyMode)
        #expect(tmux.sends.isEmpty)
    }

    @Test func claudeNotForegroundFails() async throws {
        let outcome = await makeActuator(inspector: FakeInspector(claudePID: nil)).actuate(row)
        if case .failed = outcome {} else { Issue.record("expected .failed, got \(outcome)") }
        #expect(tmux.sends.isEmpty)   // never type into a bare shell
    }

    @Test func happyPathSendsEscapeContinueEnterAndVerifiesViaActivity() async throws {
        // Activity hook already reports working → first verify poll succeeds.
        try await db.terminals.setActivityState(id: terminalID, activityState: .working)
        let outcome = await makeActuator().actuate(row)
        #expect(outcome == .sent)
        #expect(tmux.sends == ["key:Escape", "text:continue", "key:Enter"])
    }

    @Test func verifyTimeoutRetriesOnceThenFails() async throws {
        // Activity never becomes working and transcript never grows.
        try await db.terminals.setActivityState(id: terminalID, activityState: .idle)
        let outcome = await makeActuator().actuate(row)
        if case .failed = outcome {} else { Issue.record("expected .failed, got \(outcome)") }
        // Sequence sent twice: initial + one retry (spec §Actuation 5).
        #expect(tmux.sends == ["key:Escape", "text:continue", "key:Enter",
                               "key:Escape", "text:continue", "key:Enter"])
    }

    @Test func transcriptGrowthCountsAsVerification() async throws {
        try await db.terminals.setActivityState(id: terminalID, activityState: .idle)
        // Transcript grows between pre-send snapshot and verify polls.
        let counter = OSAllocatedUnfairLock(initialState: 0)
        let growing: @Sendable (String) -> Data? = { _ in
            let n = counter.withLock { $0 += 1; return $0 }
            return Data(repeating: 0x7b, count: n <= 1 ? 10 : 500)  // grows after first read
        }
        let actuator = LimitResumeActuator(
            db: db, tmux: tmux, inspector: FakeInspector(claudePID: 4242),
            readTranscript: growing, waiter: { _ in })
        let outcome = await actuator.actuate(row)
        #expect(outcome == .sent)
    }
}
