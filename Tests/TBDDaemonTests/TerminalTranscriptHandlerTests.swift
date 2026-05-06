import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("terminal.transcript handler")
struct TerminalTranscriptHandlerTests {
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
            method: RPCMethod.terminalTranscript,
            params: TerminalTranscriptParams(terminalID: UUID())
        )
        let response = await router.handle(request)

        #expect(!response.success)
        #expect(response.error?.contains("Terminal not found") == true)
    }

    @Test("returns empty messages and nil sessionID when terminal has no claude session")
    func returnsEmptyWhenNoClaudeSession() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: "/tmp/test-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-test"
        )
        // Create a terminal that has no claudeSessionID (default).
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@mock-0",
            tmuxPaneID: "%mock-0"
        )

        let request = try RPCRequest(
            method: RPCMethod.terminalTranscript,
            params: TerminalTranscriptParams(terminalID: terminal.id)
        )
        let response = await router.handle(request)

        #expect(response.success)
        let result = try response.decodeResult(TerminalTranscriptResult.self)
        #expect(result.messages.isEmpty)
        #expect(result.sessionID == nil)
    }

    @Test("returns empty messages when project dir cannot be resolved")
    func returnsEmptyWhenProjectDirMissing() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        // Worktree path that won't have any matching ~/.claude/projects/<encoded>/
        // directory on disk.
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
            method: RPCMethod.terminalTranscript,
            params: TerminalTranscriptParams(terminalID: terminal.id)
        )
        let response = await router.handle(request)

        #expect(response.success)
        let result = try response.decodeResult(TerminalTranscriptResult.self)
        #expect(result.messages.isEmpty)
        // sessionID is echoed back even when no JSONL is found, so callers
        // can tell "no transcript yet" from "no session at all".
        #expect(result.sessionID == sessionID)
    }
}
