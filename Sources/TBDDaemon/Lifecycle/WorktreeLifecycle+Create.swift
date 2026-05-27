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
    public func createWorktree(repoID: UUID, folder: String? = nil, branch: String? = nil, displayName: String? = nil, skipClaude: Bool = false, initialPrompt: String? = nil, cols: Int? = nil, rows: Int? = nil, parentWorktreeID: UUID? = nil, siblingOfWorktreeID: UUID? = nil, callerWorktreeID: UUID? = nil, suppressAutoParent: Bool = false) async throws -> Worktree {
        let pending = try await beginCreateWorktree(repoID: repoID, folder: folder, branch: branch, displayName: displayName, skipClaude: skipClaude, parentWorktreeID: parentWorktreeID, siblingOfWorktreeID: siblingOfWorktreeID, callerWorktreeID: callerWorktreeID, suppressAutoParent: suppressAutoParent)
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
    public func beginCreateWorktree(repoID: UUID, folder: String? = nil, branch: String? = nil, displayName: String? = nil, skipClaude: Bool = false, parentWorktreeID: UUID? = nil, siblingOfWorktreeID: UUID? = nil, callerWorktreeID: UUID? = nil, suppressAutoParent: Bool = false) async throws -> Worktree {
        // 1. Fetch repo
        guard let repo = try await db.repos.get(id: repoID) else {
            throw WorktreeLifecycleError.repoNotFound(repoID)
        }

        // 1a. Resolve parent worktree (caller/sibling/explicit → parent id, or nil)
        let resolvedParent = try await ParentResolver.resolve(
            db: db,
            explicitParent: parentWorktreeID,
            siblingOf: siblingOfWorktreeID,
            caller: callerWorktreeID,
            suppressAutoParent: suppressAutoParent
        )

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
            status: .creating,
            parentWorktreeID: resolvedParent
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

    private func resolvePrimaryTerminalKind(
        skipClaude: Bool,
        archivedClaudeSessions: [String]?,
        configuredPreference: PrimaryAgentPreference
    ) -> TerminalKind {
        if skipClaude {
            return .shell
        }
        if let archivedClaudeSessions, !archivedClaudeSessions.isEmpty {
            return .claude
        }
        return configuredPreference.terminalKind
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
    /// is reused for the primary Claude terminal to restore the conversation, and any
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
        let config = try await db.config.get()
        let claudeEnvOverrides = config.envSettingOverrides
        let primaryTerminalKind = resolvePrimaryTerminalKind(
            skipClaude: skipClaude,
            archivedClaudeSessions: archivedClaudeSessions,
            configuredPreference: config.primaryAgentPreference
        )
        let archivedSessions = archivedClaudeSessions ?? []
        // Resolve a usable size: prefer caller's value, otherwise fall back to
        // TmuxManager's defaults. tmux's own 80x24 default would let Claude
        // render into hard-wrapped scrollback that can never be reflowed when
        // the user later attaches a wider SwiftTerm view.
        let resolvedCols = cols ?? TmuxManager.defaultCols
        let resolvedRows = rows ?? TmuxManager.defaultRows
        // Ensure tmux server exists — capture initial window ID to kill later
        let initialWindowID = try await tmux.ensureServer(
            server: tmuxServer,
            session: "main",
            cwd: worktreePath,
            cols: resolvedCols,
            rows: resolvedRows
        )

        // Resolve model profile (repo override → global default → none).
        // Failures here must NOT break worktree creation — fall back to keychain login.
        let needsResolvedClaudeProfile = !skipClaude && (
            primaryTerminalKind == .claude || !archivedSessions.isEmpty
        )
        var resolvedProfile: ResolvedModelProfile? = nil
        if needsResolvedClaudeProfile, let resolver = modelProfileResolver {
            do {
                resolvedProfile = try await resolver.resolve(repoID: repo.id)
            } catch {
                logger.warning("model profile resolution failed; falling back to keychain login")
                resolvedProfile = nil
            }
        }

        // Create terminal 1: primary agent (or shell if skipped).
        let plannedTerminalID1 = UUID()
        var createdTerminalIDs = [plannedTerminalID1]
        let primaryCommand: String
        let primaryEnv: [String: String]
        let primarySensitiveEnv: [String: String]
        let primarySessionID: String?
        let primaryProfileID: UUID?
        let primaryLabel: String
        switch primaryTerminalKind {
        case .shell:
            primaryCommand = defaultShell
            primaryEnv = [
                "TBD_WORKTREE_ID": worktreeID.uuidString,
                "TBD_TERMINAL_ID": plannedTerminalID1.uuidString,
            ]
            primarySensitiveEnv = [:]
            primarySessionID = nil
            primaryProfileID = nil
            primaryLabel = "shell"
        case .codex:
            let codexHome = try CodexHomeManager().ensureProfilePlugin()
            primaryCommand = CodexSpawnCommandBuilder.build(initialPrompt: initialPrompt)
            primaryEnv = [
                "TBD_WORKTREE_ID": worktreeID.uuidString,
                "TBD_TERMINAL_ID": plannedTerminalID1.uuidString,
                "CODEX_HOME": codexHome.path,
            ]
            primarySensitiveEnv = [:]
            primarySessionID = nil
            primaryProfileID = nil
            primaryLabel = "Codex"
        case .claude:
            let archivedSession = archivedSessions.first
            let sessionUUID = archivedSession ?? UUID().uuidString
            primarySessionID = sessionUUID
            let isResume = archivedSession != nil
            // `--resume` is what actually restores the prior conversation;
            // `--session-id` is for starting a NEW session with a pre-chosen
            // UUID (used on fresh create). Reviving with `--session-id` on an
            // already-existing session file would lose the transcript.
            let appendPrompt = isResume
                ? nil
                : SystemPromptBuilder.build(repo: repo, worktree: worktree, isResume: false)
            let spawn = ClaudeSpawnCommandBuilder.build(
                resumeID: isResume ? sessionUUID : nil,
                freshSessionID: isResume ? nil : sessionUUID,
                appendSystemPrompt: appendPrompt,
                initialPrompt: isResume ? nil : initialPrompt,
                profileSecret: resolvedProfile?.secret,
                profileKind: resolvedProfile?.kind,
                profileBaseURL: resolvedProfile?.baseURL,
                profileModel: resolvedProfile?.model,
                profileAwsRegion: resolvedProfile?.awsRegion,
                profileAwsProfile: resolvedProfile?.awsProfile,
                profileConfigDir: ClaudeProfileConfigDirManager.resolveConfigDir(for: resolvedProfile),
                cmd: nil,
                shellFallback: defaultShell,
                settingsOverlayPath: ClaudeHookOverlay.overlayPath,
                pluginDirPath: PluginDirWriter.pluginDirPath,
                envSettingOverrides: claudeEnvOverrides
            )
            primaryCommand = spawn.command
            primaryEnv = [
                "TBD_WORKTREE_ID": worktreeID.uuidString,
                "TBD_TERMINAL_ID": plannedTerminalID1.uuidString,
            ]
            primarySensitiveEnv = spawn.sensitiveEnv
            primaryProfileID = resolvedProfile?.profileID
            primaryLabel = "Claude Code"
        }
        let window1 = try await tmux.createWindow(
            server: tmuxServer,
            session: "main",
            cwd: worktreePath,
            shellCommand: primaryCommand,
            env: primaryEnv,
            sensitiveEnv: primarySensitiveEnv,
            cols: resolvedCols,
            rows: resolvedRows
        )
        _ = try await db.terminals.create(
            id: plannedTerminalID1,
            worktreeID: worktreeID,
            tmuxWindowID: window1.windowID,
            tmuxPaneID: window1.paneID,
            label: primaryLabel,
            claudeSessionID: primarySessionID,
            profileID: primaryProfileID,
            kind: primaryTerminalKind
        )

        // Create terminal 2: setup hook
        let plannedTerminalID2 = UUID()
        createdTerminalIDs.append(plannedTerminalID2)
        let setupHookPath = hooks.resolve(
            event: .setup,
            repoPath: worktreePath,
            appHookPath: TBDConstants.hookPath(repoID: worktree.repoID, eventName: HookEvent.setup.rawValue)
        )
        let setupCommand = shellWrapped(setupHookPath ?? defaultShell)
        // Inject TBD_TERMINAL_ID + TBD_WORKTREE_ID so setup hooks and any
        // tooling they run can identify their owning terminal.
        let setupEnv: [String: String] = [
            "TBD_WORKTREE_ID": worktreeID.uuidString,
            "TBD_TERMINAL_ID": plannedTerminalID2.uuidString,
        ]
        let window2 = try await tmux.createWindow(
            server: tmuxServer,
            session: "main",
            cwd: worktreePath,
            shellCommand: setupCommand,
            env: setupEnv,
            cols: resolvedCols,
            rows: resolvedRows
        )
        _ = try await db.terminals.create(
            id: plannedTerminalID2,
            worktreeID: worktreeID,
            tmuxWindowID: window2.windowID,
            tmuxPaneID: window2.paneID,
            label: "setup",
            kind: .shell
        )

        // Restore any archived Claude sessions that were not consumed by the
        // primary terminal.
        let additionalArchivedClaudeSessions: [String]
        switch primaryTerminalKind {
        case .claude:
            additionalArchivedClaudeSessions = Array(archivedSessions.dropFirst())
        case .codex:
            additionalArchivedClaudeSessions = archivedSessions
        case .shell:
            additionalArchivedClaudeSessions = []
        }
        if !skipClaude {
            for sessionID in additionalArchivedClaudeSessions {
                let plannedID = UUID()
                createdTerminalIDs.append(plannedID)
                let spawn = ClaudeSpawnCommandBuilder.build(
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
                    settingsOverlayPath: ClaudeHookOverlay.overlayPath,
                    pluginDirPath: PluginDirWriter.pluginDirPath,
                    envSettingOverrides: claudeEnvOverrides
                )
                let perTermEnv: [String: String] = [
                    "TBD_WORKTREE_ID": worktreeID.uuidString,
                    "TBD_TERMINAL_ID": plannedID.uuidString,
                ]
                let window = try await tmux.createWindow(
                    server: tmuxServer,
                    session: "main",
                    cwd: worktreePath,
                    shellCommand: spawn.command,
                    env: perTermEnv,
                    sensitiveEnv: spawn.sensitiveEnv,
                    cols: resolvedCols,
                    rows: resolvedRows
                )
                _ = try await db.terminals.create(
                    id: plannedID,
                    worktreeID: worktreeID,
                    tmuxWindowID: window.windowID,
                    tmuxPaneID: window.paneID,
                    label: "Claude Code",
                    claudeSessionID: sessionID,
                    profileID: resolvedProfile?.profileID,
                    kind: .claude
                )
            }
        }

        try await db.worktrees.setTabOrder(worktreeID: worktreeID, tabIDs: createdTerminalIDs)
        try await db.worktrees.setActiveTabID(worktreeID: worktreeID, tabID: plannedTerminalID1)

        // Kill the untracked initial window that new-session created
        if let windowID = initialWindowID {
            try? await tmux.killWindow(server: tmuxServer, windowID: windowID)
        }
    }
}
