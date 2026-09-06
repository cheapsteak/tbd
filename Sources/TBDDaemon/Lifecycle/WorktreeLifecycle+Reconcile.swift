import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "reconcile")

/// What one reconcile pass established about a holder-backed session row.
///
/// Three-way in spirit rather than two, for the same reason
/// `HolderRegistry.ExitProbeOutcome` is: "the round trip failed" and "the
/// holder is gone" are different facts and only the second is evidence. The two
/// failure shapes collapse into one `keep` here — this sweep asks once, and the
/// next reconcile is the retry — but they keep their reasons apart in the log.
/// The **whole-pass** bound on how long the holder arm may spend at
/// rendezvous sockets, and the reason a per-probe timeout is not one.
///
/// A per-holder receive timeout bounds one probe; a serial phase over N rows
/// costs N times that bound, and this arm runs inside
/// `performStartupReconciliation` — before the socket is bound, holding a tmux
/// server resource lock. That is the failure `HolderRegistry.adoptAllBudget`
/// exists to prevent, and this is the same mechanism applied at the same place
/// in startup: a timer flips one flag, the loop reads it before each probe, and
/// a pass that runs out keeps every row it has not reached. Keeping is free —
/// this sweep asks once and the next reconcile *is* the retry — so an unreached
/// row loses nothing but a pass.
///
/// It bounds the pass, not a probe: the real cost is the budget plus the one
/// round trip in flight when it expired, exactly as `adoptAllBudget`'s is. That
/// round trip is bounded by its receive timeout alone, because the
/// `Darwin.connect` opening it cannot wait on a listener — on Darwin an
/// `AF_UNIX` connect is answered or refused outright, never queued behind a
/// listener that has stopped accepting.
///
/// An actor because one `WorktreeLifecycle` value is copied per call and every
/// copy must read the same flag — the same reason `conflictSweepCache` is one.
actor HolderProbeBudget {
    private var spent = false
    private var timer: Task<Void, Never>?

    /// Starts the clock for one pass. A second call while a pass is running is
    /// a no-op, so a nested or re-entered pass shares the outer one's budget
    /// rather than silently granting itself a fresh one.
    func begin(_ budget: Duration, clock: any Clock<Duration>) {
        guard timer == nil else { return }
        spent = false
        timer = Task { [weak self] in
            do {
                try await clock.sleep(for: budget)
            } catch {
                // Cancelled because the pass finished inside its budget.
                return
            }
            await self?.expire()
        }
    }

    /// Ends the pass and cancels the timer. Safe to call when no pass is
    /// running.
    func end() {
        timer?.cancel()
        timer = nil
    }

    /// Whether the current pass has already spent its budget.
    var isSpent: Bool { spent }

    private func expire() { spent = true }
}

enum HolderRowVerdict: Sendable, Equatable {
    /// Nothing can reach this session any more, and the status is the last
    /// thing anybody knew about how its job ended. `exitedStatusUnknown` is the
    /// honest answer for an exit nobody collected and must never be rounded to
    /// `.exited(code: 0)` — downstream could not tell a fabricated code from a
    /// real one.
    case sessionOver(HolderChildStatus)
    /// Nothing here says the session ended; `reason` names what kept it.
    case keep(reason: String)
}

extension WorktreeLifecycle {
    // MARK: - Git Status

