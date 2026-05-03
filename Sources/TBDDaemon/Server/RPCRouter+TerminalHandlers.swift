import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "terminalHandlers")

extension RPCRouter {

    // MARK: - Terminal Handlers

    func handleTerminalCreate(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalCreateParams.self, from: paramsData)

        // Look up the worktree to get tmux server and path
        guard let worktree = try await db.worktrees.get(id: params.worktreeID) else {
            return RPCResponse(error: "Worktree not found: \(params.worktreeID)")
        }

        // Resolve initial size: caller-supplied → TmuxManager defaults to avoid
        // tmux's 80x24 default producing un-reflowable hard-wrapped scrollback.
        let resolvedCols = params.cols ?? TmuxManager.defaultCols
        let resolvedRows = params.rows ?? TmuxManager.defaultRows

        // Ensure tmux server exists before creating window
        _ = try await tmux.ensureServer(
            server: worktree.tmuxServer,
            session: "main",
            cwd: worktree.path,
            cols: resolvedCols,
            rows: resolvedRows
        )

        // Look up repo once for system prompt env vars and Claude session setup
        let repo = try await db.repos.get(id: worktree.repoID)

        // Build env vars available in all TBD terminals
        var env = SystemPromptBuilder.promptLayers(repo: repo, worktree: worktree)
        env["TBD_WORKTREE_ID"] = params.worktreeID.uuidString

        // Codex branch: minimal launch with isolated CODEX_HOME. No session
        // tracking, no system prompt injection, no token resolution. Session
        // resume / state detection / hooks are tracked as follow-up issues.
        //
        // Build env independently — do NOT inherit the Claude-shaped
        // TBD_PROMPT_CONTEXT / TBD_PROMPT_RENAME / TBD_PROMPT_INSTRUCTIONS
        // vars from SystemPromptBuilder.promptLayers; those describe TBD as
        // a Claude-centric host and would be misleading noise inside a
        // Codex pane.
        if params.type == .codex {
            let codexHome = try CodexHomeManager().ensureHome(forRepoID: worktree.repoID)
            var codexEnv: [String: String] = [:]
            codexEnv["TBD_WORKTREE_ID"] = params.worktreeID.uuidString
            codexEnv["CODEX_HOME"] = codexHome.path

            let window = try await tmux.createWindow(
                server: worktree.tmuxServer,
                session: "main",
                cwd: worktree.path,
                shellCommand: "codex --full-auto",
                env: codexEnv,
                cols: resolvedCols,
                rows: resolvedRows
            )

            let terminal = try await db.terminals.create(
                worktreeID: params.worktreeID,
                tmuxWindowID: window.windowID,
                tmuxPaneID: window.paneID,
                label: "Codex",
                claudeSessionID: nil,
                claudeTokenID: nil
            )

            subscriptions.broadcast(delta: .terminalCreated(TerminalDelta(
                terminalID: terminal.id, worktreeID: terminal.worktreeID, label: terminal.label
            )))

            return try RPCResponse(result: terminal)
        }

        let isClaudeType = params.type == .claude || params.resumeSessionID != nil
        let claudeSessionID: String?
        let label: String?

        // Resolve claude token (repo override → global default → none).
        // Failure here must NOT break terminal spawn — fall back to keychain login.
        var resolvedToken: ResolvedClaudeToken? = nil
        if isClaudeType {
            do {
                if let overrideID = params.overrideTokenID {
                    resolvedToken = try await claudeTokenResolver.loadByID(overrideID)
                } else {
                    resolvedToken = try await claudeTokenResolver.resolve(repoID: worktree.repoID)
                }
            } catch {
                logger.warning("claude token resolution failed; falling back to keychain login")
                resolvedToken = nil
            }
        }

        // Build the spawn command via the pure helper.
        let appendSystemPrompt: String?
        let freshSessionID: String?
        if let resumeID = params.resumeSessionID {
            claudeSessionID = resumeID
            freshSessionID = nil
            appendSystemPrompt = nil
            label = "claude"
        } else if isClaudeType {
            let sessionID = UUID().uuidString
            claudeSessionID = sessionID
            freshSessionID = sessionID
            if let repo,
               let prompt = SystemPromptBuilder.build(repo: repo, worktree: worktree, isResume: false) {
                appendSystemPrompt = prompt
            } else {
                appendSystemPrompt = nil
            }
            label = "Claude Code"
        } else if let cmd = params.cmd {
            claudeSessionID = nil
            freshSessionID = nil
            appendSystemPrompt = nil
            label = cmd
        } else {
            claudeSessionID = nil
            freshSessionID = nil
            appendSystemPrompt = nil
            label = nil
        }

