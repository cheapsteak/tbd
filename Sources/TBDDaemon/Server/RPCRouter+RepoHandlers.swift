import Foundation
import TBDShared

extension RPCRouter {

    // MARK: - Repo Handlers

    func handleRepoAdd(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(RepoAddParams.self, from: paramsData)

        // Resolve to absolute path
        let path = (params.path as NSString).standardizingPath

        // Reject paths inside TBD's scratch area — those must go through
        // `tbd scratch promote`, which moves the folder out first.
        // Canonicalize both paths to resolve symlinks (e.g., /tmp → /private/tmp on macOS)
        let canonPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let canonScratchBase = URL(fileURLWithPath: TBDConstants.scratchDir.path).resolvingSymlinksInPath().path
        if canonPath == canonScratchBase || canonPath.hasPrefix(canonScratchBase + "/") {
            return RPCResponse(error: "That path is inside TBD's scratch area. Use `tbd scratch promote <dest-path>` to move it out and register it as a repo.")
        }

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

        return try RPCResponse(result: try await addRepo(path: path, displayNameOverride: nil))
    }

    /// Register `path` as a repo (default-branch detect, create row, synthetic
    /// main worktree, reconcile, broadcast). `displayNameOverride` wins over the
    /// folder-name default. Assumes `path` is already a git repo.
    func addRepo(path: String, displayNameOverride: String?) async throws -> Repo {
        let defaultBranch = (try? await git.detectDefaultBranch(repoPath: path)) ?? "main"
        let remoteURL = await git.getRemoteURL(repoPath: path)
        let displayName = displayNameOverride ?? (path as NSString).lastPathComponent
        let repo = try await db.repos.create(path: path, displayName: displayName,
                                             defaultBranch: defaultBranch, remoteURL: remoteURL)
        let tmuxServer = TmuxManager.serverName(forRepoPath: repo.path)
        _ = try await db.worktrees.createMain(repoID: repo.id, name: defaultBranch,
                                              branch: defaultBranch, path: path, tmuxServer: tmuxServer)
        try? await lifecycle.reconcile(repoID: repo.id)
        subscriptions.broadcast(delta: .repoAdded(RepoDelta(
            repoID: repo.id, path: repo.path, displayName: repo.displayName)))
        return repo
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

        // Reclaim scratchpads for EVERY worktree row this repo owns (every
        // status, including archived) before the rows below vanish — once
        // they're gone, reconciliation has no path left to resolve them by.
        if let orphanGC {
            await orphanGC.reconcileScratchpadsBeforeRepoRemoval(repoID: repo.id, repoPath: repo.path)
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

    func handleRepoUpdateInstructions(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(RepoUpdateInstructionsParams.self, from: paramsData)

        guard try await db.repos.get(id: params.repoID) != nil else {
            return RPCResponse(error: "Repository not found: \(params.repoID)")
        }

        try await db.repos.updateInstructions(
            id: params.repoID,
            renamePrompt: params.renamePrompt,
            customInstructions: params.customInstructions
        )

        guard let updated = try await db.repos.get(id: params.repoID) else {
            return RPCResponse(error: "Repository not found after update: \(params.repoID)")
        }

        return try RPCResponse(result: updated)
    }

    func handleRepoSetHidden(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(RepoSetHiddenParams.self, from: paramsData)

        guard try await db.repos.get(id: params.repoID) != nil else {
            return RPCResponse(error: "Repository not found: \(params.repoID)")
        }

        try await db.repos.setHidden(id: params.repoID, hidden: params.hidden)

        subscriptions.broadcast(delta: .repoHiddenChanged(RepoHiddenDelta(
            repoID: params.repoID, hidden: params.hidden
        )))

        return .ok()
    }

    func handleRepoSetExpanded(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(RepoSetExpandedParams.self, from: paramsData)

        guard try await db.repos.get(id: params.repoID) != nil else {
            return RPCResponse(error: "Repository not found: \(params.repoID)")
        }

        try await db.repos.setExpanded(id: params.repoID, expanded: params.expanded)

        subscriptions.broadcast(delta: .repoExpandedChanged(RepoExpandedDelta(
            repoID: params.repoID, expanded: params.expanded
        )))

        return .ok()
    }

    func handleRepoListBranches(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(RepoListBranchesParams.self, from: paramsData)

        guard let repo = try await db.repos.get(id: params.repoID) else {
            return RPCResponse(error: "Repository not found: \(params.repoID)")
        }

        let refs = try await git.listBranches(repoPath: repo.path)
        let branches = refs.map {
            BranchInfo(
                name: $0.name,
                localName: $0.localName,
                isRemote: $0.isRemote
            )
        }
        return try RPCResponse(result: RepoListBranchesResult(branches: branches))
    }

    /// Repo-scoped open-PR list for the branch picker (spec §1). Degrades to an
    /// empty list rather than an RPC error on any `gh`/GraphQL failure — see
    /// `PRStatusManager.fetchOpenPRs`. Drops PRs already checked out in a
    /// worktree, mirroring `listBranches`' in-use filter.
    func handleRepoListOpenPRs(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(RepoListOpenPRsParams.self, from: paramsData)

        guard let repo = try await db.repos.get(id: params.repoID) else {
            return RPCResponse(error: "Repository not found: \(params.repoID)")
        }

        let prs = await prManager.fetchOpenPRs(repoPath: repo.path)
        let inUse = Set((try? await git.worktreeList(repoPath: repo.path))?.map(\.branch).filter { !$0.isEmpty } ?? [])
        let filtered = prs.filter { !inUse.contains($0.headRefName) }

        return try RPCResponse(result: RepoListOpenPRsResult(prs: filtered))
    }

    func handleRepoRename(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(RepoRenameParams.self, from: paramsData)

        guard try await db.repos.get(id: params.repoID) != nil else {
            return RPCResponse(error: "Repository not found: \(params.repoID)")
        }

        try await db.repos.rename(id: params.repoID, displayName: params.displayName)

        subscriptions.broadcast(delta: .repoRenamed(RepoRenameDelta(
            repoID: params.repoID, displayName: params.displayName
        )))

        return .ok()
    }
}
