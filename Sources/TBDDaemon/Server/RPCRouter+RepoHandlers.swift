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
        try? await lifecycle.reconcile(repoID: repo.id, actuationLog: actuationLog)
        subscriptions.broadcast(delta: .repoAdded(RepoDelta(
            repoID: repo.id, path: repo.path, displayName: repo.displayName)))
        return repo
    }

    func handleRepoRemove(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(RepoRemoveParams.self, from: paramsData)

        guard let repo = try await db.repos.get(id: params.repoID) else {
            return RPCResponse(error: "Repository not found: \(params.repoID)")
        }

        // Check for active worktrees
        let activeWorktrees = try await db.worktrees.list(repoID: repo.id, status: .active)

        if !activeWorktrees.isEmpty {
            if params.force {
                // A forced removal tears down every active worktree's sessions,
                // killing live windows the operator can see. One row per
                // worktree, each naming that worktree with no terminal: the
                // handler resolves the list itself and archives each through its
                // own `archiveWorktree` call, so these are separate teardowns —
                // the same reasoning that gives reconcile a row per act, and the
                // same worktree-named shape `worktree.archive` uses for one.
                //
                // Every row is written BEFORE the first teardown, not
                // interleaved. Fail-closed means an unrecordable act does not
                // happen, and a cascade that stopped halfway would leave the
                // repo half-dismantled; rowing the whole set first makes the
                // refusal all-or-nothing, with the repo and every session it
                // owns still standing.
                var actuationIDs: [String] = []
                for wt in activeWorktrees {
                    actuationIDs.append(try await beginActuation(
                        .repoRemove, actor: actor,
                        target: ActuationTarget(worktree: wt.id.uuidString)))
                }

                // Cascade-archive all active worktrees
                for (index, wt) in activeWorktrees.enumerated() {
                    do {
                        try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)
                    } catch {
                        // The throw ends the cascade, so this row and every row
                        // behind it names a teardown that did not happen. They
                        // are confirmed as transport-failed together rather than
                        // left unconfirmed, which the record would otherwise
                        // read as an outcome that was merely lost.
                        for pending in actuationIDs[index...] {
                            await finishActuation(pending, .transportFailed, error: "\(error)")
                        }
                        throw error
                    }
                    await finishActuation(actuationIDs[index], .dispatched)
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
        let inUseBranches = Set((try? await git.worktreeList(repoPath: repo.path))?.map(\.branch).filter { !$0.isEmpty } ?? [])
        // A PR head fetched into a uniquified/renamed local branch (e.g. head
        // "foo" checked out as "foo-2") no longer matches by head name, but the
        // worktree row carries the PR number — filter on that too. Use
        // excludeArchived (not status: .active) so a worktree still
        // `.creating` — several seconds of tmux/terminal spawn — still counts
        // as in-use; otherwise its PR is selectable again during that window,
        // letting a second worktree land on the same PR (matches the
        // "globalLiveRows" excludeArchived convention in
        // WorktreeLifecycle+Reconcile.swift).
        let inUsePRNumbers = Set((try? await db.worktrees.list(repoID: repo.id, excludeArchived: true))?.compactMap(\.prNumber) ?? [])
        let filtered = Self.filterOpenPRsNotInUse(prs, inUseBranches: inUseBranches, inUsePRNumbers: inUsePRNumbers)

        return try RPCResponse(result: RepoListOpenPRsResult(prs: filtered))
    }

    /// Drop PRs already checked out in a worktree — by head branch name OR by a
    /// number stamped on an active worktree row (covers a PR whose head was
    /// fetched under a uniquified local branch, whose name no longer matches).
    /// The branch-name check applies only to same-repo PRs: a fork PR's head
    /// branch lives in the contributor's namespace, so a name matching a
    /// checked-out origin branch (e.g. a fork PR opened off "main") is
    /// coincidental, not the same ref — only the stored-PR-number check
    /// applies to fork PRs. Pure so it's unit-testable without git/gh/db.
    static func filterOpenPRsNotInUse(
        _ prs: [OpenPRInfo], inUseBranches: Set<String>, inUsePRNumbers: Set<Int>
    ) -> [OpenPRInfo] {
        prs.filter { pr in
            let branchInUse = !pr.isCrossRepository && inUseBranches.contains(pr.headRefName)
            return !branchInUse && !inUsePRNumbers.contains(pr.number)
        }
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
