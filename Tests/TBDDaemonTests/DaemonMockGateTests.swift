import Testing
import Foundation
import DaemonTestSupport
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// Tests that `Daemon.performStartupReconciliation` correctly gates the
/// DB-mutating startup work on `mockMode`. Avoids a real socket server by
/// testing the extracted seam directly.
@Suite("DaemonMockGateTests")
struct DaemonMockGateTests {

    // MARK: - Mock OFF: reconciliation runs

    @Test("mock OFF: stale-path repo flipped to .missing by RepoHealthValidator")
    func mockOffRunsReconciliation() async throws {
        let db = try TBDDatabase(inMemory: true)
        let git = GitManager()
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: git,
            tmux: TmuxManager(dryRun: true),
            hooks: HookResolver()
        )

        // Seed a repo whose path definitely does not exist.
        let stalePath = "/tmp/tbd-mock-gate-nonexistent-\(UUID().uuidString)"
        _ = try await db.repos.create(
            path: stalePath,
            displayName: "ghost-repo",
            defaultBranch: "main"
        )

        // Confirm initial status is .ok (default)
        let before = try await db.repos.list()
        #expect(before.first?.status == .ok)

        // Run with mockMode == nil (live mode) — RepoHealthValidator should flip it
        await Daemon().performStartupReconciliation(
            mockMode: nil, database: db, git: git, lifecycle: lifecycle,
            actuationLog: makeTestActuationLog())

