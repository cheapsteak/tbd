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
            repoPath: repoPath, base: "origin/\(defaultBranch)", branch: branch
        ) else {
            // git error or origin/<defaultBranch> doesn't exist yet —
            // leave hasConflicts at its previous value. For purely local repos
            // (no origin remote) this is a permanent no-op, which is acceptable.
            return nil
        }
        if isAncestor { return false }

        // Branches have diverged — check for conflicts
        let (hasConflicts, _) = await git.checkMergeConflicts(
            repoPath: repoPath, branch: branch, targetBranch: "origin/\(defaultBranch)"
        )
        return hasConflicts
    }

    // MARK: - Reconcile

    /// Reconciles the database state with actual git worktrees on disk.
    ///
    /// - Worktrees in db but missing from git: marked as archived
    /// - Worktrees in git but missing from db: added with default names
    public func reconcile(repoID: UUID) async throws {
        // Null out parent pointers whose target is missing OR archived. Either
        // case would leave the child unreachable in the sidebar — missing rows
        // can't render, and archived parents are filtered out of the subtree
        // walk. Promoting to top-level is the only sensible recovery. Cheap
        // single UPDATE — safe to run per repo.
        try await db.worktrees.nullOrphanedParents()

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
                logger.warning("reconcile: failed to update tmux server for worktree \(wt.id, privacy: .public): \(error, privacy: .public)")
            }
        }
        // Re-fetch with corrected names
        dbWorktrees = try await db.worktrees.list(repoID: repoID, status: .active)

        let gitPaths = Set(gitWorktrees.map(\.path))
        // Include `.creating` rows so a worktree whose pre-session phase-3
        // wait is still in flight (status flips to .active only when the hook
        // finishes) isn't "unknown" to the re-adopt pass below — re-adopting
        // its path would violate the UNIQUE path constraint and abort this
        // repo's reconcile.
        let creatingPaths = Set(
            (try await db.worktrees.list(repoID: repoID, status: .creating)).map(\.path)
        )
        let dbPaths = Set(dbWorktrees.map(\.path)).union(creatingPaths)

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
                    logger.warning("reconcile: failed to kill window \(terminal.tmuxWindowID, privacy: .public): \(error, privacy: .public)")
                }
            }
            try await db.terminals.deleteForWorktree(worktreeID: wt.id)
            try await db.tabs.deleteForWorktree(worktreeID: wt.id)
            for terminal in terminals {
                await pendingQuestions.clear(terminalID: terminal.id)
                // Reclaim any per-session fallbackModel overlay (keyed by terminal
                // id), mirroring handleTerminalDelete. No-op when none was written.
                ClaudeHookOverlay.removePerSessionOverlay(sessionKey: terminal.id.uuidString)
            }
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
                        if terminal.isClaudeResumable, let sessionID = terminal.claudeSessionID {
                            // Window is gone but a resumable session exists.
                            // Suspend the terminal instead of deleting it — the
                            // suspend/resume machinery rebuilds a window from the
                            // session ID on demand. Deleting here would orphan the
                            // transcript and the session would vanish from TBD.
                            try? await db.terminals.setSuspended(id: terminal.id, sessionID: sessionID)
                            logger.info("reconcile: suspended terminal \(terminal.id, privacy: .public) — window \(terminal.tmuxWindowID, privacy: .public) gone, session \(sessionID, privacy: .public) preserved")
                        } else {
                            try? await db.terminals.delete(id: terminal.id)
                            logger.info("reconcile: deleted terminal \(terminal.id, privacy: .public) — window \(terminal.tmuxWindowID, privacy: .public) gone, no session to preserve")
                        }
                        await pendingQuestions.clear(terminalID: terminal.id)
                    }
                } else {
                    do {
                        try await recreateAfterReboot(terminal: terminal, worktree: wt)
                        logger.info("Reboot recovery: recreated terminal \(terminal.id, privacy: .public) in worktree \(wt.id, privacy: .public)")
                    } catch {
                        logger.error("Reboot recovery: failed to recreate terminal \(terminal.id, privacy: .public): \(error, privacy: .public)")
                    }
                }
            }
        }

        // Clean up orphaned tmux windows — windows not tracked by any terminal
        // (active, main, or creating). `.creating` worktrees count as live: a
        // pre-session hook wait that's still in flight (or just resumed by the
        // startup recovery sweep) owns a real tmux window, and phase 3 spawns
        // primary/setup windows before the row flips `.active`. Treating those
        // rows as dead would kill the hook mid-run (interrupting e.g. a running
        // npm install), fire a spurious `.paneKilled` notification, and spawn
        // the agent prematurely.
        let tmuxServer = TmuxManager.serverName(forRepoPath: repo.path)
        let activeWorktrees = try await db.worktrees.list(repoID: repoID, status: .active)
        let mainWorktreesForCleanup = try await db.worktrees.list(repoID: repoID, status: .main)
        let creatingWorktreesForCleanup = try await db.worktrees.list(repoID: repoID, status: .creating)
        let allLiveWorktreesForCleanup = activeWorktrees + mainWorktreesForCleanup + creatingWorktreesForCleanup
        if allLiveWorktreesForCleanup.isEmpty {
            // No live worktrees (including `.creating` ones) — kill the entire
            // tmux server. A repo whose only live row is mid-pre-session must
            // NOT land here, or the hook's window dies with the server.
            do {
                try await tmux.killServer(server: tmuxServer)
            } catch {
                logger.warning("reconcile: failed to kill tmux server \(tmuxServer, privacy: .public): \(error, privacy: .public)")
            }
        } else {
            // Collect all tracked window IDs (active + main + creating worktrees)
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
                        logger.warning("reconcile: failed to kill orphaned window \(window.windowID, privacy: .public): \(error, privacy: .public)")
                    }
                }
            } catch {
                logger.warning("reconcile: failed to list tmux windows for server \(tmuxServer, privacy: .public): \(error, privacy: .public)")
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
    ///
    /// Visibility: `internal` (not `private`) so tests in the same module can drive
    /// this path directly. The reconcile dispatcher only enters this branch when
    /// `serverExists → false`, which `TmuxManager(dryRun: true)` cannot simulate.
    internal func recreateAfterReboot(terminal: Terminal, worktree: Worktree) async throws {
        // tmux invariant: killing the ONLY window in a session destroys the
        // session, and a server with no sessions exits. `ensureServer` here
        // bootstraps a brand-new server via `new-session -d -s main`, leaving
        // exactly one window. If we kill that bootstrap window now, the
        // session collapses, the server exits, and the `createWindow` call
        // below fails with `no server running on …`. Defer the kill until
        // after the real window exists so the session always has at least
        // one window during the transition.
        let bootstrapWindowID = try await tmux.ensureServer(
            server: worktree.tmuxServer, session: "main", cwd: worktree.path
        )

        let rebootConfig = try? await db.config.get()
        let claudeEnvOverrides = rebootConfig?.envSettingOverrides ?? [:]
        // Free-form env overrides applied to recreated agent panes (global <
        // repo < profile). Codex takes the merged map as-is; Claude layers the
        // builder's auth/routing env on top; plain shells get nothing.
        let rebootRepo = try? await db.repos.get(id: worktree.repoID)
        let rebootGlobalRepoEnv = EnvOverrideResolver.merge(
            global: rebootConfig?.envOverrides,
            repo: rebootRepo?.envOverrides,
            profile: nil
        )
        let spawn: ClaudeSpawnCommandBuilder.Result
        // Per-branch free-form env layered into the recreated pane; defaults to
        // none (plain shells stay clean).
        var primarySensitiveEnv: [String: String] = [:]
        var env: [String: String] = [:]
        // Always announce the worktree to recreated panes. Without this, the
        // pane inherits whatever TBD_WORKTREE_ID the tmux server was spawned
        // with — which would misattribute notifications to a different
        // worktree. Applies to all branches below (claude, codex, shell/cmd).
        env["TBD_WORKTREE_ID"] = worktree.id.uuidString
        // Persist the terminal ID into the spawned env so the SessionStart
        // hook bridge can route session events for `/clear`/`/compact`
        // rollovers without depending on cwd-based heuristics.
        env["TBD_TERMINAL_ID"] = terminal.id.uuidString

        if terminal.isCodexTerminal {
            // Codex's SessionStart hook records session metadata into the
            // shared Claude fields, so terminal kind must win over the
            // presence of a captured session ID during reboot recovery.
            let codexHome = try CodexHomeManager().ensureProfilePlugin()
            env["CODEX_HOME"] = codexHome.path
            // Codex: the merged free-form overrides ARE the entire sensitive env.
            primarySensitiveEnv = rebootGlobalRepoEnv
            spawn = ClaudeSpawnCommandBuilder.build(
                resumeID: nil,
                freshSessionID: nil,
                appendSystemPrompt: nil,
                initialPrompt: nil,
                profileSecret: nil,
                cmd: CodexSpawnCommandBuilder.command,
                shellFallback: defaultShell
            )
        } else if terminal.isClaudeResumable, let sessionID = terminal.claudeSessionID {
            // Claude terminal — resume existing session with persisted profile
            var resolvedProfile: ResolvedModelProfile? = nil
            if let profileID = terminal.profileID, let resolver = modelProfileResolver {
                resolvedProfile = try? await resolver.loadByID(profileID)
            }
            spawn = ClaudeSpawnCommandBuilder.build(
                resumeID: sessionID,
                freshSessionID: nil,
                appendSystemPrompt: nil,
                initialPrompt: nil,
                profileSecret: resolvedProfile?.secret,
                profileKind: resolvedProfile?.kind,
                profileBaseURL: resolvedProfile?.baseURL,
                profileModel: resolvedProfile?.model,
                profileAwsRegion: resolvedProfile?.awsRegion,
                profileAwsProfile: resolvedProfile?.awsProfile,
                profileConfigDir: ClaudeProfileConfigDirManager.resolveConfigDir(for: resolvedProfile),
                cmd: nil,
                shellFallback: defaultShell,
                settingsOverlayPath: ClaudeHookOverlay.resolveOverlayPath(
                    fallbackModels: resolvedProfile?.fallbackModels,
                    sessionKey: terminal.id.uuidString
                ),
                pluginDirPath: PluginDirWriter.pluginDirPath,
                envSettingOverrides: claudeEnvOverrides
            )
            // Claude: layer the builder's auth/routing env ON TOP of the merged
            // free-form overrides (incl. this terminal's profile scope) so auth wins.
            let mergedEnvOverrides = EnvOverrideResolver.merge(
                global: rebootConfig?.envOverrides,
                repo: rebootRepo?.envOverrides,
                profile: resolvedProfile?.envOverrides
            )
            primarySensitiveEnv = mergedEnvOverrides.merging(spawn.sensitiveEnv) { _, builder in builder }
        } else {
            // Shell or custom-cmd terminal. Plain shell terminals have label nil or
            // TerminalLabel.shell; custom-cmd terminals store the command string directly in label.
            let cmd = (terminal.label == TerminalLabel.shell || terminal.label == nil) ? nil : terminal.label
            spawn = ClaudeSpawnCommandBuilder.build(
                resumeID: nil,
                freshSessionID: nil,
                appendSystemPrompt: nil,
                initialPrompt: nil,
                profileSecret: nil,
                cmd: cmd,
                shellFallback: defaultShell
            )
        }

        let window: (windowID: String, paneID: String)
        do {
            window = try await tmux.createWindow(
                server: worktree.tmuxServer,
                session: "main",
                cwd: worktree.path,
                shellCommand: spawn.command,
                env: env,
                sensitiveEnv: primarySensitiveEnv
            )
        } catch {
            // If we just bootstrapped the server and createWindow failed, the
            // server is alive with only the placeholder window. On the next
            // reconcile, `serverAlive=true` + `windowExists("@stale")=false`
            // would route this terminal to the dead-window-delete path and
            // lose the record. Kill the server so the next reconcile takes
            // the serverExists=false branch and retries recovery here.
            if bootstrapWindowID != nil {
                try? await tmux.killServer(server: worktree.tmuxServer)
            }
            throw error
        }
        // Now that a real window exists, it's safe to kill the bootstrap.
        // The session retains the freshly-created window, so it stays alive
        // and the server keeps running. Best-effort: a failure here just
        // leaves an empty placeholder window behind, which the orphan-window
        // cleanup pass in reconcile() will remove next time.
        if let bootstrapWindowID {
            try? await tmux.killWindow(server: worktree.tmuxServer, windowID: bootstrapWindowID)
        }
        try await db.terminals.updateTmuxIDs(id: terminal.id, windowID: window.windowID, paneID: window.paneID)
    }
}
