import Foundation
import TBDShared

extension RPCRouter {

    // MARK: - Repo Handlers

    func handleRepoAdd(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(RepoAddParams.self, from: paramsData)

        // Resolve to absolute path
        let path = (params.path as NSString).standardizingPath

        // Validate it's a git repo
        guard await git.isGitRepo(path: path) else {
            return RPCResponse(error: "Not a git repository: \(path)")
        }

        // Check if already registered
        if let existing = try await db.repos.findByPath(path: path) {
            // Ensure main worktree exists (may be missing if repo was added via reconciliation)
            let mainWts = try await db.worktrees.list(repoID: existing.id, status: .main)
            if mainWts.isEmpty {
                let serverName = TmuxManager.serverName(forRepoPath: existing.path)
                _ = try await db.worktrees.createMain(
                    repoID: existing.id,
                    name: existing.defaultBranch,
                    branch: existing.defaultBranch,
                    path: existing.path,
                    tmuxServer: serverName
                )
            }
            return try RPCResponse(result: existing)
        }

        // Detect default branch and remote URL
        let defaultBranch: String
        do {
            defaultBranch = try await git.detectDefaultBranch(repoPath: path)
        } catch {
            defaultBranch = "main"
        }

        let remoteURL = await git.getRemoteURL(repoPath: path)

        // Derive display name from last path component
        let displayName = (path as NSString).lastPathComponent

        let repo = try await db.repos.create(
            path: path,
            displayName: displayName,
            defaultBranch: defaultBranch,
            remoteURL: remoteURL
        )

        // Create synthetic "main" worktree entry pointing at repo root
        let tmuxServer = TmuxManager.serverName(forRepoPath: repo.path)
        _ = try await db.worktrees.createMain(
            repoID: repo.id,
            name: defaultBranch,
            branch: defaultBranch,
            path: path,
            tmuxServer: tmuxServer
        )

        // Reconcile existing git worktrees into the DB
        try? await lifecycle.reconcile(repoID: repo.id)

        subscriptions.broadcast(delta: .repoAdded(RepoDelta(
            repoID: repo.id, path: repo.path, displayName: repo.displayName
        )))

        return try RPCResponse(result: repo)
    }

    func handleRepoRemove(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(RepoRemoveParams.self, from: paramsData)

        guard let repo = try await db.repos.get(id: params.repoID) else {
            return RPCResponse(error: "Repository not found: \(params.repoID)")
        }

        // Check for active worktrees
        let activeWorktrees = try await db.worktrees.list(repoID: repo.id, status: .active)

        if !activeWorktrees.isEmpty {
            if params.force {
                // Cascade-archive all active worktrees
                for wt in activeWorktrees {
                    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)
                }
            } else {
                return RPCResponse(
                    error: "Repository has \(activeWorktrees.count) active worktree(s). Use force to archive them first."
                )
            }
        }

        // Delete any remaining worktrees (e.g. main worktree) for this repo
        try await db.worktrees.deleteForRepo(repoID: params.repoID)

        try await db.repos.remove(id: params.repoID)

        subscriptions.broadcast(delta: .repoRemoved(RepoIDDelta(repoID: params.repoID)))

        return .ok()
    }

    func handleRepoList() async throws -> RPCResponse {
        let repos = try await db.repos.list()
        return try RPCResponse(result: repos)
    }
}
