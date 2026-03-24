import Foundation
import TBDShared

extension RPCRouter {

    // MARK: - Worktree Handlers

    func handleWorktreeCreate(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeCreateParams.self, from: paramsData)
        let worktree = try await lifecycle.createWorktree(repoID: params.repoID, name: params.name)

        subscriptions.broadcast(delta: .worktreeCreated(WorktreeDelta(
            worktreeID: worktree.id, repoID: worktree.repoID,
            name: worktree.name, path: worktree.path
        )))

        return try RPCResponse(result: worktree)
    }

    func handleWorktreeList(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeListParams.self, from: paramsData)
        let worktrees = try await db.worktrees.list(repoID: params.repoID, status: params.status)
        return try RPCResponse(result: worktrees)
    }

    func handleWorktreeArchive(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeArchiveParams.self, from: paramsData)
        try await lifecycle.archiveWorktree(worktreeID: params.worktreeID, force: params.force)

        subscriptions.broadcast(delta: .worktreeArchived(WorktreeIDDelta(
            worktreeID: params.worktreeID
        )))

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
