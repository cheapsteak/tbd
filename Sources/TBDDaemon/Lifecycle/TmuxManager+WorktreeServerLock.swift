import Foundation
import TBDShared

extension TmuxManager {
    /// Locks the worktree's current tmux server and revalidates the row after
    /// waiting. Promotion and reconcile can change `tmuxServer` while a caller
    /// is queued; retrying prevents a window from being created on the stale
    /// server after the lock protecting it has already been released.
    func withWorktreeServerLock<Result: Sendable>(
        db: TBDDatabase,
        worktreeID: UUID,
        allowedStatuses: Set<WorktreeStatus>,
        operation: @Sendable (LocalWorktree) async throws -> Result
    ) async throws -> Result {
        while true {
            guard let candidate = try await db.worktrees.getLocal(id: worktreeID) else {
                throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
            }
            guard allowedStatuses.contains(candidate.status) else {
                throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
            }
            let candidateServer = candidate.tmuxServer
            let result: Result? = try await withServerResourceLock(server: candidateServer) {
                guard let current = try await db.worktrees.getLocal(id: worktreeID) else {
                    throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
                }
                guard allowedStatuses.contains(current.status) else {
                    throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
                }
                guard current.tmuxServer == candidateServer else { return nil }
                return try await operation(current)
            }
            if let result { return result }
        }
    }
}
