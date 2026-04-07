import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("SuspendResumeCoordinator Tests")
struct SuspendResumeCoordinatorTests {

    /// Helper: create an in-memory DB with a repo, worktree, and suspended terminal.
    private func setupSuspendedTerminal() async throws -> (TBDDatabase, UUID, UUID) {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test-repo", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt",
            branch: "main", path: "/tmp/test-repo",
            tmuxServer: "tbd-test"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude-1", claudeSessionID: "session-abc"
        )
        try await db.terminals.setSuspended(
            id: terminal.id, sessionID: "session-abc", snapshot: "fake snapshot"
        )
        return (db, wt.id, terminal.id)
    }

    @Test func resumeRunsWhenSuspendDisabled() async throws {
        let (db, worktreeID, terminalID) = try await setupSuspendedTerminal()
        let tmux = TmuxManager(dryRun: true)
        let coordinator = SuspendResumeCoordinator(db: db, tmux: tmux)

        // Verify terminal is suspended
        let before = try await db.terminals.get(id: terminalID)
        #expect(before?.suspendedAt != nil)
        #expect(before?.suspendedSnapshot != nil)

        // Simulate arriving at the worktree with suspend disabled
        await coordinator.selectionChanged(to: [worktreeID], suspendEnabled: false)

        // Wait for the async resume to complete (3s delay + margin)
        try await Task.sleep(for: .seconds(5))

        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.suspendedAt == nil, "Resume should clear suspendedAt even when suspendEnabled is false")
        // Snapshot is intentionally kept — TerminalPanelView uses it as initial content
        #expect(after?.suspendedSnapshot != nil, "Snapshot should be preserved for initial terminal content")
    }

    @Test func resumeRunsWhenSuspendEnabled() async throws {
        let (db, worktreeID, terminalID) = try await setupSuspendedTerminal()
        let tmux = TmuxManager(dryRun: true)
        let coordinator = SuspendResumeCoordinator(db: db, tmux: tmux)

        await coordinator.selectionChanged(to: [worktreeID], suspendEnabled: true)

        try await Task.sleep(for: .seconds(5))

        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.suspendedAt == nil, "Resume should clear suspendedAt when suspendEnabled is true")
    }

    @Test func manualSuspendSkipsAlreadySuspended() async throws {
        let (db, _, terminalID) = try await setupSuspendedTerminal()
        let tmux = TmuxManager(dryRun: true)
        let coordinator = SuspendResumeCoordinator(db: db, tmux: tmux)

        let result = await coordinator.manualSuspend(terminalID: terminalID)
        #expect(result == .alreadySuspended)
    }

    @Test func manualSuspendRejectsNonClaudeTerminal() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test-repo", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt",
            branch: "main", path: "/tmp/test-repo",
            tmuxServer: "tbd-test"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "zsh"
        )
        let tmux = TmuxManager(dryRun: true)
        let coordinator = SuspendResumeCoordinator(db: db, tmux: tmux)

        let result = await coordinator.manualSuspend(terminalID: terminal.id)
        #expect(result == .notClaudeTerminal)
    }

    @Test func manualResumeSkipsNonSuspended() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test-repo", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt",
            branch: "main", path: "/tmp/test-repo",
            tmuxServer: "tbd-test"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude-1", claudeSessionID: "session-abc"
        )
        let tmux = TmuxManager(dryRun: true)
        let coordinator = SuspendResumeCoordinator(db: db, tmux: tmux)

        let result = await coordinator.manualResume(terminalID: terminal.id)
        #expect(result == .notSuspended)
    }

    @Test func resumeInjectsTokenWhenResolverProvided() async throws {
        // Build DB with a token row + suspended terminal referencing it.
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test-repo", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt",
            branch: "main", path: "/tmp/test-repo",
            tmuxServer: "tbd-test"
        )
        let token = try await db.claudeTokens.create(name: "test-token", kind: .oauth)
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude-1", claudeSessionID: "session-abc",
            claudeTokenID: token.id
        )
        try await db.terminals.setSuspended(
            id: terminal.id, sessionID: "session-abc", snapshot: nil
        )

        // Stub keychain closure returns a known secret only for this token.
        let secret = "sk-ant-oat01-FAKETOKEN_value"
        let resolver = ClaudeTokenResolver(
            tokens: db.claudeTokens,
            repos: db.repos,
            config: db.config,
            keychain: { id in id == token.id.uuidString ? secret : nil }
        )

        // Recorder to capture the createWindow shellCommand argument.
        let recorded = RecordedCommands()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { args in
            recorded.append(args)
        })
        let coordinator = SuspendResumeCoordinator(db: db, tmux: tmux, claudeTokenResolver: resolver)

        await coordinator.selectionChanged(to: [wt.id], suspendEnabled: false)
        try await Task.sleep(for: .seconds(5))

        let after = try await db.terminals.get(id: terminal.id)
        #expect(after?.suspendedAt == nil)

        // Find the createWindow invocation (it's the only dryRun call recorded here).
        let joined = recorded.snapshot().map { $0.joined(separator: " ") }
        let resumeArg = joined.first { $0.contains("claude --resume") }
        #expect(resumeArg != nil, "expected a createWindow call containing claude --resume")
        #expect(resumeArg?.contains("CLAUDE_CODE_OAUTH_TOKEN='\(secret)'") == true,
                "expected token env var injected; got: \(resumeArg ?? "nil")")
        #expect(resumeArg?.contains("claude --resume session-abc") == true)
    }

    @Test func resumeOmitsTokenWhenResolverNil() async throws {
        let (db, worktreeID, terminalID) = try await setupSuspendedTerminal()

        let recorded = RecordedCommands()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { args in
            recorded.append(args)
        })
        // No resolver supplied — fallback branch.
        let coordinator = SuspendResumeCoordinator(db: db, tmux: tmux, claudeTokenResolver: nil)

        await coordinator.selectionChanged(to: [worktreeID], suspendEnabled: false)
        try await Task.sleep(for: .seconds(5))

        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.suspendedAt == nil)

        let joined = recorded.snapshot().map { $0.joined(separator: " ") }
        let resumeArg = joined.first { $0.contains("claude --resume") }
        #expect(resumeArg != nil, "expected a createWindow call containing claude --resume")
        #expect(resumeArg?.contains("CLAUDE_CODE_OAUTH_TOKEN") == false,
                "fallback branch must not inject CLAUDE_CODE_OAUTH_TOKEN; got: \(resumeArg ?? "nil")")
        #expect(resumeArg?.contains("ANTHROPIC_API_KEY") == false)
        #expect(resumeArg?.contains("claude --resume session-abc") == true)
    }

    @Test func suspendSkippedWhenDisabled() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test-repo", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt",
            branch: "main", path: "/tmp/test-repo",
            tmuxServer: "tbd-test"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude-1", claudeSessionID: "session-abc"
        )
        let tmux = TmuxManager(dryRun: true)
        let coordinator = SuspendResumeCoordinator(db: db, tmux: tmux)

        // First: arrive at the worktree so it's in lastKnownSelection
        await coordinator.selectionChanged(to: [wt.id], suspendEnabled: false)
        // Seed the idle hook so the terminal would be eligible for suspend
        await coordinator.responseCompleted(worktreeID: wt.id)

        // Now depart with suspend disabled
        await coordinator.selectionChanged(to: [], suspendEnabled: false)

        // Wait for any async suspend to complete
        try await Task.sleep(for: .seconds(2))

        let after = try await db.terminals.get(id: terminal.id)
        #expect(after?.suspendedAt == nil, "Terminal should NOT be suspended when suspendEnabled is false")
    }
}

/// Thread-safe collector for TmuxManager dryRun recorded args.
private final class RecordedCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [[String]] = []

    func append(_ args: [String]) {
        lock.lock(); defer { lock.unlock() }
        commands.append(args)
    }

    func snapshot() -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        return commands
    }
}
