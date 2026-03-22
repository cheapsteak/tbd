import Foundation
import TBDShared

/// Errors that can occur during worktree lifecycle operations.
public enum WorktreeLifecycleError: Error, CustomStringConvertible {
    case repoNotFound(UUID)
    case worktreeNotFound(UUID)
    case worktreeNotArchived(UUID)
    case worktreeAlreadyActive(UUID)
    case createFailed(String)

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

    /// The user's default shell (from $SHELL, falls back to /bin/zsh)
    private var defaultShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    public init(db: TBDDatabase, git: GitManager, tmux: TmuxManager, hooks: HookResolver) {
        self.db = db
        self.git = git
        self.tmux = tmux
        self.hooks = hooks
    }

    // MARK: - Create

    /// Creates a new worktree for the given repository.
    ///
    /// Flow:
    /// 1. Fetch repo from db
    /// 2. git fetch origin <default_branch> (best effort)
    /// 3. Generate a unique name
    /// 4. git worktree add
    /// 5. Insert worktree into db
    /// 6. Create tmux windows
    /// 7. Insert terminals into db
    /// 8. Run setup hook
    ///
    /// - Parameters:
    ///   - repoID: The repository to create the worktree in.
    ///   - skipClaude: If true, skip launching claude in the first terminal window.
    /// - Returns: The newly created worktree.
    public func createWorktree(repoID: UUID, skipClaude: Bool = false) async throws -> Worktree {
        // 1. Fetch repo
        guard let repo = try await db.repos.get(id: repoID) else {
            throw WorktreeLifecycleError.repoNotFound(repoID)
        }

        // 2. Best-effort fetch from origin
        do {
            try await git.fetch(repoPath: repo.path, branch: repo.defaultBranch)
        } catch {
            // Continue with local state if fetch fails
        }

        // 3. Generate name and construct path
        let name = NameGenerator.generate()
        let branch = "tbd/\(name)"
        let worktreePath = (repo.path as NSString)
            .appendingPathComponent(".tbd/worktrees/\(name)")

        // 4. Create parent directory
        let parentDir = (worktreePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parentDir,
            withIntermediateDirectories: true
        )

        // 5. git worktree add - try origin/<branch> first, fall back to local <branch>
        let result = try await attemptWorktreeAdd(
            repoPath: repo.path, name: name, branch: branch,
            worktreePath: worktreePath, defaultBranch: repo.defaultBranch
        )

        return try await finishCreate(
            repo: repo, name: result.name, branch: result.branch,
            worktreePath: result.path, skipClaude: skipClaude
        )
    }

    /// Attempts to create a git worktree, trying origin/<default> then falling back
    /// to local <default> as the base branch. Retries once with a new name on collision.
    private func attemptWorktreeAdd(
        repoPath: String, name: String, branch: String,
        worktreePath: String, defaultBranch: String
    ) async throws -> (name: String, branch: String, path: String) {
        // Try with origin/<default> first, then local <default>
        let baseBranches = ["origin/\(defaultBranch)", defaultBranch]

        for baseBranch in baseBranches {
            do {
                try await git.worktreeAdd(
                    repoPath: repoPath,
                    worktreePath: worktreePath,
                    branch: branch,
                    baseBranch: baseBranch
                )
                return (name: name, branch: branch, path: worktreePath)
            } catch {
                // Clean up the directory if it was partially created
                try? FileManager.default.removeItem(atPath: worktreePath)
            }
        }

        // Retry with a fresh name (branch collision case)
        let retryName = NameGenerator.generate()
        let retryBranch = "tbd/\(retryName)"
        let retryPath = (repoPath as NSString)
            .appendingPathComponent(".tbd/worktrees/\(retryName)")
        let retryParentDir = (retryPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: retryParentDir,
            withIntermediateDirectories: true
        )

        for baseBranch in baseBranches {
            do {
                try await git.worktreeAdd(
                    repoPath: repoPath,
                    worktreePath: retryPath,
                    branch: retryBranch,
                    baseBranch: baseBranch
                )
                return (name: retryName, branch: retryBranch, path: retryPath)
            } catch {
                try? FileManager.default.removeItem(atPath: retryPath)
            }
        }

        throw WorktreeLifecycleError.createFailed(
            "git worktree add failed after all attempts"
        )
    }

