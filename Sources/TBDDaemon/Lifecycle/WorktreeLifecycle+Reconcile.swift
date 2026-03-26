import Foundation
import TBDShared

extension WorktreeLifecycle {
    // MARK: - Git Status

    /// Recompute conflict status for all active worktrees in a repo.
    /// Also detects branch name changes (e.g., `git checkout -b` inside a worktree).
    /// Runs git checks concurrently and updates the DB + broadcasts deltas.
    public func refreshGitStatuses(repoID: UUID) async {
        guard let repo = try? await db.repos.get(id: repoID) else { return }
        var worktrees = (try? await db.worktrees.list(repoID: repoID, status: .active)) ?? []

        // Sync branch names: one `git worktree list` call gives us
        // the current branch for every worktree — update DB if changed.
        if let gitWorktrees = try? await git.worktreeList(repoPath: repo.path) {
            let branchByPath = Dictionary(gitWorktrees.map { ($0.path, $0.branch) }, uniquingKeysWith: { _, b in b })
            for (i, wt) in worktrees.enumerated() {
                if let gitBranch = branchByPath[wt.path], gitBranch != wt.branch {
                    try? await db.worktrees.updateBranch(id: wt.id, branch: gitBranch)
                    worktrees[i].branch = gitBranch  // use updated branch for conflict check below
                }
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for wt in worktrees {
                group.addTask {
                    guard let newHasConflicts = await self.checkHasConflicts(
                        repoPath: repo.path,
                        defaultBranch: repo.defaultBranch,
                        branch: wt.branch
                    ), newHasConflicts != wt.hasConflicts else { return }
                    try? await self.db.worktrees.updateHasConflicts(id: wt.id, hasConflicts: newHasConflicts)
                    self.subscriptions?.broadcast(delta: .worktreeConflictsChanged(
                        WorktreeConflictDelta(worktreeID: wt.id, hasConflicts: newHasConflicts)
                    ))
                }
            }
        }
    }

    /// Check whether a branch would conflict if merged into the default branch.
    /// Returns nil if git commands fail (leaves status unchanged).
    private func checkHasConflicts(repoPath: String, defaultBranch: String, branch: String) async -> Bool? {
        guard let isAncestor = await git.isMergeBaseAncestor(
            repoPath: repoPath, base: defaultBranch, branch: branch
        ) else {
            return nil  // git error — leave status unchanged
        }
        if isAncestor { return false }

        // Branches have diverged — check for conflicts
        let (hasConflicts, _) = await git.checkMergeConflicts(
            repoPath: repoPath, branch: branch, targetBranch: defaultBranch
        )
        return hasConflicts
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
            do {
                try await db.worktrees.updateTmuxServer(id: wt.id, tmuxServer: correctTmuxServer)
            } catch {
                print("[TBD] reconcile: failed to update tmux server for worktree \(wt.id): \(error)")
            }
        }
        // Re-fetch with corrected names
        dbWorktrees = try await db.worktrees.list(repoID: repoID, status: .active)

        let gitPaths = Set(gitWorktrees.map(\.path))
        let dbPaths = Set(dbWorktrees.map(\.path))

        // Mark missing worktrees as archived — also kill their tmux windows
        for wt in dbWorktrees where !gitPaths.contains(wt.path) {
            let terminals = try await db.terminals.list(worktreeID: wt.id)
            for terminal in terminals {
                do {
                    try await tmux.killWindow(
                        server: wt.tmuxServer,
                        windowID: terminal.tmuxWindowID
                    )
                } catch {
                    print("[TBD] reconcile: failed to kill window \(terminal.tmuxWindowID): \(error)")
                }
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

        // Clean up terminal records pointing to dead tmux windows (especially main worktrees)
        let allLiveWorktrees = try await db.worktrees.list(repoID: repoID, status: .active)
            + (try await db.worktrees.list(repoID: repoID, status: .main))
        for wt in allLiveWorktrees {
            let terminals = try await db.terminals.list(worktreeID: wt.id)
            for terminal in terminals {
                let alive = await tmux.windowExists(
                    server: wt.tmuxServer, windowID: terminal.tmuxWindowID
                )
                if !alive {
                    try? await db.terminals.delete(id: terminal.id)
                }
            }
        }

        // Clean up orphaned tmux windows — windows not tracked by any active terminal
        let tmuxServer = TmuxManager.serverName(forRepoPath: repo.path)
        let activeWorktrees = try await db.worktrees.list(repoID: repoID, status: .active)
        if activeWorktrees.isEmpty {
            // No active worktrees — kill the entire tmux server
            do {
                try await tmux.killServer(server: tmuxServer)
            } catch {
                print("[TBD] reconcile: failed to kill tmux server \(tmuxServer): \(error)")
            }
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
            do {
                let tmuxWindows = try await tmux.listWindows(server: tmuxServer, session: "main")
                for window in tmuxWindows where !trackedWindowIDs.contains(window.windowID) {
                    do {
                        try await tmux.killWindow(server: tmuxServer, windowID: window.windowID)
                    } catch {
                        print("[TBD] reconcile: failed to kill orphaned window \(window.windowID): \(error)")
                    }
                }
            } catch {
                print("[TBD] reconcile: failed to list tmux windows for server \(tmuxServer): \(error)")
            }
        }
    }
}
