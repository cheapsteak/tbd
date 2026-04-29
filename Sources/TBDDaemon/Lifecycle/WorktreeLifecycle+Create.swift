import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "worktreeLifecycle")

extension WorktreeLifecycle {
    // MARK: - Create

    /// Creates a new worktree for the given repository (synchronous, blocking).
    ///
    /// This is the legacy all-in-one method. Prefer `beginCreateWorktree` +
    /// `completeCreateWorktree` for non-blocking creation.
    public func createWorktree(repoID: UUID, folder: String? = nil, branch: String? = nil, displayName: String? = nil, skipClaude: Bool = false, initialPrompt: String? = nil, cols: Int? = nil, rows: Int? = nil) async throws -> Worktree {
        let pending = try await beginCreateWorktree(repoID: repoID, folder: folder, branch: branch, displayName: displayName, skipClaude: skipClaude)
        try await completeCreateWorktree(worktreeID: pending.id, skipClaude: skipClaude, initialPrompt: initialPrompt, userSpecifiedFolder: folder != nil, userSpecifiedBranch: branch != nil, cols: cols, rows: rows)
        guard let completed = try await db.worktrees.get(id: pending.id) else {
            throw WorktreeLifecycleError.worktreeNotFound(pending.id)
        }
        return completed
    }

    // MARK: - Two-Phase Create

    /// Phase 1: Synchronous-fast. Generates a name, inserts a DB row with
    /// `status = .creating`, and returns the worktree immediately.
    /// NO git operations happen here.
    public func beginCreateWorktree(repoID: UUID, folder: String? = nil, branch: String? = nil, displayName: String? = nil, skipClaude: Bool = false) async throws -> Worktree {
        // 1. Fetch repo
        guard let repo = try await db.repos.get(id: repoID) else {
            throw WorktreeLifecycleError.repoNotFound(repoID)
        }

        // 2. Generate name and construct path
        let name = folder ?? NameGenerator.generate()
        let branch = branch ?? "tbd/\(name)"
        let layout = WorktreeLayout()
        let canonicalBase = layout.basePath(for: repo)
        // Lazily create the canonical base directory for this slot.
        // (Phase A's v14_worktree_location migration guarantees worktreeSlot is set
        // for every repo, so basePath(for:) won't precondition-fail here.)
        try? FileManager.default.createDirectory(
            atPath: canonicalBase, withIntermediateDirectories: true
        )
        // try? above swallows both "already exists" (fine) and permission
        // errors (not fine). Verify the dir actually exists so a permission
        // failure surfaces here instead of as a misleading `git worktree add`
        // error downstream.
        if !FileManager.default.fileExists(atPath: canonicalBase) {
            logger.error("Failed to create worktree base dir \(canonicalBase, privacy: .public)")
        }
        let worktreePath = (canonicalBase as NSString).appendingPathComponent(name)
        let tmuxServer = TmuxManager.serverName(forRepoPath: repo.path)

        // 3. Insert DB row with status = .creating
        let worktree = try await db.worktrees.create(
            repoID: repo.id,
            name: name,
            displayName: displayName,
            branch: branch,
            path: worktreePath,
            tmuxServer: tmuxServer,
            status: .creating
        )

        return worktree
    }

