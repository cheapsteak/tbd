import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "worktreeHandlers")

extension RPCRouter {

    // MARK: - Worktree Handlers

    func handleWorktreeCreate(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeCreateParams.self, from: paramsData)
        let useExistingBranch = params.useExistingBranch ?? false

        // Phase 1: Fast — insert DB row with status = .creating, return immediately
        let pending = try await lifecycle.beginCreateWorktree(
            repoID: params.repoID,
            folder: params.folder,
            branch: params.branch,
            displayName: params.displayName,
            parentWorktreeID: params.parentWorktreeID,
            siblingOfWorktreeID: params.siblingOfWorktreeID,
            callerWorktreeID: params.callerWorktreeID,
            suppressAutoParent: params.suppressAutoParent ?? false,
            useExistingBranch: useExistingBranch,
            prNumber: params.prNumber
        )

        // Reads precede the row; the row precedes the acts. This lookup is a
        // plain DB read, so a missing repo is pre-row validation — the create is
        // refused before anything claims it was about to be dispatched, exactly
        // as the worktree-not-found guards on the sibling handlers do.
        guard let repo = try await db.repos.get(id: params.repoID) else {
            // Mirror completeCreateWorktree's guard: clean up the .creating row
            // inserted by beginCreateWorktree so it can't be orphaned forever.
            try? await db.worktrees.delete(id: pending.id)
            throw WorktreeLifecycleError.repoNotFound(params.repoID)
        }

        // Creation ends in a spawn — the lifecycle's phase 2/3 opens this
        // worktree's primary terminals, the same call `worktree.revive` reaches
        // — so it gets the same shape of row: one per call, naming the worktree,
        // with no terminal (those are minted inside the lifecycle phase). Phase
        // 1 above is DB-only and touches no process, which is why the row can
        // sit after it and still precede every acting step.
        let actuationID: String
        do {
            actuationID = try await beginActuation(
                .worktreeCreate, actor: actor,
                target: ActuationTarget(worktree: pending.id.uuidString))
        } catch {
            // Same cleanup the repo guard above does: an unrecordable spawn is
            // refused, so don't leave the `.creating` row orphaned forever.
            try? await db.worktrees.delete(id: pending.id)
            throw error
        }

        // Arm the per-worktree auto-archive-on-merge override when the spawn
        // requested it. nil leaves the row following the global default.
        if let autoArchive = params.autoArchiveOnMerge {
            do {
                try await db.worktrees.setAutoArchiveOnMerge(id: pending.id, value: autoArchive)
            } catch {
                logger.warning("failed to arm auto-archive for \(pending.id, privacy: .public): \(error, privacy: .public)")
            }
        }

        // Phase 1.5: Fetch from origin (coalesced, with tight timeout)
        // Fire off as a background task so it doesn't block the RPC response.
        // Phase 2 will re-await before git worktree add; FetchCache's singleflight
        // means the second await joins the in-flight fetch or is a no-op if cached.
        let repoPath = repo.path
        let defaultBranch = repo.defaultBranch
        let fetchCache = self.fetchCache
        Task {
            await fetchCache.fetchIfNeeded(repoPath: repoPath, branch: defaultBranch)
        }

