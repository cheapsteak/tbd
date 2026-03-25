import Foundation
import TBDShared

extension RPCRouter {

    // MARK: - Worktree Handlers

    func handleWorktreeCreate(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeCreateParams.self, from: paramsData)

        // Phase 1: Fast — insert DB row with status = .creating, return immediately
        let pending = try await lifecycle.beginCreateWorktree(repoID: params.repoID, name: params.name)

        // Phase 2: Fire-and-forget — git operations + tmux setup in background
        let lifecycle = self.lifecycle
        let subs = self.subscriptions
        Task.detached {
            do {
                try await lifecycle.completeCreateWorktree(worktreeID: pending.id)
                // Broadcast the completed worktree
                subs.broadcast(delta: .worktreeCreated(WorktreeDelta(
                    worktreeID: pending.id, repoID: pending.repoID,
                    name: pending.name, path: pending.path
                )))
            } catch {
                // completeCreateWorktree already deletes the DB row on failure.
                // Broadcast an archive delta so clients remove the pending entry.
                subs.broadcast(delta: .worktreeArchived(WorktreeIDDelta(
                    worktreeID: pending.id
                )))
                print("[RPCRouter] Background worktree creation failed for \(pending.id): \(error)")
            }
        }

        return try RPCResponse(result: pending)
    }

    func handleWorktreeList(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeListParams.self, from: paramsData)
        let worktrees = try await db.worktrees.list(repoID: params.repoID, status: params.status)
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

    func handleWorktreeRevive(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeReviveParams.self, from: paramsData)
        let worktree = try await lifecycle.reviveWorktree(worktreeID: params.worktreeID)

        subscriptions.broadcast(delta: .worktreeRevived(WorktreeDelta(
            worktreeID: worktree.id, repoID: worktree.repoID,
            name: worktree.name, path: worktree.path
        )))

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
}
