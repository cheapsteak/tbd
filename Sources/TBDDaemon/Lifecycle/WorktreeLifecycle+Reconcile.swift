import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "reconcile")

extension WorktreeLifecycle {
    // MARK: - Git Status

    /// Recompute conflict status for all active worktrees in a repo.
    /// Also detects branch name changes (e.g., `git checkout -b` inside a worktree).
    /// Runs git checks concurrently and updates the DB + broadcasts deltas.
    public func refreshGitStatuses(repoID: UUID) async {
        guard let repo = try? await db.repos.get(id: repoID) else { return }
        var worktrees = (try? await db.worktrees.list(repoID: repoID, status: .active)) ?? []

        // Sync branch names: one `git worktree list` call gives us
        // the current branch for every worktree — update DB if changed.
        if let gitWorktrees = try? await git.worktreeList(repoPath: repo.path) {
            let branchByPath = Dictionary(gitWorktrees.map { ($0.path, $0.branch) }, uniquingKeysWith: { _, b in b })
            for (i, wt) in worktrees.enumerated() {
                if let gitBranch = branchByPath[wt.path], gitBranch != wt.branch {
                    try? await db.worktrees.updateBranch(id: wt.id, branch: gitBranch)
                    worktrees[i].branch = gitBranch  // use updated branch for conflict check below
                }
            }
        }

        // Dirty gate: resolve every branch tip plus the origin/<defaultBranch>
        // tip in ONE `for-each-ref` subprocess. The conflict answer depends
        // only on that (branch tip, base tip) pair, so a worktree whose pair is
        // unchanged since its last successful check is skipped — no merge-base,
        // no merge-tree. On failure (e.g. no origin remote yet) `tips` is empty
        // and every worktree falls through to the ungated legacy path.
        let tips = (try? await git.refTips(repoPath: repo.path)) ?? [:]
        let baseTip = tips["origin/\(repo.defaultBranch)"]
        await conflictSweepCache.retain(repoID: repoID, worktreeIDs: Set(worktrees.map(\.id)))

        await withTaskGroup(of: Void.self) { group in
            for wt in worktrees {
                group.addTask {
                    // Both tips known → gate on the cached pair. Unknown refs
                    // (deleted branch, missing origin) → check unconditionally,
                    // matching pre-gate behavior.
                    var key: ConflictSweepCache.Key?
                    if let baseTip, let branchTip = tips[wt.branch] {
                        key = ConflictSweepCache.Key(branchTip: branchTip, baseTip: baseTip)
                    }
                    if let key {
                        guard await self.conflictSweepCache.shouldCheck(
                            repoID: repoID, worktreeID: wt.id, key: key
                        ) else { return }
                    }
                    guard let newHasConflicts = await self.checkHasConflicts(
                        repoPath: repo.path,
                        defaultBranch: repo.defaultBranch,
                        branch: wt.branch
                    ) else { return }
                    if newHasConflicts != wt.hasConflicts {
                        do {
                            try await self.db.worktrees.updateHasConflicts(id: wt.id, hasConflicts: newHasConflicts)
                        } catch {
                            // Persist failed — don't mark the pair checked, so
                            // the next sweep recomputes and retries the write
                            // (pre-gate behavior was self-healing on the next
                            // sweep; the gate must not cache over a lost write).
                            return
                        }
                        self.subscriptions?.broadcast(delta: .worktreeConflictsChanged(
                            WorktreeConflictDelta(worktreeID: wt.id, hasConflicts: newHasConflicts)
                        ))
                    }
                    // Record only successful checks whose result is persisted,
                    // so transient git/DB failures retry next sweep instead of
                    // caching a non-answer.
                    if let key {
                        await self.conflictSweepCache.markChecked(repoID: repoID, worktreeID: wt.id, key: key)
                    }
                }
            }
        }
    }

