import Foundation
import TBDShared

/// Errors that can occur during worktree lifecycle operations.
public enum WorktreeLifecycleError: Error, CustomStringConvertible {
    case repoNotFound(UUID)
    case worktreeNotFound(UUID)
    case worktreeNotArchived(UUID)
    case worktreeAlreadyActive(UUID)
    case createFailed(String)
    case uncommittedChanges(String)
    case nothingToMerge
    case rebaseConflict(String)
    case mergeFailed(String)
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
        case .uncommittedChanges(let detail):
            return detail
        case .nothingToMerge:
            return "Nothing to merge"
        case .rebaseConflict(let detail):
            return "Rebase failed with conflicts: \(detail)"
        case .mergeFailed(let detail):
            return "Merge failed: \(detail)"
        case .invalidOperation(let detail):
            return detail
        }
    }
}

/// Result of checking whether a worktree can be merged.
public struct WorktreeMergeStatus: Sendable {
    public let canMerge: Bool
    public let reason: String?
    public let commitCount: Int

    public init(canMerge: Bool, reason: String?, commitCount: Int) {
        self.canMerge = canMerge
        self.reason = reason
        self.commitCount = commitCount
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

    /// The user's default shell (from $SHELL, falls back to /bin/zsh)
    private var defaultShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    public init(db: TBDDatabase, git: GitManager, tmux: TmuxManager, hooks: HookResolver, subscriptions: StateSubscriptionManager? = nil) {
        self.db = db
        self.git = git
        self.tmux = tmux
        self.hooks = hooks
        self.subscriptions = subscriptions
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
    private func setupTerminals(
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

        // Refuse to archive the main branch worktree
        if worktree.status == .main {
            throw WorktreeLifecycleError.invalidOperation("Cannot archive the main branch worktree")
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

        try await setupTerminals(
            worktreeID: worktree.id, repoPath: repo.path,
            tmuxServer: worktree.tmuxServer, worktreePath: worktree.path,
            skipClaude: skipClaude
        )

        // Update status to active
        try await db.worktrees.revive(id: worktreeID)

        // Return updated worktree
        guard let revived = try await db.worktrees.get(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }
        return revived
    }

    // MARK: - Merge

    /// Merges a worktree branch back into the default branch using rebase + fast-forward merge.
    ///
    /// Flow:
    /// 1. Validate no uncommitted changes in worktree or main repo
    /// 2. Check there are commits to merge
    /// 3. Fetch from origin
    /// 4. Rebase worktree branch onto origin/<default_branch>
    /// 5. Fast-forward merge into default branch
    /// 6. Optionally archive the worktree
    ///
    /// - Parameters:
    ///   - worktreeID: The worktree to merge.
    ///   - archiveAfter: If true, archive the worktree after a successful merge.
    public func mergeWorktree(worktreeID: UUID, archiveAfter: Bool = false) async throws {
        // 1. Get worktree and repo from DB
        guard let worktree = try await db.worktrees.get(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }

        // Refuse to merge the main branch worktree
        if worktree.status == .main {
            throw WorktreeLifecycleError.invalidOperation("Cannot merge the main branch worktree")
        }

        guard let repo = try await db.repos.get(id: worktree.repoID) else {
            throw WorktreeLifecycleError.repoNotFound(worktree.repoID)
        }

        // 2. Check worktree has no uncommitted changes
        if try await git.hasUncommittedChanges(repoPath: worktree.path) {
            throw WorktreeLifecycleError.uncommittedChanges(
                "Commit or stash changes first"
            )
        }

        // 3. Check main repo has no uncommitted changes
        if try await git.hasUncommittedChanges(repoPath: repo.path) {
            throw WorktreeLifecycleError.uncommittedChanges(
                "Main repo has uncommitted changes"
            )
        }

        // 4. Check there are commits to merge
        let count = try await git.commitCount(
            repoPath: repo.path,
            from: repo.defaultBranch,
            to: worktree.branch
        )
        if count == 0 {
            throw WorktreeLifecycleError.nothingToMerge
        }

        // Build hook environment
        let hookEnv: [String: String] = [
            "TBD_EVENT": "merge",
            "TBD_WORKTREE_ID": worktree.id.uuidString,
            "TBD_WORKTREE_NAME": worktree.name,
            "TBD_WORKTREE_PATH": worktree.path,
            "TBD_REPO_PATH": repo.path,
            "TBD_BRANCH": worktree.branch,
            "TBD_TARGET_BRANCH": repo.defaultBranch,
        ]

        // 5. Fire preMerge hook
        let preMergeHookPath = hooks.resolve(
            event: .preMerge,
            repoPath: repo.path,
            appHookPath: nil
        )
        if let hookPath = preMergeHookPath {
            let (success, output) = try await hooks.execute(
                hookPath: hookPath,
                cwd: worktree.path,
                env: hookEnv,
                timeout: 60
            )
            if !success {
                throw WorktreeLifecycleError.mergeFailed("preMerge hook failed: \(output)")
            }
        }

        // 6. Fetch from origin
        try await git.fetch(repoPath: repo.path)

        // 7. Checkout default branch and fast-forward to origin
        try await git.checkout(repoPath: repo.path, branch: repo.defaultBranch)
        try? await git.mergeFFOnly(repoPath: repo.path, branch: "origin/\(repo.defaultBranch)")

        // 8. Squash merge worktree branch — stages all changes as one commit
        do {
            try await git.mergeSquash(repoPath: repo.path, branch: worktree.branch)
        } catch {
            throw WorktreeLifecycleError.mergeFailed("Squash merge failed (conflicts?): check the main repo")
        }

        // 9. Build commit message from worktree's commit history and commit
        let commitMessages = (try? await git.commitMessages(
            repoPath: repo.path,
            from: repo.defaultBranch,
            to: worktree.branch
        )) ?? []

        let commitMessage: String
        if commitMessages.count == 1 {
            // Single commit — just use its message directly
            commitMessage = commitMessages[0]
        } else if commitMessages.isEmpty {
            commitMessage = "Merge \(worktree.displayName)"
        } else {
            // Multiple commits — use first as title, list rest as bullets
            let title = commitMessages[0]
            let rest = commitMessages.dropFirst().map { "- \($0)" }.joined(separator: "\n")
            commitMessage = "\(title)\n\n\(rest)"
        }

        do {
            try await git.commit(repoPath: repo.path, message: commitMessage)
        } catch {
            throw WorktreeLifecycleError.mergeFailed("Commit failed after squash merge")
        }

        // 10. Push main to origin so next worktree branches off the latest
        try? await git.push(repoPath: repo.path, branch: repo.defaultBranch)

        // 11. Fire postMerge hook (async, best effort)
        let postMergeHookPath = hooks.resolve(
            event: .postMerge,
            repoPath: repo.path,
            appHookPath: nil
        )
        if let hookPath = postMergeHookPath {
            _ = try? await hooks.execute(
                hookPath: hookPath,
                cwd: repo.path,
                env: hookEnv,
                timeout: 60
            )
        }

        // 11. Optionally archive
        if archiveAfter {
            try await archiveWorktree(worktreeID: worktreeID, force: true)
        }
    }

    // MARK: - Merge Status Check

    /// Cache for merge status keyed by (worktreeID, worktreeHead, targetHead)
    struct MergeCacheKey: Hashable, Sendable {
        let worktreeID: UUID
        let worktreeHead: String
        let targetHead: String
        let hasUncommitted: Bool
    }

    private static let mergeStatusCache = MergeStatusCache()

    final class MergeStatusCache: @unchecked Sendable {
        private var cache: [MergeCacheKey: WorktreeMergeStatus] = [:]
        private let lock = NSLock()

        subscript(key: MergeCacheKey) -> WorktreeMergeStatus? {
            get { lock.lock(); defer { lock.unlock() }; return cache[key] }
            set { lock.lock(); defer { lock.unlock() }; cache[key] = newValue }
        }
    }

    /// Checks whether a worktree can be merged and returns detailed status.
    /// Results are cached based on HEAD SHAs — only re-runs git merge-tree when something changes.
    public func checkWorktreeMergeability(worktreeID: UUID) async throws -> WorktreeMergeStatus {
        guard let worktree = try await db.worktrees.get(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }
        guard let repo = try await db.repos.get(id: worktree.repoID) else {
            throw WorktreeLifecycleError.repoNotFound(worktree.repoID)
        }

        // Get current SHAs for cache key
        let worktreeHead = (try? await git.headSHA(repoPath: worktree.path)) ?? ""
        let targetHead = (try? await git.headSHA(repoPath: repo.path, ref: repo.defaultBranch)) ?? ""
        let hasUncommitted = try await git.hasUncommittedChanges(repoPath: worktree.path)

        let cacheKey = MergeCacheKey(
            worktreeID: worktreeID,
            worktreeHead: worktreeHead,
            targetHead: targetHead,
            hasUncommitted: hasUncommitted
        )

        // Return cached result if nothing changed
        if let cached = Self.mergeStatusCache[cacheKey] {
            return cached
        }

        // Compute fresh status
        let result: WorktreeMergeStatus

        if hasUncommitted {
            let count = (try? await git.commitCount(
                repoPath: repo.path, from: repo.defaultBranch, to: worktree.branch
            )) ?? 0
            result = WorktreeMergeStatus(canMerge: false, reason: "Has uncommitted changes", commitCount: count)
        } else {
            let commitCount = try await git.commitCount(
                repoPath: repo.path, from: repo.defaultBranch, to: worktree.branch
            )
            if commitCount == 0 {
                result = WorktreeMergeStatus(canMerge: false, reason: "Nothing to merge", commitCount: 0)
            } else {
                let (hasConflicts, conflictFiles) = await git.checkMergeConflicts(
                    repoPath: repo.path, branch: worktree.branch, targetBranch: repo.defaultBranch
                )
                if hasConflicts {
                    let fileList = conflictFiles.joined(separator: ", ")
                    result = WorktreeMergeStatus(
                        canMerge: false,
                        reason: "Conflicts with \(repo.defaultBranch): \(fileList)",
                        commitCount: commitCount
                    )
                } else {
                    result = WorktreeMergeStatus(canMerge: true, reason: nil, commitCount: commitCount)
                }
            }
        }

        Self.mergeStatusCache[cacheKey] = result
        return result
    }

    // MARK: - Git Status

    /// Recompute git status for all active worktrees in a repo.
    /// Runs git checks concurrently and updates the DB + broadcasts deltas.
    public func refreshGitStatuses(repoID: UUID) async {
        guard let repo = try? await db.repos.get(id: repoID) else { return }
        let worktrees = (try? await db.worktrees.list(repoID: repoID, status: .active)) ?? []

        await withTaskGroup(of: Void.self) { group in
            for wt in worktrees {
                // Skip already-merged worktrees (terminal state)
                if wt.gitStatus == .merged { continue }

                group.addTask {
                    guard let newStatus = await self.computeGitStatus(
                        repoPath: repo.path,
                        defaultBranch: repo.defaultBranch,
                        branch: wt.branch
                    ), newStatus != wt.gitStatus else { return }
                    try? await self.db.worktrees.updateGitStatus(id: wt.id, gitStatus: newStatus)
                    self.subscriptions?.broadcast(delta: .worktreeGitStatusChanged(
                        WorktreeGitStatusDelta(worktreeID: wt.id, gitStatus: newStatus)
                    ))
                }
            }
        }
    }

    /// Compute git status for a single branch relative to the default branch.
    /// Returns nil if git commands fail (leaves status unchanged).
    private func computeGitStatus(repoPath: String, defaultBranch: String, branch: String) async -> GitStatus? {
        guard let isAncestor = await git.isMergeBaseAncestor(
            repoPath: repoPath, base: defaultBranch, branch: branch
        ) else {
            return nil  // git error — leave status unchanged
        }
        if isAncestor {
            return .current
        }

        // Branches have diverged — check for conflicts
        let (hasConflicts, _) = await git.checkMergeConflicts(
            repoPath: repoPath, branch: branch, targetBranch: defaultBranch
        )
        return hasConflicts ? .conflicts : .behind
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
        let correctTmuxServer = TmuxManager.serverName(forRepoPath: repo.path)
        var dbWorktrees = try await db.worktrees.list(repoID: repoID, status: .active)

        // Fix stale tmux server names (e.g. after migration from UUID-based to path-based naming)
        let mainWorktrees = try await db.worktrees.list(repoID: repoID, status: .main)
        for wt in (dbWorktrees + mainWorktrees) where wt.tmuxServer != correctTmuxServer {
            try? await db.worktrees.updateTmuxServer(id: wt.id, tmuxServer: correctTmuxServer)
        }
        // Re-fetch with corrected names
        dbWorktrees = try await db.worktrees.list(repoID: repoID, status: .active)

        let gitPaths = Set(gitWorktrees.map(\.path))
        let dbPaths = Set(dbWorktrees.map(\.path))

        // Mark missing worktrees as archived — also kill their tmux windows
        for wt in dbWorktrees where !gitPaths.contains(wt.path) {
            let terminals = try await db.terminals.list(worktreeID: wt.id)
            for terminal in terminals {
                try? await tmux.killWindow(
                    server: wt.tmuxServer,
                    windowID: terminal.tmuxWindowID
                )
            }
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
            let tmuxServer = TmuxManager.serverName(forRepoPath: repo.path)
            _ = try await db.worktrees.create(
                repoID: repoID,
                name: name,
                branch: gitWt.branch,
                path: gitWt.path,
                tmuxServer: tmuxServer
            )
        }

        // Clean up orphaned tmux windows — windows not tracked by any active terminal
        let tmuxServer = TmuxManager.serverName(forRepoPath: repo.path)
        let activeWorktrees = try await db.worktrees.list(repoID: repoID, status: .active)
        if activeWorktrees.isEmpty {
            // No active worktrees — kill the entire tmux server
            try? await tmux.killServer(server: tmuxServer)
        } else {
            // Collect all tracked window IDs
            var trackedWindowIDs: Set<String> = []
            for wt in activeWorktrees {
                let terminals = try await db.terminals.list(worktreeID: wt.id)
                for t in terminals {
                    trackedWindowIDs.insert(t.tmuxWindowID)
                }
            }

            // List actual tmux windows and kill any that aren't tracked
            if let tmuxWindows = try? await tmux.listWindows(server: tmuxServer, session: "main") {
                for window in tmuxWindows where !trackedWindowIDs.contains(window.windowID) {
                    try? await tmux.killWindow(server: tmuxServer, windowID: window.windowID)
                }
            }
        }
    }
}
