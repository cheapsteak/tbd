import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "worktreeLifecycle")
private let archiveLogger = Logger(subsystem: "com.tbd.daemon", category: "archive")

extension WorktreeLifecycle {

    // MARK: - Startup recovery for `.creating` rows

    /// Resolves worktree rows stranded in `.creating` by a daemon restart.
    ///
    /// The pre-session phase-3 wait lives in an in-memory detached task; when
    /// the daemon dies mid-wait the row stays `.creating` forever — reconcile
    /// only lists `.active` rows, archive rejects `.creating`, and revive
    /// requires `.archived`, so nothing else can ever resolve it. Call this at
    /// startup BEFORE the per-repo reconcile loop.
    ///
    /// Per `.creating` row:
    /// - Remote row → mark it `.failed`; see the guard below.
    /// - Checkout missing on disk → creation never completed; delete the row
    ///   (and its terminal/tab records).
    /// - Checkout exists and primary (non-pre-session) terminals exist → the
    ///   daemon died between the primary spawn and the final status flip;
    ///   just flip to `.active`.
    /// - Checkout exists and ONLY a pre-session terminal exists → the daemon
    ///   died mid-wait. The tmux server and the hook process survive daemon
    ///   restarts, so resume the wait: rebuild the `PreSessionSpawn` from the
    ///   terminal record and run phase 3 in a detached task. A row that still
    ///   carries `archivedClaudeSessions` was mid-REVIVE — resume it with
    ///   revive semantics (restore the sessions, then clear them); otherwise
    ///   resume exactly like the create path. Never blocks startup.
    /// - Checkout exists but no terminals at all → the daemon died after
    ///   `git worktree add` but before any tmux spawn. There is no hook
    ///   window to resume. TBD created the checkout and reconcile does not
    ///   adopt trees that have no row, so the row is kept and flipped to
    ///   `.active` with no terminals (`activateTerminalLessCreate`).
    /// - Checkout + pre-session terminal exist but the repo row is gone →
    ///   the wait can never be resumed (phase 3 needs the repo) and nothing
    ///   else ever resolves a `.creating` row, so skipping would strand it
    ///   forever. Delete the row and its terminal/tab records.
    ///
    /// Every delete here goes through `rollBackFailedCreate`, and the
    /// terminal-less activation saves the same way, so a first message the app
    /// parked in the row is saved to `unsent-prompts/` rather than deleted or
    /// left behind; `unsentPromptsReposDir` is that save's test seam.
    ///
    /// Returns the detached phase-3 resume tasks (for tests); the daemon
    /// ignores them.
    @discardableResult
    public func recoverCreatingWorktrees(unsentPromptsReposDir: URL? = nil) async -> [Task<Void, Never>] {
        // Location-neutral: this sweep is the only thing that resolves a
        // `.creating` row, so fencing it to local rows would strand every
        // remote one. The fence is the per-row guard below instead, which
        // gives a remote row an outcome rather than skipping it.
        let creating = (try? await db.worktrees.list(status: .creating)) ?? []
        var resumed: [Task<Void, Never>] = []
        for row in creating {
            // A remote `.creating` row has no checkout to inspect and no
            // pre-session wait to resume, and reconcile is fenced from remote
            // rows too — so nothing else would ever resolve it and the lane
            // would spin forever. Mark it `.failed`, the terminal state the
            // creation flow already uses for a create that did not finish.
            // Deleting instead would make "the create never ran" and "the row
            // silently vanished" indistinguishable, and would orphan a session
            // the provider may well have started before the daemon died.
            guard row.location.isLocal else {
                logger.warning("recovery: marking remote .creating worktree \(row.id, privacy: .public) as .failed — the daemon died mid-create and no other sweep resolves a remote creating row")
                do {
                    try await db.worktrees.updateStatus(id: row.id, status: .failed)
                } catch {
                    logger.warning("recovery: failed to mark remote .creating worktree \(row.id, privacy: .public) as .failed: \(error.localizedDescription, privacy: .public)")
                }
                continue
            }

            let terminals = (try? await db.terminals.list(worktreeID: row.id)) ?? []
            let preSessionTerminal = terminals.first { $0.label == TerminalLabel.preSession }
            // "Has phase 3 already spawned the primaries?" is the same question
            // `park` asks before it promises a first message to a spawn, so it
            // is asked through the same rule — a second copy here would be free
            // to drift into disagreeing with the promise the operator was made.
            let hasPrimaries = !PrimaryTerminal.spawnIsStillComing(terminals: terminals)

            // Everything past here needs a directory, so convert once. The
            // conversion also covers a local row with no path at all — the
            // daemon computes the path before the insert, so that shape should
            // not persist, and if it ever does it is the same "creation never
            // completed" case as a missing checkout.
            guard FileManager.default.fileExists(atPath: row.localPath),
                  let worktree = LocalWorktree(row) else {
                logger.warning("recovery: deleting .creating worktree \(row.id, privacy: .public) — checkout missing at \(row.localPath, privacy: .public)")
                do {
                    try await db.terminals.deleteForWorktree(worktreeID: row.id)
                    try await db.tabs.deleteForWorktree(worktreeID: row.id)
                    // Hard delete: closed-terminal history (rows + files) goes too.
                    try await db.terminalHistory.deleteForWorktree(worktreeID: row.id)
                    await rollBackStrandedCreate(row.id, reposDir: unsentPromptsReposDir)
                } catch {
                    logger.warning("recovery: cleanup of missing-checkout worktree \(row.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
                continue
            }

            if hasPrimaries {
                // Phase 3 already spawned the primary terminals; only the
                // final status flip was lost. Reconcile's dead-window pass
                // will clean up any terminals whose windows didn't survive.
                logger.info("recovery: activating .creating worktree \(worktree.id, privacy: .public) — primary terminals already exist")
                do {
                    try await db.worktrees.updateStatus(id: worktree.id, status: .active)
                } catch {
                    logger.warning("recovery: failed to activate worktree \(worktree.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                continue
            }

            guard let preSessionTerminal else {
                await activateTerminalLessCreate(row, reposDir: unsentPromptsReposDir)
                continue
            }

            guard let rid = worktree.repoID, let repo = (try? await db.repos.get(id: rid)) ?? nil else {
                logger.warning("recovery: deleting .creating worktree \(worktree.id, privacy: .public) — repo \(String(describing: worktree.repoID), privacy: .public) row is missing, so the pre-session wait can never be resumed")
                do {
                    try await db.terminals.deleteForWorktree(worktreeID: worktree.id)
                    try await db.tabs.deleteForWorktree(worktreeID: worktree.id)
                    // Hard delete: closed-terminal history (rows + files) goes too.
                    try await db.terminalHistory.deleteForWorktree(worktreeID: worktree.id)
                    await rollBackStrandedCreate(worktree.id, reposDir: unsentPromptsReposDir)
                } catch {
                    logger.warning("recovery: cleanup of repo-less worktree \(worktree.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
                continue
            }

            // Resume the wait. The hook command wraps its exit code into the
            // marker file, so a hook that finished while the daemon was down
            // is picked up on the first poll.
            let spawn = PreSessionSpawn(
                terminalID: preSessionTerminal.id,
                tmuxServer: worktree.tmuxServer,
                windowID: preSessionTerminal.tmuxWindowID,
                paneID: preSessionTerminal.tmuxPaneID,
                markerPath: Self.preSessionMarkerPath(worktreeID: worktree.id),
                // Informational only in phase 3; best-effort re-resolve.
                hookPath: hooks.resolve(
                    event: .preSession,
                    repoPath: worktree.path,
                    appHookPath: TBDConstants.hookPath(
                        repoID: rid,
                        eventName: HookEvent.preSession.rawValue
                    )
                ) ?? "",
                // Carried from the row: a resumed wait must probe the hook tab
                // in the terms its own transport has. A holder-backed tab has
                // no tmux window, so a descriptor that claimed `.tmux` would
                // ask a server that was never started and read the answer as a
                // closed pane.
                transport: preSessionTerminal.transport,
                holderPID: preSessionTerminal.holderPID,
                childPID: preSessionTerminal.childPID,
                // A resumed wait anchors the identity check the same way every
                // other reader of a holder row does: the recorded start time,
                // falling back to the row's own `createdAt` for a row written
                // before that column existed.
                childStartedAt: preSessionTerminal.holderChildStartedAt
                    ?? preSessionTerminal.createdAt
            )
            // Distinguish an interrupted CREATE from an interrupted REVIVE:
            // a mid-revive row still carries its archived Claude sessions
            // (`beginReviveWorktree` only clears them in phase 3 via
            // `.revive(clearSessions:)`). Resuming such a row with
            // `.markActive` and no sessions would spawn a FRESH Claude
            // session, and the next archive would unconditionally overwrite
            // `archivedClaudeSessions` — silently losing the old transcript.
            // So: restore the archived sessions and finish with revive
            // semantics (flip `.active`, clear `archivedAt`, clear the
            // session list). The other original params (skipClaude,
            // initialPrompt, cols/rows) died with the previous daemon
            // process — spawn with defaults.
            let archivedSessions = worktree.archivedClaudeSessions ?? []
            let isMidRevive = !archivedSessions.isEmpty
            if !isMidRevive {
                archiveLogger.warning(
                    "recovery: resuming ordinary .creating worktree \(worktree.id, privacy: .public); any ephemeral conversation carryover cannot survive a daemon restart. If this create came from a fresh-branch conversation revive, the user can run that action again."
                )
            }
            logger.info("recovery: resuming pre-session wait for .creating worktree \(worktree.id, privacy: .public) (\(isMidRevive ? "mid-revive" : "mid-create", privacy: .public))")
            let task = Task.detached { [self] in
                await runPreSessionPhase3(
                    preSession: spawn,
                    worktree: worktree.worktree, repo: repo,
                    worktreePath: worktree.path,
                    skipClaude: false,
                    archivedClaudeSessions: isMidRevive ? archivedSessions : nil,
                    completionAction: isMidRevive ? .revive(clearSessions: true) : .markActive
                )
            }
            resumed.append(task)
        }
        return resumed
    }

    /// Keep a terminal-less `.creating` row whose checkout exists and flip it to
    /// `.active`: the same shape `adoptWorktree` produces, a row with no
    /// terminals that the user can open from the app.
    ///
    /// TBD made this checkout itself, so the row is the only thing that owns it.
    /// Reconcile does not adopt a git worktree that has no row, so deleting the
    /// row would orphan a tree TBD created.
    ///
    /// - A first message parked in the row is saved to `unsent-prompts/` exactly
    ///   as a failed create saves it, then cleared from the column. It was
    ///   meant for a create whose terminals never spawned, so it must not wait
    ///   in the row for some later terminal to take it. The column is cleared
    ///   even when the save failed, as a failed create deletes it either way;
    ///   the loss is logged.
    /// - A row still carrying `archivedClaudeSessions` was mid-revive. No
    ///   terminal exists to restore them into, so they are kept: the row goes
    ///   through `revive(clearSessions: false)`, which also clears
    ///   `archivedAt`, the same outcome as a revive with `skipClaude`.
    private func activateTerminalLessCreate(_ row: Worktree, reposDir: URL?) async {
        let saved = saveParkedFirstMessage(of: row, reposDir: reposDir)
        if saved.lost {
            logger.error("recovery: the parked first message of \(row.id, privacy: .public) could not be saved and is being cleared")
        }
        do {
            if row.pendingPrompt != nil {
                _ = try await db.worktrees.setPendingPrompt(worktreeID: row.id, text: nil, submit: false)
            }
            if row.archivedClaudeSessions?.isEmpty == false {
                try await db.worktrees.revive(id: row.id, clearSessions: false)
            } else {
                try await db.worktrees.updateStatus(id: row.id, status: .active)
            }
            logger.info("recovery: activated terminal-less .creating worktree \(row.id, privacy: .public) — its checkout exists and TBD created it, so the row is kept")
        } catch {
            logger.warning("recovery: failed to activate terminal-less worktree \(row.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Delete a stranded `.creating` row the way a failed create is rolled
    /// back, saving any parked first message, and log where it went. No
    /// broadcast: recovery runs at startup, before any client is connected.
    private func rollBackStrandedCreate(_ worktreeID: UUID, reposDir: URL?) async {
        let delta = await rollBackFailedCreate(worktreeID: worktreeID, reposDir: reposDir)
        if let path = delta.unsentPromptPath {
            logger.info("recovery: saved the parked first message of \(worktreeID, privacy: .public) to \(path, privacy: .public)")
        }
    }
}