    /// Check whether a branch would conflict if merged into the default branch.
    /// Returns nil if git commands fail (leaves status unchanged).
    private func checkHasConflicts(repoPath: String, defaultBranch: String, branch: String) async -> Bool? {
        guard let isAncestor = await git.isMergeBaseAncestor(
            repoPath: repoPath, base: "origin/\(defaultBranch)", branch: branch
        ) else {
            // git error or origin/<defaultBranch> doesn't exist yet —
            // leave hasConflicts at its previous value. For purely local repos
            // (no origin remote) this is a permanent no-op, which is acceptable.
            return nil
        }
        if isAncestor { return false }

        // Branches have diverged — check for conflicts
        let (hasConflicts, _) = await git.checkMergeConflicts(
            repoPath: repoPath, branch: branch, targetBranch: "origin/\(defaultBranch)"
        )
        return hasConflicts
    }

    // MARK: - Reconcile

    /// Reconciles the database state with actual git worktrees on disk.
    ///
    /// - Worktrees in db but missing from git: marked as archived
    /// - Worktrees in git but missing from db: added with default names
    ///
    /// This sweep is a daemon-internal actuation rail in its own right: boot
    /// (and `cleanup`) invoke it, and it kills windows, parks sessions and kills
    /// whole tmux servers on its own judgement. So it takes the record and
    /// writes one row **per act** — each kill or park is an independent decision
    /// about a target it has already resolved, unlike an RPC archive where the
    /// caller asked for one worktree-level thing. The shared helpers it calls
    /// (`captureThenKillWindow`, `killWindowAndReap`) stay silent so the RPC
    /// paths that also reach them are not double-counted.
    ///
    /// `actuationLog` is a required parameter rather than a defaulted one: a
    /// default would point every caller at one real file under `$TBD_HOME`,
    /// which is exactly the "helper ignores its caller's injected seam" shape.
    /// Fail-closed here means skipping the individual act — the daemon still
    /// boots, and the orphan waits for a writable log and the next sweep.
    public func reconcile(repoID: UUID, actuationLog: ActuationLog) async throws {
        // Null out parent pointers whose target is missing OR archived. Either
        // case would leave the child unreachable in the sidebar — missing rows
        // can't render, and archived parents are filtered out of the subtree
        // walk. Promoting to top-level is the only sensible recovery. Cheap
        // single UPDATE — safe to run per repo.
        try await db.worktrees.nullOrphanedParents()

        guard let repo = try await db.repos.get(id: repoID) else {
            throw WorktreeLifecycleError.repoNotFound(repoID)
        }

        // If the repo's filesystem path is gone, don't try to talk to git.
        // The startup health validator will (or already has) flipped its status
        // to .missing. Reconcile becomes a no-op until the user runs `tbd repo
        // relocate`. The daemon must not crash or hang on stale paths.
        if repo.status == .missing {
            return
        }

        let gitWorktrees = try await git.worktreeList(repoPath: repo.path)
        let correctTmuxServer = TmuxManager.serverName(forRepoPath: repo.path)
        var dbWorktrees = try await db.worktrees.list(repoID: repoID, status: .active)

        // Fix stale tmux server names (e.g. after migration from UUID-based to
        // path-based naming). CAUTION: a non-canonical stored server is NOT
        // automatically stale — a promoted scratch space's main worktree
        // deliberately inherits the scratch tmux server its live sessions run
        // on. Rewriting such a row would orphan those live windows: the next
        // pass below probes the (empty) canonical server, concludes every
        // window is dead, and parks/deletes terminals that are actually alive.
        // So: canonicalize ONLY when the stored server has no live window for
        // this worktree's terminals — the genuinely-stale case the self-heal
        // was built for.
        let mainWorktrees = try await db.worktrees.list(repoID: repoID, status: .main)
        for wt in (dbWorktrees + mainWorktrees) where wt.tmuxServer != correctTmuxServer {
            if await hasLiveWindow(server: wt.tmuxServer, worktreeID: wt.id) {
                logger.info("reconcile: keeping non-canonical tmux server \(wt.tmuxServer, privacy: .public) for worktree \(wt.id, privacy: .public) — it has live windows (promoted-scratch inheritance)")
                continue
            }
            do {
                try await db.worktrees.updateTmuxServer(id: wt.id, tmuxServer: correctTmuxServer)
            } catch {
                logger.warning("reconcile: failed to update tmux server for worktree \(wt.id, privacy: .public): \(error, privacy: .public)")
            }
        }
        // Re-fetch with corrected names
        dbWorktrees = try await db.worktrees.list(repoID: repoID, status: .active)

        let gitPaths = Set(gitWorktrees.map(\.path))
        // Include `.creating` rows so a worktree whose pre-session phase-3
        // wait is still in flight (status flips to .active only when the hook
        // finishes) isn't "unknown" to the re-adopt pass below — re-adopting
        // its path would violate the UNIQUE path constraint and abort this
        // repo's reconcile.
        let creatingPaths = Set(
            (try await db.worktrees.list(repoID: repoID, status: .creating)).map(\.path)
        )
        let dbPaths = Set(dbWorktrees.map(\.path)).union(creatingPaths)

        // Mark missing worktrees as archived — also capture each terminal's
        // scrollback into Closed Terminals history, then kill its tmux window.
        // The checkout is gone but the tmux server may still be live; capture
        // is best-effort (a dead window/pane just logs and skips). The archived
        // row and its history rows survive, so the output stays readable.
        for wt in dbWorktrees where !gitPaths.contains(wt.path) {
            let terminals = try await db.terminals.list(worktreeID: wt.id)
            var recordedEveryKill = true
            for terminal in terminals {
                var row = ActuationRow(
                    actor: .daemon(rail: ActuationRail.reconcile), kind: .dispose)
                row.target = .local(worktree: wt.id, terminal: terminal.id)
                guard let actuationID = try? await actuationLog.appendRequest(row) else {
                    recordedEveryKill = false
                    continue
                }
                await captureThenKillWindow(terminal: terminal, server: wt.tmuxServer)
                await actuationLog.appendOutcome(confirms: actuationID, result: .dispatched)
            }
            // A kill that could not be recorded did not happen, so the rows that
            // still point at those windows must not be torn down either — that
            // would archive the worktree and leave its live windows unreachable.
            // Leave the whole worktree for the next sweep instead.
            guard recordedEveryKill else {
                logger.warning("reconcile: leaving \(wt.id, privacy: .public) for the next sweep — the actuation record is unwritable, so its windows were not killed")
                continue
            }
            try await db.terminals.deleteForWorktree(worktreeID: wt.id)
            try await db.tabs.deleteForWorktree(worktreeID: wt.id)
            for terminal in terminals {
                await pendingQuestions.clear(terminalID: terminal.id)
                // Reclaim any per-session fallbackModel overlay (keyed by terminal
                // id), mirroring handleTerminalDelete. No-op when none was written.
                ClaudeHookOverlay.removePerSessionOverlay(sessionKey: terminal.id.uuidString)
            }
            try await db.worktrees.archive(id: wt.id)
        }

        // Add unknown worktrees (skip the main repo worktree).
        // LEGACY-WORKTREE-LOCATION: remove after 2026-06-01
        // Reads worktrees from <repo>/.tbd/worktrees/ for backward compatibility with
        // worktrees created before the canonical-location switch. New worktrees are
        // always created under ~/tbd/worktrees/<repo>/<name>. After 2026-06-01, all
        // pre-switch worktrees will have archived naturally and this path can be deleted.
        // Dual-prefix view: accept worktrees living under either the canonical
        // (~/tbd/worktrees/<slot>/) or legacy (<repo>/.tbd/worktrees/) layout.
        let layout = WorktreeLayout()
        let acceptablePrefixes = layout.legacyAndCanonicalPrefixes(for: repo)
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        // Paths the user explicitly forgot (`tbd worktree forget`) must NOT be
        // re-adopted, even though they still sit under a TBD-managed prefix
        // and remain registered with git. Loaded once per reconcile pass.
        // Tombstones are cleared by the adopt/create flows when the user
        // deliberately re-adds a path.
        let forgottenPaths = try await db.forgottenWorktrees.allPaths()
        for gitWt in gitWorktrees where !dbPaths.contains(gitWt.path) {
            guard acceptablePrefixes.contains(where: { gitWt.path.hasPrefix($0) }) else { continue }
            if forgottenPaths.contains(gitWt.path) {
                logger.debug("reconcile: skipping forgotten worktree path \(gitWt.path, privacy: .public)")
                continue
            }

            let name = (gitWt.path as NSString).lastPathComponent
            let tmuxServer = TmuxManager.serverName(forRepoPath: repo.path)
            _ = try await db.worktrees.create(
                repoID: repoID,
                name: name,
                branch: gitWt.branch,
                path: gitWt.path,
                tmuxServer: tmuxServer
            )
        }

        // Reconcile terminals whose tmux window is gone. A window can vanish two
        // ways: its specific window died while the server is still up, or the
        // whole server is gone after a reboot/long sleep. BOTH are handled the
        // same way — park resumable Claude sessions and let the user bring them
        // back on demand via wake (HibernationCoordinator.wake, the single
        // unified resume path; see #285 for the dead-server bootstrap history).
        //
        // We deliberately do NOT eagerly recreate terminals on reboot: on a
        // machine with many worktrees that spawned N simultaneous `claude
        // --resume` processes (~0.5-1.5 GB each) and OOM'd the machine (#284).
        // Lazy recreate-on-demand keeps idle worktrees as cheap suspended rows.
        let allLiveWorktrees = try await db.worktrees.list(repoID: repoID, status: .active)
            + (try await db.worktrees.list(repoID: repoID, status: .main))
        // Probe the server each worktree row actually STORES, not the
        // canonical name: after a scratch promote the main worktree's windows
        // live on the inherited scratch server, and probing the canonical
        // (empty) server would declare every live window dead. Cached per
        // server name — rows overwhelmingly share one server.
        var serverAliveByName: [String: Bool] = [:]
        for wt in allLiveWorktrees {
            let serverAlive: Bool
            if let cached = serverAliveByName[wt.tmuxServer] {
                serverAlive = cached
            } else {
                serverAlive = await tmux.serverExists(server: wt.tmuxServer)
                serverAliveByName[wt.tmuxServer] = serverAlive
            }
            let terminals = try await db.terminals.list(worktreeID: wt.id)
            // Parked rows (`hibernatedAt` OR legacy `suspendedAt` — see
            // `isParked`) are skipped: a parked terminal's window being gone
            // is expected (post-reboot), the row is already exactly what this
            // pass would produce, and re-evaluating it would refresh the park
            // timestamp or, worse, DELETE a parked non-Claude-resumable row.
            for terminal in terminals where !terminal.isParked {
                // After a reboot the server is gone, so every window is dead;
                // otherwise probe the specific window. (Split across statements
                // because `&&` builds an autoclosure that can't contain `await`.)
                var windowAlive = false
                if serverAlive {
                    windowAlive = await tmux.windowExists(server: wt.tmuxServer, windowID: terminal.tmuxWindowID)
                }
                guard !windowAlive else { continue }

                // Extra safety: If this is a Claude-resumable terminal, double-check
                // that the process is truly gone before parking. If Claude is still
                // running, leave the terminal active — the next reconcile can reassess.
                if terminal.isClaudeResumable {
                    if let cmd = try? await tmux.paneCurrentCommand(server: wt.tmuxServer, paneID: terminal.tmuxPaneID),
                       ClaudeStateDetector.isClaudeProcess(cmd) {
                        // Claude is still running in this pane despite windowExists returning false.
                        // This shouldn't happen, but don't park if it's true.
                        logger.warning("reconcile: terminal \(terminal.id, privacy: .public) window marked dead but claude process still running — skipping park")
                        continue
                    }
                }

                if terminal.isClaudeResumable, let sessionID = terminal.claudeSessionID {
                    // Resumable Claude session: park it. The unified park/wake
                    // machinery rebuilds a window from the session ID on demand.
                    // Deleting here would orphan the transcript and the session
                    // would vanish from TBD. Write the authoritative `hibernatedAt`
                    // column so `wake()` (which un-parks any parked row) can resume it.
                    //
                    // This park bypasses `HibernationCoordinator` entirely, so it
                    // is this sweep's own act and carries this sweep's own row.
                    // Fail-closed: an unrecordable park is skipped and the row
                    // stays as it is for the next sweep.
                    var row = ActuationRow(
                        actor: .daemon(rail: ActuationRail.reconcile), kind: .hibernate)
                    row.target = .local(worktree: wt.id, terminal: terminal.id)
                    guard let actuationID = try? await actuationLog.appendRequest(row) else {
                        logger.warning("reconcile: skipped parking terminal \(terminal.id, privacy: .public) — the actuation record is unwritable")
                        continue
                    }
                    do {
                        try await db.terminals.setHibernated(id: terminal.id, sessionID: sessionID, reason: .recovery)
                        await actuationLog.appendOutcome(
                            confirms: actuationID, result: .dispatched)
                    } catch {
                        await actuationLog.appendOutcome(
                            confirms: actuationID, result: .transportFailed, error: "\(error)")
                    }
                    logger.info("reconcile: parked terminal \(terminal.id, privacy: .public) — window \(terminal.tmuxWindowID, privacy: .public) gone, session \(sessionID, privacy: .public) preserved, wakeable via the unified resume path")
                } else {
                    // Plain shell / Codex: nothing resumable to preserve, delete.
                    try? await db.terminals.delete(id: terminal.id)
                    logger.info("reconcile: deleted terminal \(terminal.id, privacy: .public) — window \(terminal.tmuxWindowID, privacy: .public) gone, no session to preserve")
                }
                await pendingQuestions.clear(terminalID: terminal.id)
            }
        }

        // Clean up orphaned tmux windows and dead servers. This must cover
        // every server actually referenced by the repo's worktree rows, not
        // just the canonical name for the repo path: a promoted scratch
        // space's main worktree deliberately inherits the shared scratch
        // server (see the self-heal caution above), and after such a worktree
        // is archived its row is the only remaining pointer to that server —
        // so archived rows are included when collecting servers to visit.
        //
        // A server can be SHARED beyond this repo: every scratch space runs
        // on the one server derived from the scratch base dir, and a promoted
        // repo's main worktree keeps using it. Both decisions below are
        // therefore made against live rows across ALL repos and scratch
        // spaces, not just this repo's:
        //   - kill a server only when NO live worktree row anywhere still
        //     references it (reaping its agent processes first so a wedged
        //     one doesn't reparent to launchd);
        //   - otherwise sweep only windows untracked by any live row on that
        //     server, so other worktrees' live windows survive.
        //
        // "Live" includes `.creating`: a pre-session hook wait that's still
        // in flight (or just resumed by the startup recovery sweep) owns a
        // real tmux window, and phase 3 spawns primary/setup windows before
        // the row flips `.active`. Treating those rows as dead would kill the
        // hook mid-run (interrupting e.g. a running npm install), fire a
        // spurious `.paneKilled` notification, and spawn the agent
        // prematurely.
        //
        // For the canonical per-repo server — referenced by nothing outside
        // this repo — this reduces to the previous behavior: killed when the
        // repo has no live worktrees, orphan-swept otherwise.
        let repoRows = try await db.worktrees.list(repoID: repoID)
        var referencedServers = Set(repoRows.map(\.tmuxServer))
        referencedServers.insert(correctTmuxServer)
        // Also visit every server referenced by scratch rows (repoID nil,
        // archived included — the retired promoted-scratch row is often the
        // LAST pointer). Scratch spaces belong to no repo, so no per-repo
        // visit set would otherwise ever include their shared server once the
        // repo-side pointer is gone: `repo.remove` on a promoted repo
        // hard-deletes its main worktree row (deleteForRepo) — the only repo
        // row referencing the inherited scratch server — leaving that
        // server, and the removed repo's still-running windows on it,
        // reachable by no reconcile at all (#325-class leak). Folding scratch
        // servers into every repo's reconcile makes whichever repo reconciles
        // next sweep those orphans; the live-row checks below already span
        // all repos + scratch spaces, so live scratch windows stay safe.
        let scratchRows = try await db.worktrees.list(scratchOnly: true)
        referencedServers.formUnion(scratchRows.map(\.tmuxServer))
        let globalLiveRows = try await db.worktrees.list(excludeArchived: true)

        for server in referencedServers.sorted() {
            let liveRowsOnServer = globalLiveRows.filter { $0.tmuxServer == server }
            if liveRowsOnServer.isEmpty {
                // Nothing references this server anymore. Skip silently when
                // it isn't running (nothing to reap or kill — and archived
                // rows keep pointing here forever, so this is the steady
                // state on every later reconcile).
                guard await tmux.serverExists(server: server) else { continue }
                // Nothing left names this server — that is why it is being
                // killed — so the row is identified by what IS known: the
                // server, and the repo whose sweep found it. The child reap is
                // part of this one disposal, not a second act.
                var row = ActuationRow(
                    actor: .daemon(rail: ActuationRail.reconcile), kind: .dispose)
                row.target = .tmux(server: server, repo: repoID)
                guard let actuationID = try? await actuationLog.appendRequest(row) else {
                    logger.warning("reconcile: skipped killing tmux server \(server, privacy: .public) — the actuation record is unwritable")
                    continue
                }
                await reaper.reapServerChildren(server: server)
                do {
                    try await tmux.killServer(server: server)
                    await actuationLog.appendOutcome(confirms: actuationID, result: .dispatched)
                } catch {
                    await actuationLog.appendOutcome(
                        confirms: actuationID, result: .transportFailed, error: "\(error)")
                    logger.warning("reconcile: failed to kill tmux server \(server, privacy: .public): \(error, privacy: .public)")
                }
            } else {
                // Collect window IDs tracked by ANY live worktree row on this
                // server (all repos + scratch), then kill the untracked rest.
                var trackedWindowIDs: Set<String> = []
                for wt in liveRowsOnServer {
                    let terminals = try await db.terminals.list(worktreeID: wt.id)
                    for t in terminals {
                        trackedWindowIDs.insert(t.tmuxWindowID)
                    }
                }

                do {
                    let tmuxWindows = try await tmux.listWindows(server: server, session: "main")
                    for window in tmuxWindows where !trackedWindowIDs.contains(window.windowID) {
                        // No terminal row claims this window — that is what
                        // makes it an orphan — so the row names the server, the
                        // window and the sweeping repo.
                        var row = ActuationRow(
                            actor: .daemon(rail: ActuationRail.reconcile), kind: .dispose)
                        row.target = .tmux(
                            server: server, window: window.windowID, repo: repoID)
                        guard let actuationID = try? await actuationLog.appendRequest(row) else {
                            logger.warning("reconcile: skipped sweeping orphan window \(window.windowID, privacy: .public) on \(server, privacy: .public) — the actuation record is unwritable")
                            continue
                        }
                        await killWindowAndReap(
                            server: server,
                            windowID: window.windowID,
                            paneID: window.paneID
                        )
                        await actuationLog.appendOutcome(
                            confirms: actuationID, result: .dispatched)
                    }
                } catch {
                    logger.warning("reconcile: failed to list tmux windows for server \(server, privacy: .public): \(error, privacy: .public)")
                }
            }
        }

        // Recompute health so the next call sees the right status. A repo that
        // just transitioned ok→missing here would otherwise stay ok in memory
        // until the next startup sweep.
        let validator = RepoHealthValidator(git: git)
        let observed = await validator.validate(repo: repo)
        if observed != repo.status {
            try? await db.repos.updateStatus(id: repo.id, status: observed)
            // Broadcast a coarse refresh so the sidebar dims/un-dims immediately
            // when reconcile is triggered via an RPC (e.g. cleanup) with active
            // subscribers. .repoAdded is the existing coarse signal — see the
            // matching call site in RPCRouter+RelocateHandler.
            subscriptions?.broadcast(delta: .repoAdded(RepoDelta(
                repoID: repo.id, path: repo.path, displayName: repo.displayName
            )))
        }
    }

    /// True when `server` is up AND hosts a live tmux window for at least one
    /// of `worktreeID`'s terminal rows. Used by the stale-server self-heal to
    /// distinguish a genuinely dead/renamed server (safe to canonicalize)
    /// from a deliberately inherited one whose sessions are still running
    /// (promoted scratch space). Early-exits on the first live window.
    private func hasLiveWindow(server: String, worktreeID: UUID) async -> Bool {
        guard await tmux.serverExists(server: server) else { return false }
        let terminals = (try? await db.terminals.list(worktreeID: worktreeID)) ?? []
        for terminal in terminals {
            if await tmux.windowExists(server: server, windowID: terminal.tmuxWindowID) {
                return true
            }
        }
        return false
    }
}