        let spawn = ClaudeSpawnCommandBuilder.build(
            resumeID: params.resumeSessionID,
            freshSessionID: freshSessionID,
            appendSystemPrompt: appendSystemPrompt,
            initialPrompt: params.prompt,
            tokenSecret: resolvedToken?.secret,
            tokenKind: resolvedToken?.kind,
            cmd: params.cmd,
            shellFallback: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        )

        let window = try await tmux.createWindow(
            server: worktree.tmuxServer,
            session: "main",
            cwd: worktree.path,
            shellCommand: spawn.command,
            env: env,
            sensitiveEnv: spawn.sensitiveEnv,
            cols: resolvedCols,
            rows: resolvedRows
        )

        let terminal = try await db.terminals.create(
            worktreeID: params.worktreeID,
            tmuxWindowID: window.windowID,
            tmuxPaneID: window.paneID,
            label: label,
            claudeSessionID: claudeSessionID,
            claudeTokenID: resolvedToken?.tokenID
        )

        subscriptions.broadcast(delta: .terminalCreated(TerminalDelta(
            terminalID: terminal.id, worktreeID: terminal.worktreeID, label: terminal.label
        )))

        return try RPCResponse(result: terminal)
    }

    func handleTerminalList(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalListParams.self, from: paramsData)
        let terminals = try await db.terminals.list(worktreeID: params.worktreeID)
        return try RPCResponse(result: terminals)
    }


    func handleTerminalDelete(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalDeleteParams.self, from: paramsData)

        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            return RPCResponse(error: "Terminal not found: \(params.terminalID)")
        }

        // Kill the tmux window
        if let worktree = try await db.worktrees.get(id: terminal.worktreeID) {
            try? await tmux.killWindow(server: worktree.tmuxServer, windowID: terminal.tmuxWindowID)
        }

        // Delete from DB
        try await db.terminals.delete(id: params.terminalID)

        subscriptions.broadcast(delta: .terminalRemoved(TerminalIDDelta(
            terminalID: terminal.id
        )))

        return .ok()
    }

    func handleTerminalSetPin(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalSetPinParams.self, from: paramsData)
        let pinnedAt: Date? = params.pinned ? Date() : nil
        try await db.terminals.setPin(id: params.terminalID, pinned: params.pinned, at: pinnedAt ?? Date())
        subscriptions.broadcast(delta: .terminalPinChanged(TerminalPinDelta(
            terminalID: params.terminalID, pinnedAt: pinnedAt
        )))
        return .ok()
    }

    func handleTerminalRecreateWindow(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalRecreateWindowParams.self, from: paramsData)

        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            return RPCResponse(error: "Terminal not found: \(params.terminalID)")
        }

        guard let worktree = try await db.worktrees.get(id: terminal.worktreeID) else {
            return RPCResponse(error: "Worktree not found for terminal: \(params.terminalID)")
        }

        // Kill the old window if it still exists (avoids orphans)
        try? await tmux.killWindow(server: worktree.tmuxServer, windowID: terminal.tmuxWindowID)

        let resolvedCols = params.cols ?? TmuxManager.defaultCols
        let resolvedRows = params.rows ?? TmuxManager.defaultRows

        // Ensure tmux server exists
        _ = try await tmux.ensureServer(
            server: worktree.tmuxServer,
            session: "main",
            cwd: worktree.path,
            cols: resolvedCols,
            rows: resolvedRows
        )

        // Create a new tmux window with a default shell.
        // Defensively set TBD_WORKTREE_ID even though the recreated pane runs a
        // plain shell — the user may run `tbd` CLI commands or launch `claude`
        // themselves from that shell, and those tools resolve the worktree from
        // the env. Without this set, the pane would inherit whatever TBD_WORKTREE_ID
        // got baked into the tmux server's global env, leaking another worktree's
        // identity into this one.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let env: [String: String] = ["TBD_WORKTREE_ID": worktree.id.uuidString]
        let window = try await tmux.createWindow(
            server: worktree.tmuxServer,
            session: "main",
            cwd: worktree.path,
            shellCommand: shell,
            env: env,
            cols: resolvedCols,
            rows: resolvedRows
        )

        // Update the terminal record with new window/pane IDs and clear stale
        // Claude metadata — the recreated window runs a plain shell, not Claude.
        try await db.terminals.updateTmuxIDs(
            id: params.terminalID,
            windowID: window.windowID,
            paneID: window.paneID
        )
        try await db.terminals.clearRecreated(id: params.terminalID)

        // Return updated terminal
        guard let updated = try await db.terminals.get(id: params.terminalID) else {
            return RPCResponse(error: "Terminal not found after update")
        }

        return try RPCResponse(result: updated)
    }

    func handleTerminalOutput(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalOutputParams.self, from: paramsData)

        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            return RPCResponse(error: "Terminal not found: \(params.terminalID)")
        }

        guard let worktree = try await db.worktrees.get(id: terminal.worktreeID) else {
            return RPCResponse(error: "Worktree not found for terminal: \(params.terminalID)")
        }

        let rawOutput = try await tmux.capturePaneOutput(
            server: worktree.tmuxServer,
            paneID: terminal.tmuxPaneID
        )

        let lines = params.lines ?? 50
        let outputLines = rawOutput.split(separator: "\n", omittingEmptySubsequences: false)
        let trimmed = outputLines.suffix(lines).joined(separator: "\n")

        return try RPCResponse(result: TerminalOutputResult(output: trimmed))
    }

    func handleTerminalConversation(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalConversationParams.self, from: paramsData)

        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            return RPCResponse(error: "Terminal not found: \(params.terminalID)")
        }

        guard let sessionID = terminal.claudeSessionID else {
            return RPCResponse(error: "No Claude session ID for terminal \(params.terminalID)")
        }

        guard let worktree = try await db.worktrees.get(id: terminal.worktreeID) else {
            return RPCResponse(error: "Worktree not found for terminal: \(params.terminalID)")
        }

        let count = params.messages ?? 1
        let messages = Self.readSessionMessages(
            sessionID: sessionID,
            worktreePath: worktree.path,
            count: count
        )
        return try RPCResponse(result: TerminalConversationResult(messages: messages, sessionID: sessionID))
    }

    // MARK: - Session JSONL Parsing (Codable)

    private struct SessionEntry: Decodable {
        let type: String
        let message: SessionMessage?
    }

    private struct SessionMessage: Decodable {
        let role: String?
        let content: [ContentBlock]?
    }

    private struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }

    /// Read the last N user/assistant text messages from the session JSONL,
    /// scoped to the project directory belonging to `worktreePath`. Returns
    /// `[]` if the session does not live under that worktree's project dir.
    static func readSessionMessages(
        sessionID: String,
        worktreePath: String,
        count: Int,
        projectsBase: URL? = nil
    ) -> [ConversationMessage] {
        let fm = FileManager.default
        guard let projectDir = ClaudeProjectDirectory.resolve(
            worktreePath: worktreePath,
            projectsBase: projectsBase
        ) else {
            return []
        }
        let path = projectDir.appendingPathComponent("\(sessionID).jsonl")
        guard fm.fileExists(atPath: path.path),
              let data = fm.contents(atPath: path.path),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        var allMessages: [ConversationMessage] = []

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(SessionEntry.self, from: lineData) else {
                continue
            }

            guard entry.type == "assistant" || entry.type == "user",
                  let blocks = entry.message?.content else {
                continue
            }

            let textParts = blocks.compactMap { $0.type == "text" ? $0.text : nil }
            if !textParts.isEmpty {
                allMessages.append(ConversationMessage(
                    role: entry.type,
                    content: textParts.joined(separator: "\n")
                ))
            }
        }

        return Array(allMessages.suffix(count))
    }

    // MARK: - Swap Claude Token (mid-conversation)

    /// Decision for how to spawn the new pane during a token swap.
    /// Pure data — facilitates unit-testing the branch without spinning up tmux.
    enum SwapSpawnPlan: Equatable {
        /// Session has prior content — `claude --resume <id>` and recapture
        /// the forked session ID after a brief delay.
        case resume(sessionID: String)
        /// Session JSONL is missing or has no conversation — start a new
        /// session with the system prompt, no recapture needed.
        case fresh(sessionID: String)
    }

    /// Choose between the resume and fresh-spawn paths for a token swap.
    static func planTerminalSwap(
        oldSessionID: String,
        isBlank: Bool,
        freshSessionIDProvider: () -> String = { UUID().uuidString }
    ) -> SwapSpawnPlan {
        if isBlank {
            return .fresh(sessionID: freshSessionIDProvider())
        }
        return .resume(sessionID: oldSessionID)
    }

    func handleTerminalSwapClaudeToken(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalSwapClaudeTokenParams.self, from: paramsData)

        guard let oldTerminal = try await db.terminals.get(id: params.terminalID) else {
            return RPCResponse(error: "Terminal not found: \(params.terminalID)")
        }
        guard let sessionID = oldTerminal.claudeSessionID else {
            return RPCResponse(error: "Terminal \(params.terminalID) is not a Claude terminal")
        }
        guard let worktree = try await db.worktrees.get(id: oldTerminal.worktreeID) else {
            return RPCResponse(error: "Worktree not found for terminal: \(params.terminalID)")
        }

        // Resolve the requested token (nil = no override; keychain login).
        // We do NOT touch the old terminal — both tabs coexist after the swap.
        let resolved: ResolvedClaudeToken?
        if let newID = params.newTokenID {
            do {
                resolved = try await claudeTokenResolver.loadByID(newID)
            } catch {
                return RPCResponse(error: "Failed to load token")
            }
            if resolved == nil {
                return RPCResponse(error: "Token not found or unreadable")
            }
        } else {
            resolved = nil
        }

        // Spawn a NEW window in the same worktree. If the existing session has
        // any conversation content, `claude --resume` forks it into a fresh
        // session file (we recapture the forked ID below). If the session is
        // blank — JSONL never written or no real entries — resuming it would
        // produce "no conversation found" and chaotic behavior, so we instead
        // spawn a brand-new session and skip the recapture.
        let repo = try await db.repos.get(id: worktree.repoID)
        var env = SystemPromptBuilder.promptLayers(repo: repo, worktree: worktree)
        env["TBD_WORKTREE_ID"] = worktree.id.uuidString

        let blank = ClaudeSessionScanner.isSessionBlank(
            sessionID: sessionID,
            worktreePath: worktree.path
        )
        let plan = Self.planTerminalSwap(oldSessionID: sessionID, isBlank: blank)

        let spawn: ClaudeSpawnCommandBuilder.Result
        let storedSessionID: String
        let scheduleRecapture: Bool
        switch plan {
        case .resume(let resumeID):
            logger.debug("swap: resuming session \(resumeID, privacy: .public)")
            spawn = ClaudeSpawnCommandBuilder.build(
                resumeID: resumeID,
                freshSessionID: nil,
                appendSystemPrompt: nil,
                initialPrompt: nil,
                tokenSecret: resolved?.secret,
                tokenKind: resolved?.kind,
                cmd: nil,
                shellFallback: ""
            )
            storedSessionID = resumeID
            scheduleRecapture = true
        case .fresh(let newSessionID):
            logger.debug("swap: blank session — spawning fresh \(newSessionID, privacy: .public)")
            let appendPrompt = repo.flatMap {
                SystemPromptBuilder.build(repo: $0, worktree: worktree, isResume: false)
            }
            spawn = ClaudeSpawnCommandBuilder.build(
                resumeID: nil,
                freshSessionID: newSessionID,
                appendSystemPrompt: appendPrompt,
                initialPrompt: nil,
                tokenSecret: resolved?.secret,
                tokenKind: resolved?.kind,
                cmd: nil,
                shellFallback: ""
            )
            storedSessionID = newSessionID
            scheduleRecapture = false
        }

        // Resolve initial size: caller-supplied → TmuxManager defaults to avoid
        // tmux's 80x24 default producing un-reflowable hard-wrapped scrollback.
        let resolvedCols = params.cols ?? TmuxManager.defaultCols
        let resolvedRows = params.rows ?? TmuxManager.defaultRows

        let window = try await tmux.createWindow(
            server: worktree.tmuxServer,
            session: "main",
            cwd: worktree.path,
            shellCommand: spawn.command,
            env: env,
            sensitiveEnv: spawn.sensitiveEnv,
            cols: resolvedCols,
            rows: resolvedRows
        )

        let newTerminal = try await db.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: window.windowID,
            tmuxPaneID: window.paneID,
            label: "claude",
            claudeSessionID: storedSessionID,
            claudeTokenID: resolved?.tokenID
        )

        subscriptions.broadcast(delta: .terminalCreated(TerminalDelta(
            terminalID: newTerminal.id, worktreeID: newTerminal.worktreeID, label: newTerminal.label
        )))

        // For the resume path, `claude --resume <oldID>` forks the conversation
        // into a NEW session file with a fresh UUID. Mirror SuspendResumeCoordinator's
        // post-resume pattern: wait ~5s for Claude to settle, then capture the
        // new session ID from the pane and persist it. The fresh path already
        // stored the correct ID, so no recapture is needed.
        if scheduleRecapture {
            let newTerminalID = newTerminal.id
            let newPaneID = window.paneID
            let server = worktree.tmuxServer
            let tmuxRef = self.tmux
            let dbRef = self.db
            Task {
                try? await Task.sleep(for: .seconds(5))
                let detector = ClaudeStateDetector(tmux: tmuxRef)
                if let recaptured = await detector.captureSessionID(server: server, paneID: newPaneID) {
                    try? await dbRef.terminals.updateSessionID(id: newTerminalID, sessionID: recaptured)
                }
            }
        }

        guard let updated = try await db.terminals.get(id: newTerminal.id) else {
            return RPCResponse(error: "Terminal vanished after swap")
        }
        return try RPCResponse(result: updated)
    }

    func handleTerminalSend(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalSendParams.self, from: paramsData)

        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            return RPCResponse(error: "Terminal not found: \(params.terminalID)")
        }

        // Look up the worktree to get the tmux server name
        guard let worktree = try await db.worktrees.get(id: terminal.worktreeID) else {
            return RPCResponse(error: "Worktree not found for terminal: \(params.terminalID)")
        }

        try await tmux.sendKeys(
            server: worktree.tmuxServer,
            paneID: terminal.tmuxPaneID,
            text: params.text
        )

        if params.submit == true {
            try await tmux.sendKey(
                server: worktree.tmuxServer,
                paneID: terminal.tmuxPaneID,
                key: "Enter"
            )
        }

        return .ok()
    }

    // MARK: - Main Area Size Broadcast

    /// Resize every known tmux window to the new cell dimensions. Called by
    /// the app when its main terminal area resizes (debounced) so detached
    /// panes don't keep stale dimensions; attached panes get overwritten by
    /// SwiftTerm's TIOCSWINSZ within milliseconds.
    func handleSetMainAreaSize(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(SetMainAreaSizeParams.self, from: paramsData)
        guard params.cols >= TmuxManager.minCols, params.rows >= TmuxManager.minRows else {
            // Silently ignore degenerate sizes — clients can race below the
            // minimum during window setup; tmux handles it correctly when the
            // next valid size comes in.
            return .ok()
        }

        let allTerminals = try await db.terminals.list()
        // Filter to active worktrees only — archived worktrees have had their
        // tmux servers killed, so resizing windows there spawns dead `tmux
        // resize-window` processes (errors swallowed by `try?`) on every
        // resize-debounce tick during a window drag.
        let worktrees = try await db.worktrees.list(status: .active)
        let serverByWorktree = Dictionary(uniqueKeysWithValues: worktrees.map { ($0.id, $0.tmuxServer) })

        logger.debug("setMainAreaSize \(params.cols, privacy: .public)x\(params.rows, privacy: .public) across \(allTerminals.count, privacy: .public) terminals")

        for terminal in allTerminals {
            guard let server = serverByWorktree[terminal.worktreeID] else { continue }
            try? await tmux.resizeWindow(
                server: server,
                windowID: terminal.tmuxWindowID,
                cols: params.cols,
                rows: params.rows
            )
        }
        return .ok()
    }

    // MARK: - Notification Handler

    func handleNotify(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(NotifyParams.self, from: paramsData)

        guard let worktreeID = params.worktreeID else {
            return RPCResponse(error: "worktreeID is required for notifications")
        }

        let notification = try await db.notifications.create(
            worktreeID: worktreeID,
            type: params.type,
            message: params.message
        )

        subscriptions.broadcast(delta: .notificationReceived(NotificationDelta(
            notificationID: notification.id, worktreeID: notification.worktreeID,
            type: notification.type, message: notification.message
        )))

        // Signal the suspend/resume coordinator that Claude finished a response
        if params.type == .responseComplete {
            await suspendResumeCoordinator.responseCompleted(worktreeID: worktreeID)
        }

        return try RPCResponse(result: notification)
    }

    // MARK: - Notifications List

    func handleNotificationsList() async throws -> RPCResponse {
        let notifications = try await db.notifications.allUnreadByWorktree()
        return try RPCResponse(result: NotificationsListResult(notifications: notifications))
    }

    // MARK: - Notifications Mark Read

    func handleNotificationsMarkRead(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(NotificationsMarkReadParams.self, from: paramsData)
        try await db.notifications.markRead(worktreeID: params.worktreeID)
        return .ok()
    }

    // MARK: - Cleanup

    func handleCleanup() async throws -> RPCResponse {
        let repos = try await db.repos.list()
        var errors: [String] = []
        var worktreesReconciled = 0

        for repo in repos {
            // Prune stale worktree tracking entries
            do {
                try await git.worktreePrune(repoPath: repo.path)
            } catch {
                errors.append("Prune failed for \(repo.displayName): \(error)")
            }

            // Reconcile DB against actual git worktree list
            do {
                let beforeCount = try await db.worktrees.list(repoID: repo.id, status: .active).count
                try await lifecycle.reconcile(repoID: repo.id)
                let afterCount = try await db.worktrees.list(repoID: repo.id, status: .active).count
                let delta = abs(beforeCount - afterCount)
                worktreesReconciled += delta
            } catch {
                errors.append("Reconcile failed for \(repo.displayName): \(error)")
            }
        }

        let result = CleanupResult(
            reposProcessed: repos.count,
            worktreesReconciled: worktreesReconciled,
            errors: errors
        )
        return try RPCResponse(result: result)
    }

    // MARK: - Daemon Status

    func handleDaemonStatus() throws -> RPCResponse {
        let uptime = Date().timeIntervalSince(startTime)
        let status = DaemonStatusResult(
            version: TBDConstants.version,
            uptime: uptime,
            connectedClients: 0,  // Will be updated when socket server is implemented
            executablePath: Self.resolvedExecutablePath()
        )
        return try RPCResponse(result: status)
    }

    /// Resolve the daemon's own executable path to an absolute, standardized
    /// path. Falls back to nil if no usable argv[0] is available.
    private static func resolvedExecutablePath() -> String? {
        guard let argv0 = CommandLine.arguments.first, !argv0.isEmpty else { return nil }
        let url: URL
        if argv0.hasPrefix("/") {
            url = URL(fileURLWithPath: argv0)
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            url = URL(fileURLWithPath: argv0, relativeTo: URL(fileURLWithPath: cwd))
        }
        // Resolve symlinks so we return the real binary path — `cliPath()`
        // expects to find `TBDCLI` next to the actual TBDDaemon binary, not
        // next to a symlink that points at it.
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Resolve Path

    func handleResolvePath(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ResolvePathParams.self, from: paramsData)
        let path = (params.path as NSString).standardizingPath

        // Walk up from the given path and try to match against known repos/worktrees
        var currentPath = path

        while currentPath != "/" && currentPath != "" {
            // Check if this path matches a worktree
            if let worktree = try await db.worktrees.findByPath(path: currentPath) {
                let result = ResolvedPathResult(repoID: worktree.repoID, worktreeID: worktree.id)
                return try RPCResponse(result: result)
            }

            // Check if this path matches a repo
            if let repo = try await db.repos.findByPath(path: currentPath) {
                let result = ResolvedPathResult(repoID: repo.id, worktreeID: nil)
                return try RPCResponse(result: result)
            }

            // Move up one directory
            currentPath = (currentPath as NSString).deletingLastPathComponent
        }

        // No match found
        let result = ResolvedPathResult(repoID: nil, worktreeID: nil)
        return try RPCResponse(result: result)
    }
}
