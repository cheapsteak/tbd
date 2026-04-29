import Testing
import Foundation
@testable import TBDDaemonLib

@Suite("TerminalSwap planning")
struct TerminalSwapPlanTests {

    @Test("blank session takes the fresh path with a new session ID")
    func blankPicksFresh() {
        let plan = RPCRouter.planTerminalSwap(
            oldSessionID: "OLD-1234",
            isBlank: true,
            freshSessionIDProvider: { "FRESH-9999" }
        )
        #expect(plan == .fresh(sessionID: "FRESH-9999"))
    }

    @Test("non-blank session takes the resume path with the old ID")
    func nonBlankPicksResume() {
        let plan = RPCRouter.planTerminalSwap(
            oldSessionID: "OLD-1234",
            isBlank: false,
            freshSessionIDProvider: { "FRESH-9999" }
        )
        #expect(plan == .resume(sessionID: "OLD-1234"))
    }

    @Test("default fresh provider returns a syntactically valid UUID")
    func defaultProviderUsesUUID() {
        let plan = RPCRouter.planTerminalSwap(oldSessionID: "ANY", isBlank: true)
        guard case let .fresh(sessionID) = plan else {
            Issue.record("expected fresh branch")
            return
        }
        #expect(UUID(uuidString: sessionID) != nil)
    }
}

@Suite("readSessionMessages worktree scoping")
struct ReadSessionMessagesScopingTests {

    @Test("returns messages from the matching worktree's project dir")
    func readsFromMatchingWorktree() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let wt = "/Users/test/scoped-match-\(UUID().uuidString.prefix(8))"
        let encoded = wt.map { "/." .contains($0) ? "-" : String($0) }.joined()
        let dir = base.appendingPathComponent(encoded)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ClaudeProjectDirectory.clearCache()

        let sessionID = "shared-id"
        let lines = """
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"hello from this worktree"}]},"sessionId":"shared-id"}
        """
        try lines.data(using: .utf8)!.write(to: dir.appendingPathComponent("\(sessionID).jsonl"))

        let messages = RPCRouter.readSessionMessages(
            sessionID: sessionID,
            worktreePath: wt,
            count: 5,
            projectsBase: base
        )
        #expect(messages.count == 1)
        #expect(messages.first?.role == "user")
    }

    @Test("returns [] when the JSONL only exists in a different worktree's dir")
    func ignoresOtherWorktreesJSONL() throws {
        // Two distinct worktrees, one shared sessionID; the file lives only in
        // worktree A's dir, but we query for worktree B.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }

        let wtA = "/Users/test/scoped-a-\(UUID().uuidString.prefix(8))"
        let wtB = "/Users/test/scoped-b-\(UUID().uuidString.prefix(8))"
        let encA = wtA.map { "/." .contains($0) ? "-" : String($0) }.joined()
        let encB = wtB.map { "/." .contains($0) ? "-" : String($0) }.joined()
        let dirA = base.appendingPathComponent(encA)
        let dirB = base.appendingPathComponent(encB)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        ClaudeProjectDirectory.clearCache()

        let sessionID = "collision-id"
        let lines = """
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"only in A"}]},"sessionId":"collision-id"}
        """
        try lines.data(using: .utf8)!.write(to: dirA.appendingPathComponent("\(sessionID).jsonl"))

        let messages = RPCRouter.readSessionMessages(
            sessionID: sessionID,
            worktreePath: wtB,
            count: 5,
            projectsBase: base
        )
        #expect(messages.isEmpty)
    }
}
