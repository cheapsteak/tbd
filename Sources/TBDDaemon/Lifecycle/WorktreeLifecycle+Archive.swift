import Foundation
import os
import TBDShared

private let archiveLogger = Logger(subsystem: "com.tbd.daemon", category: "archive")
private let cliInstallerLogger = Logger(subsystem: "com.tbd.daemon", category: "cli-installer")

/// Reorders `stored` so `preferred` is first, preserving the relative order of
/// the rest. Returns `stored` unchanged when `preferred` is nil, when `stored`
/// is nil, or when `stored` does not contain `preferred`.
internal func reorderSessions(stored: [String]?, preferred: String?) -> [String]? {
    guard let preferred, let stored, stored.contains(preferred) else { return stored }
    return [preferred] + stored.filter { $0 != preferred }
}

extension WorktreeLifecycle {
    // MARK: - Archive

    /// Archives a worktree, cleaning up tmux windows and removing the git worktree.
    ///
    /// - Parameters:
    ///   - worktreeID: The worktree to archive.
    ///   - force: If true, skip running the archive hook.
    /// Phase 1 (fast): Validates, updates DB status, kills tmux windows.
    /// Returns the worktree and repo for phase 2.
    public func beginArchiveWorktree(worktreeID: UUID, force: Bool = false) async throws -> (Worktree, Repo) {
        guard let worktree = try await db.worktrees.get(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }

        if worktree.status == .main {
            throw WorktreeLifecycleError.invalidOperation("Cannot archive the main branch worktree")
        }

        // Refuse to archive a worktree whose direct children are still active
        // or being created. `force` bypasses the check for cascade flows like
        // repo deletion. Performed before any tmux/disk work.
        if !force {
            try await db.worktrees.assertArchivable(id: worktreeID)
        }

        guard let repo = try await db.repos.get(id: worktree.repoID) else {
            throw WorktreeLifecycleError.repoNotFound(worktree.repoID)
        }

        // Collect Claude session IDs before archiving so they survive terminal deletion
        let terminals = try await db.terminals.list(worktreeID: worktreeID)
        let claudeSessionIDs = terminals
            .sorted(by: { $0.createdAt < $1.createdAt })
            .compactMap { $0.claudeSessionID }

        // Sync the branch in DB with what git reports for the worktree path,
        // so a rename done inside the worktree (e.g. `git branch -m`) is
        // captured before we lose the live worktree. Without this, revive
        // would later try to check out a stale branch that no longer exists.
        // git canonicalizes worktree paths (e.g. /var → /private/var on macOS),
        // so compare resolved-symlink forms when matching against `worktree.path`.
        let resolvedWtPath = (URL(fileURLWithPath: worktree.path).resolvingSymlinksInPath()).path
        if let gitWorktrees = try? await git.worktreeList(repoPath: repo.path),
           let gitWt = gitWorktrees.first(where: {
               let resolvedGitPath = (URL(fileURLWithPath: $0.path).resolvingSymlinksInPath()).path
               return resolvedGitPath == resolvedWtPath
           }),
           !gitWt.branch.isEmpty,
           gitWt.branch != worktree.branch {
            do {
                try await db.worktrees.updateBranch(id: worktreeID, branch: gitWt.branch)
                archiveLogger.info("archive: updated branch for \(worktreeID, privacy: .public) from '\(worktree.branch, privacy: .public)' to '\(gitWt.branch, privacy: .public)' (git worktree list)")
            } catch {
                archiveLogger.warning("archive: failed to update branch for \(worktreeID, privacy: .public): \(error, privacy: .public)")
            }
        }

        // Capture HEAD SHA from the live worktree directory while it still
        // exists on disk. Persisted as a fallback for revive when the branch
        // has been renamed or deleted.
        var capturedSHA: String? = nil
        if FileManager.default.fileExists(atPath: worktree.path) {
            do {
                capturedSHA = try await git.headSHA(worktreePath: worktree.path)
            } catch {
                archiveLogger.warning("archive: failed to capture HEAD SHA for \(worktreeID, privacy: .public) at \(worktree.path, privacy: .public): \(error, privacy: .public)")
            }
        }

        // Status flip, session save, and SHA persist all in one transaction —
        // a crash mid-archive can't leave the row half-updated.
        try await db.worktrees.archive(
            id: worktreeID,
            claudeSessionIDs: claudeSessionIDs,
            archivedHeadSHA: capturedSHA
        )

        // Kill all tmux windows for this worktree
        for terminal in terminals {
            try? await tmux.killWindow(
                server: worktree.tmuxServer,
                windowID: terminal.tmuxWindowID
            )
        }

        // Delete terminals from db
        try await db.terminals.deleteForWorktree(worktreeID: worktreeID)
        try await db.tabs.deleteForWorktree(worktreeID: worktreeID)
        for terminal in terminals {
            await pendingQuestions.clear(terminalID: terminal.id)
        }

        return (worktree, repo)
    }

