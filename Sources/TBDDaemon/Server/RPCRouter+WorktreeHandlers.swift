import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "worktreeHandlers")

extension RPCRouter {

    // MARK: - Worktree Handlers

    func handleWorktreeCreate(_ paramsData: Data) async throws -> RPCResponse {
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
            useExistingBranch: useExistingBranch
        )

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
        await repoSerializer.submit(repoID: pending.repoID) {
            do {
                let completion = try await lifecycle.completeCreateWorktree(worktreeID: pending.id, initialPrompt: initialPrompt, userSpecifiedFolder: userSpecifiedFolder, userSpecifiedBranch: userSpecifiedBranch, cols: cols, rows: rows, existingBranchRef: existingBranchRef)
                switch completion {
                case .ready:
                    subs.broadcast(delta: .worktreeCreated(WorktreeDelta(
                        worktreeID: pending.id, repoID: pending.repoID,
                        name: pending.name, path: pending.path
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
                subs.broadcast(delta: .worktreeArchived(WorktreeIDDelta(
                    worktreeID: pending.id
                )))
                logger.error("background worktreeCreate failed for \(pending.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        return try RPCResponse(result: pending)
    }

    func handleWorktreeList(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeListParams.self, from: paramsData)
        var worktrees = try await db.worktrees.list(
            repoID: params.repoID,
            status: params.status,
            excludeArchived: params.excludeArchived ?? false,
            limit: params.limit,
            offset: params.offset
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
        if params.status == .archived {
            for i in worktrees.indices where worktrees[i].status == .archived {
                if let dir = ClaudeProjectDirectory.resolve(worktreePath: worktrees[i].path) {
                    worktrees[i].liveClaudeSessionCount = ClaudeSessionScanner.countSessionFiles(projectDir: dir)
                } else {
                    worktrees[i].liveClaudeSessionCount = 0
                }
            }
        }
        return try RPCResponse(result: worktrees)
    }

    func handleWorktreeArchive(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeArchiveParams.self, from: paramsData)

        // Phase 1: Fast — update DB, kill tmux, return immediately
        let (worktree, repo) = try await lifecycle.beginArchiveWorktree(worktreeID: params.worktreeID)

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

    func handleWorktreeForget(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeForgetParams.self, from: paramsData)

        // Capture the path before the row is deleted so the result can report
        // the directory we deliberately left on disk.
        let path = try await db.worktrees.get(id: params.worktreeID)?.path

        try await lifecycle.forgetWorktree(worktreeID: params.worktreeID)

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

    func handleWorktreeRevive(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeReviveParams.self, from: paramsData)
        // Non-blocking: when a preSession hook gates the primary terminals,
        // this returns promptly with the row in `.creating` (which is what
        // the app gates its pre-session UI on — beginReviveWorktree flips it
        // before returning) and the detached phase-3 task finishes the revive
        // in the background. Blocking here for up to the hook timeout (600s)
        // would starve the RPC connection.
        let completion = try await lifecycle.beginReviveWorktree(
            worktreeID: params.worktreeID,
            cols: params.cols,
            rows: params.rows,
            preferredSessionID: params.preferredSessionID
        )
        let worktree = completion.worktree

        subscriptions.broadcast(delta: .worktreeRevived(WorktreeDelta(
            worktreeID: worktree.id, repoID: worktree.repoID,
            name: worktree.name, path: worktree.path
        )))

        return try RPCResponse(result: worktree)
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
                name: worktree.name, path: worktree.path
            )))
        case .revived:
            subscriptions.broadcast(delta: .worktreeRevived(WorktreeDelta(
                worktreeID: worktree.id, repoID: worktree.repoID,
                name: worktree.name, path: worktree.path
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
}