    /// Completes the creation flow after the git worktree has been added.
    private func finishCreate(
        repo: Repo, name: String, branch: String,
        worktreePath: String, skipClaude: Bool
    ) async throws -> Worktree {
        let tmuxServer = TmuxManager.serverName(forRepoID: repo.id)

        // Insert worktree into db
        let worktree = try await db.worktrees.create(
            repoID: repo.id,
            name: name,
            branch: branch,
            path: worktreePath,
            tmuxServer: tmuxServer
        )

        // Ensure tmux server exists
        try await tmux.ensureServer(
            server: tmuxServer,
            session: "main",
            cwd: worktreePath
        )

        // Create terminal 1: claude (or shell if skipClaude)
        let claudeCommand: String
        if skipClaude {
            claudeCommand = defaultShell
        } else {
            claudeCommand = "claude --dangerously-skip-permissions"
        }
        let window1 = try await tmux.createWindow(
            server: tmuxServer,
            session: "main",
            cwd: worktreePath,
            shellCommand: claudeCommand
        )
        _ = try await db.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: window1.windowID,
            tmuxPaneID: window1.paneID,
            label: skipClaude ? "shell" : "claude"
        )

        // Create terminal 2: setup hook
        let setupHookPath = hooks.resolve(
            event: .setup,
            repoPath: repo.path,
            appHookPath: nil
        )
        let setupCommand = setupHookPath ?? defaultShell
        let window2 = try await tmux.createWindow(
            server: tmuxServer,
            session: "main",
            cwd: worktreePath,
            shellCommand: setupCommand
        )
        _ = try await db.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: window2.windowID,
            tmuxPaneID: window2.paneID,
            label: "setup"
        )

        return worktree
    }

    // MARK: - Archive

    /// Archives a worktree, cleaning up tmux windows and removing the git worktree.
    ///
    /// - Parameters:
    ///   - worktreeID: The worktree to archive.
    ///   - force: If true, skip running the archive hook.
    public func archiveWorktree(worktreeID: UUID, force: Bool = false) async throws {
        // Get worktree from db
        guard let worktree = try await db.worktrees.get(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }

        guard let repo = try await db.repos.get(id: worktree.repoID) else {
            throw WorktreeLifecycleError.repoNotFound(worktree.repoID)
        }

        // Run archive hook unless force
        if !force {
            let archiveHookPath = hooks.resolve(
                event: .archive,
                repoPath: repo.path,
                appHookPath: nil
            )
            if let hookPath = archiveHookPath {
                _ = try await hooks.execute(
                    hookPath: hookPath,
                    cwd: worktree.path,
                    env: [
                        "TBD_EVENT": "archive",
                        "TBD_WORKTREE_ID": worktree.id.uuidString,
                        "TBD_WORKTREE_NAME": worktree.name,
                        "TBD_WORKTREE_PATH": worktree.path,
                        "TBD_REPO_PATH": repo.path,
                        "TBD_BRANCH": worktree.branch,
                    ],
                    timeout: 60
                )
            }
        }

        // Kill all tmux windows for this worktree
        let terminals = try await db.terminals.list(worktreeID: worktreeID)
        for terminal in terminals {
            try? await tmux.killWindow(
                server: worktree.tmuxServer,
                windowID: terminal.tmuxWindowID
            )
        }

        // Delete terminals from db
        try await db.terminals.deleteForWorktree(worktreeID: worktreeID)

        // git worktree remove
        try await git.worktreeRemove(
            repoPath: repo.path,
            worktreePath: worktree.path
        )

        // Update worktree status to archived
        try await db.worktrees.archive(id: worktreeID)
    }

    // MARK: - Revive

    /// Revives an archived worktree, re-creating the git worktree and tmux windows.
    ///
    /// - Parameters:
    ///   - worktreeID: The archived worktree to revive.
    ///   - skipClaude: If true, skip launching claude in the first terminal window.
    /// - Returns: The revived worktree.
    public func reviveWorktree(worktreeID: UUID, skipClaude: Bool = false) async throws -> Worktree {
        guard let worktree = try await db.worktrees.get(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }

        guard worktree.status == .archived else {
            throw WorktreeLifecycleError.worktreeAlreadyActive(worktreeID)
        }

        guard let repo = try await db.repos.get(id: worktree.repoID) else {
            throw WorktreeLifecycleError.repoNotFound(worktree.repoID)
        }

        // Create parent directory if needed
        let parentDir = (worktree.path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parentDir,
            withIntermediateDirectories: true
        )

        // Re-add the git worktree using the existing branch
        try await git.worktreeAddExisting(
            repoPath: repo.path,
            worktreePath: worktree.path,
            branch: worktree.branch
        )

        // Ensure tmux server
        try await tmux.ensureServer(
            server: worktree.tmuxServer,
            session: "main",
            cwd: worktree.path
        )

        // Create terminal 1: claude (or shell)
        let claudeCommand = skipClaude ? defaultShell : "claude --dangerously-skip-permissions"
        let window1 = try await tmux.createWindow(
            server: worktree.tmuxServer,
            session: "main",
            cwd: worktree.path,
            shellCommand: claudeCommand
        )
        _ = try await db.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: window1.windowID,
            tmuxPaneID: window1.paneID,
            label: skipClaude ? "shell" : "claude"
        )

        // Create terminal 2: setup hook
        let setupHookPath = hooks.resolve(
            event: .setup,
            repoPath: repo.path,
            appHookPath: nil
        )
        let setupCommand = setupHookPath ?? defaultShell
        let window2 = try await tmux.createWindow(
            server: worktree.tmuxServer,
            session: "main",
            cwd: worktree.path,
            shellCommand: setupCommand
        )
        _ = try await db.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: window2.windowID,
            tmuxPaneID: window2.paneID,
            label: "setup"
        )

        // Update status to active
        try await db.worktrees.revive(id: worktreeID)

        // Return updated worktree
        guard let revived = try await db.worktrees.get(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }
        return revived
    }

    // MARK: - Reconcile

    /// Reconciles the database state with actual git worktrees on disk.
    ///
    /// - Worktrees in db but missing from git: marked as archived
    /// - Worktrees in git but missing from db: added with default names
    public func reconcile(repoID: UUID) async throws {
        guard let repo = try await db.repos.get(id: repoID) else {
            throw WorktreeLifecycleError.repoNotFound(repoID)
        }

        let gitWorktrees = try await git.worktreeList(repoPath: repo.path)
        let dbWorktrees = try await db.worktrees.list(repoID: repoID, status: .active)

        let gitPaths = Set(gitWorktrees.map(\.path))
        let dbPaths = Set(dbWorktrees.map(\.path))

        // Mark missing worktrees as archived
        for wt in dbWorktrees where !gitPaths.contains(wt.path) {
            // Clean up terminals
            try await db.terminals.deleteForWorktree(worktreeID: wt.id)
            try await db.worktrees.archive(id: wt.id)
        }

        // Add unknown worktrees (skip the main repo worktree)
        let tbdWorktreePrefix = (repo.path as NSString)
            .appendingPathComponent(".tbd/worktrees/")
        for gitWt in gitWorktrees where !dbPaths.contains(gitWt.path) {
            // Only track worktrees inside .tbd/worktrees/
            guard gitWt.path.hasPrefix(tbdWorktreePrefix) else { continue }

            let name = (gitWt.path as NSString).lastPathComponent
            let tmuxServer = TmuxManager.serverName(forRepoID: repoID)
            _ = try await db.worktrees.create(
                repoID: repoID,
                name: name,
                branch: gitWt.branch,
                path: gitWt.path,
                tmuxServer: tmuxServer
            )
        }
    }
}