    /// Phase 2: Async. Performs git fetch, git worktree add, tmux setup,
    /// then updates status to `.active`. On failure, deletes the DB row.
    public func completeCreateWorktree(worktreeID: UUID, skipClaude: Bool = false, initialPrompt: String? = nil, userSpecifiedFolder: Bool = false, userSpecifiedBranch: Bool = false, cols: Int? = nil, rows: Int? = nil) async throws {
        guard let worktree = try await db.worktrees.get(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }
        guard let repo = try await db.repos.get(id: worktree.repoID) else {
            try? await db.worktrees.delete(id: worktreeID)
            throw WorktreeLifecycleError.repoNotFound(worktree.repoID)
        }

        do {
            // 1. Best-effort fetch from origin
            do {
                try await git.fetch(repoPath: repo.path, branch: repo.defaultBranch)
            } catch {
                // Continue with local state if fetch fails
            }

            // 2. Create parent directory
            let parentDir = (worktree.path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: parentDir,
                withIntermediateDirectories: true
            )

            // 3. git worktree add
            let result = try await attemptWorktreeAdd(
                repo: repo, name: worktree.name, branch: worktree.branch,
                worktreePath: worktree.path,
                userSpecifiedFolder: userSpecifiedFolder,
                userSpecifiedBranch: userSpecifiedBranch
            )

            // 4. If the name changed due to collision, update the DB record
            if result.name != worktree.name {
                // Update path/branch/name in DB would be complex — for now the retry
                // names the worktree path differently but we keep the original DB row.
                // The attemptWorktreeAdd already handles retries.
            }

            // 5. Setup tmux terminals
            try await setupTerminals(
                worktree: worktree, repo: repo,
                worktreePath: result.path,
                skipClaude: skipClaude,
                initialPrompt: initialPrompt,
                cols: cols,
                rows: rows
            )

            // 6. Update status to active
            try await db.worktrees.updateStatus(id: worktreeID, status: .active)

        } catch {
            // On failure, delete the DB row
            try? await db.worktrees.delete(id: worktreeID)
            throw error
        }
    }

