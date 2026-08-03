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
    ///   - force: If true, bypass archive-safety and active-child gates. The
    ///     slow phase also skips the archive hook.
    /// Phase 1 is read-only validation. It returns the exact worktree and repo
    /// for the removal/finalization phase.
    public func beginArchiveWorktree(
        worktreeID: UUID,
        force: Bool = false,
        knownPublished: Bool = false
    ) async throws -> (Worktree, Repo) {
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

        guard let rid = worktree.repoID, let repo = try await db.repos.get(id: rid) else {
            throw WorktreeLifecycleError.repoNotFound(worktree.repoID ?? worktreeID)
        }

        // This preflight is read-only and runs before the DB status flip,
        // terminal teardown, hooks, or disk removal. A manifest entry only
        // counts when both its provenance and its current bytes verify.
        if !force {
            let report: ArchiveSafetyReport
            if let archiveSafetyEvaluator {
                report = await archiveSafetyEvaluator(worktree.path, knownPublished)
            } else {
                report = await ArchiveSafetyClassifier(git: git).classify(
                    worktreeID: worktreeID,
                    worktreePath: worktree.path,
                    knownPublished: knownPublished
                )
            }
            guard report.isEligible else {
                throw WorktreeLifecycleError.archiveUnsafe(
                    name: worktree.name, detail: report.blockingSummary
                )
            }
        }

        return (worktree, repo)
    }

    /// Runs the hook, revalidates, removes and verifies the path, then records
    /// the archive. No archived-final state is published before disk removal.
    public func completeArchiveWorktree(
        worktree: Worktree,
        repo: Repo,
        force: Bool = false,
        knownPublished: Bool = false
    ) async throws {
        // Silence the worktree's own writers first. Phase 1 already gated
        // eligibility, so reaching here means archive is going ahead; leaving
        // a live agent running through the hook, the revalidation and the
        // forced removal would let it create a file that the final check
        // never saw and `git worktree remove --force` then discards. Killing
        // the windows costs nothing here — `captureThenKillWindow` only
        // touches tmux and the history rows, never the directory — and the
        // terminal rows themselves stay until removal is verified.
        let terminals = try await db.terminals.list(worktreeID: worktree.id)
        let sessionIDs = terminals.sorted(by: { $0.createdAt < $1.createdAt })
            .filter(\.isClaudeResumable).compactMap(\.claudeSessionID)
        for terminal in terminals {
            await captureThenKillWindow(terminal: terminal, server: worktree.tmuxServer)
        }

        // Run archive hook
        if !force {
            let archiveHookPath = hooks.resolve(
                event: .archive,
                repoPath: worktree.path,
                appHookPath: worktree.repoID.map {
                    TBDConstants.hookPath(repoID: $0, eventName: HookEvent.archive.rawValue)
                }
            )
            if let hookPath = archiveHookPath {
                // A failing hook stops the archive — it may be the thing that
                // preserves work elsewhere, so proceeding past it would be
                // unsafe. It is reported as its own error rather than as a
                // safety refusal: the user's script is what broke, and the
                // blocking-summary phrasing would send them to `--force`,
                // which skips every content and publication check as well.
                do {
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
                } catch {
                    throw WorktreeLifecycleError.archiveHookFailed(
                        name: worktree.name, detail: String(describing: error)
                    )
                }
            }
        }

        // Preserve an in-worktree branch rename before the directory goes
        // away. This is metadata repair, not archived-final publication.
        let resolvedWorktreePath = URL(fileURLWithPath: worktree.path)
            .resolvingSymlinksInPath().path
        if let gitWorktrees = try? await git.worktreeList(repoPath: repo.path),
           let gitWorktree = gitWorktrees.first(where: {
               URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path
                   == resolvedWorktreePath
           }),
           !gitWorktree.branch.isEmpty,
           gitWorktree.branch != worktree.branch {
            try await db.worktrees.updateBranch(id: worktree.id, branch: gitWorktree.branch)
        }

        let capturedSHA = try? await git.headSHA(worktreePath: worktree.path)

        // This is intentionally the final worktree operation before removal.
        // Terminals are already dead and the hook and all metadata reads have
        // run, so nothing is left that can mutate or race the content this
        // check attests.
        if !force {
            let report: ArchiveSafetyReport
            if let archiveSafetyEvaluator {
                report = await archiveSafetyEvaluator(worktree.path, knownPublished)
            } else {
                report = await ArchiveSafetyClassifier(git: git).classify(
                    worktreeID: worktree.id,
                    worktreePath: worktree.path,
                    knownPublished: knownPublished
                )
            }
            guard report.isEligible else {
                throw WorktreeLifecycleError.archiveUnsafe(
                    name: worktree.name, detail: report.blockingSummary
                )
            }
        }

        if let worktreeRemover {
            try await worktreeRemover(repo.path, worktree.path)
        } else {
            try await git.worktreeRemove(repoPath: repo.path, worktreePath: worktree.path)
        }
        guard !FileManager.default.fileExists(atPath: worktree.path) else {
            throw WorktreeLifecycleError.archiveRemovalFailed("path still exists: \(worktree.path)")
        }

        try await db.worktrees.archive(
            id: worktree.id,
            claudeSessionIDs: sessionIDs,
            archivedHeadSHA: capturedSHA
        )
        try await db.terminals.deleteForWorktree(worktreeID: worktree.id)
        try await db.tabs.deleteForWorktree(worktreeID: worktree.id)
        for terminal in terminals { await pendingQuestions.clear(terminalID: terminal.id) }

        // The directory is gone from disk — fire the event-driven scratchpad
        // cleanup hook (Task 8) rather than waiting for the next hourly sweep.
        if let onWorktreeRemoved {
            await onWorktreeRemoved(worktree.path, repo.path)
        }
    }

    /// Legacy all-in-one archive (used by CLI).
    public func archiveWorktree(worktreeID: UUID, force: Bool = false) async throws {
        let (worktree, repo) = try await beginArchiveWorktree(worktreeID: worktreeID, force: force)
        try await completeArchiveWorktree(worktree: worktree, repo: repo, force: force)
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

        guard let rid = worktree.repoID, let repo = try await db.repos.get(id: rid) else {
            throw WorktreeLifecycleError.repoNotFound(worktree.repoID ?? worktreeID)
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

        // Deliberate revive: disarm auto-archive AND auto-hibernate so a
        // still-merged PR doesn't immediately re-archive or re-park the
        // worktree the user just revived.
        do {
            try await db.worktrees.setAutoArchiveOnMerge(id: worktreeID, value: false)
        } catch {
            archiveLogger.warning("failed to disarm auto-archive for \(worktreeID, privacy: .public): \(error, privacy: .public)")
        }
        do {
            try await db.worktrees.setAutoHibernateOnMerge(id: worktreeID, value: false)
        } catch {
            archiveLogger.warning("failed to disarm auto-hibernate for \(worktreeID, privacy: .public): \(error, privacy: .public)")
        }

        // Return updated worktree
        guard let revived = try await db.worktrees.get(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }
        return .ready(revived)
    }
}
