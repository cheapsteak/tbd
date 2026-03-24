import Foundation
import TBDShared

extension WorktreeLifecycle {
    // MARK: - Git Status

    /// Recompute git status for all active worktrees in a repo.
    /// Runs git checks concurrently and updates the DB + broadcasts deltas.
    public func refreshGitStatuses(repoID: UUID) async {
        guard let repo = try? await db.repos.get(id: repoID) else { return }
        let worktrees = (try? await db.worktrees.list(repoID: repoID, status: .active)) ?? []

        await withTaskGroup(of: Void.self) { group in
            for wt in worktrees {
                // Skip already-merged worktrees (terminal state)
                if wt.gitStatus == .merged { continue }

                group.addTask {
                    guard let newStatus = await self.computeGitStatus(
                        repoPath: repo.path,
                        defaultBranch: repo.defaultBranch,
                        branch: wt.branch
                    ), newStatus != wt.gitStatus else { return }
                    try? await self.db.worktrees.updateGitStatus(id: wt.id, gitStatus: newStatus)
                    self.subscriptions?.broadcast(delta: .worktreeGitStatusChanged(
                        WorktreeGitStatusDelta(worktreeID: wt.id, gitStatus: newStatus)
                    ))
                }
            }
        }
    }

    /// Compute git status for a single branch relative to the default branch.
    /// Returns nil if git commands fail (leaves status unchanged).
    private func computeGitStatus(repoPath: String, defaultBranch: String, branch: String) async -> GitStatus? {
        guard let isAncestor = await git.isMergeBaseAncestor(
            repoPath: repoPath, base: defaultBranch, branch: branch
        ) else {
            return nil  // git error — leave status unchanged
        }
        if isAncestor {
            return .current
        }

        // Branches have diverged — check for conflicts
        let (hasConflicts, _) = await git.checkMergeConflicts(
            repoPath: repoPath, branch: branch, targetBranch: defaultBranch
        )
        return hasConflicts ? .conflicts : .behind
    }

    // MARK: - Reconcile

    /// Reconciles the database state with actual git worktrees on disk.
    ///
    /// - Worktrees in db but missing from git: marked as archived
    /// - Worktrees in git but missing from db: added with default names
    public func reconcile(repoID: UUID) async throws {
        guard let repo = try await db.repos.get(id: repoID) else {
            throw WorktreeLifecycleError.repoNotFound(repoID)
        }

        let gitWorktrees = try await git.worktreeList(repoPath: repo.path)
        let correctTmuxServer = TmuxManager.serverName(forRepoPath: repo.path)
        var dbWorktrees = try await db.worktrees.list(repoID: repoID, status: .active)

        // Fix stale tmux server names (e.g. after migration from UUID-based to path-based naming)
        let mainWorktrees = try await db.worktrees.list(repoID: repoID, status: .main)
        for wt in (dbWorktrees + mainWorktrees) where wt.tmuxServer != correctTmuxServer {
            try? await db.worktrees.updateTmuxServer(id: wt.id, tmuxServer: correctTmuxServer)
        }
        // Re-fetch with corrected names
        dbWorktrees = try await db.worktrees.list(repoID: repoID, status: .active)

        let gitPaths = Set(gitWorktrees.map(\.path))
        let dbPaths = Set(dbWorktrees.map(\.path))

        // Mark missing worktrees as archived — also kill their tmux windows
        for wt in dbWorktrees where !gitPaths.contains(wt.path) {
            let terminals = try await db.terminals.list(worktreeID: wt.id)
            for terminal in terminals {
                try? await tmux.killWindow(
                    server: wt.tmuxServer,
                    windowID: terminal.tmuxWindowID
                )
            }
            try await db.terminals.deleteForWorktree(worktreeID: wt.id)
            try await db.worktrees.archive(id: wt.id)
        }

        // Add unknown worktrees (skip the main repo worktree)
        let tbdWorktreePrefix = (repo.path as NSString)
            .appendingPathComponent(".tbd/worktrees/")
        for gitWt in gitWorktrees where !dbPaths.contains(gitWt.path) {
            // Only track worktrees inside .tbd/worktrees/
            guard gitWt.path.hasPrefix(tbdWorktreePrefix) else { continue }

            let name = (gitWt.path as NSString).lastPathComponent
            let tmuxServer = TmuxManager.serverName(forRepoPath: repo.path)
            _ = try await db.worktrees.create(
                repoID: repoID,
                name: name,
                branch: gitWt.branch,
                path: gitWt.path,
                tmuxServer: tmuxServer
            )
        }

        // Clean up orphaned tmux windows — windows not tracked by any active terminal
        let tmuxServer = TmuxManager.serverName(forRepoPath: repo.path)
        let activeWorktrees = try await db.worktrees.list(repoID: repoID, status: .active)
        if activeWorktrees.isEmpty {
            // No active worktrees — kill the entire tmux server
            try? await tmux.killServer(server: tmuxServer)
        } else {
            // Collect all tracked window IDs
            var trackedWindowIDs: Set<String> = []
            for wt in activeWorktrees {
                let terminals = try await db.terminals.list(worktreeID: wt.id)
                for t in terminals {
                    trackedWindowIDs.insert(t.tmuxWindowID)
                }
            }

            // List actual tmux windows and kill any that aren't tracked
            if let tmuxWindows = try? await tmux.listWindows(server: tmuxServer, session: "main") {
                for window in tmuxWindows where !trackedWindowIDs.contains(window.windowID) {
                    try? await tmux.killWindow(server: tmuxServer, windowID: window.windowID)
                }
            }
        }
    }
}