    /// Attempts to create a git worktree, trying origin/<default> then falling back
    /// to local <default> as the base branch. Retries once with a new name on collision.
    private func attemptWorktreeAdd(
        repo: Repo, name: String, branch: String,
        worktreePath: String,
        userSpecifiedFolder: Bool,
        userSpecifiedBranch: Bool
    ) async throws -> (name: String, branch: String, path: String) {
        let repoPath = repo.path
        let defaultBranch = repo.defaultBranch
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

        // Fail immediately if user specified the folder — can't silently change it
        if userSpecifiedFolder {
            throw WorktreeLifecycleError.createFailed(
                "git worktree add failed — the folder or branch may already exist"
            )
        }

        // Retry with a fresh folder name. Keep user's branch if they specified it.
        let retryName = NameGenerator.generate()
        let retryBranch = userSpecifiedBranch ? branch : "tbd/\(retryName)"
        let retryCanonicalBase = WorktreeLayout().basePath(for: repo)
        let retryPath = (retryCanonicalBase as NSString).appendingPathComponent(retryName)
        try FileManager.default.createDirectory(
            atPath: retryCanonicalBase,
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
    ///
    /// When `archivedClaudeSessions` is provided (revive path), the first session ID
    /// is reused for the main Claude terminal to restore the conversation, and any
    /// additional sessions get their own terminal windows.
    func setupTerminals(
        worktree: Worktree, repo: Repo,
        worktreePath: String? = nil, skipClaude: Bool,
        archivedClaudeSessions: [String]? = nil,
        initialPrompt: String? = nil,
        cols: Int? = nil,
        rows: Int? = nil
    ) async throws {
        let worktreeID = worktree.id
        let tmuxServer = worktree.tmuxServer
        let worktreePath = worktreePath ?? worktree.path
        // Resolve a usable size: prefer caller's value, otherwise fall back to
        // 220x50. tmux's own 80x24 default would let Claude render into hard-
        // wrapped scrollback that can never be reflowed when the user later
        // attaches a wider SwiftTerm view.
        let resolvedCols = cols ?? 220
        let resolvedRows = rows ?? 50
        // Ensure tmux server exists — capture initial window ID to kill later
        let initialWindowID = try await tmux.ensureServer(
            server: tmuxServer,
            session: "main",
            cwd: worktreePath,
            cols: resolvedCols,
            rows: resolvedRows
        )

        // Resolve claude token (repo override → global default → none).
        // Failures here must NOT break worktree creation — fall back to keychain login.
        var resolvedToken: ResolvedClaudeToken? = nil
        if !skipClaude, let resolver = claudeTokenResolver {
            do {
                resolvedToken = try await resolver.resolve(repoID: repo.id)
            } catch {
                logger.warning("claude token resolution failed; falling back to keychain login")
                resolvedToken = nil
            }
        }

        // Create terminal 1: claude (or shell if skipClaude)
        let claudeCommand: String
        let claudeSensitiveEnv: [String: String]
        let claudeSessionID: String?
        let claudeTokenID: UUID?
        if skipClaude {
            claudeCommand = defaultShell
            claudeSensitiveEnv = [:]
            claudeSessionID = nil
            claudeTokenID = nil
        } else {
            let sessionUUID = archivedClaudeSessions?.first ?? UUID().uuidString
            claudeSessionID = sessionUUID
            let isResume = archivedClaudeSessions?.first != nil
            let appendPrompt = SystemPromptBuilder.build(repo: repo, worktree: worktree, isResume: isResume)
            let spawn = ClaudeSpawnCommandBuilder.build(
                resumeID: nil,
                freshSessionID: sessionUUID,
                appendSystemPrompt: appendPrompt,
                initialPrompt: isResume ? nil : initialPrompt,
                tokenSecret: resolvedToken?.secret,
                tokenKind: resolvedToken?.kind,
                cmd: nil,
                shellFallback: defaultShell
            )
            claudeCommand = spawn.command
            claudeSensitiveEnv = spawn.sensitiveEnv
            claudeTokenID = resolvedToken?.tokenID
        }
        let window1 = try await tmux.createWindow(
            server: tmuxServer,
            session: "main",
            cwd: worktreePath,
            shellCommand: claudeCommand,
            sensitiveEnv: claudeSensitiveEnv,
            cols: resolvedCols,
            rows: resolvedRows
        )
        _ = try await db.terminals.create(
            worktreeID: worktreeID,
            tmuxWindowID: window1.windowID,
            tmuxPaneID: window1.paneID,
            label: skipClaude ? "shell" : "Claude Code",
            claudeSessionID: claudeSessionID,
            claudeTokenID: claudeTokenID
        )

        // Create terminal 2: setup hook
        let setupHookPath = hooks.resolve(
            event: .setup,
            repoPath: worktreePath,
            appHookPath: TBDConstants.hookPath(repoID: worktree.repoID, eventName: HookEvent.setup.rawValue)
        )
        let setupCommand = shellWrapped(setupHookPath ?? defaultShell)
        let window2 = try await tmux.createWindow(
            server: tmuxServer,
            session: "main",
            cwd: worktreePath,
            shellCommand: setupCommand,
            cols: resolvedCols,
            rows: resolvedRows
        )
        _ = try await db.terminals.create(
            worktreeID: worktreeID,
            tmuxWindowID: window2.windowID,
            tmuxPaneID: window2.paneID,
            label: "setup"
        )

        // Restore additional archived Claude sessions (beyond the first which was used above)
        if !skipClaude, let sessions = archivedClaudeSessions, sessions.count > 1 {
            for sessionID in sessions.dropFirst() {
                let spawn = ClaudeSpawnCommandBuilder.build(
                    resumeID: nil,
                    freshSessionID: sessionID,
                    appendSystemPrompt: nil,
                    initialPrompt: nil,
                    tokenSecret: resolvedToken?.secret,
                    tokenKind: resolvedToken?.kind,
                    cmd: nil,
                    shellFallback: defaultShell
                )
                let window = try await tmux.createWindow(
                    server: tmuxServer,
                    session: "main",
                    cwd: worktreePath,
                    shellCommand: spawn.command,
                    sensitiveEnv: spawn.sensitiveEnv,
                    cols: resolvedCols,
                    rows: resolvedRows
                )
                _ = try await db.terminals.create(
                    worktreeID: worktreeID,
                    tmuxWindowID: window.windowID,
                    tmuxPaneID: window.paneID,
                    label: "Claude Code",
                    claudeSessionID: sessionID,
                    claudeTokenID: resolvedToken?.tokenID
                )
            }
        }

        // Kill the untracked initial window that new-session created
        if let windowID = initialWindowID {
            try? await tmux.killWindow(server: tmuxServer, windowID: windowID)
        }
    }
}
