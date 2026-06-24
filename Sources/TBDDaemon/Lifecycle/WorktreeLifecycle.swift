import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "reaper")

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
    public let pendingQuestions: PendingQuestionStore
    /// How long to wait for a blocking `preSession` hook before giving up and
    /// spawning the primary terminals anyway. Injectable for tests.
    public let preSessionTimeout: TimeInterval
    /// Poll interval for the preSession completion marker file.
    public let preSessionPollInterval: TimeInterval
    /// Process-signal seam for the agent reaper. Injectable for tests.
    public let processSignaller: ProcessSignaller
    /// Reaper grace knobs (kept small in tests to avoid real sleeps).
    public let reaperGraceAttempts: Int
    public let reaperPollInterval: Duration

    /// Default `preSession` hook timeout (production value).
    public static let defaultPreSessionTimeout: TimeInterval = 600

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
        modelProfileResolver: ModelProfileResolver? = nil,
        pendingQuestions: PendingQuestionStore = PendingQuestionStore(),
        preSessionTimeout: TimeInterval = WorktreeLifecycle.defaultPreSessionTimeout,
        preSessionPollInterval: TimeInterval = 0.5,
        processSignaller: ProcessSignaller = ProductionProcessSignaller(),
        reaperGraceAttempts: Int = 30,
        reaperPollInterval: Duration = .milliseconds(100)
    ) {
        self.db = db
        self.git = git
        self.tmux = tmux
        self.hooks = hooks
        self.subscriptions = subscriptions
        self.modelProfileResolver = modelProfileResolver
        self.pendingQuestions = pendingQuestions
        self.preSessionTimeout = preSessionTimeout
        self.preSessionPollInterval = preSessionPollInterval
        self.processSignaller = processSignaller
        self.reaperGraceAttempts = reaperGraceAttempts
        self.reaperPollInterval = reaperPollInterval
    }

    /// The agent reaper composed from the injected tmux + signaller seams.
    var reaper: AgentReaper {
        AgentReaper(tmux: tmux, signaller: processSignaller,
                    graceAttempts: reaperGraceAttempts, pollInterval: reaperPollInterval)
    }

    /// Kill a tmux window, then confirm the pane process actually died and
    /// escalate (SIGTERM→SIGKILL) if it survived the SIGHUP (wedged agent).
    func killWindowAndReap(server: String, windowID: String, paneID: String) async {
        let panePID = Int32((try? await tmux.panePID(server: server, paneID: paneID)) ?? "")
        do {
            try await tmux.killWindow(server: server, windowID: windowID)
        } catch {
            logger.warning("killWindow failed on \(server, privacy: .public) window \(windowID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        // Escalate even if killWindow threw — the pane process may still be alive.
        if let panePID { await reaper.escalateAfterHangup(panePID) }
    }
}
