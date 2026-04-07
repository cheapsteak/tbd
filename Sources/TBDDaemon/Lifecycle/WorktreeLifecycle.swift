import Foundation
import TBDShared

/// Errors that can occur during worktree lifecycle operations.
public enum WorktreeLifecycleError: Error, CustomStringConvertible {
    case repoNotFound(UUID)
    case worktreeNotFound(UUID)
    case worktreeNotArchived(UUID)
    case worktreeAlreadyActive(UUID)
    case createFailed(String)
    case invalidOperation(String)

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
        }
    }
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
    public let claudeTokenResolver: ClaudeTokenResolver?

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
        claudeTokenResolver: ClaudeTokenResolver? = nil
    ) {
        self.db = db
        self.git = git
        self.tmux = tmux
        self.hooks = hooks
        self.subscriptions = subscriptions
        self.claudeTokenResolver = claudeTokenResolver
    }
}
