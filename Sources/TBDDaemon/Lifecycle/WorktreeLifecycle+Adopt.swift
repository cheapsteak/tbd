import Foundation
import os
import TBDShared

private let adoptLogger = Logger(subsystem: "com.tbd.daemon", category: "worktreeAdopt")

/// The outcome of an `adoptWorktree` call. Conveys whether a new row was
/// inserted, an archived row was revived, or an active row was returned
/// unchanged — so the RPC handler can pick the right delta to broadcast
/// (or skip the broadcast entirely on the idempotent path).
public enum WorktreeAdoptOutcome: Sendable {
    case inserted(Worktree)
    case revived(Worktree)
    case unchanged(Worktree)

    public var worktree: Worktree {
        switch self {
        case .inserted(let w), .revived(let w), .unchanged(let w):
            return w
        }
    }
}

extension WorktreeLifecycle {
    // MARK: - Adopt

    /// Adopt an existing git worktree directory into TBD.
    ///
    /// Unlike `createWorktree`, this does NOT call `git worktree add` and does
    /// NOT spawn tmux terminals — the on-disk worktree is assumed to already
    /// exist and be registered with git. We just insert a `worktrees` row
    /// pointing at it. The user (or app) can spawn terminals later via the
    /// regular terminal-create flow.
    ///
    /// Idempotent:
    /// - If an active worktree row already exists for `path`, returns `.unchanged`.
    /// - If an archived row exists for `path`, flips its status to `.active`,
    ///   applies any `displayName` override, and returns `.revived`.
    /// - Otherwise inserts a fresh row and returns `.inserted`.
    public func adoptWorktree(
        repoID: UUID,
        path: String,
        displayName: String? = nil
    ) async throws -> WorktreeAdoptOutcome {
        guard let repo = try await db.repos.get(id: repoID) else {
            throw WorktreeLifecycleError.repoNotFound(repoID)
        }

        // Verify git knows about this worktree path. If we adopted a path git
        // doesn't track, TBD would archive it on the next reconcile sweep.
        let gitWorktrees = try await git.worktreeList(repoPath: repo.path)
        guard let gitWt = gitWorktrees.first(where: { $0.path == path }) else {
            throw WorktreeAdoptError.notInGitWorktreeList(path: path)
        }

        let name = (path as NSString).lastPathComponent
        let tmuxServer = TmuxManager.serverName(forRepoPath: repo.path)

        // Idempotency: check for an existing row at this exact path.
        let existingActive = try await db.worktrees.list(repoID: repoID, status: .active)
        if let match = existingActive.first(where: { $0.path == path }) {
            adoptLogger.info("adoptWorktree: \(path, privacy: .public) already active as \(match.id, privacy: .public)")
            return .unchanged(match)
        }
        let existingArchived = try await db.worktrees.list(repoID: repoID, status: .archived)
        if let match = existingArchived.first(where: { $0.path == path }) {
            adoptLogger.info("adoptWorktree: reviving archived row \(match.id, privacy: .public) for \(path, privacy: .public)")
            try await db.worktrees.updateStatus(id: match.id, status: .active)
            // Honor caller's displayName override on revival — without this, a
            // user calling `tbd worktree adopt <path> --name "New Label"` would
            // silently keep the row's old archived name.
            if let displayName, displayName != match.displayName {
                try await db.worktrees.rename(id: match.id, displayName: displayName)
            }
            guard let refreshed = try await db.worktrees.get(id: match.id) else {
                throw WorktreeLifecycleError.worktreeNotFound(match.id)
            }
            return .revived(refreshed)
        }

        let worktree = try await db.worktrees.create(
            repoID: repoID,
            name: name,
            displayName: displayName ?? name,
            branch: gitWt.branch,
            path: path,
            tmuxServer: tmuxServer,
            status: .active
        )
        adoptLogger.info("adoptWorktree: inserted \(worktree.id, privacy: .public) for \(path, privacy: .public)")
        return .inserted(worktree)
    }
}

public enum WorktreeAdoptError: Error, CustomStringConvertible {
    case notInGitWorktreeList(path: String)

    public var description: String {
        switch self {
        case .notInGitWorktreeList(let path):
            return "Path is not registered in `git worktree list` for the resolved repo: \(path). Run `git worktree repair` and retry."
        }
    }
}
