import Foundation
import TBDShared

extension WorktreeLifecycle {
    // MARK: - Archive

    /// Archives a worktree, cleaning up tmux windows and removing the git worktree.
    ///
    /// - Parameters:
    ///   - worktreeID: The worktree to archive.
    ///   - force: If true, skip running the archive hook.
    /// Phase 1 (fast): Validates, updates DB status, kills tmux windows.
    /// Returns the worktree and repo for phase 2.
    public func beginArchiveWorktree(worktreeID: UUID) async throws -> (Worktree, Repo) {
        guard let worktree = try await db.worktrees.get(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }

        if worktree.status == .main {
            throw WorktreeLifecycleError.invalidOperation("Cannot archive the main branch worktree")
        }

        guard let repo = try await db.repos.get(id: worktree.repoID) else {
            throw WorktreeLifecycleError.repoNotFound(worktree.repoID)
        }

        // Collect Claude session IDs before archiving so they survive terminal deletion
        let terminals = try await db.terminals.list(worktreeID: worktreeID)
        let claudeSessionIDs = terminals
            .sorted(by: { $0.createdAt < $1.createdAt })
            .compactMap { $0.claudeSessionID }

        // Update DB status and save sessions in one transaction
        try await db.worktrees.archive(id: worktreeID, claudeSessionIDs: claudeSessionIDs)

        // Kill all tmux windows for this worktree
        for terminal in terminals {
            try? await tmux.killWindow(
                server: worktree.tmuxServer,
                windowID: terminal.tmuxWindowID
            )
        }

        // Delete terminals from db
        try await db.terminals.deleteForWorktree(worktreeID: worktreeID)

        return (worktree, repo)
    }

    /// Phase 2 (slow, fire-and-forget): Runs archive hook and removes git worktree.
    public func completeArchiveWorktree(worktree: Worktree, repo: Repo, force: Bool = false) async {
        // Run archive hook
        if !force {
            let archiveHookPath = hooks.resolve(
                event: .archive,
                repoPath: worktree.path,
                appHookPath: nil
            )
            if let hookPath = archiveHookPath {
                _ = try? await hooks.execute(
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

        // git worktree remove
        try? await git.worktreeRemove(
            repoPath: repo.path,
            worktreePath: worktree.path
        )
    }

    /// Legacy all-in-one archive (used by CLI).
    public func archiveWorktree(worktreeID: UUID, force: Bool = false) async throws {
        let (worktree, repo) = try await beginArchiveWorktree(worktreeID: worktreeID)
        await completeArchiveWorktree(worktree: worktree, repo: repo, force: force)
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
            worktreeID: worktree.id, repo: repo,
            tmuxServer: worktree.tmuxServer, worktreePath: worktree.path,
            skipClaude: skipClaude,
            archivedClaudeSessions: worktree.archivedClaudeSessions
        )

        // Update status to active.
        // Only clear archivedClaudeSessions if Claude was actually restored —
        // otherwise preserve them so a subsequent revive (without skipClaude) can use them.
        try await db.worktrees.revive(id: worktreeID, clearSessions: !skipClaude)

        // Return updated worktree
        guard let revived = try await db.worktrees.get(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }
        return revived
    }
}
