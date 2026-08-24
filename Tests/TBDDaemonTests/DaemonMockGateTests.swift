import Testing
import Foundation
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

private final class StartupReconcileCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [[String]] = []

    func append(_ command: [String]) {
        lock.lock()
        commands.append(command)
        lock.unlock()
    }

    func contains(_ argument: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return commands.contains { $0.contains(argument) }
    }
}

private enum StartupReconcileProbeError: Error {
    case unavailable
}

/// Tests that `Daemon.performStartupReconciliation` correctly gates the
/// DB-mutating startup work on `mockMode`. Avoids real socket/HTTP servers
/// by testing the extracted seam directly.
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

    @Test("mock OFF: scratch terminal ownership is reconciled without a registered repo")
    func mockOffReconcilesScratchTerminalOwnershipWithoutRepo() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorder = StartupReconcileCommandRecorder()
        let currentTerminalID = UUID()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: recorder.append,
            dryRunListWindows: { server, _ in
                server == "scratch-shared" ? [(windowID: "@1", paneID: "%1")] : []
            },
            dryRunPaneSendTarget: { _, _ in
                .live(terminalID: currentTerminalID.uuidString.lowercased())
            }
        )
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: tmux,
            hooks: HookResolver()
        )

        let sharedServer = "scratch-shared"
        let staleScratch = try await db.worktrees.createScratch(
            name: "scratch-old", displayName: "Scratch Old",
            path: "/tmp/tbd-scratch-old", tmuxServer: sharedServer
        )
        let currentScratch = try await db.worktrees.createScratch(
            name: "scratch-current", displayName: "Scratch Current",
            path: "/tmp/tbd-scratch-current", tmuxServer: sharedServer
        )
        let staleTerminal = try await db.terminals.create(
            worktreeID: staleScratch.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex
        )
        try await db.tabs.setLabel(
            tabID: staleTerminal.id, worktreeID: staleScratch.id, label: "Old tab")
        _ = try await db.terminals.create(
            id: currentTerminalID,
            worktreeID: currentScratch.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex
        )

        await Daemon().performStartupReconciliation(
            mockMode: nil, database: db, git: GitManager(), lifecycle: lifecycle,
            actuationLog: makeTestActuationLog())

        #expect(try await db.terminals.get(id: staleTerminal.id) == nil)
        #expect(try await db.tabs.listForWorktree(worktreeID: staleScratch.id).isEmpty)
        #expect(try await db.terminals.get(id: currentTerminalID) != nil)
        #expect(!recorder.contains("kill-window"), "a recycled pane belongs to the current terminal")
    }

    @Test("mock OFF: dead scratch terminal cleanup reaps its orphan window and tab metadata")
    func mockOffReapsDeadScratchTerminalResourcesWithoutRepo() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorder = StartupReconcileCommandRecorder()
        let sharedServer = "scratch-shared"
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: recorder.append,
            dryRunWindowIsDead: { $0 == "@2" },
            dryRunListWindows: { server, _ in
                server == sharedServer ? [(windowID: "@2", paneID: "%2")] : []
            }
        )
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: tmux,
            hooks: HookResolver()
        )
        let scratch = try await db.worktrees.createScratch(
            name: "scratch-dead", displayName: "Scratch Dead",
            path: "/tmp/tbd-scratch-dead", tmuxServer: sharedServer
        )
        let terminal = try await db.terminals.create(
            worktreeID: scratch.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: "Codex", kind: .codex
        )
        try await db.tabs.setLabel(
            tabID: terminal.id, worktreeID: scratch.id, label: "Dead tab")

        await Daemon().performStartupReconciliation(
            mockMode: nil, database: db, git: GitManager(), lifecycle: lifecycle,
            actuationLog: makeTestActuationLog())

        #expect(try await db.terminals.get(id: terminal.id) == nil)
        #expect(try await db.tabs.listForWorktree(worktreeID: scratch.id).isEmpty)
        #expect(recorder.contains("kill-window"))
        #expect(recorder.contains("@2"))
    }

    @Test("mock OFF: unstamped scratch pane remains live for compatibility")
    func mockOffKeepsScratchTerminalWithNoPaneIdentity() async throws {
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(
                dryRun: true,
                dryRunPaneSendTarget: { _, _ in .live(terminalID: nil) }
            ),
            hooks: HookResolver()
        )
        let scratch = try await db.worktrees.createScratch(
            name: "scratch-legacy", displayName: "Scratch Legacy",
            path: "/tmp/tbd-scratch-legacy", tmuxServer: "scratch-shared"
        )
        let terminal = try await db.terminals.create(
            worktreeID: scratch.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex
        )

        await Daemon().performStartupReconciliation(
            mockMode: nil, database: db, git: GitManager(), lifecycle: lifecycle,
            actuationLog: makeTestActuationLog())

        #expect(try await db.terminals.get(id: terminal.id) != nil)
    }

    @Test("mock OFF: unreadable scratch pane identity retains terminal")
    func mockOffKeepsScratchTerminalWhenPaneProbeFails() async throws {
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(
                dryRun: true,
                dryRunPaneSendTarget: { _, _ in throw StartupReconcileProbeError.unavailable }
            ),
            hooks: HookResolver()
        )
        let scratch = try await db.worktrees.createScratch(
            name: "scratch-unreadable", displayName: "Scratch Unreadable",
            path: "/tmp/tbd-scratch-unreadable", tmuxServer: "scratch-shared"
        )
        let terminal = try await db.terminals.create(
            worktreeID: scratch.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex
        )

        await Daemon().performStartupReconciliation(
            mockMode: nil, database: db, git: GitManager(), lifecycle: lifecycle,
            actuationLog: makeTestActuationLog())

        #expect(try await db.terminals.get(id: terminal.id) != nil)
    }

    @Test("mock OFF: dead scratch pane is stale even if its old command was Claude")
    func mockOffParksScratchClaudeWhenPaneIsDead() async throws {
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(
                dryRun: true,
                dryRunPaneCurrentCommand: { _, _ in "1.2.3" },
                dryRunPaneSendTarget: { _, _ in .dead }
            ),
            hooks: HookResolver()
        )
        let scratch = try await db.worktrees.createScratch(
            name: "scratch-dead", displayName: "Scratch Dead",
            path: "/tmp/tbd-scratch-dead", tmuxServer: "scratch-shared"
        )
        let terminal = try await db.terminals.create(
            worktreeID: scratch.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Claude", claudeSessionID: "session-dead", kind: .claude
        )

        await Daemon().performStartupReconciliation(
            mockMode: nil, database: db, git: GitManager(), lifecycle: lifecycle,
            actuationLog: makeTestActuationLog())

        let after = try await db.terminals.get(id: terminal.id)
        #expect(after?.hibernatedAt != nil)
        #expect(after?.claudeSessionID == "session-dead")
    }

    @Test("mock OFF: foreign pane identity is not inspected as stale Claude")
    func mockOffDoesNotInspectForeignPaneCommand() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminalID = UUID()
        let foreignTerminalID = UUID()
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(
                dryRun: true,
                // ClaudeStateDetector recognizes this version-shaped command.
                // If reconciliation inspects the foreign pane, it will retain
                // the stale row instead of parking it and this test will fail.
                dryRunPaneCurrentCommand: { _, _ in "1.2.3" },
                dryRunPaneSendTarget: { _, _ in
                    .live(terminalID: foreignTerminalID.uuidString)
                }
            ),
            hooks: HookResolver()
        )
        let scratch = try await db.worktrees.createScratch(
            name: "scratch-foreign", displayName: "Scratch Foreign",
            path: "/tmp/tbd-scratch-foreign", tmuxServer: "scratch-shared"
        )
        let terminal = try await db.terminals.create(
            id: terminalID,
            worktreeID: scratch.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Claude", claudeSessionID: "session-foreign", kind: .claude
        )

        await Daemon().performStartupReconciliation(
            mockMode: nil, database: db, git: GitManager(), lifecycle: lifecycle,
            actuationLog: makeTestActuationLog())

        #expect(try await db.terminals.get(id: terminal.id)?.hibernatedAt != nil)
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