        // Phase 2: Fire-and-forget — git operations + tmux setup in background.
        // Serialize per-repo so concurrent creates don't contend on .git/index.lock.
        let lifecycle = self.lifecycle
        let subs = self.subscriptions
        let initialPrompt = params.prompt
        let userSpecifiedFolder = params.folder != nil
        let userSpecifiedBranch = params.branch != nil
        let cols = params.cols
        let rows = params.rows
        // Pass the raw branch ref (possibly `origin/...`) to phase 2 so it
        // can dispatch to the right git command.
        let existingBranchRef = useExistingBranch ? params.branch : nil
        // Fork-PR rows opt into the refs/pull/<n>/head fetch; decorated
        // same-repo rows leave this false and check out the existing branch.
        let checkoutPRHead = params.checkoutPRHead ?? false
        // Explicit per-creation model-profile override (sidebar `+` picker).
        // nil preserves the repo/scratch/global precedence chain.
        let overrideProfileID = params.profileID
        // Per-spawn Claude model override (picker model buttons). Initial
        // spawn only — respawns fall back to the profile default.
        let modelOverride = params.model
        // Explicit primary agent for this creation. nil preserves the global
        // preference resolved by the lifecycle.
        let primaryAgentPreference = params.primaryAgentPreference
        // General Claude settings passthrough, deep-merged into the per-session
        // --settings overlay on the fresh-primary spawn (see ClaudeHookOverlay).
        let claudeSettingsOverlay = params.claudeSettingsOverlay
        // handleWorktreeCreate is always repo-scoped (scratch creation uses a
        // separate RPC), so params.repoID is the reliable non-optional source
        // — pending.repoID mirrors it but is now UUID? on the shared model.
        await repoSerializer.submit(repoID: params.repoID) {
            do {
                // Re-await the fetch to ensure it completes before git operations.
                // FetchCache's singleflight means this either joins the in-flight
                // fetch from phase 1.5, or is a no-op if cached within the 60s TTL.
                await fetchCache.fetchIfNeeded(repoPath: repoPath, branch: defaultBranch)

                let completion = try await lifecycle.completeCreateWorktree(worktreeID: pending.id, initialPrompt: initialPrompt, userSpecifiedFolder: userSpecifiedFolder, userSpecifiedBranch: userSpecifiedBranch, cols: cols, rows: rows, existingBranchRef: existingBranchRef, checkoutPRHead: checkoutPRHead, overrideProfileID: overrideProfileID, modelOverride: modelOverride, primaryAgentPreference: primaryAgentPreference, claudeSettingsOverlay: claudeSettingsOverlay)
                switch completion {
                case .ready:
                    subs.broadcast(delta: .worktreeCreated(WorktreeDelta(
                        worktreeID: pending.id, repoID: pending.repoID,
                        name: pending.name, path: pending.localPath
                    )))
                case .preSessionPending:
                    // The lifecycle already broadcast `.worktreeCreated` (and
                    // `.terminalCreated` for the pre-session terminal) so the
                    // app refreshes early; the detached phase-3 task spawns
                    // the primary terminals OUTSIDE this serializer lane and
                    // broadcasts their `.terminalCreated` deltas itself.
                    // Broadcasting again here would duplicate the row.
                    break
                }
            } catch {
                // completeCreateWorktree already deletes the DB row on failure.
                // Broadcast an archive delta so clients remove the pending entry.
                // `creationFailed: true` is set ONLY here — this is the single
                // path where a row disappears because its creation actually
                // failed, so it's the only place that can tell clients apart
                // from a deliberate archive of a still-`.creating` row.
                subs.broadcast(delta: .worktreeArchived(WorktreeIDDelta(
                    worktreeID: pending.id,
                    creationFailed: true
                )))
                logger.error("background worktreeCreate failed for \(pending.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Dispatched once the synchronous phase returned, exactly as
        // `worktree.revive` records it: the spawn itself runs in the lifecycle's
        // own background phase, and what this rung can honestly claim is that
        // the daemon handed it off.
        await finishActuation(actuationID, .dispatched)
        return try RPCResponse(result: pending)
    }

    func handleWorktreeList(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeListParams.self, from: paramsData)
        var worktrees = try await db.worktrees.list(
            repoID: params.repoID,
            status: params.status,
            excludeArchived: params.excludeArchived ?? false,
            scratchOnly: params.scratchOnly ?? false,
            limit: params.limit,
            offset: params.offset,
            nameQuery: params.nameQuery
        )
        // Enrich archived worktrees with a real session-file count so the
        // client can filter on actual disk state, not stale stored IDs.
        //
        // Only run this enrichment when the caller explicitly asked for the
        // archived list. The default (status=nil) listing is hit by the app's
        // 2s poll, and `ClaudeProjectDirectory.resolve` can fall through to a
        // full scan of `~/.claude/projects/*` (reading the first line of every
        // session JSONL) when the tier-1/2 path-encoding lookups miss — which
        // they do on every archived worktree whose project directory has been
        // cleaned up. Negative scan results are not cached, so without this
        // guard the poll re-scans the entire projects directory every 2s,
        // pegging the daemon at ~95% CPU.
        //
        // The deep-link archived lookup opts out via `includeSessionCounts ==
        // false`: it only needs the target row's identity, not its session
        // count, and enriching all archived rows made that lookup take ~19s.
        if params.status == .archived && (params.includeSessionCounts ?? true) {
            for i in worktrees.indices where worktrees[i].status == .archived {
                if let dir = ClaudeProjectDirectory.resolve(worktreePath: worktrees[i].localPath) {
                    worktrees[i].liveClaudeSessionCount = ClaudeSessionScanner.countSessionFiles(projectDir: dir)
                } else {
                    worktrees[i].liveClaudeSessionCount = 0
                }
            }
        }
        return try RPCResponse(result: worktrees)
    }

    func handleWorktreeArchive(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeArchiveParams.self, from: paramsData)

        // A remote lane is not archivable, and is refused here rather than
        // allowed to fail downstream. Archiving a remote worktree would mean
        // stopping the provider's session — deliberately unimplemented, not an
        // oversight — so `beginArchiveWorktree` resolves its row through
        // `getLocal` and throws for a remote one. Reaching it would mean this
        // handler had already written a `.dispose` request for an act it
        // structurally cannot perform, and the record may only claim acts that
        // were attempted, so the gate belongs above the row.
        //
        // Loud, unlike the auto-archive rail's silent `false`: that is a
        // background rail, this is a deliberate user gesture, and a gesture
        // that does nothing deserves an answer saying so. This is a plain DB
        // read, so it is pre-row validation — the same shape as the
        // worktree-not-found guards on the sibling handlers. A *missing* row is
        // deliberately not handled here: that stays `beginArchiveWorktree`'s
        // throw, recorded as transport-failed, unchanged.
        if let existing = try await db.worktrees.get(id: params.worktreeID),
           !existing.location.isLocal {
            logger.debug("worktree.archive refused (remote lane): \(params.worktreeID, privacy: .public)")
            return RPCResponse(
                error: "Cannot archive \(existing.name): it is a remote lane, and archiving one is not supported.")
        }

        // One row per call, naming the worktree and no terminal: the caller
        // asked to archive a worktree, and the per-terminal captures and kills
        // are how `WorktreeLifecycle`'s phase 1 carries that out — sub-steps of
        // one intent, not separate actuations. Same shape as `worktree.create`,
        // for the same reason.
        let actuationID = try await beginActuation(
            .worktreeArchive, actor: actor,
            target: ActuationTarget(worktree: params.worktreeID.uuidString))

        // Phase 1: Fast — update DB, kill tmux, return immediately
        let worktree: Worktree
        let repo: Repo
        do {
            (worktree, repo) = try await lifecycle.beginArchiveWorktree(
                worktreeID: params.worktreeID)
        } catch {
            await finishActuation(actuationID, .transportFailed, error: "\(error)")
            throw error
        }
        await finishActuation(actuationID, .dispatched)

        subscriptions.broadcast(delta: .worktreeArchived(WorktreeIDDelta(
            worktreeID: params.worktreeID
        )))

        // Phase 2: Slow — hook + git worktree remove in background
        let lifecycle = self.lifecycle
        let force = params.force
        Task.detached {
            await lifecycle.completeArchiveWorktree(worktree: worktree, repo: repo, force: force)
        }

        return .ok()
    }