    /// Recompute conflict status for all active worktrees in a repo.
    /// Also detects branch name changes (e.g., `git checkout -b` inside a worktree).
    /// Runs git checks concurrently and updates the DB + broadcasts deltas.
    public func refreshGitStatuses(repoID: UUID) async {
        guard let repo = try? await db.repos.get(id: repoID) else { return }
        // Fetched through `listLocal`: a remote row has no checkout on this
        // disk, so it has no path to match against `git worktree list` and no
        // branch for the conflict probes below. Unwrapped back to bare rows
        // because the branch-sync pass mutates elements in place and
        // `LocalWorktree` forwards reads only — the fence is at the fetch.
        var worktrees = ((try? await db.worktrees.listLocal(repoID: repoID, status: .active)) ?? [])
            .map(\.worktree)

        // Sync branch names: one `git worktree list` call gives us
        // the current branch for every worktree — update DB if changed.
        if let gitWorktrees = try? await git.worktreeList(repoPath: repo.path) {
            let branchByPath = Dictionary(gitWorktrees.map { ($0.path, $0.branch) }, uniquingKeysWith: { _, b in b })
            for (i, wt) in worktrees.enumerated() {
                if let gitBranch = branchByPath[wt.localPath], gitBranch != wt.branch {
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

        // §13's "commits unchanged across cycles" rides along on the map that
        // was just resolved: the sweep already knows every branch tip, so
        // remembering when each one first arrived costs one actor hop and no
        // subprocess. A tip that keeps arriving unchanged keeps its original
        // stamp. Deliberately no working-tree diff fact — answering that half
        // would mean a `git status` per worktree per sweep, and an
        // unestablished fact is reported as nil rather than as "unchanged".
        let observedAt = now()
        await branchTipTracker.retain(repoID: repoID, worktreeIDs: Set(worktrees.map(\.id)))
        for wt in worktrees {
            guard let branchTip = tips[wt.branch] else { continue }
            await branchTipTracker.record(
                repoID: repoID, worktreeID: wt.id, branchTip: branchTip, at: observedAt)
        }

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
    public func reconcile(
        repoID: UUID,
        actuationLog: ActuationLog,
        reapSharedScratchTmuxResources: Bool
    ) async throws {
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
        // Every fetch in this sweep is `listLocal`, not `list`. Reconcile's
        // whole job is to make DB rows agree with what git and tmux report on
        // THIS disk, so a row with no local checkout is not stale — it is out
        // of scope. Handed the location-neutral `list`, the archival pass
        // below would archive every remote row on every sweep (its path is
        // never in `gitPaths`) and the canonicalization pass would stamp a
        // tmux server name onto rows that have no tmux server at all.
        var dbWorktrees = try await db.worktrees.listLocal(repoID: repoID, status: .active)

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
        let mainWorktrees = try await db.worktrees.listLocal(repoID: repoID, status: .main)
        for wt in (dbWorktrees + mainWorktrees) where wt.tmuxServer != correctTmuxServer {
            try await tmux.withServerResourceLock(server: wt.tmuxServer) {
                // A concurrent reconciliation may have already moved this row
                // while we waited. Only judge the server whose lock we hold.
                guard let current = try await db.worktrees.getLocal(id: wt.id),
                      current.tmuxServer == wt.tmuxServer else { return }
                switch await liveWindowPresence(
                    server: current.tmuxServer, worktreeID: current.id)
                {
                case .alive:
                    logger.info("reconcile: keeping non-canonical tmux server \(current.tmuxServer, privacy: .public) for worktree \(current.id, privacy: .public) — it has live windows (promoted-scratch inheritance)")
                    return
                case .unknown:
                    // Renaming the server on ignorance is worse than renaming
                    // it late: the row would be re-pointed at a server that
                    // really has no windows, and the terminal sweep below
                    // would then park and delete its rows on an answer that
                    // looks affirmative. A later pass canonicalizes once tmux
                    // answers.
                    logger.warning("reconcile: leaving non-canonical tmux server \(current.tmuxServer, privacy: .public) for worktree \(current.id, privacy: .public) — tmux gave no usable answer about its windows; not canonicalizing this pass")
                    return
                case .absent:
                    break
                }
                do {
                    try await db.worktrees.updateTmuxServer(
                        id: current.id, tmuxServer: correctTmuxServer)
                } catch {
                    logger.warning("reconcile: failed to update tmux server for worktree \(current.id, privacy: .public): \(error, privacy: .public)")
                }
            }
        }
        // Re-fetch with corrected names
        dbWorktrees = try await db.worktrees.listLocal(repoID: repoID, status: .active)

        let gitPaths = Set(gitWorktrees.map(\.path))
        // Include `.creating` rows so a worktree whose pre-session phase-3
        // wait is still in flight (status flips to .active only when the hook
        // finishes) isn't "unknown" to the re-adopt pass below — re-adopting
        // its path would violate the UNIQUE path constraint and abort this
        // repo's reconcile.
        //
        // This one set deliberately fetches through the location-neutral
        // `list(...)` and then states its two exclusions here, in the open,
        // rather than borrowing `LocalWorktree.init?`. What it must contain is
        // "every path a live creating row already claims", and a path missing
        // from it is not a harmless omission: the re-adopt pass would treat
        // that path as unknown, create a second row on it, and abort this
        // repo's whole reconcile on the UNIQUE path constraint.
        // `LocalWorktree.init?` is a predicate about a worktree TBD may act on
        // right now, which is a different question — and any later tightening
        // of it (say, requiring the directory to exist, which a creating row's
        // does not yet) would silently shrink this set.
        //
        // Both exclusions are safe because neither kind of row can claim a
        // path `git worktree list` will ever report back: a remote row's
        // `remote://` path is synthetic, and an empty path is no path at all.
        let creatingPaths = Set(
            (try await db.worktrees.list(repoID: repoID, status: .creating))
                .filter { $0.location.isLocal }
                .map(\.localPath)
                .filter { !$0.isEmpty }
        )
        let dbPaths = Set(dbWorktrees.map(\.path)).union(creatingPaths)

        // Mark missing worktrees as archived — also capture each terminal's
        // scrollback into Closed Terminals history, then kill its tmux window.
        // The checkout is gone but the tmux server may still be live; capture
        // is best-effort (a dead window/pane just logs and skips). The archived
        // row and its history rows survive, so the output stays readable.
        for wt in dbWorktrees where !gitPaths.contains(wt.path) {
            try await tmux.withWorktreeServerLock(
                db: db, worktreeID: wt.id, allowedStatuses: [wt.status]
            ) { current in
                let terminals = try await db.terminals.list(worktreeID: current.id)
                var recordedEveryKill = true
                for terminal in terminals {
                    var row = ActuationRow(
                        actor: .daemon(rail: ActuationRail.reconcile), kind: .dispose)
                    row.target = .local(worktree: current.id, terminal: terminal.id)
                    guard let actuationID = try? await actuationLog.appendRequest(row) else {
                        recordedEveryKill = false
                        continue
                    }
                    await captureThenKillWindow(
                        terminal: terminal, server: current.tmuxServer)
                    await actuationLog.appendOutcome(
                        confirms: actuationID, result: .dispatched)
                }
                // A kill that could not be recorded did not happen, so the
                // rows still pointing at those windows must survive too.
                guard recordedEveryKill else {
                    logger.warning("reconcile: leaving \(current.id, privacy: .public) for the next sweep — the actuation record is unwritable, so its windows were not killed")
                    return
                }
                try await db.terminals.deleteForWorktree(worktreeID: current.id)
                try await db.tabs.deleteForWorktree(worktreeID: current.id)
                for terminal in terminals {
                    await pendingQuestions.clear(terminalID: terminal.id)
                    await subscriptions?.broadcastPendingQuestions(
                        terminalID: terminal.id, from: pendingQuestions)
                    ClaudeHookOverlay.removePerSessionOverlay(
                        sessionKey: terminal.id.uuidString)
                }
                try await db.worktrees.archive(id: current.id)
            }
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

        let allLiveWorktrees = try await db.worktrees.listLocal(repoID: repoID, status: .active)
            + (try await db.worktrees.listLocal(repoID: repoID, status: .main))
        try await reconcileTerminals(in: allLiveWorktrees, actuationLog: actuationLog)

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
        // Local rows only, at all three fetches below: the servers to visit and
        // the rows that keep one alive are both tmux facts, and a remote row
        // names no tmux server. Including one would put its empty server name
        // in `referencedServers` and make that same row count as a live
        // reference to it.
        let repoRows = try await db.worktrees.listLocal(repoID: repoID)
        var referencedServers = Set(repoRows.map(\.tmuxServer))
        referencedServers.insert(correctTmuxServer)
        // Full recovery also visits every server referenced by scratch rows
        // (repoID nil, archived included — the retired promoted-scratch row is
        // often the LAST pointer). Scratch spaces belong to no repo, so no
        // per-repo visit set would otherwise ever include their shared server
        // once the repo-side pointer is gone: `repo.remove` on a promoted repo
        // hard-deletes its main worktree row (deleteForRepo) — the only repo
        // row referencing the inherited scratch server — leaving that server,
        // and the removed repo's still-running windows on it, reachable by no
        // repo reconcile at all (#325-class leak). Callers that are not a full
        // recovery pass can exclude those shared servers explicitly.
        let scratchRows = try await db.worktrees.listLocal(scratchOnly: true)
        let scratchServers = Set(scratchRows.map(\.tmuxServer))
        if reapSharedScratchTmuxResources {
            referencedServers.formUnion(scratchServers)
        } else {
            // Protect current scratch pointers, the deterministic scratch
            // server, and inherited noncanonical repo servers whose retired
            // scratch source row may already be gone. Reinsert the repo's
            // canonical server last so its ordinary orphan cleanup still runs.
            let canonicalScratchServer = TmuxManager.serverName(
                forRepoPath: TBDConstants.scratchDir.path)
            let inheritedServers = Set(
                repoRows.map(\.tmuxServer).filter { $0 != correctTmuxServer })
            referencedServers.subtract(scratchServers)
            referencedServers.remove(canonicalScratchServer)
            referencedServers.subtract(inheritedServers)
            referencedServers.insert(correctTmuxServer)
        }
        try await reconcileTmuxResources(
            servers: referencedServers, sweepingRepoID: repoID, actuationLog: actuationLog)

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

    /// Reconcile active scratch-space terminals independently of registered
    /// repositories. Scratch spaces deliberately share a tmux server, so tmux
    /// may recycle one pane coordinate after an older scratch row survives.
    public func reconcileScratchTerminals(
        actuationLog: ActuationLog,
        reapOrphanTmuxResources: Bool
    ) async throws {
        let scratchWorktrees = try await db.worktrees.listLocal(
            status: .active, scratchOnly: true)
        try await reconcileTerminals(in: scratchWorktrees, actuationLog: actuationLog)

        // Hourly maintenance requests ownership repair only. Startup and
        // explicit cleanup also request external-resource recovery; that
        // destructive pass serializes with terminal creation per server.
        guard reapOrphanTmuxResources else { return }

        // Scratch rows have no repo, so the per-repo pass cannot be relied on
        // to visit their servers — particularly on installations with zero
        // registered repos. Prune stale terminal owners first, then let the
        // shared global-row sweep reclaim only windows nobody still owns.
        let allScratchWorktrees = try await db.worktrees.listLocal(scratchOnly: true)
        try await reconcileTmuxResources(
            servers: Set(allScratchWorktrees.map(\.tmuxServer)),
            sweepingRepoID: nil,
            actuationLog: actuationLog
        )
    }

    /// Reclaim tmux resources on the requested servers using ownership from
    /// every live local worktree row. A repo-initiated sweep records that repo;
    /// a scratch-only sweep has no repo to name and leaves it absent.
    private func reconcileTmuxResources(
        servers: Set<String>, sweepingRepoID: UUID?, actuationLog: ActuationLog
    ) async throws {
        for server in servers.sorted() {
            try await tmux.withServerResourceLock(server: server) {
                // Reclaim `tbd-ext-*` sessions before judging the server: the
                // branch below may kill the whole server, which would take
                // them with it, but only when nothing references it. A server
                // that stays alive is the case this pass exists for.
                await reapExternalAttachSessions(server: server)
                // Ownership must be read only after acquiring the same lock a
                // creator holds through its terminal-row commit.
                let globalLiveRows = try await db.worktrees.listLocal(excludeArchived: true)
                let liveRowsOnServer = globalLiveRows.filter { $0.tmuxServer == server }
                if liveRowsOnServer.isEmpty {
                    // Nothing references this server anymore. Skip silently
                    // when it isn't running (nothing to reap or kill — and
                    // archived rows keep pointing here forever, so this is
                    // the steady state on every later reconcile).
                    guard await tmux.serverExists(server: server) else { return }
                    // Nothing left names this server — that is why it is being
                    // killed — so the row is identified by what IS known: the
                    // server, and the repo whose sweep found it when there is
                    // one. The child reap is part of this disposal, not a
                    // second act.
                    var row = ActuationRow(
                        actor: .daemon(rail: ActuationRail.reconcile), kind: .dispose)
                    row.target = .tmux(server: server, repo: sweepingRepoID)
                    guard let actuationID = try? await actuationLog.appendRequest(row) else {
                        logger.warning("reconcile: skipped killing tmux server \(server, privacy: .public) — the actuation record is unwritable")
                        return
                    }
                    await reaper.reapServerChildren(server: server)
                    do {
                        try await tmux.killServer(server: server)
                        await actuationLog.appendOutcome(
                            confirms: actuationID, result: .dispatched)
                    } catch {
                        await actuationLog.appendOutcome(
                            confirms: actuationID,
                            result: .transportFailed,
                            error: "\(error)")
                        logger.warning("reconcile: failed to kill tmux server \(server, privacy: .public): \(error, privacy: .public)")
                    }
                } else {
                    // Collect window IDs tracked by ANY live worktree row on
                    // this server (all repos + scratch), then kill the
                    // untracked rest.
                    var trackedWindowIDs: Set<String> = []
                    for wt in liveRowsOnServer {
                        let terminals = try await db.terminals.list(worktreeID: wt.id)
                        for terminal in terminals {
                            trackedWindowIDs.insert(terminal.tmuxWindowID)
                        }
                    }

                    do {
                        let tmuxWindows = try await tmux.listWindows(
                            server: server, session: "main")
                        for window in tmuxWindows
                        where !trackedWindowIDs.contains(window.windowID) {
                            // No terminal row claims this window — that is what
                            // makes it an orphan — so the row names the server,
                            // window, and sweeping repo when there is one.
                            var row = ActuationRow(
                                actor: .daemon(rail: ActuationRail.reconcile), kind: .dispose)
                            row.target = .tmux(
                                server: server,
                                window: window.windowID,
                                repo: sweepingRepoID)
                            guard let actuationID = try? await actuationLog.appendRequest(row) else {
                                logger.warning("reconcile: skipped sweeping orphan window \(window.windowID, privacy: .public) on \(server, privacy: .public) — the actuation record is unwritable")
                                continue
                            }
                            let killFailure = await killWindowAndReap(
                                server: server,
                                windowID: window.windowID,
                                paneID: window.paneID
                            )
                            if let killFailure {
                                await actuationLog.appendOutcome(
                                    confirms: actuationID,
                                    result: .transportFailed,
                                    error: killFailure)
                            } else {
                                await actuationLog.appendOutcome(
                                    confirms: actuationID, result: .dispatched)
                            }
                        }
                    } catch {
                        logger.warning("reconcile: failed to list tmux windows for server \(server, privacy: .public): \(error, privacy: .public)")
                    }
                }
            }
        }
    }

    /// Reconcile terminals nothing can reach any more: a tmux row whose window
    /// is gone or no longer belongs to it, and a holder row whose holder is
    /// gone. All of them use the same established outcomes: park resumable
    /// Claude sessions and delete non-resumable Codex/shell rows.
    ///
    /// The two transports differ only in what "unreachable" is read off. tmux
    /// rows are judged by their window and pane; holder rows by the holder
    /// inventory, via `holderRowVerdict(for:)`.
    ///
    /// We deliberately do NOT eagerly recreate terminals on reboot: on a
    /// machine with many worktrees that spawned N simultaneous `claude
    /// --resume` processes (~0.5-1.5 GB each) and OOM'd the machine (#284).
    /// Lazy recreate-on-demand keeps idle worktrees as cheap suspended rows.
    private func reconcileTerminals(
        in worktrees: [LocalWorktree], actuationLog: ActuationLog
    ) async throws {
        // Read once per pass, not per row: the gate decides what this whole
        // sweep is allowed to do, and re-reading it mid-pass would let a flip
        // land between two rows of one judgement.
        let holderArmEnabled =
            (try? await db.config.get().holderRowReconcileEnabled)
            ?? Config.holderRowReconcileEnabledDefault
        // Read beside the arm's own gate and for the same reason: what a
        // finished holder session's row BECOMES is one judgement per pass, and
        // a flip landing between two rows would park one and delete its sibling
        // for no reason a reader could reconstruct.
        let holderHibernationEnabled =
            (try? await db.config.get().holderHibernationEnabled)
            ?? Config.holderHibernationEnabledDefault
        // The budget covers the pass, not one server: the arm is serial across
        // every server this call reconciles, so a per-server budget would
        // multiply by the server count exactly the way a per-probe timeout
        // multiplies by the row count.
        if holderArmEnabled {
            await holderProbeBudget.begin(Self.holderPhaseBudget, clock: clock)
        }
        // `end()` has to run on every exit, including the throwing one: the
        // budget's timer is what makes `begin` a no-op while a pass is running,
        // so a pass that walked away from its own timer would leave every later
        // pass reading a spent budget. `defer` cannot await, so the throw is
        // caught and rethrown instead.
        do {
            try await reconcileTerminalsWhileLockedPerServer(
                in: worktrees, actuationLog: actuationLog,
                holderArmEnabled: holderArmEnabled,
                holderHibernationEnabled: holderHibernationEnabled)
        } catch {
            await holderProbeBudget.end()
            throw error
        }
        await holderProbeBudget.end()
    }

    /// The per-server half of `reconcileTerminals`, split out only so its
    /// caller can bracket it with the pass's probe budget.
    private func reconcileTerminalsWhileLockedPerServer(
        in worktrees: [LocalWorktree], actuationLog: ActuationLog, holderArmEnabled: Bool,
        holderHibernationEnabled: Bool
    ) async throws {
        let grouped = Dictionary(grouping: worktrees, by: \.tmuxServer)
        for server in grouped.keys.sorted() {
            let candidates = grouped[server] ?? []
            try await tmux.withServerResourceLock(server: server) {
                var currentWorktrees: [LocalWorktree] = []
                for candidate in candidates {
                    guard let current = try await db.worktrees.getLocal(id: candidate.id),
                          current.tmuxServer == server else { continue }
                    currentWorktrees.append(current)
                }
                try await reconcileTerminalsWhileLocked(
                    in: currentWorktrees, actuationLog: actuationLog,
                    holderArmEnabled: holderArmEnabled,
                    holderHibernationEnabled: holderHibernationEnabled)
            }
        }
    }

    /// Ownership probing while the caller holds the server resource lock.
    ///
    /// The lock is a *tmux server* lock, which is why the holder arm does not
    /// depend on it: a holder row's ground truth is its own rendezvous, and
    /// holding this lock neither protects nor delays it.
    private func reconcileTerminalsWhileLocked(
        in worktrees: [LocalWorktree], actuationLog: ActuationLog,
        holderArmEnabled: Bool,
        holderHibernationEnabled: Bool
    ) async throws {
        // Probe the server each worktree row actually stores, not a canonical
        // name. Promoted scratch worktrees keep their inherited scratch server.
        // Cached per server name — rows overwhelmingly share one server.
        //
        // The probe is tri-state on purpose. A `Bool` probe reports a timed-out
        // tmux as "gone", and both arms below destroy state on "gone", so a
        // machine merely busy enough to blow the 15 s command ceiling used to
        // park a live fleet — 49 of 56 lane sessions in one measured pass on
        // 2026-09-02. `unknown` is ignorance, not evidence: it parks nothing,
        // deletes nothing, and leaves the row for the next sweep.
        var serverPresenceByName: [String: TmuxPresence] = [:]
        for wt in worktrees {
            let serverPresence: TmuxPresence
            if let cached = serverPresenceByName[wt.tmuxServer] {
                serverPresence = cached
            } else {
                serverPresence = await tmux.probeServer(server: wt.tmuxServer)
                serverPresenceByName[wt.tmuxServer] = serverPresence
            }
            if serverPresence == .unknown {
                logger.warning("reconcile: skipping worktree \(wt.id, privacy: .public) — tmux server \(wt.tmuxServer, privacy: .public) gave no usable answer (probeServer: unknown); leaving its terminals alone")
                continue
            }
            let terminals = try await db.terminals.list(worktreeID: wt.id)
            // Parked rows (`hibernatedAt` OR legacy `suspendedAt` — see
            // `isParked`) are skipped: a parked terminal's window being gone
            // is expected, and the row is already exactly what this pass would
            // produce.
            for terminal in terminals where !terminal.isParked {
                // **Two transports, one fork.** Each arm establishes the
                // same fact in its own vocabulary — nothing can reach this
                // session any more — and then hands it to the shared
                // park-or-delete outcome below.
                //
                // A holder-backed row carries no tmux coordinate at all: its
                // `tmuxWindowID` is "" and the repo's tmux server may never
                // have been created, so `windowExists` could only ever answer
                // "gone" for it, and the tmux arm would destroy a live session
                // on the very daemon restart the transport exists to survive.
                // Its ground truth is the holder inventory instead
                // (`docs/specs/2026-08-30-pty-holder-session-transport-design.md`,
                // "Reconciliation"), which is what `holderRowVerdict(for:)`
                // reads.
                let disposal: String
                switch terminal.transport {
                case .holder:
                    // The gate, and the same `continue` the old exemption
                    // took. Off — the shipped default — this arm establishes
                    // nothing and moves nothing, so a holder row is exactly as
                    // untouched as it was before the arm existed.
                    guard holderArmEnabled else {
                        logger.debug("reconcile: leaving holder-backed terminal \(terminal.id, privacy: .public) alone — holder_row_reconcile_enabled is off")
                        continue
                    }
                    switch await holderRowVerdict(for: terminal) {
                    case .keep(let reason):
                        logger.debug("reconcile: keeping holder-backed terminal \(terminal.id, privacy: .public) — \(reason, privacy: .public)")
                        continue
                    case .sessionOver(let status):
                        disposal = "its holder is gone and its job "
                            + Self.jobEndingDescription(status)
                    }

                case .tmux:
                    // A server that is positively absent has positively no
                    // windows on it, so the window probe is skipped rather than
                    // guessed at.
                    var windowPresence: TmuxPresence = .absent
                    if serverPresence == .alive {
                        windowPresence = await tmux.probeWindow(
                            server: wt.tmuxServer, windowID: terminal.tmuxWindowID)
                    }
                    if windowPresence == .unknown {
                        logger.warning("reconcile: skipping terminal \(terminal.id, privacy: .public) in worktree \(wt.id, privacy: .public) — window \(terminal.tmuxWindowID, privacy: .public) on server \(wt.tmuxServer, privacy: .public) gave no usable answer (probeWindow: unknown); leaving the row live")
                        continue
                    }
                    let windowAlive = windowPresence == .alive

                    if windowAlive {
                        do {
                            switch try await tmux.paneSendTarget(
                                server: wt.tmuxServer, paneID: terminal.tmuxPaneID)
                            {
                            case .live(let paneTerminalID), .dead(let paneTerminalID):
                                if let paneTerminalID {
                                    let paneBelongsToDifferentTerminal =
                                        paneTerminalID.caseInsensitiveCompare(
                                            terminal.id.uuidString) != .orderedSame
                                    if !paneBelongsToDifferentTerminal { continue }
                                } else {
                                    // Panes predating the identity stamp remain
                                    // attributed for backward compatibility.
                                    continue
                                }
                            case .missing:
                                break
                            }
                        } catch {
                            // An unreadable identity is not evidence of staleness.
                            // Keep the row and let a later sweep retry the probe.
                            logger.warning("reconcile: failed to inspect pane ownership for terminal \(terminal.id, privacy: .public): \(error, privacy: .public)")
                            continue
                        }
                    }

                    // Preserve the existing extra safety when the window probe
                    // itself says a Claude window is gone: if Claude is still
                    // running, retain the row. A pane that answered `.missing` or
                    // with another terminal's identity is already definitive, so
                    // never inspect its current command. An owned dead pane
                    // continued above because remain-on-exit makes it an intended
                    // readable gravestone.
                    if terminal.isClaudeResumable && !windowAlive {
                        if let cmd = try? await tmux.paneCurrentCommand(
                            server: wt.tmuxServer, paneID: terminal.tmuxPaneID),
                           ClaudeStateDetector.isClaudeProcess(cmd) {
                            logger.warning("reconcile: terminal \(terminal.id, privacy: .public) window marked dead but claude process still running — skipping park")
                            continue
                        }
                    }
                    disposal = "window \(terminal.tmuxWindowID) gone or reassigned"
                }

                // **What a finished session's row becomes is one rule with one
                // per-transport condition.** A resumable Claude row is PARKED,
                // preserving its session id for a later wake; anything else is
                // deleted, because there is nothing to preserve.
                //
                // The holder transport joins that rule only when
                // `holder_hibernation_enabled` is on, and the reason is that a
                // parked row is only worth having if something can wake it.
                // With the gate off `HibernationCoordinator.wake` refuses a
                // holder row, and this sweep skips parked rows, so a parked
                // holder row would never be judged again — while the app's
                // focus-wake selects exactly `isParked && isClaudeResumable &&
                // hibernateReason != .manual` and would fire a failing wake RPC
                // on every focus of that worktree, forever. Deleting says the
                // true thing in that state. With the gate on, the wake path
                // exists and the park is worth exactly what it is worth on
                // tmux.
                let parkable = terminal.isClaudeResumable
                    && (terminal.transport != .holder || holderHibernationEnabled)
                if parkable, let sessionID = terminal.claudeSessionID {
                    // This park bypasses `HibernationCoordinator`, so the
                    // reconcile rail records its own independent actuation.
                    // Fail closed if that authoritative record cannot be made.
                    var row = ActuationRow(
                        actor: .daemon(rail: ActuationRail.reconcile), kind: .hibernate)
                    row.target = .local(worktree: wt.id, terminal: terminal.id)
                    guard let actuationID = try? await actuationLog.appendRequest(row) else {
                        logger.warning("reconcile: skipped parking terminal \(terminal.id, privacy: .public) — the actuation record is unwritable")
                        continue
                    }
                    do {
                        try await db.terminals.setHibernated(
                            id: terminal.id, sessionID: sessionID, reason: .recovery)
                        // A parked holder row names no processes. The holder
                        // and its job are already gone — that is what
                        // `.sessionOver` established — so leaving their pids on
                        // the row would point the reaper's holder leg and every
                        // identity check at numbers the kernel has recycled.
                        if terminal.transport == .holder {
                            try await db.terminals.setHolderProcess(
                                id: terminal.id, holderPID: nil, childPID: nil, startedAt: nil)
                        }
                        await actuationLog.appendOutcome(
                            confirms: actuationID, result: .dispatched)
                    } catch {
                        await actuationLog.appendOutcome(
                            confirms: actuationID, result: .transportFailed, error: "\(error)")
                    }
                    logger.info("reconcile: parked terminal \(terminal.id, privacy: .public) — \(disposal, privacy: .public), session \(sessionID, privacy: .public) preserved, wakeable via the unified resume path")
                } else {
                    try? await db.deleteTerminalAndTab(id: terminal.id)
                    logger.info("reconcile: deleted terminal \(terminal.id, privacy: .public) — \(disposal, privacy: .public), \(Self.deletionRationale(for: terminal, holderHibernationEnabled: holderHibernationEnabled), privacy: .public)")
                }
                await pendingQuestions.clear(terminalID: terminal.id)
                await subscriptions?.broadcastPendingQuestions(
                    terminalID: terminal.id, from: pendingQuestions)
            }
        }
    }

    // MARK: - The holder inventory

    /// How long one holder gets to answer the reconcile probe.
    ///
    /// The same two seconds `HolderRendezvousCollector.probeTimeout` and
    /// `RowlessHolderCollector.handshakeTimeout` allow, for the same reason: a
    /// stranger that connects and then says nothing must not stall a sweep that
    /// may have hundreds of rows behind it.
    static let holderProbeTimeout: Duration = .seconds(2)

    /// How long the holder arm gets across one `reconcileTerminals` call.
    ///
    /// The same five seconds `HolderRegistry.defaultAdoptAllBudget` allows,
    /// because per pass it is the same trade against the same per-probe
    /// timeout. **It is not the same ceiling, and a reader comparing the two
    /// must not read parity into the number.** `begin`/`end` bracket one
    /// `reconcileTerminals` call, and `performStartupReconciliation` makes one
    /// `reconcile(repoID:)` call per repo plus one `reconcileScratchTerminals`
    /// — each its own pass, each with its own budget. So what this constant
    /// implies before the socket is bound is `(repos + 1) × 5 s`, about 45 s on
    /// an eight-repo install whose rendezvous sockets all listen and never
    /// answer, where `adoptAllBudget` is a single 5 s across every holder row
    /// on the machine.
    ///
    /// **Per pass rather than hoisted around startup, deliberately.** The arm
    /// has callers startup does not own — `repo.add`
    /// (`RPCRouter+RepoHandlers`), the `cleanup` RPC and the hourly
    /// `performOrphanMaintenance` (`Daemon.swift`, scratch rows)
    /// — and a budget begun inside `performStartupReconciliation` would bound
    /// none of them. Those callers run after the socket is bound, so their
    /// stake is an RPC handler rather than startup, but a serial arm with no
    /// bound at all is what this exists to prevent wherever it runs.
    ///
    /// For the same reason the arm is not simply reordered to run after
    /// `HolderRegistry.adoptAll` and lean on *its* budget: adoption precedes
    /// none of those callers. And even where it does precede a pass, the rows
    /// adoption's own budget deferred, rows a foreign owner answered for and
    /// rows a busy holder refused all leave no remembered status behind, so
    /// they reach the probe below and need bounding regardless.
    ///
    /// See `HolderProbeBudget` for why a per-probe timeout is not a bound on a
    /// pass at all.
    static let holderPhaseBudget: Duration = .seconds(5)

    /// Why the sweep deleted a row rather than parking it, for the one log line
    /// that records the judgement.
    ///
    /// Composed by a named function so a test can pin the text: the two
    /// deletions are not the same event, and a line that told a
    /// holder-transport Claude row it had "no session to preserve" would be
    /// false about the one row shape whose park was withheld by a soak gate
    /// rather than by having nothing worth keeping.
    static func deletionRationale(
        for terminal: Terminal, holderHibernationEnabled: Bool
    ) -> String {
        guard terminal.transport == .holder, !holderHibernationEnabled,
            terminal.isClaudeResumable, terminal.claudeSessionID != nil
        else { return "no session to preserve" }
        return "holder hibernation is off, so a parked holder row would have nothing to wake it"
    }

    /// How a finished session's job ended, in words, for the one log line that
    /// records the sweep's judgement.
    ///
    /// `exitedStatusUnknown` says so in as many words rather than borrowing
    /// `0`: an exit nobody observed is not a clean exit, and a fabricated code
    /// would be indistinguishable from a real one to everything that reads it.
    static func jobEndingDescription(_ status: HolderChildStatus) -> String {
        switch status {
        case .alive: return "was still running when it was last seen"
        case .exited(let code): return "exited with status \(code)"
        case .exitedStatusUnknown: return "ended with a status nobody collected"
        }
    }

    /// What one handshake against a holder's rendezvous says about its row.
    ///
    /// Separate from the probe around it so the classification can be pinned
    /// answer by answer without standing up a holder — and, more importantly,
    /// so the error half is `HolderRegistry.exitProbeOutcome(for:)` itself
    /// rather than a **fifth** copy of the same errno rules. Those rules are
    /// already read in three places (`exitProbeOutcome`,
    /// `RowlessHolderCollector.productionHandshake`,
    /// `HolderRendezvousCollector.probeForListener`), all of which must agree
    /// that only `ENOENT` and `ECONNREFUSED` are evidence of absence; a copy
    /// here is how they would drift.
    ///
    /// `retry` and `keep` collapse to the same answer, and that is not a lost
    /// distinction. They differ only in whether asking again could help, and
    /// this sweep asks once — the next reconcile *is* the retry. Neither
    /// establishes anything, so neither may move a row.
    ///
    /// **A rejected connection is terminal in both directions.** It classifies
    /// as `keep`, so the row is not marked exited; and nothing here signals or
    /// unlinks anything, so it is not reclaimed either. A live holder serving
    /// somebody else — a stale daemon from another checkout is the known hazard
    /// on a development machine — is left alone and logged.
    static func holderRowVerdict(
        expecting owner: HolderOwnerToken,
        describing describe: () async throws -> HolderChildDescription
    ) async -> HolderRowVerdict {
        do {
            let description = try await describe()
            // A completed handshake is proof of liveness, not of ownership.
            // The default `TBD_HOME` is shared by every checkout on a machine,
            // so a holder that answers may be another installation's perfectly
            // healthy session, and nothing about it may decide one of our rows.
            guard description.owner == owner else { return .keep(reason: "foreign-owner") }
            switch description.status {
            case .alive:
                return .keep(reason: "alive")
            case .exited, .exitedStatusUnknown:
                // Carried through exactly as reported. A holder that answers
                // with a real code gives a real code; one that could not
                // observe its child gives `exitedStatusUnknown`, and the two
                // must stay distinguishable downstream.
                return .sessionOver(description.status)
            }
        } catch {
            switch HolderRegistry.exitProbeOutcome(for: error) {
            case .established(let status):
                return .sessionOver(status)
            case .retry, .keep:
                return .keep(reason: keepReason(for: error))
            }
        }
    }

    /// What one *connection* to a holder's rendezvous says about its row, for
    /// the rows a `describe` may not be asked about.
    ///
    /// **A connect establishes absence and nothing else, which is the point.**
    /// A holder winds itself down the moment an answer carrying the terminal
    /// status reaches a client, so describing a session whose master this
    /// daemon has never taken would end that holder and take the output its job
    /// wrote and nobody read with it — the rule
    /// `HolderRegistry.confirmChildExit` states, and the reason adoption asks
    /// for the hand-over rather than a description. Connecting asks for nothing
    /// that could be an answer, so it cannot collect the exit it is looking
    /// for — near-absolutely rather than absolutely: `Holder.run`'s reaping
    /// branch speaks first to whatever client is connected, so a child that
    /// exits inside the few milliseconds this probe is attached can still be
    /// collected by it. That window is a race with the child's own exit, not a
    /// question this daemon asked, and it is narrower than a `describe` by the
    /// whole life of the session.
    ///
    /// What that costs is the *fidelity* of the positive case: a holder that is
    /// alive with an exited child reads as `keep` here, where a `describe`
    /// would have carried a real exit code back. That is the right trade — the
    /// row is judged on the next daemon start, whose adoption takes the master
    /// first and records the status honestly, and until then the screen is
    /// still there to hand a viewer.
    ///
    /// The failure half is `HolderRegistry.exitProbeOutcome(for:)`, exactly as
    /// the describing verdict's is, so absence means the same thing whichever
    /// probe observed it.
    static func holderListenerVerdict(
        connecting connect: () async throws -> Void
    ) async -> HolderRowVerdict {
        do {
            try await connect()
            // Something is bound to that path and accepting. Whose it is and
            // what its child is doing were not asked and are not known.
            return .keep(reason: "listening")
        } catch {
            switch HolderRegistry.exitProbeOutcome(for: error) {
            case .established(let status):
                return .sessionOver(status)
            case .retry, .keep:
                return .keep(reason: keepReason(for: error))
            }
        }
    }

    /// The *label* a kept row carries into the log, and only the label — the
    /// decision was `exitProbeOutcome`'s.
    ///
    /// Distinguishing a busy holder from an unreadable one is what makes a soak
    /// legible, the same reason `RowlessHolderHandshake` keeps `rejected` and
    /// `unreachable` apart although both mean "leave it alone".
    private static func keepReason(for error: Swift.Error) -> String {
        if case HolderClient.Error.rejected = error { return "rejected" }
        return "unestablished"
    }

    /// Whether this daemon can establish that a holder-backed row's session is
    /// over — the inventory direction of the holder reconciler, and the sweep
    /// the tmux arm's exemption was holding a place for.
    ///
    /// Every gate fails toward keeping, and the order is the argument:
    ///
    ///   1. **No registry, no opinion.** A daemon with no `HolderRegistry`
    ///      (mock mode, a test that does not exercise the transport) knows
    ///      nothing about holders and may not judge their rows.
    ///   2. **A viewer owning the pty ends it.** After `confirmAttach` the app
    ///      holds the descriptor and the daemon has no reader at all, so the
    ///      probes below would be asking about a session somebody is looking
    ///      at.
    ///   3. **A live reader ends it.** The daemon is draining this pty right
    ///      now. That stays true after the job exits, deliberately: a drained
    ///      screen is a readable gravestone, exactly as an owned dead tmux pane
    ///      is on the other arm, and it is released by
    ///      `reclaimIfSessionEnded` rather than by this sweep.
    ///   4. **A terminal status already recorded ends the questioning.** A
    ///      holder winds itself down the moment an answer carrying the status
    ///      reaches a client, so once one has there is nobody left to ask.
    ///   5. **Otherwise, ask the rendezvous — and *what* is asked depends on
    ///      whether this daemon has ever taken the master.** A row the registry
    ///      remembers as `.alive` was handed over, so a `describe` costs it
    ///      nothing and gives a real exit code. A row it remembers nothing
    ///      about may still be a holder sitting on output nobody has drained,
    ///      and describing it would collect the exit, wind the holder down and
    ///      destroy exactly the screen the handover exists to preserve — so
    ///      that row gets `holderListenerVerdict`, which asks nothing.
    ///
    /// Every probe is additionally under the pass's `HolderProbeBudget`: gates
    /// 1-4 are dictionary reads and always run, and a pass that has spent its
    /// budget keeps the rest rather than opening more sockets before the
    /// daemon's own is bound.
    ///
    /// The last gate is the one that is not about the holder at all. **A row
    /// whose job is still running is kept even when its holder is provably
    /// gone**, because that row is the only record of the child pid, and
    /// `AgentReaper.sweepHolderChildren` — the named reconciler for a job whose
    /// holder died — reads exactly that record. Deleting the row here would
    /// reclaim an inventory entry and strand the process it named, which is the
    /// hazard `HolderRegistry.killJob`'s doc comment describes. So this sweep
    /// signals nothing, ever.
    ///
    /// **Naming that contingency honestly: the loop does not always close.**
    /// The reaper leg this gate waits for is itself gated on
    /// `reapHolderChildrenEnabled`, which ships off, so on the shipped defaults
    /// nothing ever kills the job and the row is kept for as long as the pid is
    /// alive. Even with both flags on, the reaper keeps rather than signals
    /// whenever identity is uncertain — `holder-unrecorded`,
    /// `start-time-mismatch`, `foreign-executable` — and each of those is a
    /// permanent keep here too. A pid the row names that has been reused by a
    /// stranger therefore keeps the row indefinitely instead of killing that
    /// stranger. That is the direction to fail in, and a kept row is a visible
    /// session the user can close by hand.
    func holderRowVerdict(for terminal: Terminal) async -> HolderRowVerdict {
        guard let holderRegistry else { return .keep(reason: "no-holder-registry") }
        if await holderRegistry.viewerAttachment(for: terminal.id) != nil {
            return .keep(reason: "viewer-attached")
        }
        if await holderRegistry.reader(for: terminal.id) != nil {
            return .keep(reason: "reader-live")
        }

        let verdict: HolderRowVerdict
        let lastKnown = await holderRegistry.lastKnownStatus(for: terminal.id)
        switch lastKnown {
        // Established without a round trip, and by the same rule the probe
        // uses: this is what a holder said, or what its absence said, and
        // neither becomes less true for being remembered.
        //
        // **That claim is a claim about provenance, and it is enforced at the
        // writes rather than assumed here.** A status is recorded at four
        // sites: `HolderRegistry.spawn` and the hand-over inside `adopt`
        // (`beginAdoption`), both answers a holder gave; `adoptOne`, which
        // brands only the `exitProbeOutcome`-established errnos — the same
        // `ENOENT` and `ECONNREFUSED` the probes below read as absence; and
        // `reclaimIfSessionEnded`, whose value is either an already-remembered
        // terminal status or `confirmChildExit`'s return, and
        // `confirmChildExit` itself returns only a `describe` answer or
        // `exitProbeOutcome`'s `.established` — so it satisfies the same
        // answer-or-absence property rather than being exempt from it.
        // (`abandon` also touches this dictionary, but only to clear it to nil
        // on teardown; that is direction-safe and not a write of a status.) A
        // round trip that merely timed out records nothing at any of these
        // sites, so it cannot reach this gate: it would otherwise delete the
        // row and tab of a holder that is alive but slow. The childPID gate
        // below still keeps a row whose job is provably still running, so
        // what that would actually cost is narrower than ending a live
        // session outright: a wedged holder whose child had already exited
        // would lose its row, its tab, and the undrained gravestone screen,
        // with the holder reclaimed. Reaching a genuinely live session would
        // additionally require that gate to miss — a null `childPID`, or a
        // liveness probe reading false — and the holder to unwedge before
        // `RowlessHolderCollector` can `describe` it.
        case .exited(let code):
            verdict = .sessionOver(.exited(code: code))
        case .exitedStatusUnknown:
            verdict = .sessionOver(.exitedStatusUnknown)
        case .alive, nil:
            // A remembered `.alive` is a status this daemon was *given*, which
            // it is given only on a hand-over. So it doubles as the record that
            // the master has been taken and a `describe` costs this session
            // nothing; `nil` is the absence of that record.
            let handedOver = lastKnown != nil
            guard await !holderProbeBudget.isSpent else {
                return .keep(reason: "phase-budget-spent")
            }
            guard
                let socketPath = try? HolderRendezvous.socketPath(
                    sessionID: terminal.id, environment: holderRegistry.environment)
            else { return .keep(reason: "unrepresentable-rendezvous") }
            let client = HolderClient(
                socketPath: socketPath, receiveTimeout: Self.holderProbeTimeout)
            if handedOver {
                verdict = await Self.holderRowVerdict(expecting: holderRegistry.owner) {
                    try await client.describe()
                }
            } else {
                verdict = await Self.holderListenerVerdict {
                    try await client.connectOnly()
                }
            }
            await client.close()
        }

        guard case .sessionOver = verdict else { return verdict }
        if let childPID = terminal.childPID, childPID > 1,
           processSignaller.isAlive(childPID) {
            return .keep(reason: "job-still-running")
        }
        return verdict
    }

    /// Reclaim the external-attach sessions on one tmux server.
    ///
    /// `tbd terminal attach` mints a `tbd-ext-<tid8>` session per terminal so
    /// an external emulator can be a second client on a TBD window. Those
    /// sessions are a durable external resource, so they get a named
    /// reconciler, and this is it. `destroy-unattached on` reclaims the
    /// ordinary case the instant the last client leaves; this pass carries
    /// every case that option misses.
    ///
    /// Candidates are exactly the names `ExternalAttachCommand` mints —
    /// `isGeneratedSessionName`, the prefix followed by eight lowercase hex
    /// digits — so TBD's own panel sessions (`tbd-view-*`), the daemon's
    /// `main`, and any hand-made session are out of scope. The prefix alone
    /// would not do it: a hand-made `tbd-ext-notes` matches the prefix, and a
    /// hand-made `tbd-ext-aa ; kill-server` would be fed to the conditional
    /// kill, whose inner command tmux re-parses and splits on `;` — see
    /// `TmuxManager.killSessionIfClientlessCommand`. Killing a session does
    /// not disturb the terminal: its window is `link-window`ed from `main` and
    /// survives.
    ///
    /// The 60-second grace period is the point, not a courtesy — see
    /// `ExternalAttachReclamation.gracePeriod`, which also explains why the
    /// clock lives on the tmux session rather than in this process.
    func reapExternalAttachSessions(server: String) async {
        let sessions: [TmuxSessionInfo]
        do {
            sessions = try await tmux.listSessions(server: server)
        } catch {
            // A server that will not answer is not evidence about any session
            // on it. Leave every stamp standing and retry next sweep.
            logger.debug("reconcile: could not list sessions on \(server, privacy: .public) for external-attach reclamation: \(error, privacy: .public)")
            return
        }
        let observedAt = now()
        for session in sessions
        where ExternalAttachCommand.isGeneratedSessionName(session.name) {
            switch ExternalAttachReclamation.decide(session: session, now: observedAt) {
            case .leaveAlone:
                continue
            case .stamp(let date):
                do {
                    try await tmux.setExternalAttachClientlessSince(
                        server: server, session: session.name, date: date)
                } catch {
                    logger.debug("reconcile: could not stamp external attach session \(session.name, privacy: .public) on \(server, privacy: .public): \(error, privacy: .public)")
                }
            case .clearStamp:
                do {
                    try await tmux.clearExternalAttachClientlessSince(
                        server: server, session: session.name)
                } catch {
                    logger.debug("reconcile: could not clear the client-less stamp on external attach session \(session.name, privacy: .public) on \(server, privacy: .public): \(error, privacy: .public)")
                }
            case .reap:
                do {
                    // Conditional, decided inside tmux: a client that attached
                    // between the listing above and this call keeps its session
                    // rather than being disconnected mid-measurement.
                    let killed = try await tmux.killSessionIfClientless(
                        server: server, session: session.name)
                    guard killed else {
                        logger.debug("reconcile: spared external attach session \(session.name, privacy: .public) on \(server, privacy: .public) — a client attached after it was listed")
                        continue
                    }
                    logger.info("\(Self.externalAttachReapLogLine(server: server, session: session.name), privacy: .public)")
                } catch {
                    logger.warning("reconcile: failed to kill external attach session \(session.name, privacy: .public) on \(server, privacy: .public): \(error, privacy: .public)")
                }
            }
        }
    }

    /// The line `reapExternalAttachSessions` logs for each session it kills.
    ///
    /// Composed by a named function so a test can assert the exact text: the
    /// spec requires the reap to be *detectable afterwards*, so that a
    /// truncated measurement run is distinguishable from a quiet one, and a
    /// line that stopped naming its session would defeat that silently.
    static func externalAttachReapLogLine(server: String, session: String) -> String {
        "reconcile: killed external attach session \(session) on tmux server \(server) — no client had been attached to it for at least \(Int(ExternalAttachReclamation.gracePeriod))s"
    }

    /// The recurring driver for external-attach reclamation, called from the
    /// daemon's hourly orphan-maintenance cadence.
    ///
    /// Reclamation needs a periodic caller of its own. The other entry points
    /// into `reapExternalAttachSessions` are startup, `repo.add`, and the
    /// `cleanup` RPC — none of which recur — so a session abandoned by a failed
    /// attach would sit on the server until the daemon next restarted. The
    /// hourly cadence is defensible because this pass is a **backstop**:
    /// `destroy-unattached on` reclaims the ordinary case the instant the last
    /// client detaches, and a terminal-keyed name bounds the population at one
    /// session per terminal in the meantime. Worst case is therefore about an
    /// hour for a never-attached orphan (one observation decides it), and about
    /// two for the rarer session that was attached, detached, and outlived its
    /// `destroy-unattached` — that one needs a sweep to stamp and a later sweep
    /// to act.
    ///
    /// Sweeps every server named by a live local worktree row: `tbd-ext-*`
    /// sessions only ever exist on a server that hosts a TBD terminal. Takes
    /// the same per-server resource lock the reconcile call site holds, which
    /// is why `reapExternalAttachSessions` itself does not (the coordinator is
    /// not reentrant).
    public func reclaimExternalAttachSessions() async {
        let servers: Set<String>
        do {
            servers = Set(try await db.worktrees.listLocal(excludeArchived: true)
                .map(\.tmuxServer))
        } catch {
            logger.warning("Failed to list worktrees for external-attach reclamation: \(error.localizedDescription, privacy: .public)")
            return
        }
        for server in servers.sorted() {
            await tmux.withServerResourceLock(server: server) {
                await reapExternalAttachSessions(server: server)
            }
        }
    }

    /// Whether `server` hosts a live tmux window for any of `worktreeID`'s
    /// terminal rows — `alive`, `absent`, or `unknown`.
    ///
    /// Used by the stale-server self-heal to distinguish a genuinely
    /// dead/renamed server (safe to canonicalize) from a deliberately
    /// inherited one whose sessions are still running (promoted scratch
    /// space).
    ///
    /// **This is tri-state for the same reason the terminal sweep is, and the
    /// two are load-bearing together.** A `Bool` here reads a timed-out probe
    /// as "no live window", the row is re-pointed at the canonical server, and
    /// the terminal sweep then probes windows on a server that genuinely does
    /// not have them. Its answer is an honest `absent`, so the sweep's own
    /// `unknown` guard never fires and the rows are parked and deleted on
    /// evidence that was manufactured one pass earlier. Hardening the sweep
    /// alone would have left that route open.
    ///
    /// `alive` on the first affirmative live window. Otherwise `unknown` if
    /// any probe failed to answer, and `absent` only when every probe answered
    /// and answered no.
    ///
    /// Rows carrying no tmux coordinate at all (holder-backed sessions, whose
    /// `tmuxWindowID` is `""`) are skipped rather than probed: they are
    /// evidence in neither direction, and probing `""` would answer `unknown`
    /// forever and freeze the self-heal.
    private func liveWindowPresence(server: String, worktreeID: UUID) async -> TmuxPresence {
        switch await tmux.probeServer(server: server) {
        case .absent:
            return .absent
        case .unknown:
            return .unknown
        case .alive:
            break
        }
        let terminals = (try? await db.terminals.list(worktreeID: worktreeID)) ?? []
        var sawUnknown = false
        for terminal in terminals where !terminal.tmuxWindowID.isEmpty {
            switch await tmux.probeWindow(server: server, windowID: terminal.tmuxWindowID) {
            case .alive:
                return .alive
            case .unknown:
                sawUnknown = true
            case .absent:
                continue
            }
        }
        return sawUnknown ? .unknown : .absent
    }
}
