import Foundation
import TBDShared

extension WorktreeLifecycle {
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
    public func createWorktree(repoID: UUID, name: String? = nil, skipClaude: Bool = false) async throws -> Worktree {
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
        let name = name ?? NameGenerator.generate()
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

    /// Wraps a command so the user's shell takes over when it exits,
    /// preventing tmux from destroying the window and jumping to another.
    /// If the command is already the user's shell, returns it unchanged.
    private func shellWrapped(_ command: String) -> String {
        if command == defaultShell { return command }
        let escaped = command.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'; exec \(defaultShell)"
    }

    /// Sets up tmux windows and terminal records for a worktree.
    /// Shared by `finishCreate` and `reviveWorktree`.
    func setupTerminals(
        worktreeID: UUID, repoPath: String,
        tmuxServer: String, worktreePath: String, skipClaude: Bool
    ) async throws {
        // Ensure tmux server exists — capture initial window ID to kill later
        let initialWindowID = try await tmux.ensureServer(
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
            worktreeID: worktreeID,
            tmuxWindowID: window1.windowID,
            tmuxPaneID: window1.paneID,
            label: skipClaude ? "shell" : "claude"
        )

        // Create terminal 2: setup hook
        let setupHookPath = hooks.resolve(
            event: .setup,
            repoPath: repoPath,
            appHookPath: nil
        )
        let setupCommand = shellWrapped(setupHookPath ?? defaultShell)
        let window2 = try await tmux.createWindow(
            server: tmuxServer,
            session: "main",
            cwd: worktreePath,
            shellCommand: setupCommand
        )
        _ = try await db.terminals.create(
            worktreeID: worktreeID,
            tmuxWindowID: window2.windowID,
            tmuxPaneID: window2.paneID,
            label: "setup"
        )

        // Kill the untracked initial window that new-session created
        if let windowID = initialWindowID {
            try? await tmux.killWindow(server: tmuxServer, windowID: windowID)
        }
    }

    /// Completes the creation flow after the git worktree has been added.
    private func finishCreate(
        repo: Repo, name: String, branch: String,
        worktreePath: String, skipClaude: Bool
    ) async throws -> Worktree {
        let tmuxServer = TmuxManager.serverName(forRepoPath: repo.path)

        // Insert worktree into db
        let worktree = try await db.worktrees.create(
            repoID: repo.id,
            name: name,
            branch: branch,
            path: worktreePath,
            tmuxServer: tmuxServer
        )

        try await setupTerminals(
            worktreeID: worktree.id, repoPath: repo.path,
            tmuxServer: tmuxServer, worktreePath: worktreePath,
            skipClaude: skipClaude
        )

        return worktree
    }
}
