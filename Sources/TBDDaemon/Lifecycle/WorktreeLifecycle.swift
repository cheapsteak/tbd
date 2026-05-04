import Foundation
import TBDShared

/// Errors that can occur during worktree lifecycle operations.
public enum WorktreeLifecycleError: Error, CustomStringConvertible, LocalizedError {
    case repoNotFound(UUID)
    case worktreeNotFound(UUID)
    case worktreeNotArchived(UUID)
    case worktreeAlreadyActive(UUID)
    case createFailed(String)
    case invalidOperation(String)
    case worktreePathAlreadyExists(String)
    case worktreeAlreadyRegistered(String)
    /// The archived worktree's branch no longer exists and we have no captured
    /// HEAD SHA to fall back to — there's no safe way to recreate the working tree.
    case branchMissingNoFallback(branch: String)

    public var description: String {
        switch self {
        case .repoNotFound(let id):
            return "Repository not found: \(id)"
        case .worktreeNotFound(let id):
            return "Worktree not found: \(id)"
        case .worktreeNotArchived(let id):
            return "Worktree is not archived: \(id)"
        case .worktreeAlreadyActive(let id):
            return "Worktree is already active: \(id)"
        case .createFailed(let reason):
            return "Failed to create worktree: \(reason)"
        case .invalidOperation(let detail):
            return detail
        case .worktreePathAlreadyExists(let path):
            return "Cannot revive worktree: a file or directory already exists at \(path). Remove or move it and try again."
        case .worktreeAlreadyRegistered(let path):
            return "Cannot revive worktree: git already has a worktree registered at \(path). Run `git worktree remove \(path)` (or `git worktree prune`) from the main repo and try again."
        case .branchMissingNoFallback(let branch):
            return "Cannot revive worktree: branch '\(branch)' no longer exists in the repository, and no archived HEAD SHA was captured to fall back to. The branch may have been renamed or deleted before this worktree was archived."
        }
    }

    public var errorDescription: String? { description }
}

/// Orchestrates the full lifecycle of worktrees: create, archive, revive, and reconcile.
///
/// Coordinates between git, the database, tmux, and hooks to provide
/// high-level operations that maintain consistency across all subsystems.
public struct WorktreeLifecycle: Sendable {
    public let db: TBDDatabase
    public let git: GitManager
    public let tmux: TmuxManager
    public let hooks: HookResolver
    public let subscriptions: StateSubscriptionManager?
    public let modelProfileResolver: ModelProfileResolver?

    /// The user's default shell (from $SHELL, falls back to /bin/zsh)
    var defaultShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    public init(
        db: TBDDatabase,
        git: GitManager,
        tmux: TmuxManager,
        hooks: HookResolver,
        subscriptions: StateSubscriptionManager? = nil,
        modelProfileResolver: ModelProfileResolver? = nil
    ) {
        self.db = db
        self.git = git
        self.tmux = tmux
        self.hooks = hooks
        self.subscriptions = subscriptions
        self.modelProfileResolver = modelProfileResolver
    }
}
