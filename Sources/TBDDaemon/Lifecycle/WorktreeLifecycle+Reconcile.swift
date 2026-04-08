import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "reconcile")

extension WorktreeLifecycle {
    // MARK: - Git Status

    /// Recompute conflict status for all active worktrees in a repo.
    /// Also detects branch name changes (e.g., `git checkout -b` inside a worktree).
    /// Runs git checks concurrently and updates the DB + broadcasts deltas.
    public func refreshGitStatuses(repoID: UUID) async {
        guard let repo = try? await db.repos.get(id: repoID) else { return }
        var worktrees = (try? await db.worktrees.list(repoID: repoID, status: .active)) ?? []

        // Sync branch names: one `git worktree list` call gives us
        // the current branch for every worktree — update DB if changed.
        if let gitWorktrees = try? await git.worktreeList(repoPath: repo.path) {
            let branchByPath = Dictionary(gitWorktrees.map { ($0.path, $0.branch) }, uniquingKeysWith: { _, b in b })
            for (i, wt) in worktrees.enumerated() {
                if let gitBranch = branchByPath[wt.path], gitBranch != wt.branch {
                    try? await db.worktrees.updateBranch(id: wt.id, branch: gitBranch)
                    worktrees[i].branch = gitBranch  // use updated branch for conflict check below
                }
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for wt in worktrees {
                group.addTask {
                    guard let newHasConflicts = await self.checkHasConflicts(
                        repoPath: repo.path,
                        defaultBranch: repo.defaultBranch,
                        branch: wt.branch
                    ), newHasConflicts != wt.hasConflicts else { return }
                    try? await self.db.worktrees.updateHasConflicts(id: wt.id, hasConflicts: newHasConflicts)
                    self.subscriptions?.broadcast(delta: .worktreeConflictsChanged(
                        WorktreeConflictDelta(worktreeID: wt.id, hasConflicts: newHasConflicts)
                    ))
                }
            }
        }
    }

    /// Check whether a branch would conflict if merged into the default branch.
    /// Returns nil if git commands fail (leaves status unchanged).
    private func checkHasConflicts(repoPath: String, defaultBranch: String, branch: String) async -> Bool? {
        guard let isAncestor = await git.isMergeBaseAncestor(
            repoPath: repoPath, base: defaultBranch, branch: branch
        ) else {
            return nil  // git error — leave status unchanged
        }
        if isAncestor { return false }

        // Branches have diverged — check for conflicts
        let (hasConflicts, _) = await git.checkMergeConflicts(
            repoPath: repoPath, branch: branch, targetBranch: defaultBranch
        )
        return hasConflicts
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

        // If the repo's filesystem path is gone, don't try to talk to git.
        // The startup health validator will (or already has) flipped its status
        // to .missing. Reconcile becomes a no-op until the user runs `tbd repo
        // relocate`. The daemon must not crash or hang on stale paths.
        if repo.status == .missing {
            return
        }

        let gitWorktrees = try await git.worktreeList(repoPath: repo.path)
        let correctTmuxServer = TmuxManager.serverName(forRepoPath: repo.path)
        var dbWorktrees = try await db.worktrees.list(repoID: repoID, status: .active)

        // Fix stale tmux server names (e.g. after migration from UUID-based to path-based naming)
        let mainWorktrees = try await db.worktrees.list(repoID: repoID, status: .main)
        for wt in (dbWorktrees + mainWorktrees) where wt.tmuxServer != correctTmuxServer {
            do {
                try await db.worktrees.updateTmuxServer(id: wt.id, tmuxServer: correctTmuxServer)
            } catch {
                print("[TBD] reconcile: failed to update tmux server for worktree \(wt.id): \(error)")
            }
        }
        // Re-fetch with corrected names
        dbWorktrees = try await db.worktrees.list(repoID: repoID, status: .active)

        let gitPaths = Set(gitWorktrees.map(\.path))
        let dbPaths = Set(dbWorktrees.map(\.path))

        // Mark missing worktrees as archived — also kill their tmux windows
        for wt in dbWorktrees where !gitPaths.contains(wt.path) {
            let terminals = try await db.terminals.list(worktreeID: wt.id)
            for terminal in terminals {
                do {
                    try await tmux.killWindow(
                        server: wt.tmuxServer,
                        windowID: terminal.tmuxWindowID
                    )
                } catch {
                    print("[TBD] reconcile: failed to kill window \(terminal.tmuxWindowID): \(error)")
                }
            }
            try await db.terminals.deleteForWorktree(worktreeID: wt.id)
            try await db.worktrees.archive(id: wt.id)
        }

        // Add unknown worktrees (skip the main repo worktree).
        // LEGACY-WORKTREE-LOCATION: remove after 2026-06-01
        // Reads worktrees from <repo>/.tbd/worktrees/ for backward compatibility with
        // worktrees created before the canonical-location switch. New worktrees are
        // always created under ~/tbd/worktrees/<repo>/<name>. After 2026-06-01, all
        // pre-switch worktrees will have archived naturally and this path can be deleted.
        // Dual-prefix view: accept worktrees living under either the canonical
        // (~/tbd/worktrees/<slot>/) or legacy (<repo>/.tbd/worktrees/) layout.
        let layout = WorktreeLayout()
        let acceptablePrefixes = layout.legacyAndCanonicalPrefixes(for: repo)
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        for gitWt in gitWorktrees where !dbPaths.contains(gitWt.path) {
            guard acceptablePrefixes.contains(where: { gitWt.path.hasPrefix($0) }) else { continue }

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

        // Clean up terminal records pointing to dead tmux windows (especially main worktrees).
        // If the entire tmux server is gone (e.g. machine reboot), recreate windows from
        // persisted records instead of deleting them.
        let allLiveWorktrees = try await db.worktrees.list(repoID: repoID, status: .active)
            + (try await db.worktrees.list(repoID: repoID, status: .main))
        let serverAlive = await tmux.serverExists(server: correctTmuxServer)
        for wt in allLiveWorktrees {
            let terminals = try await db.terminals.list(worktreeID: wt.id)
            for terminal in terminals where terminal.suspendedAt == nil {
                if serverAlive {
                    let alive = await tmux.windowExists(server: wt.tmuxServer, windowID: terminal.tmuxWindowID)
                    if !alive {
                        try? await db.terminals.delete(id: terminal.id)
                    }
                } else {
                    do {
                        try await recreateAfterReboot(terminal: terminal, worktree: wt)
                        logger.info("Reboot recovery: recreated terminal \(terminal.id, privacy: .public) in worktree \(wt.id, privacy: .public)")
                    } catch {
                        logger.error("Reboot recovery: failed to recreate terminal \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }

        // Clean up orphaned tmux windows — windows not tracked by any terminal (active or main)
        let tmuxServer = TmuxManager.serverName(forRepoPath: repo.path)
        let activeWorktrees = try await db.worktrees.list(repoID: repoID, status: .active)
        let mainWorktreesForCleanup = try await db.worktrees.list(repoID: repoID, status: .main)
        let allLiveWorktreesForCleanup = activeWorktrees + mainWorktreesForCleanup
        if allLiveWorktreesForCleanup.isEmpty {
            // No live worktrees — kill the entire tmux server
            do {
                try await tmux.killServer(server: tmuxServer)
            } catch {
                print("[TBD] reconcile: failed to kill tmux server \(tmuxServer): \(error)")
            }
        } else {
            // Collect all tracked window IDs (active + main worktrees)
            var trackedWindowIDs: Set<String> = []
            for wt in allLiveWorktreesForCleanup {
                let terminals = try await db.terminals.list(worktreeID: wt.id)
                for t in terminals {
                    trackedWindowIDs.insert(t.tmuxWindowID)
                }
            }

            // List actual tmux windows and kill any that aren't tracked
            do {
                let tmuxWindows = try await tmux.listWindows(server: tmuxServer, session: "main")
                for window in tmuxWindows where !trackedWindowIDs.contains(window.windowID) {
                    do {
                        try await tmux.killWindow(server: tmuxServer, windowID: window.windowID)
                    } catch {
                        print("[TBD] reconcile: failed to kill orphaned window \(window.windowID): \(error)")
                    }
                }
            } catch {
                print("[TBD] reconcile: failed to list tmux windows for server \(tmuxServer): \(error)")
            }
        }

        // Recompute health so the next call sees the right status. A repo that
        // just transitioned ok→missing here would otherwise stay ok in memory
        // until the next startup sweep.
        let validator = RepoHealthValidator(git: git)
        let observed = await validator.validate(repo: repo)
        if observed != repo.status {
            try? await db.repos.updateStatus(id: repo.id, status: observed)
            // Broadcast a coarse refresh so the sidebar dims/un-dims immediately
            // when reconcile is triggered via an RPC (e.g. cleanup) with active
            // subscribers. .repoAdded is the existing coarse signal — see the
            // matching call site in RPCRouter+RelocateHandler.
            subscriptions?.broadcast(delta: .repoAdded(RepoDelta(
                repoID: repo.id, path: repo.path, displayName: repo.displayName
            )))
        }
    }

    // MARK: - Reboot Recovery

    /// Recreates a tmux window for a terminal record after the tmux server has been lost
    /// (e.g. machine reboot). Updates the terminal's stored window/pane IDs in the DB.
    private func recreateAfterReboot(terminal: Terminal, worktree: Worktree) async throws {
        if let bootstrapWindowID = try await tmux.ensureServer(server: worktree.tmuxServer, session: "main", cwd: worktree.path) {
            try? await tmux.killWindow(server: worktree.tmuxServer, windowID: bootstrapWindowID)
        }

        let spawn: ClaudeSpawnCommandBuilder.Result
        var env: [String: String] = [:]

        if let sessionID = terminal.claudeSessionID {
            // Claude terminal — resume existing session with persisted token
            var resolvedToken: ResolvedClaudeToken? = nil
            if let tokenID = terminal.claudeTokenID, let resolver = claudeTokenResolver {
                resolvedToken = try? await resolver.loadByID(tokenID)
            }
            spawn = ClaudeSpawnCommandBuilder.build(
                resumeID: sessionID,
                freshSessionID: nil,
                appendSystemPrompt: nil,
                initialPrompt: nil,
                tokenSecret: resolvedToken?.secret,
                tokenKind: resolvedToken?.kind,
                cmd: nil,
                shellFallback: defaultShell
            )
        } else if terminal.label == "Codex" {
            // Codex terminal — detected by label "Codex" (set during terminal creation).
            // No structured type field exists; label matching is the only discriminator available.
            let codexHome = try CodexHomeManager().ensureHome(forRepoID: worktree.repoID)
            env["TBD_WORKTREE_ID"] = worktree.id.uuidString
            env["CODEX_HOME"] = codexHome.path
            spawn = ClaudeSpawnCommandBuilder.build(
                resumeID: nil,
                freshSessionID: nil,
                appendSystemPrompt: nil,
                initialPrompt: nil,
                tokenSecret: nil,
                cmd: "codex --full-auto",
                shellFallback: defaultShell
            )
        } else {
            // Shell or custom-cmd terminal. Plain shell terminals have label nil or "shell";
            // custom-cmd terminals store the command string directly in label.
            let cmd = (terminal.label == "shell" || terminal.label == nil) ? nil : terminal.label
            spawn = ClaudeSpawnCommandBuilder.build(
                resumeID: nil,
                freshSessionID: nil,
                appendSystemPrompt: nil,
                initialPrompt: nil,
                tokenSecret: nil,
                cmd: cmd,
                shellFallback: defaultShell
            )
        }

        let window = try await tmux.createWindow(
            server: worktree.tmuxServer,
            session: "main",
            cwd: worktree.path,
            shellCommand: spawn.command,
            env: env,
            sensitiveEnv: spawn.sensitiveEnv
        )
        try await db.terminals.updateTmuxIDs(id: terminal.id, windowID: window.windowID, paneID: window.paneID)
    }
}