        let after = try await db.repos.list()
        #expect(after.first?.status == .missing)
    }

    /// A lifecycle whose leftover-tmux probe answers `state` for every server,
    /// so no socket is asked.
    private func makeLifecycle(
        db: TBDDatabase, state: LeftoverTmuxServerState,
        pendingQuestions: PendingPromptStore = PendingPromptStore()
    ) -> WorktreeLifecycle {
        var lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(dryRun: true),
            hooks: HookResolver(),
            pendingQuestions: pendingQuestions)
        lifecycle.leftoverTmuxProbe = LeftoverTmuxServerProbe { _ in state }
        return lifecycle
    }

    /// Scratch spaces have no repo row, so startup reaches their terminals on
    /// its own, with no registered repo at all. Once their tmux server is gone
    /// a resumable session is parked with its identity kept and its pending
    /// question cleared, and a tab with nothing to resume goes with its tab
    /// metadata.
    @Test("mock OFF: scratch terminals whose tmux server is gone are reclaimed without a registered repo")
    func mockOffReclaimsScratchTerminalsWithoutRepo() async throws {
        let db = try TBDDatabase(inMemory: true)
        let pendingQuestions = PendingPromptStore()
        let lifecycle = makeLifecycle(db: db, state: .absent, pendingQuestions: pendingQuestions)
        let scratch = try await db.worktrees.createScratch(
            name: "scratch-gone", displayName: "Scratch Gone",
            path: "/tmp/tbd-scratch-gone", tmuxServer: "scratch-shared")
        let codex = try await db.terminals.create(
            worktreeID: scratch.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        try await db.tabs.setLabel(tabID: codex.id, worktreeID: scratch.id, label: "Old tab")
        let claude = try await db.terminals.create(
            worktreeID: scratch.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: "Claude", claudeSessionID: "session-gone", kind: .claude)
        await pendingQuestions.set(
            terminalID: claude.id,
            PendingAskUserQuestion(
                toolUseID: "toolu_gone", inputJSON: "{}",
                timestamp: Date(timeIntervalSince1970: 1)))
        #expect(try await db.repos.list().isEmpty)

        await Daemon().performStartupReconciliation(
            mockMode: nil, database: db, git: GitManager(), lifecycle: lifecycle,
            actuationLog: makeTestActuationLog())

        #expect(try await db.terminals.get(id: codex.id) == nil)
        #expect(try await db.tabs.listForWorktree(worktreeID: scratch.id)
            .contains { $0.id == codex.id } == false)
        let parked = try #require(try await db.terminals.get(id: claude.id))
        #expect(parked.hibernatedAt != nil)
        #expect(parked.hibernateReason == .recovery)
        #expect(parked.claudeSessionID == "session-gone")
        #expect(await pendingQuestions.entries(forTerminal: claude.id).isEmpty,
                "a parked session kept a question nothing can answer")
    }

    /// While a scratch tab's tmux server may still be running, startup keeps
    /// the row exactly as it was, pending question and all: the session may
    /// still be running where TBD cannot reach it.
    @Test("mock OFF: scratch terminals whose tmux server may still run are kept")
    func mockOffKeepsScratchTerminalsWhileTheirServerMayRun() async throws {
        let db = try TBDDatabase(inMemory: true)
        let pendingQuestions = PendingPromptStore()
        let lifecycle = makeLifecycle(db: db, state: .running, pendingQuestions: pendingQuestions)
        let scratch = try await db.worktrees.createScratch(
            name: "scratch-running", displayName: "Scratch Running",
            path: "/tmp/tbd-scratch-running", tmuxServer: "scratch-shared")
        let codex = try await db.terminals.create(
            worktreeID: scratch.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        let claude = try await db.terminals.create(
            worktreeID: scratch.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: "Claude", claudeSessionID: "session-running", kind: .claude)
        await pendingQuestions.set(
            terminalID: claude.id,
            PendingAskUserQuestion(
                toolUseID: "toolu_running", inputJSON: "{}",
                timestamp: Date(timeIntervalSince1970: 1)))
        let codexBefore = try #require(try await db.terminals.get(id: codex.id))
        let claudeBefore = try #require(try await db.terminals.get(id: claude.id))

        await Daemon().performStartupReconciliation(
            mockMode: nil, database: db, git: GitManager(), lifecycle: lifecycle,
            actuationLog: makeTestActuationLog())

        #expect(try await db.terminals.get(id: codex.id) == codexBefore)
        #expect(try await db.terminals.get(id: claude.id) == claudeBefore)
        #expect(await pendingQuestions.entries(forTerminal: claude.id).map(\.toolUseID)
                == ["toolu_running"])
    }

    @Test("mock OFF: startup preserves pending Codex recovery for post-bind handoff")
    func mockOffPreservesPendingCodexRecoveryBeforeOrdinaryDisposal() async throws {
        let db = try TBDDatabase(inMemory: true)
        // The server is gone, so only the pending-recovery guard keeps the row.
        let lifecycle = makeLifecycle(db: db, state: .absent)
        let scratch = try await db.worktrees.createScratch(
            name: "scratch-pending-recovery",
            displayName: "Scratch Pending Recovery",
            path: "/tmp/tbd-scratch-pending-recovery",
            tmuxServer: "scratch-shared")
        let terminal = try await db.terminals.create(
            worktreeID: scratch.id,
            tmuxWindowID: "@gone",
            tmuxPaneID: "%gone",
            label: TerminalLabel.codex,
            claudeSessionID: "source-thread",
            kind: .codex)
        let pendingToken = UUID()
        _ = try #require(try await db.terminals.beginContinueInClaude(
            id: terminal.id,
            expectedState: TerminalContinueInClaudeSnapshot(terminal: terminal),
            pendingIncarnationID: pendingToken))

        await Daemon().performStartupReconciliation(
            mockMode: nil,
            database: db,
            git: GitManager(),
            lifecycle: lifecycle,
            actuationLog: makeTestActuationLog())

        let preserved = try #require(try await db.terminals.get(id: terminal.id))
        #expect(preserved.kind == .codex)
        #expect(preserved.pendingSessionIncarnationID == pendingToken)
        #expect(!preserved.isParked)
    }

    // MARK: - Mock ON: reconciliation skipped

    @Test("mock ON: stale-path repo stays .ok (reconciliation skipped)")
    func mockOnSkipsReconciliation() async throws {
        let db = try TBDDatabase(inMemory: true)
        let git = GitManager()
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: git,
            tmux: TmuxManager(dryRun: true),
            hooks: HookResolver()
        )

        let stalePath = "/tmp/tbd-mock-gate-nonexistent-\(UUID().uuidString)"
        let repo = try await db.repos.create(
            path: stalePath,
            displayName: "ghost-repo",
            defaultBranch: "main"
        )
        _ = try await db.worktrees.create(
            repoID: repo.id,
            name: "main",
            displayName: "Main",
            branch: "main",
            path: stalePath + "/.tbd/worktrees/main",
            tmuxServer: "mock-server",
            status: .main
        )

        // Run with mockMode == .enabled — reconciliation should be skipped
        await Daemon().performStartupReconciliation(
            mockMode: .enabled(fixturePath: "/tmp/x.json"),
            database: db, git: git, lifecycle: lifecycle,
            actuationLog: makeTestActuationLog())

        // Repo should still be .ok (RepoHealthValidator never ran)
        let repos = try await db.repos.list()
        #expect(repos.first?.status == .ok)

        // Worktree should still exist (reconcile loop never ran)
        let worktrees = try await db.worktrees.list(repoID: repo.id)
        #expect(worktrees.count == 1)
    }
}