    /// Re-run the worktree's `preSession` hook. Returns as soon as the hook's
    /// tab exists; the wait + teardown run detached inside the lifecycle.
    ///
    /// Rejections (`no hook`, `already running`, `still creating`) come back as
    /// RPC errors and surface as an app alert — the menu hides the item when no
    /// hook resolves, but the app's view can be a keystroke stale.
    func handleWorktreeRerunPreSession(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeRerunPreSessionParams.self, from: paramsData)
        // The hook's terminal is minted inside the lifecycle, so — as with
        // `worktree.revive` — the row names the worktree and no terminal. Every
        // rejection below happens after the row and confirms it as refused: the
        // lifecycle owns those checks, and duplicating them here to get ahead of
        // the row would be two implementations of one rule.
        let actuationID = try await beginActuation(
            .worktreeRerunPreSession, actor: actor,
            target: ActuationTarget(worktree: params.worktreeID.uuidString))
        do {
            try await lifecycle.rerunPreSessionHook(worktreeID: params.worktreeID, cols: params.cols, rows: params.rows)
            await finishActuation(actuationID, .dispatched)
            return .ok()
        } catch let error as RerunPreSessionError {
            await finishActuation(
                actuationID, .refused(Self.refusedReason(error)), error: error.description)
            return RPCResponse(error: error.description)
        } catch {
            await finishActuation(actuationID, .transportFailed, error: "\(error)")
            throw error
        }
    }

    /// Why a pre-session re-run was declined, in the record's closed vocabulary
    /// — so "which acts did my controls stop?" is a query over the envelope
    /// rather than a match on a message that may be reworded.
    private static func refusedReason(_ error: RerunPreSessionError) -> RefusedReason {
        switch error {
        case .worktreeNotFound: return .notFound
        case .noHookConfigured: return .notEligible
        // Both mean the same thing to a reader: this worktree's hook is already
        // running, under a manual re-run or under the create/revive phase 3.
        case .alreadyRunning, .worktreeBusy: return .inFlight
        }
    }

    func handleWorktreeForget(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeForgetParams.self, from: paramsData)

        // Capture the path before the row is deleted so the result can report
        // the directory we deliberately left on disk.
        let existing = try await db.worktrees.get(id: params.worktreeID)
        let path = existing?.localPath

        // Same gate, and for the same reason, as `worktree.archive` above.
        // Forget means "stop tracking this checkout but leave its files
        // alone", and a remote lane has no checkout here to leave alone:
        // `forgetWorktree` resolves its row through `getLocal` and throws
        // `worktreeNotFound` for a remote one. Without this gate the handler
        // would write a `.worktreeForget` request and then a `.transportFailed`
        // outcome for an act it structurally cannot perform, and the record may
        // only claim acts that were attempted — so the gate belongs above the
        // row, not in the catch below it. A *missing* row stays
        // `forgetWorktree`'s throw, unchanged.
        if let existing, !existing.location.isLocal {
            logger.debug("worktree.forget refused (remote lane): \(params.worktreeID, privacy: .public)")
            return RPCResponse(
                error: "Cannot forget \(existing.name): it is a remote lane, and forgetting one is not supported.")
        }

        // Forget kills the same windows archive does, so it records the same
        // shape: one worktree-named row per call, ahead of the first kill.
        let actuationID = try await beginActuation(
            .worktreeForget, actor: actor,
            target: ActuationTarget(worktree: params.worktreeID.uuidString))
        do {
            try await lifecycle.forgetWorktree(worktreeID: params.worktreeID)
        } catch {
            await finishActuation(actuationID, .transportFailed, error: "\(error)")
            throw error
        }
        await finishActuation(actuationID, .dispatched)

        // Reuse the archive delta — from the client's perspective the row has
        // left the active list, which is exactly what `.worktreeArchived`
        // signals. (forget hard-deletes, so it never appears in the archived
        // list either.)
        subscriptions.broadcast(delta: .worktreeArchived(WorktreeIDDelta(
            worktreeID: params.worktreeID
        )))

        return try RPCResponse(result: WorktreeForgetResult(
            worktreeID: params.worktreeID,
            path: path ?? ""
        ))
    }

    func handleWorktreeRevive(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeReviveParams.self, from: paramsData)
        // The row names the worktree, not a terminal: revive spawns its
        // primary terminals inside the lifecycle's own (possibly detached,
        // pre-session-gated) phase, so no terminal ID exists to name yet.
        let actuationID = try await beginActuation(
            .worktreeRevive, actor: actor,
            target: ActuationTarget(worktree: params.worktreeID.uuidString))
        // Non-blocking: when a preSession hook gates the primary terminals,
        // this returns promptly with the row in `.creating` (which is what
        // the app gates its pre-session UI on — beginReviveWorktree flips it
        // before returning) and the detached phase-3 task finishes the revive
        // in the background. Blocking here for up to the hook timeout (600s)
        // would starve the RPC connection.
        let completion: WorktreeReviveCompletion
        do {
            completion = try await lifecycle.beginReviveWorktree(
                worktreeID: params.worktreeID,
                cols: params.cols,
                rows: params.rows,
                preferredSessionID: params.preferredSessionID
            )
        } catch {
            await finishActuation(actuationID, .transportFailed, error: "\(error)")
            throw error
        }
        await finishActuation(actuationID, .dispatched)
        let worktree = completion.worktree

        subscriptions.broadcast(delta: .worktreeRevived(WorktreeDelta(
            worktreeID: worktree.id, repoID: worktree.repoID,
            name: worktree.name, path: worktree.localPath
        )))

        return try RPCResponse(result: worktree)
    }

    func handleWorktreeReviveConversationFresh(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(
            WorktreeReviveConversationFreshParams.self,
            from: paramsData
        )
        guard let source = try await db.worktrees.get(id: params.archivedWorktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(params.archivedWorktreeID)
        }
        guard source.status == .archived else {
            throw WorktreeLifecycleError.worktreeNotArchived(params.archivedWorktreeID)
        }
        guard let repoID = source.repoID else {
            throw WorktreeLifecycleError.invalidOperation(
                "Cannot revive a conversation on a fresh branch without a repository."
            )
        }

        // As in `handleWorktreeRevive`: the new worktree and its terminals are
        // minted inside the lifecycle, so the row names the source worktree
        // whose conversation is being brought back.
        let actuationID = try await beginActuation(
            .worktreeReviveConversationFresh, actor: actor,
            target: ActuationTarget(worktree: params.archivedWorktreeID.uuidString))

        let lifecycle = self.lifecycle
        let outcome: (
            completion: WorktreeCreateCompletion,
            result: WorktreeReviveConversationFreshResult
        )
        do {
            outcome = try await withCheckedThrowingContinuation { continuation in
                Task {
                    await repoSerializer.submit(repoID: repoID) {
                        do {
                            let outcome = try await lifecycle
                                .reviveConversationOnFreshBranch(
                                    archivedWorktreeID: params.archivedWorktreeID,
                                    sessionID: params.sessionID,
                                    cols: params.cols,
                                    rows: params.rows
                                )
                            continuation.resume(returning: outcome)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        } catch {
            await finishActuation(actuationID, .transportFailed, error: "\(error)")
            throw error
        }
        await finishActuation(actuationID, .dispatched)

        let created = outcome.result.worktree
        switch outcome.completion {
        case .ready:
            subscriptions.broadcast(delta: .worktreeCreated(WorktreeDelta(
                worktreeID: created.id,
                repoID: created.repoID,
                name: created.name,
                path: created.localPath
            )))
        case .preSessionPending:
            // The lifecycle already broadcast `.worktreeCreated` alongside
            // the pre-session terminal. Match ordinary create and do not
            // duplicate the row.
            break
        }
        return try RPCResponse(result: outcome.result)
    }

    func handleWorktreeAdopt(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeAdoptParams.self, from: paramsData)
        let outcome = try await lifecycle.adoptWorktree(
            repoID: params.repoID,
            path: params.path,
            displayName: params.displayName
        )
        let worktree = outcome.worktree

        // Pick the broadcast that matches what actually changed. Idempotent
        // calls (already-active) emit nothing — clients already know about
        // this row, and a spurious `.worktreeCreated` could cause duplicate
        // sidebar entries depending on client-side dedup.
        switch outcome {
        case .inserted:
            subscriptions.broadcast(delta: .worktreeCreated(WorktreeDelta(
                worktreeID: worktree.id, repoID: worktree.repoID,
                name: worktree.name, path: worktree.localPath
            )))
        case .revived:
            subscriptions.broadcast(delta: .worktreeRevived(WorktreeDelta(
                worktreeID: worktree.id, repoID: worktree.repoID,
                name: worktree.name, path: worktree.localPath
            )))
        case .unchanged:
            break
        }

        return try RPCResponse(result: worktree)
    }

    func handleWorktreeRename(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeRenameParams.self, from: paramsData)
        try await db.worktrees.rename(id: params.worktreeID, displayName: params.displayName)

        subscriptions.broadcast(delta: .worktreeRenamed(WorktreeRenameDelta(
            worktreeID: params.worktreeID, displayName: params.displayName
        )))

        return .ok()
    }

    func handleWorktreeReorder(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeReorderParams.self, from: paramsData)
        try await db.worktrees.reorder(repoID: params.repoID, worktreeIDs: params.worktreeIDs)

        subscriptions.broadcast(delta: .worktreeReordered(RepoIDDelta(
            repoID: params.repoID
        )))

        return .ok()
    }

    func handleWorktreeMove(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeMoveParams.self, from: paramsData)
        try await db.worktrees.move(
            worktreeID: params.worktreeID,
            newParentID: params.newParentID,
            newSortOrder: params.newSortOrder
        )

        // A worktree with active children isn't auto-archivable; disarm the new parent.
        if let newParentID = params.newParentID {
            do {
                try await db.worktrees.setAutoArchiveOnMerge(id: newParentID, value: false)
            } catch {
                logger.warning("failed to disarm auto-archive for \(newParentID, privacy: .public): \(error, privacy: .public)")
            }
        }

        subscriptions.broadcast(delta: .worktreeMoved(WorktreeMovedDelta(
            worktreeID: params.worktreeID,
            newParentID: params.newParentID,
            newSortOrder: params.newSortOrder
        )))

        return .ok()
    }

    func handleWorktreeSetAutoArchive(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeSetAutoArchiveParams.self, from: paramsData)
        try await db.worktrees.setAutoArchiveOnMerge(id: params.worktreeID, value: params.enabled)
        return .ok()
    }

    func handleWorktreeSetAutoHibernate(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeSetAutoHibernateParams.self, from: paramsData)
        try await db.worktrees.setAutoHibernateOnMerge(id: params.worktreeID, value: params.enabled)
        return .ok()
    }

    func handleWorktreeSetPin(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeSetPinParams.self, from: paramsData)
        // Stamped daemon-side so pin order is consistent across clients.
        try await db.worktrees.setPinned(id: params.worktreeID,
                                         pinnedAt: params.pinned ? Date() : nil)
        return .ok()
    }

    func handleWorktreeReorderPins(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeReorderPinsParams.self, from: paramsData)
        try await db.worktrees.reorderPins(worktreeIDs: params.worktreeIDs)
        return .ok()
    }

    /// Wire a queued-prompt coordinator to this router: route
    /// `worktree.setPendingPrompt` and the readiness hook to it, and give it
    /// the send seam its delivery needs.
    ///
    /// Both halves in one call, because either alone is a silent hole. Without
    /// the property the parking RPC refuses; without the seam every parked
    /// prompt reports "this daemon has no send path wired".
    ///
    /// The seam reaches the send core with the `<tbd-dispatch/>` envelope
    /// suppressed — a queued prompt is the operator's own words and must arrive
    /// byte-identical to what the argv path would have delivered.
    func attachPendingPromptCoordinator(_ coordinator: PendingPromptCoordinator) async {
        pendingPromptCoordinator = coordinator
        await coordinator.setDeliver { [self] terminalID, text, submit in
            await sendQueuedPromptVerbatim(
                terminalID: terminalID, text: text, submit: submit)
        }
    }

    /// Park the prompt the operator composed while the worktree was still
    /// being created (design 2026-08-10). A second, independent RPC sent after
    /// `worktree.create` is already in flight — it never participates in
    /// creation and never blocks it.
    ///
    /// The refusal is a **successful** response carrying `.refused`, not an RPC
    /// error: "the flag is off" is an answer about which delivery path the
    /// prompt took, and the caller branches on the result rather than on a
    /// thrown string. A daemon with no coordinator (mock mode) refuses for the
    /// same reason it refuses with the flag off — there is nothing that could
    /// deliver.
    func handleWorktreeSetPendingPrompt(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeSetPendingPromptParams.self, from: paramsData)
        guard let coordinator = pendingPromptCoordinator else {
            return try RPCResponse(result: WorktreeSetPendingPromptResult.refused(
                reason: "this daemon has no queued-prompt coordinator wired"))
        }
        let result = await coordinator.park(
            worktreeID: params.worktreeID, text: params.text, submit: params.submit)
        return try RPCResponse(result: result)
    }
}
