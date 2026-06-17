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
    /// 1. Kills the worktree's tmux windows.
    /// 2. Deletes its terminals + tabs and clears their pending questions and
    ///    per-session ClaudeHookOverlay files.
    /// 3. Hard-deletes the worktree row (so it's gone from BOTH the active and
    ///    archived lists — not merely flipped to `.archived`).
    ///
    /// What `forget` does NOT do:
    /// - It does not call `git.worktreeRemove` (the directory survives).
    /// - It does not run the `archive` lifecycle hook ("before_worktree_remove"),
    ///   because nothing is being removed from disk.
    ///
    /// CAVEAT — reconcile re-adoption: `reconcile` re-adopts on-disk git
    /// worktrees whose path is under one of TBD's own prefixes
    /// (`~/tbd/worktrees/<slot>/` or `<repo>/.tbd/worktrees/`). A forgotten
    /// worktree whose path is under such a prefix WILL reappear on the next
    /// reconcile (it's re-created as a fresh `.active` row). Worktrees living
    /// outside those prefixes (e.g. `~/conductor/workspaces/...`) are never
    /// re-adopted, so forget sticks for them. A tombstone/ignore-list to make
    /// forget stick for TBD-managed paths is a follow-up; this pass only logs a
    /// warning when forgetting such a worktree.
    public func forgetWorktree(worktreeID: UUID) async throws {
        guard let worktree = try await db.worktrees.get(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }

        if worktree.status == .main {
            throw WorktreeLifecycleError.invalidOperation("Cannot forget the main branch worktree")
        }

        // Warn (best-effort) when the path is under a TBD-managed prefix, since
        // reconcile would re-adopt it. Repo lookup is best-effort — a missing
        // repo row doesn't block forget (we still want the row gone).
        if let repo = try? await db.repos.get(id: worktree.repoID) {
            let acceptablePrefixes = WorktreeLayout().legacyAndCanonicalPrefixes(for: repo)
                .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
            if acceptablePrefixes.contains(where: { worktree.path.hasPrefix($0) }) {
                forgetLogger.warning(
                    "forget: worktree \(worktreeID, privacy: .public) at \(worktree.path, privacy: .public) is under a TBD-managed prefix; reconcile will re-adopt it (follow-up: tombstone/ignore-list)"
                )
            }
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
