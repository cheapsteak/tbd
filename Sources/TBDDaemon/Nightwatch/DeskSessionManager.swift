import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "nightwatch.desk")

/// Manages the persistent "Watch Desk" scratch space for daywatch/nightwatch operations.
/// Idempotent creation: mode switches reuse the existing desk session.
/// Nudges the session when judgment items are queued (tick exit code 10).
public actor DeskSessionManager {
    // MARK: - Dependencies

    private let db: TBDDatabase
    private let lifecycle: WorktreeLifecycle
    private let modelProfileResolver: ModelProfileResolver?
    private let tmux: TmuxManager

    // MARK: - State

    /// UUID of the current Watch Desk worktree; nil if none exists.
    /// Cleared when mode transitions to .off. Persists across mode switches between
    /// daywatch and nightwatch.
    private var deskWorktreeID: UUID?

    /// Cached display name to identify the desk worktree across daemon restarts.
    private let deskDisplayName = "◐ Watch Desk"

    // MARK: - Init

    public init(
        db: TBDDatabase,
        lifecycle: WorktreeLifecycle,
        modelProfileResolver: ModelProfileResolver?,
        tmux: TmuxManager
    ) {
        self.db = db
        self.lifecycle = lifecycle
        self.modelProfileResolver = modelProfileResolver
        self.tmux = tmux
        self.deskWorktreeID = nil
    }

    // MARK: - Public API

    /// Idempotent: ensure a Watch Desk scratch space exists.
    /// Returns existing desk worktree if already created, otherwise creates one.
    /// - Parameter mode: The current nightwatch mode (daywatch or nightwatch)
    /// - Returns: The Worktree for the desk session
    public func ensureDeskSession(mode: NightwatchMode) async throws -> Worktree {
        // If we already have a cached desk session, return it
        if let cachedID = deskWorktreeID,
           let existing = try await db.worktrees.get(id: cachedID) {
            return existing
        }

        // Query by displayName to detect existing desk worktrees
        // (survives daemon restart since displayName is stable).
        let allWorktrees = try await db.worktrees.list()
        if let existing = allWorktrees.first(where: { $0.displayName == deskDisplayName && $0.isScratch }) {
            deskWorktreeID = existing.id
            logger.info("Reusing existing Watch Desk session: \(existing.id, privacy: .public)")
            return existing
        }

        // Create a new scratch space
        let fm = FileManager.default
        let scratchDir = TBDConstants.scratchDir
        try fm.createDirectory(at: scratchDir, withIntermediateDirectories: true)

        // Allocate a unique directory name
        var name = "watch-desk"
        var deskPath = scratchDir.appendingPathComponent(name)
        var attempts = 0
        while fm.fileExists(atPath: deskPath.path) || (try await db.worktrees.findByPath(path: deskPath.path) != nil) {
            name = "watch-desk-\(UUID().uuidString.prefix(8))"
            deskPath = scratchDir.appendingPathComponent(name)
            attempts += 1
            if attempts > 50 {
                throw WorktreeLifecycleError.createFailed("Could not allocate unique desk directory after 50 attempts")
            }
        }

        // Create the directory
        try fm.createDirectory(at: deskPath, withIntermediateDirectories: false)

        let tmuxServer = TmuxManager.serverName(forRepoPath: scratchDir.path)

        // Create DB row
        let wt: Worktree
        do {
            wt = try await db.worktrees.createScratch(
                name: name,
                displayName: deskDisplayName,
                path: deskPath.path,
                tmuxServer: tmuxServer
            )
        } catch {
            try? fm.removeItem(at: deskPath)
            throw error
        }

        // Spawn a Claude terminal configured for nightwatch operations
        do {
            _ = try await spawnDeskTerminal(worktree: wt, mode: mode)
        } catch {
            logger.warning("Failed to spawn desk terminal: \(error.localizedDescription, privacy: .public)")
            // Terminal spawn failure is best-effort; don't fail the worktree creation
        }

        // Cache the worktree ID
        deskWorktreeID = wt.id

        logger.info("Created Watch Desk session: \(wt.id, privacy: .public) at \(wt.path, privacy: .public)")
        return wt
    }

    /// Nudge the desk session to process queued judgment items.
    /// - Parameters:
    ///   - worktreeID: The Watch Desk worktree ID
    ///   - act: true for nightwatch (auto-act), false for daywatch (dry-run/batch only)
    public func nudgeDeskSession(worktreeID: UUID, act: Bool) async {
        let mode: NightwatchMode = act ? .nightwatch : .daywatch
        let prompt = NightwatchDeskPrompts.judgePrompt(mode: mode, dryRun: false)

        do {
            let terminals = try await db.terminals.list(worktreeID: worktreeID)
            guard let claudeTerminal = terminals.first(where: { $0.label == TerminalLabel.claudeCode }) else {
                logger.warning("No Claude terminal found in Watch Desk; skipping nudge")
                return
            }

            // Send the judgment prompt to the terminal via tmux
            guard let worktree = try await db.worktrees.get(id: worktreeID) else {
                logger.warning("Watch Desk worktree not found: \(worktreeID, privacy: .public)")
                return
            }

            let escapedPrompt = shellEscape(prompt)
            try await tmux.sendKeys(
                server: worktree.tmuxServer,
                paneID: claudeTerminal.tmuxPaneID,
                text: escapedPrompt
            )

            logger.debug("Nudged Watch Desk session: act=\(act, privacy: .public)")
        } catch {
            logger.error("Failed to nudge desk session: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Gracefully close the desk session (archive it).
    public func closeDeskSession() async {
        guard let worktreeID = deskWorktreeID else { return }

        do {
            guard let wt = try await db.worktrees.get(id: worktreeID) else {
                logger.warning("Watch Desk worktree not found during close: \(worktreeID, privacy: .public)")
                deskWorktreeID = nil
                return
            }

            // Kill tmux windows
            let terminals = try await db.terminals.list(worktreeID: wt.id)
            for t in terminals {
                try? await tmux.killWindow(server: wt.tmuxServer, windowID: t.tmuxWindowID)
            }

            // Delete terminal rows
            try await db.terminals.deleteForWorktree(worktreeID: wt.id)
            try await db.tabs.deleteForWorktree(worktreeID: wt.id)

            // Archive the worktree (preserve the folder on disk)
            try await db.worktrees.archive(id: wt.id)

            logger.info("Archived Watch Desk session: \(wt.id, privacy: .public)")
        } catch {
            logger.error("Failed to close desk session: \(error.localizedDescription, privacy: .public)")
        }

        deskWorktreeID = nil
    }

    // MARK: - Private Helpers

    /// Spawn a Claude terminal in the desk worktree, configured for nightwatch operations.
    private func spawnDeskTerminal(worktree: Worktree, mode: NightwatchMode) async throws {
        let skillDir = PluginDirWriter.pluginDirPath + "/skills/nightwatch"

        // Select model based on mode
        let model: String = mode == .daywatch ? "claude-3-5-sonnet-20241022" : "claude-3-5-opus-20241022"

        // Resolve profile for model routing
        var resolvedProfile: ResolvedModelProfile? = nil
        if let resolver = modelProfileResolver {
            do {
                resolvedProfile = try await resolver.resolve(repoID: nil, override: nil)
            } catch {
                logger.warning("Failed to resolve profile for desk terminal: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Build spawn command
        let sessionID = UUID().uuidString
        let initialPrompt = NightwatchDeskPrompts.initialPrompt(mode: mode)

        let spawnResult = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: sessionID,
            appendSystemPrompt: nil,
            initialPrompt: initialPrompt,
            profileSecret: resolvedProfile?.secret,
            profileKind: resolvedProfile?.kind,
            profileBaseURL: resolvedProfile?.baseURL,
            profileModel: model,
            profileAwsRegion: resolvedProfile?.awsRegion,
            profileAwsProfile: resolvedProfile?.awsProfile,
            profileConfigDir: nil,  // ResolvedModelProfile doesn't have configDir
            cmd: nil,
            shellFallback: "/bin/zsh",
            settingsOverlayPath: ClaudeHookOverlay.overlayPath,
            pluginDirPath: skillDir,
            envSettingOverrides: [:],
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )

        // Ensure tmux server exists
        let tmuxServer = worktree.tmuxServer
        _ = try await tmux.ensureServer(
            server: tmuxServer,
            session: "main",
            cwd: skillDir,
            cols: TmuxManager.defaultCols,
            rows: TmuxManager.defaultRows
        )

        // Create the window
        let terminalID = UUID()
        let windowID = try await tmux.createWindow(
            server: tmuxServer,
            label: TerminalLabel.claudeCode,
            cwd: skillDir,
            command: spawnResult.command,
            sensitiveEnv: spawnResult.sensitiveEnv
        )

        // Record the terminal in the database
        let paneID = "1:0"  // Default pane ID for new window
        _ = try await db.terminals.create(
            id: terminalID,
            worktreeID: worktree.id,
            tmuxWindowID: windowID,
            tmuxPaneID: paneID,
            label: TerminalLabel.claudeCode,
            claudeSessionID: sessionID,
            profileID: resolvedProfile?.profileID
        )

        logger.info("Spawned desk terminal in \(worktree.id, privacy: .public) with model \(model, privacy: .public)")
    }

    /// Shell-escape a string for safe use in shell commands.
    private func shellEscape(_ str: String) -> String {
        return "'\(str.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
