import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("terminal.transcriptItemFullBody handler")
struct TerminalTranscriptItemFullBodyHandlerTests {
    let db: TBDDatabase
    let router: RPCRouter

    init() throws {
        let db = try TBDDatabase(inMemory: true)
        self.db = db
        self.router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date()
        )
    }

    @Test("returns error when terminal not found")
    func returnsErrorWhenTerminalNotFound() async throws {
        let request = try RPCRequest(
            method: RPCMethod.terminalTranscriptItemFullBody,
            params: TerminalTranscriptItemFullBodyParams(
                terminalID: UUID(),
                itemID: "toolu_anything"
            )
        )
        let response = await router.handle(request)

        #expect(!response.success)
        #expect(response.error?.contains("Terminal not found") == true)
    }

    @Test("returns placeholder when item not found")
    func returnsPlaceholderWhenItemNotFound() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        let wtPath = "/tmp/no-such-worktree-\(UUID().uuidString)"
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: wtPath,
            tmuxServer: "tbd-test"
        )
        let sessionID = "nonexistent-session-\(UUID().uuidString)"
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@mock-0",
            tmuxPaneID: "%mock-0",
            claudeSessionID: sessionID
        )

        // Make sure the cache is clean so resolution actually consults the
        // (empty) filesystem rather than a stale entry from another test.
        ClaudeProjectDirectory.clearCache()

        let request = try RPCRequest(
            method: RPCMethod.terminalTranscriptItemFullBody,
            params: TerminalTranscriptItemFullBodyParams(
                terminalID: terminal.id,
                itemID: "toolu_missing"
            )
        )
        let response = await router.handle(request)

        #expect(response.success)
        let result = try response.decodeResult(TerminalTranscriptItemFullBodyResult.self)
        #expect(result.text == "Output no longer available.")
    }

    @Test("returns full body for matching tool result")
    func returnsFullBodyForMatchingToolResult() async throws {
        // ClaudeProjectDirectory.resolve() always looks under
        // ~/.claude/projects/<encoded>/, so we plant the fixture there under a
        // unique encoded dir name and clean up afterward.
        let projectsBase = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")
        try FileManager.default.createDirectory(at: projectsBase, withIntermediateDirectories: true)

        // Pick a worktree path under /private/tmp so the tier-1 encoding
        // (`/` and `.` → `-`) yields a unique encoded directory name we can
        // safely create and remove.
        let unique = UUID().uuidString
        let wtPath = "/private/tmp/tbd-fullbody-\(unique)"
        let encoded = wtPath.map { "/.".contains($0) ? "-" : String($0) }.joined()
        let projectDir = projectsBase.appendingPathComponent(encoded)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectDir) }

        let sessionID = UUID().uuidString
        let bigPayload = String(repeating: "y", count: 5000)
        let line: [String: Any] = [
            "type": "user",
            "uuid": UUID().uuidString,
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": "toolu_full",
                        "content": bigPayload,
                    ]
                ],
            ],
        ]
        let lineData = try JSONSerialization.data(withJSONObject: line)
        let lineStr = String(data: lineData, encoding: .utf8)!
        let jsonlPath = projectDir.appendingPathComponent("\(sessionID).jsonl").path
        try (lineStr + "\n").write(toFile: jsonlPath, atomically: true, encoding: .utf8)

        // Drop any stale resolution from previous tests so our brand-new
        // project dir is actually consulted.
        ClaudeProjectDirectory.clearCache()

        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: wtPath,
            tmuxServer: "tbd-test"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@mock-0",
            tmuxPaneID: "%mock-0",
            claudeSessionID: sessionID
        )

        let request = try RPCRequest(
            method: RPCMethod.terminalTranscriptItemFullBody,
            params: TerminalTranscriptItemFullBodyParams(
                terminalID: terminal.id,
                itemID: "toolu_full"
            )
        )
        let response = await router.handle(request)

        #expect(response.success)
        let result = try response.decodeResult(TerminalTranscriptItemFullBodyResult.self)
        #expect(result.text.count == 5000)
        #expect(result.text == bigPayload)
    }
}
