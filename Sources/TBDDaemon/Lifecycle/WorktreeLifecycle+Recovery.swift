import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "worktreeLifecycle")

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
    ///
    /// Returns the detached phase-3 resume tasks (for tests); the daemon
    /// ignores them.
    @discardableResult
    public func recoverCreatingWorktrees() async -> [Task<Void, Never>] {
        let creating = (try? await db.worktrees.list(status: .creating)) ?? []
        var resumed: [Task<Void, Never>] = []
        for worktree in creating {
            let terminals = (try? await db.terminals.list(worktreeID: worktree.id)) ?? []
            let preSessionTerminal = terminals.first { $0.label == "pre-session" }
            let hasPrimaries = terminals.contains { $0.label != "pre-session" }

            guard FileManager.default.fileExists(atPath: worktree.path) else {
                logger.warning("recovery: deleting .creating worktree \(worktree.id, privacy: .public) — checkout missing at \(worktree.path, privacy: .public)")
                do {
                    try await db.terminals.deleteForWorktree(worktreeID: worktree.id)
                    try await db.tabs.deleteForWorktree(worktreeID: worktree.id)
                    try await db.worktrees.delete(id: worktree.id)
                } catch {
                    logger.warning("recovery: cleanup of missing-checkout worktree \(worktree.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
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
                    try await db.worktrees.delete(id: worktree.id)
                } catch {
                    logger.warning("recovery: failed to delete terminal-less worktree \(worktree.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                continue
            }

            guard let repo = (try? await db.repos.get(id: worktree.repoID)) ?? nil else {
                logger.error("recovery: repo \(worktree.repoID, privacy: .public) missing for .creating worktree \(worktree.id, privacy: .public); skipping")
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
                        repoID: worktree.repoID,
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
            logger.info("recovery: resuming pre-session wait for .creating worktree \(worktree.id, privacy: .public) (\(isMidRevive ? "mid-revive" : "mid-create", privacy: .public))")
            let task = Task.detached { [self] in
                await runPreSessionPhase3(
                    preSession: spawn,
                    worktree: worktree, repo: repo,
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
