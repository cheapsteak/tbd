import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Nested under TBDHomeSerialized: mutates the process-global `TBD_HOME` env var
// to isolate the runtime overlay dir. Nesting prevents cross-suite races with
// the other TBD_HOME-mutating suites. See TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {
@Suite("Reconcile overlay cleanup")
struct WorktreeReconcileOverlayCleanupTests {

    /// Reconcile-archival of a worktree whose git path has vanished must reclaim
    /// the per-session fallbackModel overlay for each deleted terminal — mirroring
    /// handleTerminalDelete — instead of leaking the file until the next prune.
    @Test("reconcile archival removes per-session overlay for a Claude terminal")
    func reconcileArchivalRemovesPerSessionOverlay() async throws {
        // Isolate the overlay runtime dir from the developer's ~/tbd.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-reconcile-overlay-\(UUID().uuidString)")
        setenv("TBD_HOME", home.path, 1)
        defer {
            unsetenv("TBD_HOME")
            try? FileManager.default.removeItem(at: home)
        }
        ClaudeHookOverlay.writeOverlay()

        // Real git repo with no extra worktrees, so any DB worktree row pointing
        // at a non-git path will be archived by reconcile.
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(dryRun: true),
            hooks: HookResolver()
        )
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "test", defaultBranch: "main"
        )

        // A worktree row whose path is NOT a live git worktree → reconcile archives it.
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "gone",
            branch: "gone-branch",
            path: tempDir.appendingPathComponent("vanished").path,
            tmuxServer: "tbd-test"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%0",
            label: "Claude Code",
            claudeSessionID: UUID().uuidString,
            kind: .claude
        )

        // Simulate the per-session overlay that a fallbackModel spawn would write.
        let overlayPath = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: ["claude-haiku-4-5-20251001"],
            sessionKey: terminal.id.uuidString
        )
        #expect(overlayPath != ClaudeHookOverlay.overlayPath)
        #expect(FileManager.default.fileExists(atPath: overlayPath))

        try await lifecycle.reconcile(repoID: repo.id)

        // Worktree archived AND its per-session overlay reclaimed.
        let reloaded = try await db.worktrees.get(id: wt.id)
        #expect(reloaded?.status == .archived)
        #expect(!FileManager.default.fileExists(atPath: overlayPath))
        // The shared global overlay is untouched.
        #expect(FileManager.default.fileExists(atPath: ClaudeHookOverlay.overlayPath))
    }
}
}
