import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import DaemonTestSupport
import TestSupport

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
            startTime: Date(),
            actuationLog: makeTestActuationLog()
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

    /// A tab on a model profile runs Claude with that profile's config dir,
    /// so before its first SessionStart hook its JSONL is found under the
    /// profile's `projects/`, not the host store's. Without the profile root
    /// the handler looks only in the host store, finds no project directory,
    /// and returns no messages.
    @Test("a profile terminal with no stored path reads the JSONL under its profile's projects root")
    func profileTerminalReadsUnderItsProfileRoot() async throws {
        let root = URL(
            fileURLWithPath: fencedScratchRoot(prefix: "tbd-transcript-profile"), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configDirManager = ClaudeProfileConfigDirManager(
            baseDirectory: root.appendingPathComponent("profiles", isDirectory: true),
            hostBaseDirectory: root.appendingPathComponent("claude-host", isDirectory: true))
        let profileRouter = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            configDirManager: configDirManager,
            actuationLog: makeTestActuationLog()
        )
        let repo = try await db.repos.create(
            path: "/tmp/acme-repo-\(UUID().uuidString)",
            displayName: "acme",
            defaultBranch: "main"
        )
        let wtPath = "/tmp/acme-profile-wt-\(UUID().uuidString)"
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "acme-wt",
            branch: "tbd/acme-wt",
            path: wtPath,
            tmuxServer: "tbd-acme"
        )
        let profileID = UUID()
        let sessionID = "profile-session-\(UUID().uuidString)"
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@mock-0",
            tmuxPaneID: "%mock-0",
            claudeSessionID: sessionID,
            profileID: profileID
        )
        let projectDir = configDirManager.configDirectory(forProfileID: profileID)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(
                wtPath.map { "/.".contains($0) ? "-" : String($0) }.joined(), isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        // A minimal user message line so TranscriptParser produces at least one item.
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hello"}]},"uuid":"abc","timestamp":"2025-01-01T00:00:00Z"}"#
        try Data((line + "\n").utf8).write(
            to: projectDir.appendingPathComponent("\(sessionID).jsonl"))

        let response = await profileRouter.handle(try RPCRequest(
            method: RPCMethod.terminalTranscript,
            params: TerminalTranscriptParams(terminalID: terminal.id)
        ))

        #expect(response.success)
        let result = try response.decodeResult(TerminalTranscriptResult.self)
        #expect(result.sessionID == sessionID)
        #expect(!result.messages.isEmpty)
    }
}
