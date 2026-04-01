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
