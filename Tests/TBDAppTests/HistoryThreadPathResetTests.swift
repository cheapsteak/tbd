import Foundation
import Testing
import TBDShared

@testable import TBDApp

@Suite("HistoryThreadPathReset")
@MainActor
struct HistoryThreadPathResetTests {

    private func makeAppState() -> (AppState, String) {
        let suite = "HistoryThreadPathResetTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (AppState(userDefaults: defaults), suite)
    }

    private func summary(_ sessionId: String) -> SessionSummary {
        SessionSummary(
            sessionId: sessionId,
            filePath: "/tmp/\(sessionId).jsonl",
            modifiedAt: Date(timeIntervalSince1970: 0),
            fileSize: 0,
            lineCount: 0,
            firstUserMessage: nil,
            lastUserMessage: nil,
            cwd: nil,
            gitBranch: nil
        )
    }

    @Test("selecting a session clears that worktree's thread path")
    func selectResetsPath() async {
        let (app, suite) = makeAppState()
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let worktreeID = UUID()
        let sid = "session-1"
        // Pre-seed the transcript so selectSession returns before any daemon call.
        app.sessionTranscripts[sid] = []
        app.historyThreadPath[worktreeID] = ["drilled-in"]

        await app.selectSession(summary(sid), worktreeID: worktreeID)

        #expect(app.historyThreadPath[worktreeID] == [])
        #expect(app.selectedSessionIDs[worktreeID] == sid)
    }
}
