import Foundation
import TBDShared

extension WorktreeLifecycle {
    // MARK: - Archive

    /// Archives a worktree, cleaning up tmux windows and removing the git worktree.
    ///
    /// - Parameters:
    ///   - worktreeID: The worktree to archive.
    ///   - force: If true, skip running the archive hook.
    public func archiveWorktree(worktreeID: UUID, force: Bool = false) async throws {
        // Get worktree from db
        guard let worktree = try await db.worktrees.get(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }

        // Refuse to archive the main branch worktree
        if worktree.status == .main {
            throw WorktreeLifecycleError.invalidOperation("Cannot archive the main branch worktree")
        }

        guard let repo = try await db.repos.get(id: worktree.repoID) else {
            throw WorktreeLifecycleError.repoNotFound(worktree.repoID)
        }

        // Run archive hook unless force
        if !force {
            let archiveHookPath = hooks.resolve(
                event: .archive,
                repoPath: repo.path,
                appHookPath: nil
            )
            if let hookPath = archiveHookPath {
                _ = try await hooks.execute(
                    hookPath: hookPath,
                    cwd: worktree.path,
                    env: [
                        "TBD_EVENT": "archive",
                        "TBD_WORKTREE_ID": worktree.id.uuidString,
                        "TBD_WORKTREE_NAME": worktree.name,
                        "TBD_WORKTREE_PATH": worktree.path,
                        "TBD_REPO_PATH": repo.path,
                        "TBD_BRANCH": worktree.branch,
                    ],
                    timeout: 60
                )
            }
        }

        // Kill all tmux windows for this worktree
        let terminals = try await db.terminals.list(worktreeID: worktreeID)
        for terminal in terminals {
            do {
                try await tmux.killWindow(
                    server: worktree.tmuxServer,
                    windowID: terminal.tmuxWindowID
                )
            } catch {
                print("[TBD] archive: failed to kill window \(terminal.tmuxWindowID): \(error)")
            }
        }

        // Delete terminals from db
        try await db.terminals.deleteForWorktree(worktreeID: worktreeID)

        // git worktree remove
        try await git.worktreeRemove(
            repoPath: repo.path,
            worktreePath: worktree.path
        )

        // Update worktree status to archived
        try await db.worktrees.archive(id: worktreeID)
    }

    // MARK: - Revive

    /// Revives an archived worktree, re-creating the git worktree and tmux windows.
    ///
    /// - Parameters:
    ///   - worktreeID: The archived worktree to revive.
    ///   - skipClaude: If true, skip launching claude in the first terminal window.
    /// - Returns: The revived worktree.
    public func reviveWorktree(worktreeID: UUID, skipClaude: Bool = false) async throws -> Worktree {
        guard let worktree = try await db.worktrees.get(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }

        guard worktree.status == .archived else {
            throw WorktreeLifecycleError.worktreeAlreadyActive(worktreeID)
        }

        guard let repo = try await db.repos.get(id: worktree.repoID) else {
            throw WorktreeLifecycleError.repoNotFound(worktree.repoID)
        }

        // Create parent directory if needed
        let parentDir = (worktree.path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parentDir,
            withIntermediateDirectories: true
        )

        // Re-add the git worktree using the existing branch
        try await git.worktreeAddExisting(
            repoPath: repo.path,
            worktreePath: worktree.path,
            branch: worktree.branch
        )

        try await setupTerminals(
            worktreeID: worktree.id, repoPath: repo.path,
            tmuxServer: worktree.tmuxServer, worktreePath: worktree.path,
            skipClaude: skipClaude
        )

        // Update status to active
        try await db.worktrees.revive(id: worktreeID)

        // Return updated worktree
        guard let revived = try await db.worktrees.get(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }
        return revived
    }
}
