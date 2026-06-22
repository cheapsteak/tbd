import Foundation
import os
import TBDShared

private let archiveLogger = Logger(subsystem: "com.tbd.daemon", category: "archive")

/// Result of `beginReviveWorktree`. Mirrors `WorktreeCreateCompletion`: the
/// pre-session path defers the primary terminal spawn to a detached task so
/// the revive RPC isn't blocked for the duration of the hook.
public enum WorktreeReviveCompletion: Sendable {
    /// All terminals were spawned inline; the worktree is `.active`.
    case ready(Worktree)
    /// A blocking `preSession` hook terminal was spawned and the row flipped
    /// to `.creating` (the app gates its pre-session UI on that status).
    /// `phase3` awaits the hook, spawns the primary terminals, and finishes
    /// the revive (status `.active`, `archivedAt`/session clearing).
    case preSessionPending(worktree: Worktree, phase3: Task<Void, Never>)

    /// The worktree row as of the moment the call returned (`.active` when
    /// ready, `.creating` while the pre-session hook runs).
    public var worktree: Worktree {
        switch self {
        case .ready(let worktree): return worktree
        case .preSessionPending(let worktree, _): return worktree
        }
    }
}

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
            .filter(\.isClaudeResumable)
            .compactMap(\.claudeSessionID)

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

        // Kill all tmux windows for this worktree, reaping any wedged agent
        // that survives kill-window's SIGHUP.
        for terminal in terminals {
            await killWindowAndReap(
                server: worktree.tmuxServer,
                windowID: terminal.tmuxWindowID,
                paneID: terminal.tmuxPaneID
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

        // git worktree remove
        try? await git.worktreeRemove(
            repoPath: repo.path,
            worktreePath: worktree.path
        )
    }

    /// Legacy all-in-one archive (used by CLI).
    public func archiveWorktree(worktreeID: UUID, force: Bool = false) async throws {
        let (worktree, repo) = try await beginArchiveWorktree(worktreeID: worktreeID, force: force)
        await completeArchiveWorktree(worktree: worktree, repo: repo, force: force)
    }

    // MARK: - Revive

    /// Revives an archived worktree, re-creating the git worktree and tmux windows.
    ///
    /// Legacy synchronous contract (CLI + tests): the returned worktree is
    /// fully set up and `.active`. When a `preSession` hook gates the primary
    /// terminals, this awaits the detached phase-3 task INLINE — mirroring
    /// `createWorktree`'s relationship to `completeCreateWorktree`.
    ///
    /// - Parameters:
    ///   - worktreeID: The archived worktree to revive.
    ///   - skipClaude: If true, skip launching the primary agent in the first terminal window.
    /// - Returns: The revived worktree.
    public func reviveWorktree(worktreeID: UUID, skipClaude: Bool = false, cols: Int? = nil, rows: Int? = nil, preferredSessionID: String? = nil) async throws -> Worktree {
        let completion = try await beginReviveWorktree(
            worktreeID: worktreeID, skipClaude: skipClaude,
            cols: cols, rows: rows, preferredSessionID: preferredSessionID
        )
        if case .preSessionPending(_, let phase3) = completion {
            await phase3.value
        }
        guard let revived = try await db.worktrees.get(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }
        return revived
    }

    /// Non-blocking revive. Validates, re-adds the git worktree, then:
    ///
    /// - No `preSession` hook → spawns all terminals inline, flips the row to
    ///   `.active`, and returns `.ready` (today's behavior, unchanged).
    /// - `preSession` hook resolves → spawns ONLY the hook terminal, flips the
    ///   row to `.creating` (the app gates its pre-session UI on that status),
    ///   and returns `.preSessionPending` promptly. The detached phase-3 task
    ///   awaits the hook's completion marker, spawns the primary terminals,
    ///   and finishes with `db.worktrees.revive(id:clearSessions:)` so the
    ///   archivedClaudeSessions-clearing semantics match the inline path.
    ///
    /// If the daemon restarts mid-wait, the row sits in `.creating` with a
    /// pre-session terminal record; `recoverCreatingWorktrees()` resumes the
    /// wait at next startup. The recovery sweep detects the interrupted
    /// revive (the row still carries `archivedClaudeSessions`) and resumes
    /// with revive semantics: the archived sessions are restored into
    /// terminals and the row finishes via `.revive(clearSessions: true)`.
    public func beginReviveWorktree(worktreeID: UUID, skipClaude: Bool = false, cols: Int? = nil, rows: Int? = nil, preferredSessionID: String? = nil) async throws -> WorktreeReviveCompletion {
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

        // Gated path: a preSession hook must finish before the primary
        // terminals spawn. Mirrors completeCreateWorktree's 5a branch.
        if let preSession = try await spawnPreSessionTerminal(
            worktree: worktree, repo: repo,
            worktreePath: worktree.path,
            cols: cols, rows: rows
        ) {
            subscriptions?.broadcast(delta: .terminalCreated(TerminalDelta(
                terminalID: preSession.terminalID,
                worktreeID: worktree.id,
                label: TerminalLabel.preSession
            )))
            // Flip to .creating AFTER the pre-session terminal exists so a
            // daemon crash in between leaves the row .archived (re-revivable)
            // rather than a terminal-less .creating row the recovery sweep
            // would discard.
            try await db.worktrees.updateStatus(id: worktreeID, status: .creating)
            let phase3 = Task.detached { [self] in
                await runPreSessionPhase3(
                    preSession: preSession,
                    worktree: worktree, repo: repo,
                    worktreePath: worktree.path,
                    skipClaude: skipClaude,
                    archivedClaudeSessions: sessions,
                    cols: cols, rows: rows,
                    // Only clear archivedClaudeSessions if Claude was actually
                    // restored — otherwise preserve them so a subsequent
                    // revive (without skipClaude) can use them.
                    completionAction: .revive(clearSessions: !skipClaude)
                )
            }
            guard let pending = try await db.worktrees.get(id: worktreeID) else {
                throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
            }
            return .preSessionPending(worktree: pending, phase3: phase3)
        }

        // No preSession hook → spawn all terminals inline (today's behavior).
        _ = try await spawnPrimaryTerminals(
            worktree: worktree, repo: repo,
            worktreePath: worktree.path,
            skipClaude: skipClaude,
            archivedClaudeSessions: sessions,
            cols: cols, rows: rows,
            preSessionTerminalID: nil
        )

        // Update status to active.
        // Only clear archivedClaudeSessions if Claude was actually restored —
        // otherwise preserve them so a subsequent revive (without skipClaude) can use them.
        try await db.worktrees.revive(id: worktreeID, clearSessions: !skipClaude)

        // Deliberate revive: disarm auto-archive so a still-merged PR doesn't
        // immediately re-archive the worktree the user just revived.
        try? await db.worktrees.setAutoArchiveOnMerge(id: worktreeID, value: false)

        // Return updated worktree
        guard let revived = try await db.worktrees.get(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }
        return .ready(revived)
    }
}