    /// Phase 2 (slow, fire-and-forget): Runs archive hook and removes git worktree.
    public func completeArchiveWorktree(worktree: Worktree, repo: Repo, force: Bool = false) async {
        // Run archive hook
        if !force {
            let archiveHookPath = hooks.resolve(
                event: .archive,
                repoPath: worktree.path,
                appHookPath: TBDConstants.hookPath(repoID: worktree.repoID, eventName: HookEvent.archive.rawValue)
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

        // Capture any legacy symlink target before remove so we can detect
        // whether it pointed inside the worktree we're about to delete. Hard
        // link installs (the current default) don't need this — the inode
        // survives the worktree's `.build` removal — but legacy symlink
        // installs still need the self-heal hook.
        let installer = CLIInstaller()
        let priorTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: installer.installPath)

        // git worktree remove
        try? await git.worktreeRemove(
            repoPath: repo.path,
            worktreePath: worktree.path
        )

        // Self-heal a legacy symlink that now dangles because it pointed at
        // the just-removed worktree's TBDCLI binary. Append "/" before the
        // hasPrefix check so a worktree at /Users/me/wt doesn't claim a
        // sibling worktree's symlink at /Users/me/wt-2/...
        let worktreePathWithSlash = worktree.path.hasSuffix("/") ? worktree.path : worktree.path + "/"
        if let priorTarget, priorTarget.hasPrefix(worktreePathWithSlash) {
            await Self.repairDanglingCLISymlink(installer: installer, reason: "archive of \(worktree.path)")
        }
    }

    /// Re-point ~/.local/bin/tbd at the daemon's sibling TBDCLI when a
    /// legacy symlink install dangles. Called after worktree removal/cleanup.
    /// Best-effort: never throws back to the caller, only logs.
    static func repairDanglingCLISymlink(installer: CLIInstaller, reason: String) async {
        guard let daemonPath = RPCRouter.resolvedExecutablePath else {
            cliInstallerLogger.warning("self-heal skipped (\(reason, privacy: .public)): daemon executablePath unknown")
            return
        }
        do {
            let outcome = try await installer.repairIfDangling(daemonExecutablePath: daemonPath)
            switch outcome {
            case .notInstalled:
                cliInstallerLogger.debug("self-heal (\(reason, privacy: .public)): no install present — nothing to do")
            case .healthy(let target):
                cliInstallerLogger.debug("self-heal (\(reason, privacy: .public)): install healthy -> \(target, privacy: .public)")
            case .unexpectedFileType:
                cliInstallerLogger.warning("self-heal (\(reason, privacy: .public)): unexpected file type at install path — leaving untouched")
            case .noDaemonSibling(let path):
                cliInstallerLogger.warning("self-heal (\(reason, privacy: .public)): daemon's sibling TBDCLI missing at \(path, privacy: .public) — leaving dangling install in place")
            case .repaired(let target):
                cliInstallerLogger.info("self-heal (\(reason, privacy: .public)): re-installed CLI -> \(target, privacy: .public)")
            }
        } catch {
            cliInstallerLogger.error("self-heal (\(reason, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Legacy all-in-one archive (used by CLI).
    public func archiveWorktree(worktreeID: UUID, force: Bool = false) async throws {
        let (worktree, repo) = try await beginArchiveWorktree(worktreeID: worktreeID, force: force)
        await completeArchiveWorktree(worktree: worktree, repo: repo, force: force)
    }

    // MARK: - Revive

    /// Revives an archived worktree, re-creating the git worktree and tmux windows.
    ///
    /// - Parameters:
    ///   - worktreeID: The archived worktree to revive.
    ///   - skipClaude: If true, skip launching claude in the first terminal window.
    /// - Returns: The revived worktree.
    public func reviveWorktree(worktreeID: UUID, skipClaude: Bool = false, cols: Int? = nil, rows: Int? = nil, preferredSessionID: String? = nil) async throws -> Worktree {
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

        // Preflight: ensure nothing exists at the target path on disk.
        if FileManager.default.fileExists(atPath: worktree.path) {
            throw WorktreeLifecycleError.worktreePathAlreadyExists(worktree.path)
        }

        // Preflight: ensure git does not already have a worktree registered at this path.
        let existing = (try? await git.worktreeList(repoPath: repo.path)) ?? []
        if existing.contains(where: { $0.path == worktree.path }) {
            throw WorktreeLifecycleError.worktreeAlreadyRegistered(worktree.path)
        }

        // Re-add the git worktree. Prefer the existing branch; fall back to
        // a new branch pointing at the captured archived HEAD SHA when the
        // branch is no longer present (renamed/deleted before archive ran).
        let branchExists = await git.refExists(repoPath: repo.path, ref: worktree.branch)
        if branchExists {
            try await git.worktreeAddExisting(
                repoPath: repo.path,
                worktreePath: worktree.path,
                branch: worktree.branch
            )
        } else if let sha = worktree.archivedHeadSHA, !sha.isEmpty {
            archiveLogger.info("revive: branch '\(worktree.branch, privacy: .public)' missing for \(worktreeID, privacy: .public), recreating from archived SHA \(sha, privacy: .public)")
            try await git.worktreeAddNewBranch(
                repoPath: repo.path,
                worktreePath: worktree.path,
                branch: worktree.branch,
                sha: sha
            )
        } else {
            archiveLogger.error("revive: branch '\(worktree.branch, privacy: .public)' missing for \(worktreeID, privacy: .public) and no archivedHeadSHA — cannot recover")
            throw WorktreeLifecycleError.branchMissingNoFallback(branch: worktree.branch)
        }

        // If the caller asked to prefer a specific session, float it to the
        // front of the stored list and persist the new order so a subsequent
        // re-archive preserves last-resumed-first ordering.
        let sessions = reorderSessions(
            stored: worktree.archivedClaudeSessions,
            preferred: preferredSessionID
        )
        if let sessions, sessions != worktree.archivedClaudeSessions {
            try await db.worktrees.setArchivedClaudeSessions(id: worktreeID, sessions: sessions)
        }

        try await setupTerminals(
            worktree: worktree, repo: repo,
            skipClaude: skipClaude,
            archivedClaudeSessions: sessions,
            cols: cols,
            rows: rows
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
