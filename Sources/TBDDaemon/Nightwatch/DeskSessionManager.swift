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
        if let existing = allWorktrees.first(where: { $0.displayName == NightwatchDeskPrompts.deskDisplayName && $0.isScratch }) {
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
        while true {
            let existsOnDisk = fm.fileExists(atPath: deskPath.path)
            let existsInDB = try await db.worktrees.findByPath(path: deskPath.path) != nil
            if !existsOnDisk && !existsInDB {
                break
            }
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
                displayName: NightwatchDeskPrompts.deskDisplayName,
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
    /// Uses pasteText + sendKey pattern (mirrors handleTerminalSend).
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

            guard let worktree = try await db.worktrees.get(id: worktreeID) else {
                logger.warning("Watch Desk worktree not found: \(worktreeID, privacy: .public)")
                return
            }

            // Paste the prompt text (matches handleTerminalSend pattern for reliability)
            try await tmux.pasteText(
                server: worktree.tmuxServer,
                paneID: claudeTerminal.tmuxPaneID,
                bytes: Data(prompt.utf8)
            )

            // Send Enter to submit
            try await tmux.sendKey(
                server: worktree.tmuxServer,
                paneID: claudeTerminal.tmuxPaneID,
                key: "Enter"
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

    /// Spawn a Claude terminal in the desk worktree using lifecycle.spawnPrimaryTerminals.
    /// This reuses the production spawn path which handles trust seeding, overlay injection, etc.
    private func spawnDeskTerminal(worktree: Worktree, mode: NightwatchMode) async throws {
        // Resolve profile to select model mode
        var resolvedProfile: ResolvedModelProfile? = nil
        if let resolver = modelProfileResolver {
            do {
                resolvedProfile = try await resolver.resolve(repoID: nil, override: nil)
            } catch {
                logger.warning("Failed to resolve profile for desk terminal: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Select model based on mode (use profile's model if available, else mode default)
        let selectedModel = resolvedProfile?.model ?? (mode == .daywatch ? "claude-3-5-sonnet-20241022" : "claude-3-5-opus-20241022")

        // Get initial prompt for mode
        let initialPrompt = NightwatchDeskPrompts.initialPrompt(mode: mode)

        // Use production spawn path which handles trust, overlay, and all lifecycle concerns
        _ = try await lifecycle.spawnPrimaryTerminals(
            worktree: worktree,
            repo: nil,
            skipClaude: false,
            initialPrompt: initialPrompt,
            preSessionTerminalID: nil,
            overrideProfileID: resolvedProfile?.profileID
        )

        logger.info("Spawned desk terminal in \(worktree.id, privacy: .public) with model \(selectedModel, privacy: .public)")
    }

}
