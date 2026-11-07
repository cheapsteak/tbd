import Foundation
import Testing
import TBDShared
@testable import TBDDaemonLib

@Suite("ClaudeTranscriptLocator")
struct ClaudeTranscriptLocatorTests {
    private func terminal(sessionID: String?, transcriptPath: String?) -> TBDShared.Terminal {
        TBDShared.Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            claudeSessionID: sessionID, transcriptPath: transcriptPath)
    }

    @Test func aStoredPathWins() {
        let t = terminal(sessionID: "sess-1", transcriptPath: "/acme/stored/sess-1.jsonl")
        #expect(ClaudeTranscriptLocator.filePath(terminal: t, worktreePath: "/acme/wt") == "/acme/stored/sess-1.jsonl")
    }

    @Test func aMissingSessionIDGivesNil() {
        let t = terminal(sessionID: nil, transcriptPath: nil)
        #expect(ClaudeTranscriptLocator.filePath(terminal: t, worktreePath: "/acme/wt") == nil)
    }

    @Test func theFallbackJoinsTheProjectDirAndSessionID() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let worktreePath = "/acme/locator-\(UUID().uuidString.prefix(8))"
        let folder = worktreePath.map { "/.".contains($0) ? "-" : String($0) }.joined()
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
        ClaudeProjectDirectory.clearCache()

        let t = terminal(sessionID: "sess-2", transcriptPath: "")
        let path = ClaudeTranscriptLocator.filePath(terminal: t, worktreePath: worktreePath, projectsBase: tmp)

        #expect(path?.hasSuffix("/sess-2.jsonl") == true)
        #expect(path?.contains(folder) == true)
    }
}
