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
    /// Routes ambient claude-projects-root resolution for the revive
    /// transcript sync — injectable (mirroring `RPCRouter.configDirManager`)
    /// so tests point it at a temp dir instead of falling back to the real
    /// `~/.claude`.
    public let configDirManager: ClaudeProfileConfigDirManager
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
    /// Resolves the Codex CLI before lifecycle code creates tmux or DB state.
    /// Stored as a seam so tests do not require Codex or ChatGPT.app installed.
    let codexExecutableResolver: @Sendable () throws -> String
    /// Prepares TBD's profile in the user's existing global Codex home before
    /// lifecycle code creates tmux or terminal state.
    let codexHomeEnsurer: @Sendable () throws -> URL
    /// Dirty gate for the periodic conflict sweep (see `refreshGitStatuses`).
    /// An actor reference, so every copy of this struct shares one cache.
    public let conflictSweepCache = ConflictSweepCache()
    /// In-flight `preSession` runs, keyed by worktree ID. An actor reference,
    /// so every copy of this struct shares one registry (same rationale as
    /// `conflictSweepCache`).
    public let preSessionRuns = PreSessionRunRegistry()
    /// Where archived worktree directories go before their bytes are
    /// reclaimed. See `WorktreeDeletionQueue`.
    let deletionQueue = WorktreeDeletionQueue()

    /// Default `preSession` hook timeout (production value).
    public static let defaultPreSessionTimeout: TimeInterval = 600

    /// Fired once a worktree's directory has genuinely left its pool slot —
    /// on the success path, right after `completeArchiveWorktree` renames it
    /// into `WorktreeDeletionQueue` (bytes may still be draining); on the
    /// fallback leg, only once `git.worktreeRemove` is verified to have
    /// actually removed it from disk. Carries the removed worktree's path and
    /// its owning repo's path (the archive caller has `repo` in scope). `nil`
    /// by default (tests, older callers).
    /// `Daemon` wires this to
    /// `OrphanGC.scratchpadCleanup(forRemovedWorktreePath:repoPath:)` so the
    /// worktree's Claude Code scratchpad is reclaimed event-driven instead of
    /// waiting for the next hourly sweep, stamped with the repo path so it
    /// surfaces in that repo's History UI. Deliberately NOT fired by
    /// `forgetWorktree` — forget leaves the directory in place.
    public var onWorktreeRemoved: (@Sendable (_ worktreePath: String, _ repoPath: String) async -> Void)?

    /// Opt-in tmux control-mode wiring. `nil` when the daemon did not provide
    /// one (tests, older callers); when present, lifecycle paths open a gated
    /// logging-only `tmux -CC` connection after each `ensureServer()`.
    ///
    /// Set by `Daemon` after construction (`internal`, so the public init's
    /// signature does not leak the internal bridge type).
    var controlMode: TmuxControlModeBridge?

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
        configDirManager: ClaudeProfileConfigDirManager = ClaudeProfileConfigDirManager(),
        preSessionTimeout: TimeInterval = WorktreeLifecycle.defaultPreSessionTimeout,
        preSessionPollInterval: TimeInterval = 0.5,
        processSignaller: ProcessSignaller = ProductionProcessSignaller(),
        reaperGraceAttempts: Int = 30,
        reaperPollInterval: Duration = .milliseconds(100),
        codexExecutableResolver: (@Sendable () throws -> String)? = nil,
        codexHomeEnsurer: (@Sendable () throws -> URL)? = nil
    ) {
        self.db = db
        self.git = git
        self.tmux = tmux
        self.hooks = hooks
        self.subscriptions = subscriptions
        self.modelProfileResolver = modelProfileResolver
        self.pendingQuestions = pendingQuestions
        self.configDirManager = configDirManager
        self.controlMode = nil
        self.preSessionTimeout = preSessionTimeout
        self.preSessionPollInterval = preSessionPollInterval
        self.processSignaller = processSignaller
        self.reaperGraceAttempts = reaperGraceAttempts
        self.reaperPollInterval = reaperPollInterval
        self.codexExecutableResolver = codexExecutableResolver ?? {
            if tmux.dryRun { return "/opt/tbd-test/bin/codex" }
            return try CodexExecutableResolver.resolve()
        }
        self.codexHomeEnsurer = codexHomeEnsurer ?? {
            if tmux.dryRun {
                return URL(fileURLWithPath: "/tmp/tbd-dry-run-codex-home", isDirectory: true)
            }
            return try CodexHomeManager().ensureProfilePlugin()
        }
    }

    /// Projects root for a revive spawn's resolved profile config dir path,
    /// falling back to the lifecycle's (injectable) ambient claude dir.
    /// Mirrors `RPCRouter.claudeProjectsRoot(profileConfigDirPath:)`: unlike
    /// `TranscriptProjectDirSync.projectsRoot`, whose nil-profile fallback
    /// constructs a default manager (real `~/.claude`), this routes through
    /// `configDirManager` so tests isolate via the injection seam.
    func claudeProjectsRoot(profileConfigDirPath: String?) -> URL {
        if let path = profileConfigDirPath, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
        }
        return configDirManager.ambientConfigDirectory
            .appendingPathComponent("projects", isDirectory: true)
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

    /// Capture a live terminal's scrollback into Closed Terminals history
    /// (best-effort), then kill its window and reap the pane. Used by the
    /// archive paths (explicit archive + reconcile auto-archive), where the
    /// worktree row and its `terminal_history` rows survive — unlike the
    /// hard-delete paths (Forget/Recovery/scratch.delete) that wipe history
    /// immediately after and so deliberately skip the capture. Capturing must
    /// happen before the window dies; mirrors `closeHookTerminal`'s
    /// never-throws capture (failures are logged inside `captureOnClose` and
    /// never block the teardown).
    func captureThenKillWindow(terminal: Terminal, server: String) async {
        await db.terminalHistory.captureOnClose(terminal: terminal) {
            try await tmux.capturePaneScrollback(server: server, paneID: terminal.tmuxPaneID)
        }
        await killWindowAndReap(
            server: server,
            windowID: terminal.tmuxWindowID,
            paneID: terminal.tmuxPaneID
        )
    }
}
