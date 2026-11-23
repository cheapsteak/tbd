import Foundation
import os
import TBDShared
import TBDKernel

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
/// `performStartupReconciliation`, before the socket is bound. That is the
/// failure `HolderRegistry.adoptAllBudget`
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
///
/// **Passes overlap, so the clock is shared and counted.** The sweep's callers
/// run independently of each other — the hourly scratch pass, `repo.add`, the
/// `cleanup` RPC, and the reaper's hand-back of a single row
/// (`reconcileHolderRowAfterJobGone`) — and the hourly pass and the reaper
/// both make their first run as the daemon starts. A pass that begins while
/// another is running joins its clock, and the clock stops only when the last
/// pass on it ends, so a pass that finishes first cannot take the bound off
/// one that is still probing.
///
/// **Each clock spends only its own passes.** Cancelling a timer cannot stop
/// one whose sleep has already returned, so its expiry can reach the actor
/// after the last pass on its clock has ended and a new pass has started
/// another. Every clock carries a generation, and an expiry from any but the
/// running one is ignored.
actor HolderProbeBudget {
    private var spent = false
    private var timer: Task<Void, Never>?
    /// How many passes are between `begin` and `end` right now.
    private var passes = 0
    /// The running clock's generation, bumped each time `begin` starts one.
    private var generation = 0

    /// Starts the clock for one pass. A call while a pass is running starts no
    /// new clock: the pass shares the running one's budget rather than
    /// silently granting itself a fresh one.
    func begin(_ budget: Duration, clock: any Clock<Duration>) {
        passes += 1
        guard timer == nil else { return }
        spent = false
        generation += 1
        let clockGeneration = generation
        timer = Task { [weak self] in
            do {
                try await clock.sleep(for: budget)
            } catch {
                // Cancelled because the pass finished inside its budget.
                return
            }
            await self?.expire(clockGeneration)
        }
    }

    /// Ends one pass, and cancels the timer when it was the last pass on it.
    /// Safe to call when no pass is running.
    func end() {
        guard passes > 0 else { return }
        passes -= 1
        guard passes == 0 else { return }
        timer?.cancel()
        timer = nil
    }

    /// Whether the current pass has already spent its budget.
    var isSpent: Bool { spent }

    /// The running clock's timer, so a test can join it and know its expiry
    /// has run. Nil when no clock is running.
    var timerForTesting: Task<Void, Never>? { timer }

    /// Spends the budget, unless `clockGeneration` names a clock that has
    /// already stopped: its passes are over, and the passes running now are
    /// another clock's to spend.
    private func expire(_ clockGeneration: Int) {
        guard clockGeneration == generation else { return }
        spent = true
    }
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
        let resolvedTips = try? await git.refTips(repoPath: repo.path)
        let tips = resolvedTips ?? [:]
        let baseTip = tips["origin/\(repo.defaultBranch)"]
        await conflictSweepCache.retain(repoID: repoID, worktreeIDs: Set(worktrees.map(\.id)))

        // PR-poll trigger: a push moves `origin/<branch>`, and that makes the
        // worktree's PR check due now. The local tip is deliberately ignored —
        // a check before the push is wasted. Same tips map, no subprocess.
        //
        // Skipped when `refTips` failed: the empty map would read as "no
        // remote ref" for every worktree, and a first sighting recorded that
        // way is a nil baseline the next good sweep reports as a push — a
        // trigger burst across the repo for nothing.
        await remoteTipTracker.retain(repoID: repoID, worktreeIDs: Set(worktrees.map(\.id)))
        if resolvedTips != nil {
            for wt in worktrees {
                await remoteTipTracker.observe(worktreeID: wt.id, remoteTip: tips["origin/\(wt.branch)"])
            }
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
    /// - Worktrees in git under one of TBD's pool prefixes but with no row: left
    ///   alone and reported in the log. TBD does not take ownership of a tree it
    ///   did not create, because its lifecycle can delete the directory (archive)
    ///   or reap it; `tbd worktree adopt <path>` is how a user opts a tree in.
    ///   The foreign-worktree sweep (`scripts/sweep-foreign-worktrees.sh`)
    ///   covers these trees.
    ///
    /// This sweep is a daemon-internal actuation rail in its own right: boot
    /// (and `cleanup`) invoke it, and it tears down the terminals of a vanished
    /// worktree and parks sessions nothing can reach on its own judgement. So
    /// it takes the record and writes one row **per act** — each teardown or
    /// park is an independent decision about a target it has already resolved,
    /// unlike an RPC archive where the caller asked for one worktree-level
    /// thing. The shared teardown helpers it calls
    /// (`disposeHolder`, `closeLeftoverTmuxRow`) stay silent so the RPC
    /// paths that also reach them are not double-counted.
    ///
    /// `actuationLog` is a required parameter rather than a defaulted one: a
    /// default would point every caller at one real file under `$TBD_HOME`,
    /// which is exactly the "helper ignores its caller's injected seam" shape.
    /// Fail-closed here means skipping the individual act — the daemon still
    /// boots, and the orphan waits for a writable log and the next sweep.
    public func reconcile(
        repoID: UUID,
        actuationLog: ActuationLog
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
        // Every fetch in this sweep is `listLocal`, not `list`. Reconcile's
        // whole job is to make DB rows agree with what git and tmux report on
        // THIS disk, so a row with no local checkout is not stale — it is out
        // of scope. Handed the location-neutral `list`, the archival pass
        // below would archive every remote row on every sweep (its path is
        // never in `gitPaths`).
        let dbWorktrees = try await db.worktrees.listLocal(repoID: repoID, status: .active)

        let gitPaths = Set(gitWorktrees.map(\.path))
        // Include `.creating` rows so a worktree whose pre-session phase-3
        // wait is still in flight (status flips to .active only when the hook
        // finishes) isn't "unknown" to the unmanaged-tree report below — it is
        // a tree TBD is creating, not a stranger, and reporting it as one
        // would point the user at `tbd worktree adopt` for a path that already
        // has a row.
        //
        // This one set deliberately fetches through the location-neutral
        // `list(...)` and then states its two exclusions here, in the open,
        // rather than borrowing `LocalWorktree.init?`. What it must contain is
        // "every path a live creating row already claims", and a path missing
        // from it is not a harmless omission: the report below would call a
        // tree TBD is in the middle of creating an unmanaged one.
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

        // Mark missing worktrees as archived, ending each terminal's session
        // and writing its Closed Terminals entry first, as
        // `beginArchiveWorktree` does. The archived row and its history rows
        // survive, so the output stays readable. Each worktree is read again
        // first, so one whose status changed since the list above is left
        // for the next sweep.
        for wt in dbWorktrees where !gitPaths.contains(wt.path) {
            guard let current = try await db.worktrees.getLocal(id: wt.id),
                  current.status == wt.status else { continue }
            let terminals = try await db.terminals.list(worktreeID: current.id)
            var sessions = SessionTeardownTally()

            // Every tmux row is closed first, before any dev server is
            // stopped or any holder disposed of, as `beginArchiveWorktree`
            // closes them before its status flip. Its close runs no tmux
            // command (`closeLeftoverTmuxRow`), and a live row's Closed
            // Terminals entry is marked with the worktree's tmux server. When
            // a mark cannot be written, or a close cannot be recorded, the
            // worktree is left for the next sweep before anything is torn
            // down, with every holder session still running: the kept tmux
            // row names its session to the resume gate, and the next sweep
            // closes the rest.
            var closedEveryTmuxRow = true
            for terminal in terminals where terminal.transport == .tmux {
                guard let actuationID = await appendReconcileDisposeRequest(
                    worktreeID: current.id, terminalID: terminal.id, to: actuationLog) else {
                    closedEveryTmuxRow = false
                    break
                }
                do {
                    try await Self.closeLeftoverTmuxRow(
                        terminal, server: current.tmuxServer, history: db.terminalHistory)
                } catch {
                    await actuationLog.appendOutcome(
                        confirms: actuationID, result: .transportFailed,
                        error: String(describing: error))
                    closedEveryTmuxRow = false
                    break
                }
                sessions.record(terminal, teardownStoppedIt: false)
                await actuationLog.appendOutcome(confirms: actuationID, result: .dispatched)
            }
            guard closedEveryTmuxRow else {
                logger.warning("reconcile: leaving \(current.id, privacy: .public) for the next sweep — a tmux row could not be closed: its Closed Terminals entry could not be marked with its server, or the actuation record is unwritable; its rows are kept to guard its sessions, and nothing was torn down")
                continue
            }

            // Dev servers TBD started in its tabs stop next, as in
            // `beginArchiveWorktree`, while those tabs' processes are
            // alive to be signalled. Tab process groups only: a server
            // known only through a running file is left running. A
            // failure is logged and the reconcile continues.
            await stopDevServersForArchive(worktree: current)
            var recordedEveryTeardown = true
            for terminal in terminals where terminal.transport == .holder {
                guard let actuationID = await appendReconcileDisposeRequest(
                    worktreeID: current.id, terminalID: terminal.id, to: actuationLog) else {
                    recordedEveryTeardown = false
                    continue
                }
                // A holder row's Closed Terminals entry is written before the
                // disposal releases the reader it is read from, as in
                // `beginArchiveWorktree`.
                await Self.recordHolderClosedTerminal(
                    terminal, registry: holderRegistry,
                    resolver: holderScreenResolver, history: db.terminalHistory)
                if let failure = await disposeHolder(for: terminal) {
                    logger.warning(
                        "reconcile: auto-archive left a holder running: \(failure, privacy: .public)")
                    await actuationLog.appendOutcome(
                        confirms: actuationID, result: .transportFailed, error: failure)
                    sessions.record(terminal, teardownStoppedIt: false)
                    continue
                }
                sessions.record(terminal, teardownStoppedIt: true)
                await actuationLog.appendOutcome(
                    confirms: actuationID, result: .dispatched)
            }
            // A teardown that could not be recorded did not happen, so the
            // rows still recording those sessions must survive too.
            guard recordedEveryTeardown else {
                logger.warning("reconcile: leaving \(current.id, privacy: .public) for the next sweep — the actuation record is unwritable, so its sessions were not ended")
                continue
            }
            // Only now, as in `beginArchiveWorktree`: every session counted
            // as ended here has had its teardown, and the `continue` above
            // leaves the directories with the rows for the next sweep.
            removeSessionDirectories(for: sessions)
            try await db.terminals.deleteForWorktree(worktreeID: current.id)
            await sessionTitles.forget(worktreeID: current.id)
            try await db.tabs.deleteForWorktree(worktreeID: current.id)
            for terminal in terminals {
                await pendingQuestions.clear(terminalID: terminal.id)
                await subscriptions?.broadcastPendingPrompts(
                    terminalID: terminal.id, from: pendingQuestions)
                ClaudeHookOverlay.removePerSessionOverlay(
                    sessionKey: terminal.id.uuidString)
            }
            // After the rows are gone, as in `beginArchiveWorktree`.
            await detachDevServerOutputsForArchive(worktreeID: current.id)
            let removedPanelTabIDs = try await db.worktrees.archive(id: current.id)
            subscriptions?.broadcastPanelSurfacesRemoved(
                worktreeID: current.id, tabIDs: removedPanelTabIDs)
        }

        // Report unmanaged worktrees (skip the main repo worktree).
        //
        // A git worktree under a pool prefix with no row is NOT adopted. It may
        // be a tree a user or another tool made with a plain `git worktree add`,
        // and a row would hand it to TBD's lifecycle: archive deletes the
        // directory and GC can reap it, taking uncommitted work with it, on the
        // strength of nothing but its location. Ownership is opt-in via
        // `tbd worktree adopt <path>`. Trees TBD creates itself always get a
        // row first (`createWorktree`, and recovery activates a stranded
        // `.creating` row), so nothing TBD made reaches this loop.
        //
        // The report is one `.info` line per tree per pass. Reconcile is not on
        // a timer: it runs at daemon start, on `tbd cleanup` and when a repo is
        // added, so a persistent unmanaged tree costs a line per such event,
        // not a stream. That is why this carries no once-per-path state.
        //
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
        // Paths the user explicitly forgot (`tbd worktree forget`) are skipped
        // silently: they still sit under a TBD-managed prefix and remain
        // registered with git, and the user has already answered the question
        // the report asks. Loaded once per reconcile pass. Tombstones are
        // cleared by the adopt/create flows when the user deliberately re-adds
        // a path.
        let forgottenPaths = try await db.forgottenWorktrees.allPaths()
        for gitWt in gitWorktrees where !dbPaths.contains(gitWt.path) {
            guard acceptablePrefixes.contains(where: { gitWt.path.hasPrefix($0) }) else { continue }
            if forgottenPaths.contains(gitWt.path) {
                logger.debug("reconcile: skipping forgotten worktree path \(gitWt.path, privacy: .public)")
                continue
            }
            // A path can be here because an archived row still holds it (an
            // interrupted archive, or a directory recreated at a row's path).
            // "No TBD row" would be wrong for it, and `adopt` revives that row.
            if let held = try await db.worktrees.findByPath(path: gitWt.path) {
                logger.info("reconcile: git worktree \(gitWt.path, privacy: .public) is under a TBD worktree directory and is held by the \(held.status.rawValue, privacy: .public) TBD worktree \(held.id, privacy: .public), so TBD is not managing it. Run `tbd worktree adopt \(shellEscape(gitWt.path), privacy: .public)` to track it again.")
            } else {
                logger.info("reconcile: git worktree \(gitWt.path, privacy: .public) is under a TBD worktree directory but has no TBD row, so TBD is not managing it and will not archive or delete it. Run `tbd worktree adopt \(shellEscape(gitWt.path), privacy: .public)` to track it.")
            }
        }

        let allLiveWorktrees = try await db.worktrees.listLocal(repoID: repoID, status: .active)
            + (try await db.worktrees.listLocal(repoID: repoID, status: .main))
        try await reconcileTerminals(in: allLiveWorktrees, actuationLog: actuationLog)

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
    /// repositories, which their rows belong to none of.
    public func reconcileScratchTerminals(actuationLog: ActuationLog) async throws {
        let scratchWorktrees = try await db.worktrees.listLocal(
            status: .active, scratchOnly: true)
        try await reconcileTerminals(in: scratchWorktrees, actuationLog: actuationLog)
    }

    /// Reconcile terminals nothing can reach any more: a live tmux row whose
    /// tmux server is gone, and a holder row whose holder is gone. All of them
    /// use the same established outcomes: park resumable identified Claude and
    /// Codex sessions and delete non-resumable rows.
    ///
    /// The two transports differ only in what "unreachable" is read off. A
    /// tmux row is judged by its server's socket and this user's tmux
    /// processes that name it (`LeftoverTmuxServerProbe`, a transition measure
    /// with a replacement date), because TBD no longer drives tmux and a server an
    /// earlier build started can still be running; holder rows are judged by
    /// the holder inventory, via `holderRowVerdict(for:)`.
    ///
    /// We deliberately do NOT eagerly recreate terminals on reboot: on a
    /// machine with many worktrees that spawned N simultaneous `claude
    /// --resume` processes (~0.5-1.5 GB each) and OOM'd the machine (#284).
    /// Lazy recreate-on-demand keeps idle worktrees as cheap suspended rows.
    private func reconcileTerminals(
        in worktrees: [LocalWorktree], actuationLog: ActuationLog
    ) async throws {
        // The budget covers the pass, not one server: the arm is serial across
        // every server this call reconciles, so a per-server budget would
        // multiply by the server count exactly the way a per-probe timeout
        // multiplies by the row count.
        await holderProbeBudget.begin(Self.holderPhaseBudget, clock: clock)
        // `end()` has to run on every exit, including the throwing one: the
        // budget's timer is what makes `begin` a no-op while a pass is running,
        // so a pass that walked away from its own timer would leave every later
        // pass reading a spent budget. `defer` cannot await, so the throw is
        // caught and rethrown instead.
        do {
            try await sweepTerminals(in: worktrees, actuationLog: actuationLog)
        } catch {
            await holderProbeBudget.end()
            throw error
        }
        await holderProbeBudget.end()
    }

    /// The sweep itself, split out only so `reconcileTerminals` can bracket it
    /// with the pass's probe budget.
    ///
    /// Neither arm's ground truth is held still by anything this pass takes:
    /// a holder row's is its own rendezvous, and a tmux row's is a socket TBD
    /// does not serve. Every write it makes is a compare-and-set against the
    /// row it read.
    private func sweepTerminals(
        in worktrees: [LocalWorktree], actuationLog: ActuationLog
    ) async throws {
        // The tmux server each worktree row stores, probed once per name and
        // only for a live tmux row: rows overwhelmingly share one server, and
        // a worktree with no tmux row asks nothing.
        var tmuxServerStates: [String: LeftoverTmuxServerState] = [:]
        for wt in worktrees {
            let terminals = try await db.terminals.list(worktreeID: wt.id)
            // Parked rows (`hibernatedAt` OR legacy `suspendedAt` — see
            // `isParked`) are skipped: a parked terminal has no process to
            // reach, and the row is already exactly what this pass would
            // produce.
            for terminal in terminals where !terminal.isParked {
                if Self.holdsUnfinishedContinueInClaude(terminal) {
                    logger.warning("reconcile: keeping Codex terminal \(terminal.id, privacy: .public) as it is — an earlier build left a Continue in Claude replacement unfinished on it; close the tab to clear it")
                    continue
                }
                // **Two transports, one outcome.** Each arm establishes the
                // same fact in its own vocabulary — nothing can reach this
                // session any more — and then parks the row if it has a
                // session to resume, or deletes it if it has none.
                //
                // A holder row's ground truth is the holder inventory
                // (`docs/specs/2026-08-30-pty-holder-session-transport-design.md`,
                // "Reconciliation"), which is what `holderRowVerdict(for:)`
                // reads, and `disposeOfEndedHolderRow` disposes of it. A tmux
                // row's is its server's socket
                // (`docs/specs/2026-10-11-holder-transport-migration-design.md`,
                // "A live row whose tmux server outlived the update"), and
                // `disposeOfLeftoverTmuxRow` disposes of it. Each write on
                // either arm is a compare-and-set.
                switch terminal.transport {
                case .holder:
                    switch await holderRowVerdict(for: terminal) {
                    case .keep(let reason):
                        logger.debug("reconcile: keeping holder-backed terminal \(terminal.id, privacy: .public) — \(reason, privacy: .public)")
                    case .sessionOver(let status):
                        await disposeOfEndedHolderRow(
                            terminal,
                            finding: "its holder is gone and its job "
                                + Self.jobEndingDescription(status),
                            actuationLog: actuationLog)
                    }

                case .tmux:
                    // TBD cannot reach a tmux session, so the only fact this
                    // pass can act on is that its server is gone, and with it
                    // every process it ran. Anything short of that keeps the
                    // row live: the app shows it as still running in tmux.
                    let state: LeftoverTmuxServerState
                    if let cached = tmuxServerStates[wt.tmuxServer] {
                        state = cached
                    } else {
                        state = await leftoverTmuxProbe.state(wt.tmuxServer)
                        tmuxServerStates[wt.tmuxServer] = state
                    }
                    guard state == .absent else {
                        logger.info("reconcile: keeping tmux terminal \(terminal.id, privacy: .public) live — tmux server \(wt.tmuxServer, privacy: .public) may still be running")
                        continue
                    }
                    await disposeOfLeftoverTmuxRow(
                        terminal, server: wt.tmuxServer, actuationLog: actuationLog)
                }
            }
        }
    }

    /// Whether `terminal` is a nonparked Codex row with a pending incarnation:
    /// an unfinished Continue in Claude fence, which nothing in the daemon
    /// finishes. The row still holds its Codex source identity. The recovery
    /// park would carry the fence onto a parked row, where it reads as a park
    /// still in flight, so the sweep keeps such a row as it is on either
    /// transport, and so does `reconcileHolderRowAfterJobGone`; closing its tab
    /// clears it.
    private static func holdsUnfinishedContinueInClaude(_ terminal: Terminal) -> Bool {
        terminal.kind == .codex && terminal.pendingSessionIncarnationID != nil
    }

    /// Park or delete a holder row whose session `holderRowVerdict(for:)` found
    /// over — the holder arm's half of "two transports, one outcome", shared by
    /// the sweep and by `reconcileHolderRowAfterJobGone` so that both reach the
    /// same disposal by the same code.
    ///
    /// An identified agent row is parked with its provider's native session ID
    /// and reason `.recovery`; a row with nothing to resume is deleted with its
    /// tab. Only this positively-unreachable recovery fork accepts Codex;
    /// manual and automatic parking remain Claude-only.
    ///
    /// Each write is a compare-and-set against `terminal`, the row as the
    /// caller read it before probing (`LiveHolderRowSnapshot`). A row that
    /// changed in between — parked and woken onto a new holder, closed,
    /// renamed — is left as it is and logged, and the next pass, or the
    /// reaper's next hand-back, judges it afresh.
    ///
    /// **A committed write is announced as every other park and close is:**
    /// `.terminalHibernationChanged` for a park, `.terminalRemoved` for a
    /// delete. The app applies both to its cached row in place, so without
    /// them a connected app keeps showing the row live until something else
    /// makes it refetch. The reaper's hand-back runs with an app connected,
    /// and so can every sweep after startup — `repo.add`, `cleanup`, the
    /// hourly scratch pass; at startup no app is connected yet, and the
    /// announcement reaches nobody. A write that failed or was refused
    /// changed nothing, and announces nothing.
    ///
    /// `finding` is what the caller established, in the words the log line
    /// carries, so the two callers' lines can be told apart.
    ///
    /// Internal rather than private only so a test can hand it a row that
    /// changed after it was read, which neither caller lets a test arrange.
    func disposeOfEndedHolderRow(
        _ terminal: Terminal, finding: String, actuationLog: ActuationLog
    ) async {
        let expectedState = LiveHolderRowSnapshot(terminal: terminal)
        if let resumePlan = terminal.recoveryResumePlan {
            let sessionID = resumePlan.identity.sessionID
            // This park bypasses `HibernationCoordinator`, so the reconcile
            // rail records its own independent actuation. Fail closed if that
            // authoritative record cannot be made.
            var row = ActuationRow(
                actor: .daemon(rail: ActuationRail.reconcile), kind: .hibernate)
            row.target = .local(worktree: terminal.worktreeID, terminal: terminal.id)
            guard let actuationID = try? await actuationLog.appendRequest(row) else {
                logger.warning("reconcile: skipped parking terminal \(terminal.id, privacy: .public) — the actuation record is unwritable")
                return
            }
            let parked: Bool
            do {
                // The park and the cleared pids in one write: the holder and
                // its job are already gone — that is what `.sessionOver`
                // established — so a parked row names no processes.
                parked = try await db.terminals.parkEndedHolderRow(
                    id: terminal.id, expectedState: expectedState,
                    sessionID: sessionID, reason: .recovery, at: now())
            } catch {
                await actuationLog.appendOutcome(
                    confirms: actuationID, result: .transportFailed, error: "\(error)")
                logger.warning("reconcile: could not park terminal \(terminal.id, privacy: .public) — \(finding, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
            guard parked else {
                await actuationLog.appendOutcome(
                    confirms: actuationID, result: .refused(.notEligible),
                    error: "the row changed after reconcile read it")
                logger.info("reconcile: left holder-backed terminal \(terminal.id, privacy: .public) as it is — it changed after this pass read it")
                return
            }
            await actuationLog.appendOutcome(confirms: actuationID, result: .dispatched)
            logger.info("reconcile: parked terminal \(terminal.id, privacy: .public) — \(finding, privacy: .public), session \(sessionID, privacy: .public) preserved, wakeable via the unified resume path")
            await announceRecoveryPark(of: terminal)
        } else {
            let deleted: Bool
            do {
                deleted = try await db.deleteEndedHolderTerminalAndTab(
                    id: terminal.id, expectedState: expectedState)
            } catch {
                logger.warning("reconcile: could not delete terminal \(terminal.id, privacy: .public) — \(finding, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
            guard deleted else {
                logger.info("reconcile: left holder-backed terminal \(terminal.id, privacy: .public) as it is — it changed after this pass read it")
                return
            }
            await sessionTitles.forget(terminalID: terminal.id)
            logger.info("reconcile: deleted terminal \(terminal.id, privacy: .public) — \(finding, privacy: .public), no session to preserve")
            subscriptions?.broadcast(delta: .terminalRemoved(TerminalIDDelta(terminalID: terminal.id)))
        }
        await pendingQuestions.clear(terminalID: terminal.id)
        await subscriptions?.broadcastPendingPrompts(
            terminalID: terminal.id, from: pendingQuestions)
    }

    /// Announce the recovery park `disposeOfEndedHolderRow` just committed on
    /// `terminal`'s row, with the delta `HibernationCoordinator.broadcastHibernation`
    /// sends for every other park.
    ///
    /// Read back after the commit, as that one is: the park minted a session
    /// incarnation and wrote the activity columns, and nothing else announces
    /// either. A row read back unparked was woken since, and one read back
    /// gone was closed; that wake or close announces the row as it now is, and
    /// a park delta landing after it would put the app's cached row back to
    /// parked, so neither is announced. A row that cannot be read back is
    /// still announced as parked, with the fields this pass read before it.
    private func announceRecoveryPark(of terminal: Terminal) async {
        guard let subscriptions else { return }
        let committed: Terminal?
        do {
            guard let row = try await db.terminals.get(id: terminal.id), row.isParked else {
                logger.debug("reconcile: not announcing the park of terminal \(terminal.id, privacy: .public) — it was woken or closed after the park")
                return
            }
            committed = row
        } catch {
            logger.warning("reconcile: parked terminal \(terminal.id, privacy: .public) but could not read it back; announcing the park without its new incarnation: \(error.localizedDescription, privacy: .public)")
            committed = nil
        }
        subscriptions.broadcast(delta: .terminalHibernationChanged(TerminalHibernationDelta(
            terminalID: terminal.id,
            worktreeID: terminal.worktreeID,
            hibernated: true,
            keepWarm: committed?.keepWarm ?? terminal.keepWarm,
            suspendedSnapshot: committed?.suspendedSnapshot ?? terminal.suspendedSnapshot,
            hibernateReason: committed?.hibernateReason ?? .recovery,
            sessionIncarnationID: committed?.sessionIncarnationID,
            activity: committed.map(TerminalActivityDelta.init(columnsOf:))
        )))
    }

    /// Judge one holder row again once `AgentReaper` has found its holder and
    /// its job both gone, and park or delete it as the startup pass would
    /// have.
    ///
    /// **This closes a keep that nothing else revisits in time.** The sweep
    /// keeps a holder row whose job is still running even when its holder is
    /// provably gone (`holderRowVerdict(for:)`, "job-still-running"), because
    /// the row is the only record of the child pid the reaper's holder leg
    /// reads. A pass that runs while the child is mid-exit — a holder killed a
    /// moment before a daemon handover's startup reconcile — keeps the row,
    /// and the job is gone a moment later. The reaper then reads `child-gone`
    /// on every sweep and signals nothing, so without a hand-back the row
    /// stays a live, unparked holder row over a dead holder and a dead job
    /// until some later pass happens to sweep its repository — too late for
    /// the wake that follows a handover, which wakes only what is parked.
    /// The reaper's `child-gone` verdict calls this (`AgentReaper.onHolderJobGone`).
    ///
    /// It decides nothing of its own. It re-reads the row, and judges it only
    /// if the row is still a live holder row naming the holder and job the
    /// caller saw gone (`expectedHolderPID`, `expectedChildPID`): a wake or a
    /// respawn in between replaces those pids, and the session they name now
    /// is running. Then it asks `holderRowVerdict(for:)`, so every gate the
    /// sweep applies applies here unchanged — a viewer attached, a live reader,
    /// a remembered status, the probe budget, a job still running — and on
    /// `.sessionOver` it disposes of the row through `disposeOfEndedHolderRow`,
    /// the sweep's own code. A keep does nothing; the reaper's next sweep asks
    /// again while the row still reads `child-gone`.
    ///
    /// The probe runs under the same `HolderProbeBudget` as a sweep's: begun
    /// here, or joined when a sweep is already running.
    ///
    /// Returns the verdict it acted on, or nil when it judged nothing because
    /// the row is not one it may judge. The daemon discards it; it is there so
    /// a test can tell which gate decided.
    @discardableResult
    func reconcileHolderRowAfterJobGone(
        terminalID: UUID,
        expectedHolderPID: Int32?,
        expectedChildPID: Int32?,
        actuationLog: ActuationLog
    ) async -> HolderRowVerdict? {
        let terminal: Terminal
        do {
            guard let current = try await db.terminals.get(id: terminalID) else {
                logger.debug("reconcile: not re-judging terminal \(terminalID, privacy: .public) — its row is gone")
                return nil
            }
            terminal = current
        } catch {
            logger.warning("reconcile: could not read terminal \(terminalID, privacy: .public) to judge it after its holder's job was found gone: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard terminal.transport == .holder, !terminal.isParked else {
            logger.debug("reconcile: not re-judging terminal \(terminalID, privacy: .public) — it is no longer a live holder-backed row")
            return nil
        }
        guard terminal.holderPID == expectedHolderPID,
              terminal.childPID == expectedChildPID else {
            logger.debug("reconcile: not re-judging terminal \(terminalID, privacy: .public) — it names a different holder or job than the one found gone")
            return nil
        }
        guard !Self.holdsUnfinishedContinueInClaude(terminal) else {
            logger.debug("reconcile: keeping Codex terminal \(terminalID, privacy: .public) as it is — a Continue in Claude replacement is unfinished on it")
            return nil
        }

        // Only the verdict is bracketed: it is the one step that may open a
        // socket, and it does not throw, so `end` is reached on every path.
        await holderProbeBudget.begin(Self.holderPhaseBudget, clock: clock)
        let verdict = await holderRowVerdict(for: terminal)
        await holderProbeBudget.end()

        switch verdict {
        case .keep(let reason):
            logger.debug("reconcile: keeping holder-backed terminal \(terminalID, privacy: .public) after its holder's job was found gone — \(reason, privacy: .public)")
        case .sessionOver(let status):
            await disposeOfEndedHolderRow(
                terminal,
                finding: "its holder and job were found gone after the startup pass, and the job "
                    + Self.jobEndingDescription(status),
                actuationLog: actuationLog)
        }
        return verdict
    }

    /// Park or delete a live tmux row whose tmux server the probe found gone.
    ///
    /// Each write is a compare-and-set against the row as this pass read it,
    /// and that is the point of keeping this apart from the holder arm's
    /// fork. The pass reads a worktree's rows before it probes, and a
    /// `terminal.migrate` can move the same row to the holder in between. An
    /// unconditional write would then stamp a park on a session already
    /// running on the holder, or delete its row, and a later wake of that
    /// park would start a second agent on the same session id. Both moves to
    /// the holder blank the row's tmux coordinates and change its session
    /// incarnation or its park, so the comparison fails and the row is left
    /// as it is.
    ///
    /// A row with a session to resume is parked by `parkLeftoverTmuxRow`, the
    /// park Check Again and the migration make; a row with nothing to resume
    /// is deleted with its tab.
    private func disposeOfLeftoverTmuxRow(
        _ terminal: Terminal, server: String, actuationLog: ActuationLog
    ) async {
        guard let resumePlan = terminal.recoveryResumePlan else {
            let deleted: Bool
            do {
                deleted = try await db.deleteLeftoverTmuxTerminalAndTab(
                    id: terminal.id,
                    expectedState: TerminalReplacementSnapshot(terminal: terminal))
            } catch {
                logger.warning("reconcile: could not delete tmux terminal \(terminal.id, privacy: .public) whose tmux server \(server, privacy: .public) is gone: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard deleted else {
                logger.info("reconcile: left tmux terminal \(terminal.id, privacy: .public) as it is — it changed after this pass read it")
                return
            }
            await sessionTitles.forget(terminalID: terminal.id)
            await pendingQuestions.clear(terminalID: terminal.id)
            await subscriptions?.broadcastPendingPrompts(
                terminalID: terminal.id, from: pendingQuestions)
            logger.info("reconcile: deleted terminal \(terminal.id, privacy: .public) — its tmux server \(server, privacy: .public) is gone, no session to preserve")
            return
        }

        let sessionID = resumePlan.identity.sessionID
        // This park bypasses `HibernationCoordinator`, so the reconcile rail
        // records its own independent actuation. Fail closed if that
        // authoritative record cannot be made.
        var row = ActuationRow(actor: .daemon(rail: ActuationRail.reconcile), kind: .hibernate)
        row.target = .local(worktree: terminal.worktreeID, terminal: terminal.id)
        guard let actuationID = try? await actuationLog.appendRequest(row) else {
            logger.warning("reconcile: skipped parking terminal \(terminal.id, privacy: .public) — the actuation record is unwritable")
            return
        }
        let outcome: LeftoverTmuxParkOutcome
        do {
            outcome = try await parkLeftoverTmuxRow(terminal)
        } catch {
            await actuationLog.appendOutcome(
                confirms: actuationID, result: .transportFailed, error: "\(error)")
            logger.warning("reconcile: could not park tmux terminal \(terminal.id, privacy: .public) whose tmux server \(server, privacy: .public) is gone: \(error.localizedDescription, privacy: .public)")
            return
        }
        switch outcome {
        case .parked, .parkedUnreadable:
            // This pass needs no row back, so a park it could not read back
            // is a park like any other.
            await actuationLog.appendOutcome(confirms: actuationID, result: .dispatched)
            logger.info("reconcile: parked terminal \(terminal.id, privacy: .public) — its tmux server \(server, privacy: .public) is gone, session \(sessionID, privacy: .public) preserved; a person's wake moves it to the pty holder")
        case .leftAlone:
            await actuationLog.appendOutcome(
                confirms: actuationID, result: .refused(.notEligible),
                error: "the row changed after reconcile read it")
            logger.info("reconcile: left tmux terminal \(terminal.id, privacy: .public) as it is — it changed after this pass read it")
        case .closed:
            // A quiet miss, as the delete arm's is: a tab closed while the
            // probe ran leaves nothing to park.
            await actuationLog.appendOutcome(
                confirms: actuationID, result: .refused(.notFound),
                error: "the tab was closed after reconcile read it")
            logger.info("reconcile: left tmux terminal \(terminal.id, privacy: .public) alone — its tab was closed after this pass read it")
        case .superseded:
            // The park was written, so it is recorded as dispatched, with what
            // became of it.
            await actuationLog.appendOutcome(
                confirms: actuationID, result: .dispatched,
                error: "the park was written, but the row changed again before it finished")
            logger.info("reconcile: parked tmux terminal \(terminal.id, privacy: .public), but it changed again before the park finished; left as that change made it")
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
    /// that could be an answer, and the holder's reaping branch pushes only at
    /// a client it has already answered, so this probe cannot collect the exit
    /// it is looking for. A holder whose serve loop pushes at whichever client
    /// is connected, which a daemon update can leave running, can still hand
    /// it the exit of a child that ends inside the few milliseconds it is
    /// attached. That window is a race with the child's own exit, not a
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
    /// **That keep is handed back once the job is gone.** It is ordinary for
    /// the job to end a moment after this gate read it — a child caught
    /// mid-exit — while a repository's rows are not swept again until the
    /// next daemon start, `repo.add` or `cleanup`. The
    /// reaper's holder leg reads the same row on every sweep, and when it finds
    /// the holder gone and nothing running under the child pid (`child-gone`)
    /// it hands the row back to `reconcileHolderRowAfterJobGone`, which asks
    /// this verdict again and, on `.sessionOver`, parks or deletes the row
    /// exactly as the sweep would have.
    ///
    /// **Naming that contingency honestly: the loop does not always close.**
    /// The reaper keeps rather than signals whenever identity is uncertain —
    /// `holder-unrecorded`, `start-time-mismatch`, `foreign-executable` — and
    /// each of those is a permanent keep here too. A pid the row names that has been reused by a
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

    /// The request row for reconcile's teardown of one terminal of a
    /// worktree whose checkout is gone, written before the teardown; nil when
    /// the actuation record cannot be written, and the teardown must then not
    /// happen.
    private func appendReconcileDisposeRequest(
        worktreeID: UUID, terminalID: UUID, to actuationLog: ActuationLog
    ) async -> String? {
        var row = ActuationRow(actor: .daemon(rail: ActuationRail.reconcile), kind: .dispose)
        row.target = .local(worktree: worktreeID, terminal: terminalID)
        return try? await actuationLog.appendRequest(row)
    }
}
