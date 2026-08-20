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
    ///   window to resume and no terminals to keep; delete the row and let
    ///   reconcile re-adopt the on-disk checkout as a fresh worktree.
    /// - Checkout + pre-session terminal exist but the repo row is gone →
    ///   the wait can never be resumed (phase 3 needs the repo) and nothing
    ///   else ever resolves a `.creating` row, so skipping would strand it
    ///   forever. Delete the row and its terminal/tab records.
    ///
    /// Returns the detached phase-3 resume tasks (for tests); the daemon
    /// ignores them.
    @discardableResult
    public func recoverCreatingWorktrees() async -> [Task<Void, Never>] {
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
                    try await db.worktrees.delete(id: row.id)
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
                logger.warning("recovery: deleting .creating worktree \(worktree.id, privacy: .public) — checkout exists but no terminals; reconcile will re-adopt it")
                do {
                    try await db.terminals.deleteForWorktree(worktreeID: worktree.id)
                    try await db.tabs.deleteForWorktree(worktreeID: worktree.id)
                    // Hard delete: closed-terminal history (rows + files) goes too.
                    try await db.terminalHistory.deleteForWorktree(worktreeID: worktree.id)
                    try await db.worktrees.delete(id: worktree.id)
                } catch {
                    logger.warning("recovery: failed to delete terminal-less worktree \(worktree.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                continue
            }

            guard let rid = worktree.repoID, let repo = (try? await db.repos.get(id: rid)) ?? nil else {
                logger.warning("recovery: deleting .creating worktree \(worktree.id, privacy: .public) — repo \(String(describing: worktree.repoID), privacy: .public) row is missing, so the pre-session wait can never be resumed")
                do {
                    try await db.terminals.deleteForWorktree(worktreeID: worktree.id)
                    try await db.tabs.deleteForWorktree(worktreeID: worktree.id)
                    // Hard delete: closed-terminal history (rows + files) goes too.
                    try await db.terminalHistory.deleteForWorktree(worktreeID: worktree.id)
                    try await db.worktrees.delete(id: worktree.id)
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
                ) ?? ""
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
}
