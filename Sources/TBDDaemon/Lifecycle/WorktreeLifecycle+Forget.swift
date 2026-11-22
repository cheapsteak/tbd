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
    /// 1. Closes each row on tmux, running no tmux command: a live row's
    ///    Closed Terminals entry is marked with the worktree's tmux server
    ///    (`closeLeftoverTmuxRow`), and a mark that cannot be written refuses
    ///    the forget before anything else is done.
    /// 2. Inserts a `forgotten_worktree` tombstone for the path (see below).
    /// 3. Ends the worktree's other sessions: each holder and its job are
    ///    reclaimed.
    /// 4. Deletes its terminals + tabs and clears their pending questions and
    ///    per-session ClaudeHookOverlay files, and its Closed Terminals
    ///    entries except the marked ones, which outlive the worktree so a
    ///    resume of their sessions still asks about the server first.
    /// 5. Hard-deletes the worktree row (so it's gone from BOTH the active and
    ///    archived lists — not merely flipped to `.archived`).
    ///
    /// What `forget` does NOT do:
    /// - It does not call `git.worktreeRemove` (the directory survives).
    /// - It does not run the `archive` lifecycle hook ("before_worktree_remove"),
    ///   because nothing is being removed from disk.
    ///
    /// A forgotten worktree is not reported as unmanaged: `reconcile` logs
    /// every on-disk git worktree under one of TBD's own prefixes
    /// (`~/tbd/worktrees/<slot>/` or `<repo>/.tbd/worktrees/`) that has no row,
    /// so `forget` also inserts a `forgotten_worktree` tombstone row keyed by
    /// the worktree's absolute path. Reconcile skips tombstoned paths without a
    /// log line, since the user has already decided about that directory. The
    /// tombstone is cleared when the user deliberately re-adds the path (adopt
    /// or create).
    public func forgetWorktree(worktreeID: UUID) async throws {
        guard let worktree = try await db.worktrees.getLocal(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }

        if worktree.status == .main {
            throw WorktreeLifecycleError.invalidOperation("Cannot forget the main branch worktree")
        }

        let terminals = try await db.terminals.list(worktreeID: worktreeID)

        // Every tmux row is closed first, before the tombstone and before any
        // holder is disposed of, as an archive closes them before its status
        // flip. Its close runs no tmux command, and a live row's Closed
        // Terminals entry is marked with the worktree's server: the hard
        // delete below keeps marked entries, so every resume of that session
        // still asks about the server first, from wherever it is resumed. A
        // mark that cannot be written refuses the forget here, with the
        // worktree and every row as they were.
        for terminal in terminals where terminal.transport == .tmux {
            try await Self.closeLeftoverTmuxRow(
                terminal, server: worktree.tmuxServer, history: db.terminalHistory,
                during: .forgettingWorktree)
        }

        // Tombstone the path so reconcile doesn't report it as unmanaged.
        // Inserted for any repo-backed worktree regardless of prefix: for paths
        // outside TBD-managed prefixes it's inert (reconcile never looks at
        // them), and skipping the prefix check keeps forget simple and
        // future-proof against layout changes. Scratch spaces (repoID == nil)
        // need no tombstone — reconcile only enumerates repo worktrees, so a
        // repo-less path is never reported.
        if let repoID = worktree.repoID {
            try await db.forgottenWorktrees.insert(path: worktree.path, repoID: repoID)
            forgetLogger.debug(
                "forget: tombstoned path \(worktree.path, privacy: .public) for worktree \(worktreeID, privacy: .public); reconcile will not report it as unmanaged"
            )
        }

        // Mirror the archive/reconcile cleanup: end each holder session,
        // delete terminals + tabs, clear pending questions, and reclaim
        // per-session ClaudeHookOverlay files. Deliberately NO git worktree
        // remove and NO archive hook.
        for terminal in terminals where terminal.transport == .holder {
            // Reclaimed, not refused: its row goes away below either way,
            // and the holder and the job it forked would outlive the only
            // record of their pids. Same branch, same reason, as
            // `handleTerminalDelete` and `closeScratchTerminals`.
            if let failure = await disposeHolder(for: terminal) {
                forgetLogger.warning(
                    "forget left a holder running: \(failure, privacy: .public)")
            }
        }

        try await db.terminals.deleteForWorktree(worktreeID: worktreeID)
        await sessionTitles.forget(worktreeID: worktreeID)
        try await db.tabs.deleteForWorktree(worktreeID: worktreeID)
        // Hard delete: closed-terminal history (rows + captured files) goes
        // too, all but the entries marked with a tmux server.
        try await db.terminalHistory.deleteForWorktree(worktreeID: worktreeID)
        for terminal in terminals {
            await pendingQuestions.clear(terminalID: terminal.id)
            await subscriptions?.broadcastPendingPrompts(
                terminalID: terminal.id, from: pendingQuestions)
            ClaudeHookOverlay.removePerSessionOverlay(sessionKey: terminal.id.uuidString)
        }

        // Hard-delete the worktree row so it's absent from active AND archived
        // listings. (Child terminal/tab rows are already gone above; the
        // worktree table also has onDelete:.cascade FKs as a backstop.)
        try await db.worktrees.delete(id: worktreeID)

        forgetLogger.info("forget: removed worktree \(worktreeID, privacy: .public) from tracking; directory left in place at \(worktree.path, privacy: .public)")
    }
}
