import Foundation
import os
import TBDShared

private let forgetLogger = Logger(subsystem: "com.tbd.daemon", category: "forget")

extension WorktreeLifecycle {
    // MARK: - Forget

    /// Removes a worktree from TBD's tracking **without** deleting the directory
    /// from disk. Contrast with `archiveWorktree`, which runs `git worktree
    /// remove --force` and deletes the folder. `forget` deliberately skips that
    /// git removal so the folder and its files (including uncommitted and
    /// gitignored content like `.context`) stay exactly in place.
    ///
    /// What `forget` does (mirrors the archive/reconcile cleanup, minus the disk
    /// removal and the archive hook):
    /// 1. Inserts a `forgotten_worktree` tombstone for the path (see below).
    /// 2. Kills the worktree's tmux windows.
    /// 3. Deletes its terminals + tabs and clears their pending questions and
    ///    per-session ClaudeHookOverlay files.
    /// 4. Hard-deletes the worktree row (so it's gone from BOTH the active and
    ///    archived lists — not merely flipped to `.archived`).
    ///
    /// What `forget` does NOT do:
    /// - It does not call `git.worktreeRemove` (the directory survives).
    /// - It does not run the `archive` lifecycle hook ("before_worktree_remove"),
    ///   because nothing is being removed from disk.
    ///
    /// Reconcile re-adoption is suppressed via a tombstone: `reconcile`
    /// re-adopts on-disk git worktrees whose path is under one of TBD's own
    /// prefixes (`~/tbd/worktrees/<slot>/` or `<repo>/.tbd/worktrees/`), so
    /// `forget` also inserts a `forgotten_worktree` tombstone row keyed by the
    /// worktree's absolute path. Reconcile skips tombstoned paths, making
    /// forget stick even for TBD-managed locations. The tombstone is cleared
    /// when the user deliberately re-adds the path (adopt or create), which
    /// restores normal reconcile behavior.
    public func forgetWorktree(worktreeID: UUID) async throws {
        guard let worktree = try await db.worktrees.getLocal(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }

        if worktree.status == .main {
            throw WorktreeLifecycleError.invalidOperation("Cannot forget the main branch worktree")
        }

        // Tombstone the path so reconcile won't re-adopt it. Inserted for any
        // repo-backed worktree regardless of prefix: for paths outside
        // TBD-managed prefixes it's inert (reconcile never adopts them anyway),
        // and skipping the prefix check keeps forget simple and future-proof
        // against layout changes. Scratch spaces (repoID == nil) need no
        // tombstone — reconcile only enumerates repo worktrees, so a repo-less
        // path can never be re-adopted. (Replaces the earlier warning-only
        // prefix check that pointed at this exact follow-up.)
        if let repoID = worktree.repoID {
            try await db.forgottenWorktrees.insert(path: worktree.path, repoID: repoID)
            forgetLogger.debug(
                "forget: tombstoned path \(worktree.path, privacy: .public) for worktree \(worktreeID, privacy: .public); reconcile will not re-adopt it"
            )
        }

        // Mirror the archive/reconcile cleanup: kill tmux windows, delete
        // terminals + tabs, clear pending questions, and reclaim per-session
        // ClaudeHookOverlay files. Deliberately NO git worktree remove and NO
        // archive hook.
        let terminals = try await db.terminals.list(worktreeID: worktreeID)
        for terminal in terminals {
            try? await tmux.killWindow(
                server: worktree.tmuxServer,
                windowID: terminal.tmuxWindowID
            )
        }

        try await db.terminals.deleteForWorktree(worktreeID: worktreeID)
        try await db.tabs.deleteForWorktree(worktreeID: worktreeID)
        // Hard delete: closed-terminal history (rows + captured files) goes too.
        try await db.terminalHistory.deleteForWorktree(worktreeID: worktreeID)
        for terminal in terminals {
            await pendingQuestions.clear(terminalID: terminal.id)
            ClaudeHookOverlay.removePerSessionOverlay(sessionKey: terminal.id.uuidString)
        }

        // Hard-delete the worktree row so it's absent from active AND archived
        // listings. (Child terminal/tab rows are already gone above; the
        // worktree table also has onDelete:.cascade FKs as a backstop.)
        try await db.worktrees.delete(id: worktreeID)

        forgetLogger.info("forget: removed worktree \(worktreeID, privacy: .public) from tracking; directory left in place at \(worktree.path, privacy: .public)")
    }
}
