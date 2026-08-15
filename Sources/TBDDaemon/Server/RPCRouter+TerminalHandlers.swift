import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "terminalHandlers")
private let perfTranscriptLog = Logger(subsystem: "com.tbd.daemon", category: "perf-transcript")

// MARK: - Transcript parse cache

private struct TranscriptParseCacheEntry {
    let mtime: Date
    let size: Int64
    let result: [TranscriptItem]
}

/// Caches the last `TranscriptParser.parse` result per session file path.
/// The fingerprint is the parent JSONL's mtime+size. Subagent files are
/// re-read on cache miss, so the cache is invalidated whenever the parent
/// gains a new tool_result line — which is the only signal we have at the
/// daemon level that subagent activity advanced.
actor TranscriptParseCache {
    static let shared = TranscriptParseCache()
    private var entries: [String: TranscriptParseCacheEntry] = [:]
    private var order: [String] = []  // most-recently-used at the end
    private let cap = 50

    func get(filePath: String) -> [TranscriptItem]? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return nil
        }
        guard let entry = entries[filePath],
              entry.mtime == mtime, entry.size == size else {
            return nil
        }
        // Touch — move to most-recently-used.
        if let idx = order.firstIndex(of: filePath) {
            order.remove(at: idx)
        }
        order.append(filePath)
        return entry.result
    }

    func put(filePath: String, result: [TranscriptItem]) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return
        }
        entries[filePath] = TranscriptParseCacheEntry(mtime: mtime, size: size, result: result)
        if let idx = order.firstIndex(of: filePath) {
            order.remove(at: idx)
        }
        order.append(filePath)
        while order.count > cap {
            let evict = order.removeFirst()
            entries.removeValue(forKey: evict)
        }
    }
}

// MARK: - The pane consultation's verdict

/// A pane consultation that came back "do not type here", with the outcome the
/// record gets and the message the caller sees.
///
/// One type for both typing paths — the send handler and the verifier's
/// retry — so a refusal cannot be classified two ways depending on which one
/// asked.
struct PaneSendRefusal: Sendable {
    let outcome: ActuationOutcome
    let message: String
}

extension RPCRouter {

    // MARK: - Terminal Handlers

    func handleTerminalCreate(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalCreateParams.self, from: paramsData)

        // Look up the worktree to get tmux server and path
        guard let worktree = try await db.worktrees.getLocal(id: params.worktreeID) else {
            return RPCResponse(error: "Worktree not found: \(params.worktreeID)")
        }

        // Never parent a new terminal to an archived worktree row — its tmux
        // state is torn down and nothing will ever show the tab. The promoted
        // scratch case gets a pointer to where the sessions actually went.
        // This early check gives a clear RPC error; the authoritative,
        // race-proof guard lives inside `db.terminals.create` (same write
        // transaction as the row insert), closing the window where a promote
        // archives the row between this check and the insert below.
        if worktree.status == .archived {
            if let promotedRepoID = worktree.promotedToRepoID {
                return RPCResponse(error: "This scratch space was promoted to a repo (\(promotedRepoID)). Its sessions moved to that repo's main worktree — create the terminal there instead.")
            }
            return RPCResponse(error: "Worktree is archived: \(worktree.displayName). Revive it before creating terminals.")
        }

        // Never spawn into a missing directory: tmux's `-c` silently falls
        // back to $HOME when the cwd doesn't exist, producing a terminal that
        // looks alive but runs in the wrong place (classic after a stale
        // worktree row, e.g. an un-migrated promoted scratch path). Fail loud.
        guard FileManager.default.fileExists(atPath: worktree.path) else {
            return RPCResponse(error: "Worktree directory missing on disk: \(worktree.path). Cannot create a terminal there.")
        }

        // Resolve Codex before creating any tmux state. A GUI-launched daemon
        // can have a minimal PATH, and a resolution failure must not leave an
        // orphan window or terminal row behind.
        let codexPreparation = params.type == .codex
            ? try CodexLaunchPreparation.prepare(
                executableResolver: codexExecutableResolver,
                homeEnsurer: codexHomeEnsurer)
            : nil

        // Resolve initial size: caller-supplied → TmuxManager defaults to avoid
        // tmux's 80x24 default producing un-reflowable hard-wrapped scrollback.
        let resolvedCols = params.cols ?? TmuxManager.defaultCols
        let resolvedRows = params.rows ?? TmuxManager.defaultRows

        // Pre-mint the terminal ID so we can inject it into the spawned env
        // as TBD_TERMINAL_ID. Claude's SessionStart hook (registered via the
        // TBD overlay file) reads this env var to route session events back
        // to the right terminal record. Minted here, ahead of any tmux call,
        // so the actuation row below can name the terminal it is about to
        // spawn.
        let plannedTerminalID = UUID()

        // Request row before the first mutating step. `profile` is deliberately
        // absent: it is resolved further down, after the tmux server exists, and
        // reordering that resolution would move which failures happen before the
        // server is created.
        let actuationID = try await beginActuation(
            .terminalCreate, actor: actor,
            target: .local(worktree: params.worktreeID, terminal: plannedTerminalID),
            prompt: params.prompt,
            agent: (params.type ?? .shell).rawValue)

        // Ensure tmux server exists before creating window
        do {
            _ = try await tmux.ensureServer(
                server: worktree.tmuxServer,
                session: "main",
                cwd: worktree.path,
                cols: resolvedCols,
                rows: resolvedRows
            )
        } catch {
            await finishActuation(actuationID, .transportFailed, error: "\(error)")
            throw error
        }
        await controlMode?.enableIfGated(serverName: worktree.tmuxServer)

        // Look up repo once for system prompt env vars and Claude session setup
        let repo: Repo?
        if let rid = worktree.repoID {
            repo = try await actuating(actuationID) { try await db.repos.get(id: rid) }
        } else {
            repo = nil
        }

        // Fetch config once for both the typed Claude env overrides and the
        // free-form env overrides (global < repo < profile). The profile scope
        // is folded in per-branch once the profile is resolved.
        let createConfig = try? await db.config.get()

        // Build env vars available in all TBD terminals
        var env = SystemPromptBuilder.promptLayers(
            repo: repo, worktree: worktree.worktree, scratchInstructions: createConfig?.scratchInstructions,
            scratchRenamePrompt: createConfig?.scratchRenamePrompt)
        env["TBD_WORKTREE_ID"] = params.worktreeID.uuidString
        env["TBD_TERMINAL_ID"] = plannedTerminalID.uuidString

        // Set COLORFGBG if provided (computed from terminal color scheme luminance).
        // This allows CLI tools (vim, less, fzf, etc.) to auto-adjust to the active scheme.
        if let colorFgBg = params.colorFgBg {
            env["COLORFGBG"] = colorFgBg
        }

        // Codex branch: minimal launch with TBD's profile plugin installed in
        // the user's global Codex home. No system prompt injection or token
        // resolution; Codex should keep using the user's normal auth/config.
        //
        // Build env independently — do NOT inherit the Claude-shaped
        // TBD_PROMPT_CONTEXT / TBD_PROMPT_RENAME / TBD_PROMPT_INSTRUCTIONS
        // vars from SystemPromptBuilder.promptLayers; those describe TBD as
        // a Claude-centric host and would be misleading noise inside a
        // Codex pane.
        if params.type == .codex {
            guard let codexPreparation else {
                await finishActuation(
                    actuationID, .refused(.notEligible),
                    error: "Codex launch preparation unexpectedly returned no result.")
                return RPCResponse(
                    error: "Codex launch preparation unexpectedly returned no result.")
            }
            var codexEnv: [String: String] = [:]
            codexEnv["TBD_WORKTREE_ID"] = params.worktreeID.uuidString
            codexEnv["TBD_TERMINAL_ID"] = plannedTerminalID.uuidString
            // Explicitly export the global Codex home. This is intentional —
            // the design's allowed "set the global path" option — not leftover
            // per-repo isolation: it pins deterministic behavior and lets the
            // TBD_TEST_CODEX_HOME test-isolation override flow through.
            codexEnv["CODEX_HOME"] = codexPreparation.codexHome.path
            // COLORFGBG isn't Claude-specific — Codex shells benefit from it too,
            // so include it at spawn time. (Live updates also reach Codex via
            // `tmux setenv -g COLORFGBG` fanned out by handleAppearanceUpdateColorFgBg.)
            if let colorFgBg = params.colorFgBg {
                codexEnv["COLORFGBG"] = colorFgBg
            }

            // Codex: the merged free-form overrides plus omz-update suppression
            // form the sensitive env. DISABLE_AUTO_UPDATE must go through `-e`
            // (process env before .zshrc) — the `env:` dict is inlined AFTER rc
            // files run, so oh-my-zsh's update prompt would still block the
            // agent. FORCED over user overrides (matching the claude path): an
            // agent tab runs a command and must never block on the interactive
            // update prompt. No profile is resolved for Codex, so that scope is nil.
            let codexEnvOverrides = EnvOverrideResolver.merge(
                global: createConfig?.envOverrides,
                repo: repo?.envOverrides,
                profile: nil
            ).merging(["DISABLE_AUTO_UPDATE": "true"]) { _, forced in forced }
            let terminal = try await actuating(actuationID) {
                let window = try await tmux.createWindow(
                    server: worktree.tmuxServer,
                    session: "main",
                    cwd: worktree.path,
                    shellCommand: CodexSpawnCommandBuilder.build(
                        initialPrompt: params.prompt,
                        executablePath: codexPreparation.executablePath),
                    env: codexEnv,
                    sensitiveEnv: codexEnvOverrides,
                    cols: resolvedCols,
                    rows: resolvedRows
                )

                return try await db.terminals.create(
                    id: plannedTerminalID,
                    worktreeID: params.worktreeID,
                    tmuxWindowID: window.windowID,
                    tmuxPaneID: window.paneID,
                    label: TerminalLabel.codex,
                    claudeSessionID: nil,
                    profileID: nil,
                    kind: .codex
                )
            }

            subscriptions.broadcast(delta: .terminalCreated(TerminalDelta(
                terminalID: terminal.id, worktreeID: terminal.worktreeID, label: terminal.label
            )))

            await finishActuation(actuationID, .dispatched)
            return try RPCResponse(result: terminal)
        }

        let isClaudeType = params.type == .claude || params.resumeSessionID != nil
        // Login sessions are always fresh Claude spawns pinned to a profile:
        // the whole point is capturing `/login` credentials into that
        // profile's isolated config dir.
        let isLoginSession = params.loginSession == true && params.resumeSessionID == nil
        let claudeSessionID: String?
        let label: String?

        // Resolve model profile (repo override → global default → none).
        // Failure here must NOT break terminal spawn — fall back to keychain login.
        var resolvedProfile: ResolvedModelProfile? = nil
        if isClaudeType {
            do {
                if let overrideID = params.overrideProfileID {
                    resolvedProfile = try await modelProfileResolver.loadByID(overrideID)
                } else {
                    resolvedProfile = try await modelProfileResolver.resolve(repoID: worktree.repoID)
                }
            } catch {
                logger.warning("model profile resolution failed; falling back to keychain login")
                resolvedProfile = nil
            }
        }

        // A login session without its profile is meaningless — spawning a
        // default-credential Claude here would look like it worked while the
        // `/login` lands in the wrong config dir. Fail loud so the app can
        // surface the error instead of leaving a ghost tab.
        if isLoginSession {
            guard isClaudeType else {
                let message = "Login sessions must be Claude terminals (type: claude)"
                await finishActuation(actuationID, .refused(.notEligible), error: message)
                return RPCResponse(error: message)
            }
            guard params.overrideProfileID != nil else {
                let message = "Login sessions require a profile (overrideProfileID)"
                await finishActuation(actuationID, .refused(.notEligible), error: message)
                return RPCResponse(error: message)
            }
            guard resolvedProfile != nil else {
                let message = "Profile not found or unreadable — cannot open a login session for it"
                await finishActuation(actuationID, .refused(.notEligible), error: message)
                return RPCResponse(error: message)
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
            appendSystemPrompt = SystemPromptBuilder.build(
                repo: repo, worktree: worktree.worktree, isResume: false,
                scratchInstructions: createConfig?.scratchInstructions,
                scratchRenamePrompt: createConfig?.scratchRenamePrompt)
            label = isLoginSession ? TerminalLabel.login : TerminalLabel.claudeCode
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

        let claudeEnvOverrides = createConfig?.envSettingOverrides ?? [:]
        let profileConfigDir = isClaudeType
            ? configDirManager.resolveConfigDir(for: resolvedProfile)
            : nil

        // Pre-accept Claude Code's folder-trust dialog: this worktree belongs to
        // a registered repo, so the trust answer is known by construction, and
        // the dialog blocks before SessionStart (a stall would be
        // machine-invisible). The seeder still declines for `foreignHead` rows.
        // Only the claude path can trigger it; best-effort (never throws), so
        // seeding on fresh and resume is safe. `createConfig` is a `try?` read —
        // falling back to `true` keeps the shipped default rather than silently
        // reinstating the stall.
        if isClaudeType {
            await ClaudeTrustSeeder.ensureTrusted(
                worktree: worktree.worktree,
                autoTrustNonScratch: createConfig?.autoTrustWorktrees ?? true,
                profileConfigDir: profileConfigDir)
        }

        // Pre-resume freshness: `claude --resume` only looks in the project
        // dir derived from the CURRENT cwd. If this session's transcript lives
        // elsewhere (worktree moved/promoted since it was written), mirror it
        // into the derived dir first (copy-if-newer; best-effort; detached so
        // the recursive copy never blocks this handler's executor). The stored
        // path, when a sibling terminal row owns this session, is authoritative.
        if let resumeID = params.resumeSessionID {
            let storedTranscriptPath = (try? await db.terminals.list(worktreeID: params.worktreeID))?
                .first(where: { $0.claudeSessionID == resumeID })?.transcriptPath
            await TranscriptProjectDirSync.ensureSessionResumableDetached(
                sessionID: resumeID,
                worktreePath: worktree.path,
                projectsRoot: claudeProjectsRoot(profileConfigDirPath: profileConfigDir),
                storedTranscriptPath: storedTranscriptPath
            )
        }

        let spawn = ClaudeSpawnCommandBuilder.build(
            resumeID: params.resumeSessionID,
            freshSessionID: freshSessionID,
            appendSystemPrompt: appendSystemPrompt,
            initialPrompt: params.prompt,
            profileSecret: resolvedProfile?.secret,
            profileKind: resolvedProfile?.kind,
            profileBaseURL: resolvedProfile?.baseURL,
            profileModel: resolvedProfile?.model,
            profileAwsRegion: resolvedProfile?.awsRegion,
            profileAwsProfile: resolvedProfile?.awsProfile,
            profileConfigDir: profileConfigDir,
            cmd: params.cmd,
            shellFallback: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
            settingsOverlayPath: isClaudeType
                ? ClaudeHookOverlay.resolveOverlayPath(
                    fallbackModels: resolvedProfile?.fallbackModels,
                    sessionKey: plannedTerminalID.uuidString,
                    // Repo fragment is file-backed config, read fresh at
                    // spawn time — applies on every spawn path, resume included.
                    repoSettingsJSON: ClaudeHookOverlay.repoSettingsFragment(repoID: repo?.id),
                    // Per-spawn fragment applies to FRESH spawns only; a
                    // resume must not reapply it. Hooks overlay still resolves
                    // for resumes — only extraSettingsJSON goes nil.
                    extraSettingsJSON: params.resumeSessionID == nil ? params.claudeSettingsOverlay : nil
                  )
                : nil,
            pluginDirPath: isClaudeType ? PluginDirWriter.pluginDirPath : nil,
            envSettingOverrides: claudeEnvOverrides,
            sessionName: worktree.displayName
        )

        // For Claude terminals, layer the builder's auth/routing env ON TOP of
        // the merged free-form overrides (global < repo < profile) so auth wins.
        // Shell/custom-cmd terminals are out of scope and get no overrides.
        let primarySensitiveEnv: [String: String]
        if isClaudeType {
            let mergedEnvOverrides = EnvOverrideResolver.merge(
                global: createConfig?.envOverrides,
                repo: repo?.envOverrides,
                profile: resolvedProfile?.envOverrides
            )
            primarySensitiveEnv = mergedEnvOverrides.merging(spawn.sensitiveEnv) { _, builder in builder }
        } else {
            primarySensitiveEnv = spawn.sensitiveEnv
        }
        let terminalKind: TerminalKind? = isClaudeType ? .claude : .shell
        let (window, terminal) = try await actuating(actuationID) {
            let window = try await tmux.createWindow(
                server: worktree.tmuxServer,
                session: "main",
                cwd: worktree.path,
                shellCommand: spawn.command,
                env: env,
                sensitiveEnv: primarySensitiveEnv,
                cols: resolvedCols,
                rows: resolvedRows
            )

            let terminal = try await db.terminals.create(
                id: plannedTerminalID,
                worktreeID: params.worktreeID,
                tmuxWindowID: window.windowID,
                tmuxPaneID: window.paneID,
                label: label,
                claudeSessionID: claudeSessionID,
                profileID: resolvedProfile?.profileID,
                kind: terminalKind
            )
            return (window, terminal)
        }

        subscriptions.broadcast(delta: .terminalCreated(TerminalDelta(
            terminalID: terminal.id, worktreeID: terminal.worktreeID, label: terminal.label
        )))

        if isLoginSession, let profile = resolvedProfile {
            await armLoginSession(
                terminalID: terminal.id,
                paneID: window.paneID,
                server: worktree.tmuxServer,
                profile: profile
            )
        }

        await finishActuation(actuationID, .dispatched)
        return try RPCResponse(result: terminal)
    }

    /// Post-spawn wiring for a profile login session:
    /// 1. starts the verified auto-`/login` pump — poll the pane until
    ///    Claude's TUI is interactive, type `/login` + Enter, then verify the
    ///    login dialog actually appeared (retrying, capped) so a send that
    ///    lands before the input loop is ready doesn't silently vanish;
    /// 2. starts the login-identity watcher so the Settings badge flips to
    ///    "Logged in as …" the moment the profile's isolated `.claude.json`
    ///    gains an `oauthAccount`.
    private func armLoginSession(
        terminalID: UUID,
        paneID: String,
        server: String,
        profile: ResolvedModelProfile
    ) async {
        let tmux = self.tmux
        await loginSessions.registerPendingAutoLogin(terminalID: terminalID)
        await loginSessions.startAutoLoginPump(
            terminalID: terminalID,
            paneText: {
                (try? await tmux.capturePaneOutput(server: server, paneID: paneID)) ?? ""
            },
            typeLogin: {
                do {
                    try await tmux.sendKeys(server: server, paneID: paneID, text: "/login")
                    try await tmux.sendKey(server: server, paneID: paneID, key: "Enter")
                } catch {
                    logger.warning("auto-login: send failed for terminal \(terminalID, privacy: .public): \(error, privacy: .public)")
                }
            }
        )

        let configDirManager = self.configDirManager
        let subscriptions = self.subscriptions
        let profileID = profile.profileID
        await loginSessions.watchLoginIdentity(
            profileID: profileID,
            interval: loginSessions.delays.identityPollInterval,
            timeout: loginSessions.delays.identityPollTimeout,
            identity: { configDirManager.loginIdentity(forProfileID: profileID) },
            onLogin: { subscriptions.broadcast(delta: .modelProfilesChanged) }
        )
    }

    func handleTerminalList(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalListParams.self, from: paramsData)
        let terminals = try await db.terminals.list(worktreeID: params.worktreeID)
        return try RPCResponse(result: terminals)
    }


    func handleTerminalDelete(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalDeleteParams.self, from: paramsData)

        // Closing an already-closed terminal is a no-op SUCCESS, not an error —
        // same contract as `terminal.wake`. Autonomous callers retry and race
        // each other; making the second one fail would push every caller into
        // string-matching this message to tell "already done" from "broken".
        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            return try RPCResponse(result: TerminalDeleteResult(closed: false, alreadyGone: true))
        }

        // Request row before the rails check, not after: the rails only read
        // state, and a refusal to close a busy session is itself something the
        // record should show. A close of an already-gone terminal returns above
        // without a row — nothing was acted on.
        let actuationID = try await beginActuation(
            .terminalDelete, actor: actor,
            target: .local(worktree: terminal.worktreeID, terminal: terminal.id))

        // Optional rails (CLI sets them; --force drops them; the app never
        // does). Refuse to kill an in-flight turn or a raised permission hand,
        // matching `isManuallyHibernatable`'s rails.
        //
        // Qualified on the window actually being ALIVE. `activityState` is
        // hook-fed and carries no timestamp, so a session that died mid-turn
        // (crash, OOM, killed pane) stays `.working` forever. An unqualified
        // rail would then refuse forever on exactly the wedged terminal a
        // caller most needs to close — turning the safety rail into a trap for
        // this command's primary cleanup use case. A dead-window row cannot be
        // mid-turn, so it stays closeable without --force.
        if params.respectActivityRails == true,
           terminal.activityState == .working || terminal.activityState == .waitingForUser {
            // Resolved inside the rails branch, not in the condition list, so
            // the lookup keeps its short-circuit (only reached when the rails
            // are on and the row looks busy) while a DB failure still confirms
            // the request row before it propagates.
            let railWorktree = try await actuating(actuationID) {
                try await db.worktrees.getLocal(id: terminal.worktreeID)
            }
            if let railWorktree,
               await tmux.windowExists(
                server: railWorktree.tmuxServer, windowID: terminal.tmuxWindowID) {
                let what = terminal.activityState == .working
                    ? "mid-turn"
                    : "waiting on a permission prompt"
                let message = "Terminal \(params.terminalID) is \(what) "
                    + "(activityState=\(terminal.activityState.rawValue)). "
                    + "Closing now would kill in-flight work. Pass --force to close anyway."
                await finishActuation(actuationID, .refused(.notEligible), error: message)
                return RPCResponse(
                    error: message,
                    code: RPCErrorCode.terminalBusy.rawValue
                )
            }
        }

        // Terminal close cancels any pending auto-resume (spec §Cancellation).
        if (try? await db.scheduledResumes.cancelPending(terminalID: terminal.id)) == true {
            await limitResumeScheduler?.wake()
        }

        // Capture the pane's scrollback just before the window dies so the
        // user can view it read-only later (Session History → Closed
        // Terminals). Strictly best-effort: any failure logs inside
        // captureOnClose and the close proceeds unchanged.
        let worktree = try await actuating(actuationID) {
            try await db.worktrees.getLocal(id: terminal.worktreeID)
        }
        // Set when the kill itself failed. The deletion proceeds regardless
        // (pre-existing contract — the row goes and the response is the same),
        // so the failure is invisible in the response and has to be carried out
        // separately, or the record would call a failed kill `dispatched`.
        var killWindowFailure: String?
        if let worktree {
            await db.terminalHistory.captureOnClose(terminal: terminal) {
                try await tmux.capturePaneScrollback(
                    server: worktree.tmuxServer, paneID: terminal.tmuxPaneID)
            }
            // Kill the tmux window
            do {
                try await tmux.killWindow(
                    server: worktree.tmuxServer, windowID: terminal.tmuxWindowID)
            } catch {
                killWindowFailure = "\(error)"
            }
        }

        // Delete from DB
        try await actuating(actuationID) {
            try await db.terminals.delete(id: params.terminalID)
            try await db.tabs.delete(tabID: params.terminalID)
        }
        await pendingQuestions.clear(terminalID: params.terminalID)
        await loginSessions.cancelPendingAutoLogin(terminalID: params.terminalID)

        // Reclaim the per-session fallbackModel overlay (keyed by terminal id),
        // if this terminal had one. No-op when the profile had no fallback.
        ClaudeHookOverlay.removePerSessionOverlay(sessionKey: params.terminalID.uuidString)

        subscriptions.broadcast(delta: .terminalRemoved(TerminalIDDelta(
            terminalID: terminal.id
        )))

        if let killWindowFailure {
            await finishActuation(actuationID, .transportFailed, error: killWindowFailure)
        } else {
            await finishActuation(actuationID, .dispatched)
        }
        return try RPCResponse(result: TerminalDeleteResult(
            closed: true,
            alreadyGone: false,
            claudeSessionID: terminal.claudeSessionID
        ))
    }

    /// Closed-terminal capture metadata for a worktree, newest first. Content
    /// is not sent over RPC — the app reads the file at
    /// `TBDConstants.terminalHistoryPath` directly.
    func handleTerminalHistoryList(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalHistoryListParams.self, from: paramsData)
        let entries = try await db.terminalHistory.list(worktreeID: params.worktreeID)
        return try RPCResponse(result: entries)
    }

    /// Revive a closed terminal from its history entry into a NEW terminal in
    /// the same (live) worktree. Claude entries with a session id resume that
    /// Claude session (no scrollback replay — Claude repaints its transcript);
    /// every other kind opens a fresh shell with the raw capture (colors
    /// intact) printed above the prompt. The history row is kept.
    func handleTerminalHistoryRevive(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalHistoryReviveParams.self, from: paramsData)

        guard let worktree = try await db.worktrees.getLocal(id: params.worktreeID) else {
            return RPCResponse(error: "Worktree not found: \(params.worktreeID)")
        }
        // A revived terminal must land in a live worktree — an archived row's
        // tmux state is gone and nothing would ever show the tab.
        if worktree.status == .archived {
            return RPCResponse(error: "Worktree is archived: \(worktree.displayName). Revive it before reviving terminals.")
        }
        guard FileManager.default.fileExists(atPath: worktree.path) else {
            return RPCResponse(error: "Worktree directory missing on disk: \(worktree.path). Cannot revive a terminal there.")
        }
        guard let entry = try await db.terminalHistory.list(worktreeID: params.worktreeID)
            .first(where: { $0.id == params.id }) else {
            return RPCResponse(error: "Closed-terminal history entry not found: \(params.id)")
        }

        let resolvedCols = params.cols ?? TmuxManager.defaultCols
        let resolvedRows = params.rows ?? TmuxManager.defaultRows
        let plannedTerminalID = UUID()
        let defaultShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        // Request row after the terminal ID is minted and before the first
        // tmux act, so it names the session it is about to bring back.
        let actuationID = try await beginActuation(
            .terminalHistoryRevive, actor: actor,
            target: .local(worktree: worktree.id, terminal: plannedTerminalID),
            agent: (entry.kind ?? .shell).rawValue)

        do {
            _ = try await tmux.ensureServer(
                server: worktree.tmuxServer, session: "main", cwd: worktree.path,
                cols: resolvedCols, rows: resolvedRows)
        } catch {
            await finishActuation(actuationID, .transportFailed, error: "\(error)")
            throw error
        }
        await controlMode?.enableIfGated(serverName: worktree.tmuxServer)

        // Claude-kind with a live session id → resume it. Mirrors the
        // archived-session restore spawn in WorktreeLifecycle+Create.
        if entry.kind == .claude, let sessionID = entry.claudeSessionID {
            let repo: Repo?
            if let rid = worktree.repoID {
                repo = try await actuating(actuationID) { try await db.repos.get(id: rid) }
            } else {
                repo = nil
            }
            let reviveConfig = try? await db.config.get()
            var resolvedProfile: ResolvedModelProfile? = nil
            do {
                resolvedProfile = try await modelProfileResolver.resolve(repoID: worktree.repoID)
            } catch {
                logger.warning("revive: model profile resolution failed; falling back to keychain login")
                resolvedProfile = nil
            }
            let profileConfigDir = configDirManager.resolveConfigDir(for: resolvedProfile)
            // Reviving a closed terminal respawns claude in the same worktree,
            // so the same trust argument applies — including the seeder's
            // `foreignHead` refusal, which is why the flag lives on the row
            // rather than in the create-time parameter list. `reviveConfig` is a
            // `try?` read; fall back to the shipped default.
            await ClaudeTrustSeeder.ensureTrusted(
                worktree: worktree.worktree,
                autoTrustNonScratch: reviveConfig?.autoTrustWorktrees ?? true,
                profileConfigDir: profileConfigDir)
            await TranscriptProjectDirSync.ensureSessionResumableDetached(
                sessionID: sessionID,
                worktreePath: worktree.path,
                projectsRoot: claudeProjectsRoot(profileConfigDirPath: profileConfigDir),
                storedTranscriptPath: nil
            )
            let claudeEnvOverrides = reviveConfig?.envSettingOverrides ?? [:]
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
                profileConfigDir: profileConfigDir,
                cmd: nil,
                shellFallback: defaultShell,
                settingsOverlayPath: ClaudeHookOverlay.resolveOverlayPath(
                    fallbackModels: resolvedProfile?.fallbackModels,
                    sessionKey: plannedTerminalID.uuidString,
                    repoSettingsJSON: ClaudeHookOverlay.repoSettingsFragment(repoID: repo?.id)
                ),
                pluginDirPath: PluginDirWriter.pluginDirPath,
                envSettingOverrides: claudeEnvOverrides,
                sessionName: worktree.displayName
            )
            let env: [String: String] = [
                "TBD_WORKTREE_ID": worktree.id.uuidString,
                "TBD_TERMINAL_ID": plannedTerminalID.uuidString,
            ]
            let mergedEnvOverrides = EnvOverrideResolver.merge(
                global: reviveConfig?.envOverrides,
                repo: repo?.envOverrides,
                profile: resolvedProfile?.envOverrides
            )
            let terminal = try await actuating(actuationID) {
                try await spawnRevivedTerminal(
                    worktree: worktree.worktree,
                    plannedTerminalID: plannedTerminalID,
                    spawnCommand: spawn.command,
                    env: env,
                    sensitiveEnv: mergedEnvOverrides.merging(spawn.sensitiveEnv) { _, builder in builder },
                    label: TerminalLabel.claudeCode,
                    kind: .claude,
                    claudeSessionID: sessionID,
                    profileID: resolvedProfile?.profileID,
                    cols: resolvedCols,
                    rows: resolvedRows
                )
            }
            logger.info("revive: resumed claude session \(sessionID, privacy: .public) as terminal \(terminal.id, privacy: .public) in worktree \(worktree.id, privacy: .public)")
            await finishActuation(actuationID, .dispatched)
            return try RPCResponse(result: terminal)
        }

        // Shell / codex / claude-with-nil-session → fresh shell with the
        // capture visible above the prompt (the raw file keeps escapes, so
        // `cat` renders its colors). Skip the `cat` if the file is gone.
        let capturePath = db.terminalHistory.contentPath(
            worktreeID: worktree.id, terminalID: entry.id)
        let haveCapture = FileManager.default.fileExists(atPath: capturePath)
        let command = Self.reviveShellCommand(
            capturePath: haveCapture ? capturePath : nil,
            closedAt: entry.closedAt,
            shell: defaultShell
        )
        let env: [String: String] = [
            "TBD_WORKTREE_ID": worktree.id.uuidString,
            "TBD_TERMINAL_ID": plannedTerminalID.uuidString,
        ]
        let terminal = try await actuating(actuationID) {
            try await spawnRevivedTerminal(
                worktree: worktree.worktree,
                plannedTerminalID: plannedTerminalID,
                spawnCommand: command,
                env: env,
                sensitiveEnv: [:],
                label: nil,
                kind: .shell,
                claudeSessionID: nil,
                profileID: nil,
                cols: resolvedCols,
                rows: resolvedRows
            )
        }
        logger.info("revive: opened shell terminal \(terminal.id, privacy: .public) from history entry \(entry.id, privacy: .public) (capture present: \(haveCapture, privacy: .public))")
        await finishActuation(actuationID, .dispatched)
        return try RPCResponse(result: terminal)
    }

    /// Shared plumbing for spawning an ADDITIONAL terminal into a live worktree
    /// during revive: create the window, insert the row, append it to the
    /// persisted tab order as the new active tab, and broadcast the same
    /// `.terminalCreated` delta the normal create path emits.
    private func spawnRevivedTerminal(
        worktree: Worktree,
        plannedTerminalID: UUID,
        spawnCommand: String,
        env: [String: String],
        sensitiveEnv: [String: String],
        label: String?,
        kind: TerminalKind,
        claudeSessionID: String?,
        profileID: UUID?,
        cols: Int,
        rows: Int
    ) async throws -> Terminal {
        let window = try await tmux.createWindow(
            server: worktree.tmuxServer,
            session: "main",
            cwd: worktree.localPath,
            shellCommand: spawnCommand,
            env: env,
            sensitiveEnv: sensitiveEnv,
            cols: cols,
            rows: rows
        )
        let terminal = try await db.terminals.create(
            id: plannedTerminalID,
            worktreeID: worktree.id,
            tmuxWindowID: window.windowID,
            tmuxPaneID: window.paneID,
            label: label,
            claudeSessionID: claudeSessionID,
            profileID: profileID,
            kind: kind
        )
        var order = try await db.worktrees.getTabOrder(worktreeID: worktree.id)
        if !order.contains(terminal.id) { order.append(terminal.id) }
        try await db.worktrees.setTabOrder(worktreeID: worktree.id, tabIDs: order)
        try await db.worktrees.setActiveTabID(worktreeID: worktree.id, tabID: terminal.id)
        subscriptions.broadcast(delta: .terminalCreated(TerminalDelta(
            terminalID: terminal.id, worktreeID: terminal.worktreeID, label: terminal.label
        )))
        return terminal
    }

    /// Build the fresh-shell revive command: a dimmed divider banner, an
    /// optional `cat` of the raw capture file (escapes intact → colors render),
    /// then `exec <shell>`. Single-quote escaping matches `preSessionCommand` /
    /// `shellWrapped`, so a capture path containing a single quote is safe.
    static func reviveShellCommand(capturePath: String?, closedAt: Date, shell: String) -> String {
        func quoted(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let stamp = Self.reviveBannerDateFormatter.string(from: closedAt)
        // Dim (SGR 2) divider; `\033`/`\n` interpreted by printf's format string.
        var command = "printf \(quoted("\\033[2m── restored from close on %s ──\\033[0m\\n")) \(quoted(stamp)); "
        if let capturePath {
            command += "/bin/cat \(quoted(capturePath)); "
        }
        command += "exec \(shell)"
        return command
    }

    private static let reviveBannerDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    func handleTerminalSetPin(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalSetPinParams.self, from: paramsData)
        let pinnedAt: Date? = params.pinned ? Date() : nil
        try await db.terminals.setPin(id: params.terminalID, pinned: params.pinned, at: pinnedAt ?? Date())
        subscriptions.broadcast(delta: .terminalPinChanged(TerminalPinDelta(
            terminalID: params.terminalID, pinnedAt: pinnedAt
        )))
        return .ok()
    }

    func handleTerminalRecreateWindow(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalRecreateWindowParams.self, from: paramsData)

        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            return RPCResponse(error: "Terminal not found: \(params.terminalID)")
        }

        guard let worktree = try await db.worktrees.getLocal(id: terminal.worktreeID) else {
            return RPCResponse(error: "Worktree not found for terminal: \(params.terminalID)")
        }

        // A Claude-resumable terminal whose window died must NOT be recreated as a
        // plain shell — that silently turns the tab into a shell and discards the
        // session identity (claudeSessionID/transcriptPath), so TBD can no longer
        // Resume and `/resume` finds nothing. Mirror reconcile(): park it as
        // suspended, preserving identity, so the app renders the suspended (moon)
        // state and offers Resume. Resume rebuilds a fresh window from the session
        // ID on demand, so this is non-destructive even if the window were somehow
        // still alive.
        if terminal.isClaudeResumable, let sessionID = terminal.claudeSessionID {
            // Stale-caller gate: if the row's CURRENT window is actually
            // alive, the caller acted on stale state — e.g. the app's
            // dead-window path racing a wake that just RECREATED the window
            // and updated the row's ids. Killing it here would tear down the
            // freshly-spawned claude and re-park the row (wake flap). Leave
            // the row untouched.
            if await tmux.windowExists(server: worktree.tmuxServer, windowID: terminal.tmuxWindowID) {
                logger.info("recreateWindow: window \(terminal.tmuxWindowID, privacy: .public) for claude terminal \(terminal.id, privacy: .public) is alive — ignoring stale recreate request")
                return try RPCResponse(result: terminal)
            }
            // This branch actuates too, and differently: it kills a window the
            // check above read as gone — a read that can be stale — and parks
            // the session. That is the same act reconcile's recovery park
            // performs, so it carries kind `hibernate` through this surface's
            // own door (`ActuationBranch.recreateWindowRepark`). The row goes in
            // ahead of the kill, fail-closed: an unrecordable park refuses the
            // RPC with the window and the row untouched.
            let reparkID = try await beginActuation(
                .recreateWindowRepark, actor: actor,
                target: .local(worktree: worktree.id, terminal: terminal.id))

            // Clean up any lingering (almost always already-dead) window to avoid orphans.
            try? await tmux.killWindow(server: worktree.tmuxServer, windowID: terminal.tmuxWindowID)
            let parked = try await actuating(reparkID) { () -> Terminal? in
                // Authoritative `hibernatedAt` column so the unified `wake()` can resume it.
                try await db.terminals.setHibernated(id: terminal.id, sessionID: sessionID)
                // Drop any stale pending-question entry — the window the question
                // belonged to is gone. Mirrors reconcile()/handleTerminalDelete.
                await pendingQuestions.clear(terminalID: terminal.id)
                return try await db.terminals.get(id: params.terminalID)
            }
            guard let updated = parked else {
                await finishActuation(
                    reparkID, .refused(.notFound), error: "Terminal not found after suspend")
                return RPCResponse(error: "Terminal not found after suspend")
            }
            await finishActuation(reparkID, .dispatched)
            logger.info("recreateWindow: parked claude terminal \(terminal.id, privacy: .public) as suspended — window \(terminal.tmuxWindowID, privacy: .public) gone, session \(sessionID, privacy: .public) preserved")
            return try RPCResponse(result: updated)
        }

        // Never respawn into a missing directory — tmux's `-c` silently falls
        // back to $HOME, leaving a live-looking pane in the wrong place. (The
        // park branch above is fine: it doesn't spawn anything.) Fail loud.
        guard FileManager.default.fileExists(atPath: worktree.path) else {
            return RPCResponse(error: "Worktree directory missing on disk: \(worktree.path). Cannot recreate the terminal window.")
        }

        // Resolve and prepare Codex before killing a recreatable pane. A bad
        // executable override must leave the existing terminal untouched.
        let codexPreparation: CodexLaunchPreparation?
        if terminal.kind == .codex || terminal.label == TerminalLabel.codex {
            codexPreparation = try CodexLaunchPreparation.prepare(
                executableResolver: codexExecutableResolver,
                homeEnsurer: codexHomeEnsurer)
        } else {
            codexPreparation = nil
        }

        // The respawning branch's own row, ahead of its first kill. The re-park
        // branch above wrote its own before returning — it is an actuation in
        // its own right, not a DB-only edit.
        let actuationID = try await beginActuation(
            .terminalRecreateWindow, actor: actor,
            target: .local(worktree: worktree.id, terminal: terminal.id),
            agent: (terminal.kind ?? .shell).rawValue)

        // Kill the old window if it still exists (avoids orphans)
        try? await tmux.killWindow(server: worktree.tmuxServer, windowID: terminal.tmuxWindowID)

        let resolvedCols = params.cols ?? TmuxManager.defaultCols
        let resolvedRows = params.rows ?? TmuxManager.defaultRows

        // Ensure tmux server exists
        try await actuating(actuationID) {
            _ = try await tmux.ensureServer(
                server: worktree.tmuxServer,
                session: "main",
                cwd: worktree.path,
                cols: resolvedCols,
                rows: resolvedRows
            )
        }
        await controlMode?.enableIfGated(serverName: worktree.tmuxServer)

        // Branch on terminal kind: codex stays codex; shell/claude become shell
        if terminal.kind == .codex || terminal.label == TerminalLabel.codex {
            // Recreate as codex — preserve identity
            guard let codexPreparation else {
                let message = "Codex launch preparation was unavailable"
                await finishActuation(actuationID, .refused(.notEligible), error: message)
                return RPCResponse(error: message)
            }
            var codexEnv: [String: String] = [:]
            codexEnv["TBD_WORKTREE_ID"] = worktree.id.uuidString
            codexEnv["TBD_TERMINAL_ID"] = terminal.id.uuidString
            // Explicitly export the global Codex home. This is intentional —
            // the design's allowed "set the global path" option — not leftover
            // per-repo isolation: it pins deterministic behavior and lets the
            // TBD_TEST_CODEX_HOME test-isolation override flow through.
            codexEnv["CODEX_HOME"] = codexPreparation.codexHome.path

            // Codex: re-apply the merged free-form overrides (global < repo) so a
            // recreated Codex pane keeps them, plus omz-update suppression via
            // `-e` (must be in the process env before .zshrc; FORCED over user
            // overrides — agent tabs must never block on the interactive update
            // prompt). No profile is resolved here, so that scope is nil.
            let recreateConfig = try? await db.config.get()
            let recreateRepo: Repo?
            if let rid = worktree.repoID {
                recreateRepo = try? await db.repos.get(id: rid)
            } else {
                recreateRepo = nil
            }
            let codexEnvOverrides = EnvOverrideResolver.merge(
                global: recreateConfig?.envOverrides,
                repo: recreateRepo?.envOverrides,
                profile: nil
            ).merging(["DISABLE_AUTO_UPDATE": "true"]) { _, forced in forced }
            let updatedTerminal = try await actuating(actuationID) {
                let window = try await tmux.createWindow(
                    server: worktree.tmuxServer,
                    session: "main",
                    cwd: worktree.path,
                    shellCommand: CodexSpawnCommandBuilder.command(
                        executablePath: codexPreparation.executablePath),
                    env: codexEnv,
                    sensitiveEnv: codexEnvOverrides,
                    cols: resolvedCols,
                    rows: resolvedRows
                )

                // Update tmux IDs but DO NOT call clearRecreated — that nukes the label and kind
                try await db.terminals.updateTmuxIDs(
                    id: params.terminalID,
                    windowID: window.windowID,
                    paneID: window.paneID
                )
                // TBD just recreated the window, so nothing has yet been
                // observed about what runs in it: `.derived` from our own act.
                //
                // `observedAt` from the router's date seam, never the store's
                // default `Date()`. This stamp is *compared*, not just stored:
                // `SessionStateResolver`'s rung 4 orders it against the
                // awaiting-input stamp to decide which observation is newer, so
                // a stamp minted inside the store is one a test cannot pin and
                // therefore a decision a test cannot pin either.
                try await db.terminals.setActivityState(
                    id: params.terminalID, activityState: .unknown, source: .derived,
                    observedAt: now())
                return try await db.terminals.get(id: params.terminalID)
            }

            // Return updated terminal
            guard let updated = updatedTerminal else {
                await finishActuation(
                    actuationID, .refused(.notFound), error: "Terminal not found after update")
                return RPCResponse(error: "Terminal not found after update")
            }

            await finishActuation(actuationID, .dispatched)
            return try RPCResponse(result: updated)
        } else {
            // Recreate as shell (claude or shell terminal becomes a plain shell)
            // Defensively set TBD_WORKTREE_ID even though the recreated pane runs a
            // plain shell — the user may run `tbd` CLI commands or launch `claude`
            // themselves from that shell, and those tools resolve the worktree from
            // the env. Without this set, the pane would inherit whatever TBD_WORKTREE_ID
            // got baked into the tmux server's global env, leaking another worktree's
            // identity into this one.
            //
            // TBD_TERMINAL_ID is set for the same reason, plus one more: it is
            // what `createWindow` stamps onto the new pane as
            // `@tbd_terminal_id`, and an unstamped pane is one `terminal.send`
            // can never verify (absence is not disagreement, so it proceeds
            // unchecked). Omitting it here would leave this branch — the only
            // spawn path that ever did — minting fresh panes that opt out of
            // the stale-coordinate check for the rest of their life.
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let env: [String: String] = [
                "TBD_WORKTREE_ID": worktree.id.uuidString,
                "TBD_TERMINAL_ID": terminal.id.uuidString,
            ]
            let updatedTerminal = try await actuating(actuationID) {
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
                return try await db.terminals.get(id: params.terminalID)
            }

            // Return updated terminal
            guard let updated = updatedTerminal else {
                await finishActuation(
                    actuationID, .refused(.notFound), error: "Terminal not found after update")
                return RPCResponse(error: "Terminal not found after update")
            }

            await finishActuation(actuationID, .dispatched)
            return try RPCResponse(result: updated)
        }
    }

    func handleTerminalOutput(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalOutputParams.self, from: paramsData)

        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            return RPCResponse(error: "Terminal not found: \(params.terminalID)")
        }

        guard let worktree = try await db.worktrees.getLocal(id: terminal.worktreeID) else {
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

        guard let worktree = try await db.worktrees.getLocal(id: terminal.worktreeID) else {
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

    /// Ensure the session transcript at `source` is reachable under the
    /// DESTINATION config dir's `projects/` tree, so a `claude --resume <id>`
    /// spawned with `CLAUDE_CONFIG_DIR=<destConfigDir>` can find it.
    ///
    /// `claude` resolves resumable conversations at
    /// `<CLAUDE_CONFIG_DIR>/projects/<cwd-slug>/<sessionID>.jsonl`. Ambient
    /// sessions write their transcript under the ambient config dir's
    /// `projects/`, while TBD profile config dirs symlink their `projects/`
    /// slot from the host claude dir. So an ambient→profile swap resumes under
    /// the profile (looking in the host `projects/`) while the transcript sits
    /// in the ambient config dir's `projects/` — "no conversation found".
    ///
    /// This copies (never moves — the source session may still be live) the
    /// transcript into the destination `projects/<same-parent-dir-name>/<file>`,
    /// preserving the cwd-slug layout by reusing the SOURCE file's parent-dir
    /// name rather than recomputing the slug. Writing THROUGH the destination
    /// config dir naturally follows the `projects/` symlink when one exists.
    ///
    /// Best-effort and non-throwing: any failure is logged and the swap proceeds
    /// (the fork simply starts fresh). No-ops when the destination file already
    /// exists or resolves (via realpath) to the same file as the source — the
    /// profile→profile case where both dirs share a symlink target.
    static func ensureTranscriptReachable(from source: URL, inConfigDir destConfigDir: URL) {
        let fm = FileManager.default

        guard fm.fileExists(atPath: source.path) else {
            logger.warning("swap transcript carry: source \(source.path, privacy: .public) missing on disk — fork will start fresh")
            return
        }

        // Preserve the source's cwd-slug layout: <projects>/<slug>/<file>.
        // The slug is the source file's PARENT directory name — reuse it
        // verbatim rather than recomputing from the worktree path, so a
        // `/clear`/`/compact`-relocated transcript still lands in the right place.
        let slug = source.deletingLastPathComponent().lastPathComponent
        let destProjectsDir = destConfigDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
        let dest = destProjectsDir.appendingPathComponent(source.lastPathComponent)

        // Same realpath → source and destination resolve to the same file
        // (profile→profile swaps sharing a symlinked `projects/` target, or a
        // no-op ambient→ambient). Nothing to copy.
        if fm.fileExists(atPath: dest.path) {
            let srcReal = source.resolvingSymlinksInPath().standardizedFileURL.path
            let dstReal = dest.resolvingSymlinksInPath().standardizedFileURL.path
            if srcReal == dstReal {
                logger.debug("swap transcript carry: destination already resolves to source — no copy")
            } else {
                logger.debug("swap transcript carry: destination \(dest.path, privacy: .public) already present — skipping")
            }
            return
        }

        do {
            try fm.createDirectory(at: destProjectsDir, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: dest)
            logger.info("swap transcript carry: copied session transcript into \(destProjectsDir.path, privacy: .public) so resume finds the conversation")
        } catch {
            logger.warning("swap transcript carry: copy failed (\(error.localizedDescription, privacy: .public)) — fork will start fresh")
        }
    }

    /// Resolve the on-disk source transcript for a swap: prefer the terminal
    /// row's `transcriptPath` (authoritative live-session jsonl); if that's
    /// nil/missing, fall back to locating `<sessionID>.jsonl` under the SOURCE
    /// config dir's `projects/` tree for `worktreePath`. Returns nil when
    /// neither is found (the fork will start fresh).
    static func resolveSwapSourceTranscript(
        transcriptPath: String?,
        sessionID: String,
        worktreePath: String,
        sourceConfigDir: URL
    ) -> URL? {
        let fm = FileManager.default
        if let p = transcriptPath, !p.isEmpty, fm.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        // Fall back to the source config dir's projects/ tree. Resolve the
        // cwd-slug dir for this worktree, then look for <sessionID>.jsonl.
        let projectsBase = sourceConfigDir.appendingPathComponent("projects", isDirectory: true)
        guard let projectDir = ClaudeProjectDirectory.resolve(
            worktreePath: worktreePath,
            projectsBase: projectsBase
        ) else {
            return nil
        }
        let candidate = projectDir.appendingPathComponent("\(sessionID).jsonl")
        return fm.fileExists(atPath: candidate.path) ? candidate : nil
    }

    func handleTerminalSwapProfile(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalSwapProfileParams.self, from: paramsData)

        guard let oldTerminal = try await db.terminals.get(id: params.terminalID) else {
            return RPCResponse(error: "Terminal not found: \(params.terminalID)")
        }
        guard let sessionID = oldTerminal.claudeSessionID else {
            return RPCResponse(error: "Terminal \(params.terminalID) is not a Claude terminal")
        }
        guard let worktree = try await db.worktrees.getLocal(id: oldTerminal.worktreeID) else {
            return RPCResponse(error: "Worktree not found for terminal: \(params.terminalID)")
        }

        // Resolve the requested profile (nil = no override; keychain login).
        // We do NOT touch the old terminal — both tabs coexist after the swap.
        let resolved: ResolvedModelProfile?
        if let newID = params.newProfileID {
            do {
                resolved = try await modelProfileResolver.loadByID(newID)
            } catch {
                return RPCResponse(error: "Failed to load profile")
            }
            if resolved == nil {
                return RPCResponse(error: "Profile not found or unreadable")
            }
        } else {
            resolved = nil
        }

        // COLD SWAP: the target session is PARKED (hibernated or legacy
        // suspended). Rebalancing a parked session onto a different account must
        // NOT wake it — the whole point is to re-home ~dozens of parked sessions
        // without re-inflating the memory hibernation just reclaimed. So we do
        // everything EXCEPT any interrupt / respawn / spawn:
        //   1. Carry the session transcript into the DESTINATION profile's config
        //      dir (best-effort) so the LATER wake's `claude --resume` finds the
        //      conversation under the new CLAUDE_CONFIG_DIR. Blank sessions have
        //      no transcript to carry — wake will just start fresh.
        //   2. Update the row's profile_id (nil = ambient).
        //   3. Broadcast the profile delta so the account chip updates.
        // We leave hibernatedAt / suspendedAt / suspendedSnapshot untouched — the
        // parked state and its backdrop survive. Wake needs NO change: it already
        // loads the row's profile via loadByID and resolves that profile's config
        // dir, so a wake after this resumes under the new account automatically.
        if oldTerminal.isParked {
            let blank = ClaudeSessionScanner.isSessionBlank(
                sessionID: sessionID,
                worktreePath: worktree.path,
                transcriptFilePath: oldTerminal.transcriptPath
            )
            if !blank {
                let sourceConfigDir: URL
                if let oldProfileID = oldTerminal.profileID {
                    sourceConfigDir = configDirManager.configDirectory(forProfileID: oldProfileID)
                } else {
                    sourceConfigDir = configDirManager.ambientConfigDirectory
                }
                let destConfigDir: URL
                if let newProfileID = resolved?.profileID {
                    destConfigDir = configDirManager.configDirectory(forProfileID: newProfileID)
                } else {
                    destConfigDir = configDirManager.ambientConfigDirectory
                }
                if let sourceTranscript = Self.resolveSwapSourceTranscript(
                    transcriptPath: oldTerminal.transcriptPath,
                    sessionID: sessionID,
                    worktreePath: worktree.path,
                    sourceConfigDir: sourceConfigDir
                ) {
                    Self.ensureTranscriptReachable(from: sourceTranscript, inConfigDir: destConfigDir)
                } else {
                    logger.warning("cold swap: no source transcript for parked session \(sessionID, privacy: .public) — wake will start fresh")
                }
            }

            let destProfileID: UUID? = resolved?.profileID
            try await db.terminals.setProfileID(id: oldTerminal.id, profileID: destProfileID)
            subscriptions.broadcast(delta: .terminalProfileChanged(TerminalProfileDelta(
                terminalID: oldTerminal.id,
                worktreeID: worktree.id,
                newProfileID: destProfileID
            )))
            logger.info("cold swap: re-homed parked terminal \(oldTerminal.id, privacy: .public) to profile \(destProfileID?.uuidString ?? "ambient", privacy: .public) — not woken")

            guard let updated = try await db.terminals.get(id: oldTerminal.id) else {
                return RPCResponse(error: "Terminal vanished after cold swap")
            }
            return try RPCResponse(result: updated)
        }

        // Two reshaping modes (see `TerminalSwapMode`):
        //   .inPlace (default) — SEAMLESS "Switch account": interrupt the
        //     pane's Claude, respawn `claude --resume <id>` under the new
        //     profile IN THE SAME window, and update the existing terminal row.
        //     One tab, no new row.
        //   .fork — explicit "Fork session": spawn a NEW window + terminal row,
        //     leaving the source session untouched (the old behavior).
        //
        // In both modes, if the existing session has conversation content we
        // `claude --resume` it. `--resume` REUSES the original session ID;
        // `.fork` mode additionally passes `--fork-session` so the fork gets a
        // genuinely new ID (the source session stays live — same-ID resume
        // would have both processes writing the same session JSONL), and the
        // recapture below picks up that new ID. `.inPlace` keeps the same ID:
        // the original process is killed, so same-ID resume is correct. If the
        // session is blank, resuming would produce "no conversation found",
        // so we spawn a brand-new session instead.
        let mode = params.resolvedMode
        let repo: Repo?
        if let rid = worktree.repoID {
            repo = try await db.repos.get(id: rid)
        } else {
            repo = nil
        }
        // In-place respawn keeps the EXISTING terminal id so its `TBD_TERMINAL_ID`
        // (and thus SessionStart-hook routing) stays stable; fork uses a fresh id.
        let plannedTerminalID = mode == .inPlace ? oldTerminal.id : UUID()
        // The desk role of the row this spawn will actually land on. An in-place
        // swap keeps the row, and nothing in this handler touches
        // `watch_desk_role`, so a resolve without the role would leave a row that
        // still claims to be a desk running with no statusline tee — and, because
        // a roleless resolve deletes the session's capture, with no denominator
        // either. A fork creates a fresh row that is branded no desk (see
        // `forkSwapNewTab`), so it must resolve without one or the overlay and
        // the row would disagree in the other direction.
        let swapDeskRole: WatchDeskRole? = mode == .inPlace ? oldTerminal.watchDeskRole : nil
        let swapConfig = try? await db.config.get()
        var env = SystemPromptBuilder.promptLayers(
            repo: repo, worktree: worktree.worktree, scratchInstructions: swapConfig?.scratchInstructions,
            scratchRenamePrompt: swapConfig?.scratchRenamePrompt)
        env["TBD_WORKTREE_ID"] = worktree.id.uuidString
        env["TBD_TERMINAL_ID"] = plannedTerminalID.uuidString

        let blank = ClaudeSessionScanner.isSessionBlank(
            sessionID: sessionID,
            worktreePath: worktree.path,
            transcriptFilePath: oldTerminal.transcriptPath
        )
        let plan = Self.planTerminalSwap(oldSessionID: sessionID, isBlank: blank)

        // One row for the whole swap, on the two branches that actually reshape
        // a live session. It sits here, as soon as the plan names what will be
        // acted on, because the very next step already mutates state outside the
        // daemon: the resume path copies the session transcript into the
        // destination profile's config dir. The interrupt the in-place branch
        // sends later is a sub-step of this one actuation, not a send of its
        // own — and the cold (parked) swap returned above without a row, because
        // re-homing a parked row touches no process. `.fork` names the new
        // terminal it is about to spawn; `.inPlace` names the one it respawns.
        let actuationID = try await beginActuation(
            .terminalSwapProfile, actor: actor,
            target: .local(
                worktree: worktree.id,
                terminal: mode == .fork ? plannedTerminalID : oldTerminal.id),
            agent: TerminalKind.claude.rawValue,
            profile: resolved?.profileID.uuidString)

        // Carry the session transcript into the DESTINATION config dir so the
        // forked `claude --resume <id>` finds the conversation. Only matters on
        // the resume path — a fresh spawn has no prior transcript to carry.
        // Best-effort: never blocks the swap.
        if case .resume = plan {
            // Source config dir: where the OLD session's transcript lives — the
            // old terminal's profile config dir, or the ambient (host) config
            // dir for an ambient session (profileID == nil).
            let sourceConfigDir: URL
            if let oldProfileID = oldTerminal.profileID {
                sourceConfigDir = configDirManager.configDirectory(forProfileID: oldProfileID)
            } else {
                sourceConfigDir = configDirManager.ambientConfigDirectory
            }
            // Destination config dir: the new profile's config dir, or the
            // ambient (host) config dir when swapping to ambient (nil profile).
            let destConfigDir: URL
            if let newProfileID = resolved?.profileID {
                destConfigDir = configDirManager.configDirectory(forProfileID: newProfileID)
            } else {
                destConfigDir = configDirManager.ambientConfigDirectory
            }

            if let sourceTranscript = Self.resolveSwapSourceTranscript(
                transcriptPath: oldTerminal.transcriptPath,
                sessionID: sessionID,
                worktreePath: worktree.path,
                sourceConfigDir: sourceConfigDir
            ) {
                Self.ensureTranscriptReachable(from: sourceTranscript, inConfigDir: destConfigDir)
            } else {
                logger.warning("swap transcript carry: no source transcript found for session \(sessionID, privacy: .public) — fork will start fresh")
            }

            // ensureTranscriptReachable preserves the transcript's ORIGINAL
            // cwd slug. If the worktree's path changed since the transcript
            // was written (scratch promotion), the resumed claude — cwd-scoped
            // — looks in the dir derived from the CURRENT path instead. Make
            // sure the session is fresh there too (copy-if-newer, best-effort,
            // detached off this handler's executor).
            await TranscriptProjectDirSync.ensureSessionResumableDetached(
                sessionID: sessionID,
                worktreePath: worktree.path,
                projectsRoot: destConfigDir.appendingPathComponent("projects", isDirectory: true),
                storedTranscriptPath: oldTerminal.transcriptPath
            )
        }

        let claudeEnvOverrides = swapConfig?.envSettingOverrides ?? [:]
        // Free-form env overrides for the swapped-in Claude pane (global < repo <
        // new profile), layered under the builder's auth/routing env below.
        let mergedEnvOverrides = EnvOverrideResolver.merge(
            global: swapConfig?.envOverrides,
            repo: repo?.envOverrides,
            profile: resolved?.envOverrides
        )
        // Pre-accept the folder-trust dialog before either swap spawn (resume
        // or fresh) — a swap onto a new profile's isolated config dir has never
        // seen this path and would otherwise re-prompt. Both build calls below
        // resolve the same `resolveConfigDir(for: resolved)`; seed it once here.
        // Claude-only handler. `swapConfig` is a `try?` read; fall back to the
        // shipped default.
        await ClaudeTrustSeeder.ensureTrusted(
            worktree: worktree.worktree,
            autoTrustNonScratch: swapConfig?.autoTrustWorktrees ?? true,
            profileConfigDir: configDirManager.resolveConfigDir(for: resolved))

        let spawn: ClaudeSpawnCommandBuilder.Result
        let storedSessionID: String
        let scheduleRecapture: Bool
        switch plan {
        case .resume(let resumeID):
            logger.debug("swap: resuming session \(resumeID, privacy: .public)")
            spawn = ClaudeSpawnCommandBuilder.build(
                resumeID: resumeID,
                forkSession: mode == .fork,
                freshSessionID: nil,
                appendSystemPrompt: nil,
                initialPrompt: nil,
                profileSecret: resolved?.secret,
                profileKind: resolved?.kind,
                profileBaseURL: resolved?.baseURL,
                profileModel: resolved?.model,
                profileAwsRegion: resolved?.awsRegion,
                profileAwsProfile: resolved?.awsProfile,
                profileConfigDir: configDirManager.resolveConfigDir(for: resolved),
                cmd: nil,
                shellFallback: "",
                settingsOverlayPath: ClaudeHookOverlay.resolveOverlayPath(
                    fallbackModels: resolved?.fallbackModels,
                    sessionKey: plannedTerminalID.uuidString,
                    repoSettingsJSON: ClaudeHookOverlay.repoSettingsFragment(repoID: repo?.id),
                    watchDeskRole: swapDeskRole,
                    worktreePath: worktree.path,
                    profileConfigDir: configDirManager.resolveConfigDir(for: resolved)
                ),
                pluginDirPath: PluginDirWriter.pluginDirPath,
                envSettingOverrides: claudeEnvOverrides,
                sessionName: worktree.displayName
            )
            storedSessionID = resumeID
            scheduleRecapture = true
        case .fresh(let newSessionID):
            logger.debug("swap: blank session — spawning fresh \(newSessionID, privacy: .public)")
            let appendPrompt = SystemPromptBuilder.build(
                repo: repo, worktree: worktree.worktree, isResume: false,
                scratchInstructions: swapConfig?.scratchInstructions,
                scratchRenamePrompt: swapConfig?.scratchRenamePrompt)
            spawn = ClaudeSpawnCommandBuilder.build(
                resumeID: nil,
                freshSessionID: newSessionID,
                appendSystemPrompt: appendPrompt,
                initialPrompt: nil,
                profileSecret: resolved?.secret,
                profileKind: resolved?.kind,
                profileBaseURL: resolved?.baseURL,
                profileModel: resolved?.model,
                profileAwsRegion: resolved?.awsRegion,
                profileAwsProfile: resolved?.awsProfile,
                profileConfigDir: configDirManager.resolveConfigDir(for: resolved),
                cmd: nil,
                shellFallback: "",
                settingsOverlayPath: ClaudeHookOverlay.resolveOverlayPath(
                    fallbackModels: resolved?.fallbackModels,
                    sessionKey: plannedTerminalID.uuidString,
                    repoSettingsJSON: ClaudeHookOverlay.repoSettingsFragment(repoID: repo?.id),
                    watchDeskRole: swapDeskRole,
                    worktreePath: worktree.path,
                    profileConfigDir: configDirManager.resolveConfigDir(for: resolved)
                ),
                pluginDirPath: PluginDirWriter.pluginDirPath,
                envSettingOverrides: claudeEnvOverrides,
                sessionName: worktree.displayName
            )
            storedSessionID = newSessionID
            scheduleRecapture = false
        }

        // Resolve initial size: caller-supplied → TmuxManager defaults to avoid
        // tmux's 80x24 default producing un-reflowable hard-wrapped scrollback.
        let resolvedCols = params.cols ?? TmuxManager.defaultCols
        let resolvedRows = params.rows ?? TmuxManager.defaultRows
        let sensitiveEnv = mergedEnvOverrides.merging(spawn.sensitiveEnv) { _, builder in builder }

        let response: RPCResponse
        // Set when the in-place respawn's tmux call failed. That failure is
        // deliberately swallowed downstream — the RPC still returns the updated
        // row (pre-existing contract) — so it is invisible in the response and
        // has to be carried out separately, or the record would call a failed
        // respawn `dispatched`.
        var respawnFailure: String?
        do {
            switch mode {
            case .fork:
                response = try await forkSwapNewTab(
                    worktree: worktree.worktree,
                    plannedTerminalID: plannedTerminalID,
                    spawnCommand: spawn.command,
                    env: env,
                    sensitiveEnv: sensitiveEnv,
                    storedSessionID: storedSessionID,
                    profileID: resolved?.profileID,
                    scheduleRecapture: scheduleRecapture,
                    cols: resolvedCols,
                    rows: resolvedRows
                )

            case .inPlace:
                let outcome = try await inPlaceSwapRespawn(
                    oldTerminal: oldTerminal,
                    worktree: worktree.worktree,
                    spawnCommand: spawn.command,
                    env: env,
                    sensitiveEnv: sensitiveEnv,
                    storedSessionID: storedSessionID,
                    newProfileID: resolved?.profileID,
                    scheduleRecapture: scheduleRecapture,
                    cols: resolvedCols,
                    rows: resolvedRows
                )
                response = outcome.response
                respawnFailure = outcome.respawnError
            }
        } catch {
            await finishActuation(actuationID, .transportFailed, error: "\(error)")
            throw error
        }
        if let respawnFailure {
            await finishActuation(actuationID, .transportFailed, error: respawnFailure)
        } else {
            // The only unsuccessful response either swap branch returns is
            // "Terminal vanished after swap" — the row it respawned is gone.
            await finishActuation(actuationID, response: response, refusedAs: .notFound)
        }
        return response
    }

    /// `.fork` swap: spawn a NEW window + terminal row in the same worktree,
    /// leaving the source session's tab untouched. Preserves the original
    /// fork-into-new-tab behavior; now only reached via the explicit "Fork
    /// session" action.
    private func forkSwapNewTab(
        worktree: Worktree,
        plannedTerminalID: UUID,
        spawnCommand: String,
        env: [String: String],
        sensitiveEnv: [String: String],
        storedSessionID: String,
        profileID: UUID?,
        scheduleRecapture: Bool,
        cols: Int,
        rows: Int
    ) async throws -> RPCResponse {
        let window = try await tmux.createWindow(
            server: worktree.tmuxServer,
            session: "main",
            cwd: worktree.localPath,
            shellCommand: spawnCommand,
            env: env,
            sensitiveEnv: sensitiveEnv,
            cols: cols,
            rows: rows
        )

        let newTerminal = try await db.terminals.create(
            id: plannedTerminalID,
            worktreeID: worktree.id,
            tmuxWindowID: window.windowID,
            tmuxPaneID: window.paneID,
            label: "claude",
            claudeSessionID: storedSessionID,
            profileID: profileID,
            kind: .claude
        )

        subscriptions.broadcast(delta: .terminalCreated(TerminalDelta(
            terminalID: newTerminal.id, worktreeID: newTerminal.worktreeID, label: newTerminal.label
        )))

        if scheduleRecapture {
            scheduleSessionRecapture(
                terminalID: newTerminal.id, paneID: window.paneID, server: worktree.tmuxServer
            )
        }

        guard let updated = try await db.terminals.get(id: newTerminal.id) else {
            return RPCResponse(error: "Terminal vanished after swap")
        }
        return try RPCResponse(result: updated)
    }

    /// `.inPlace` swap (seamless "Switch account"): gracefully interrupt the
    /// pane's current Claude, respawn `claude` under the new profile IN THE SAME
    /// tmux window, and update the EXISTING terminal row (new profile id, same
    /// session id + tmux ids). One tab, no new row.
    ///
    /// The terminal row's `profile_id` is set to the new profile BEFORE the
    /// respawn so a respawn failure still leaves the row on the new account
    /// (the pane shows the error; the user can retry). The transcript was
    /// already carried into the destination config dir upstream.
    ///
    /// A failed respawn is therefore invisible in the returned response — by
    /// design, and unchanged here. `respawnError` reports it out of band so the
    /// caller's actuation row can say `transport-failed` instead of inheriting
    /// the response's success.
    private func inPlaceSwapRespawn(
        oldTerminal: Terminal,
        worktree: Worktree,
        spawnCommand: String,
        env: [String: String],
        sensitiveEnv: [String: String],
        storedSessionID: String,
        newProfileID: UUID?,
        scheduleRecapture: Bool,
        cols: Int,
        rows: Int
    ) async throws -> (response: RPCResponse, respawnError: String?) {
        let server = worktree.tmuxServer
        let paneID = oldTerminal.tmuxPaneID
        let windowID = oldTerminal.tmuxWindowID
        var respawnError: String?

        // 1. Gracefully interrupt the pane's current Claude before respawn.
        //    `respawn-window -k` will forcibly replace it regardless, but a
        //    graceful stop lets Claude finish flushing and avoids yanking an
        //    in-flight generation. Best-effort — never blocks the swap.
        await gracefullyInterruptPane(server: server, paneID: paneID)

        // 2. Update the terminal row to the new profile + session up front, so a
        //    later respawn failure still leaves the row on the new account.
        try await db.terminals.setProfileID(id: oldTerminal.id, profileID: newProfileID)
        try await db.terminals.updateSessionID(id: oldTerminal.id, sessionID: storedSessionID)
        // Step 1 killed the process any recorded prompt was raised on, and this
        // row survives the swap — so a `permission_prompt` standing here now
        // describes a dead pane. `SessionStateResolver`'s rung 4 would keep
        // reporting it as a live wait: `transcriptPath` is unchanged and its
        // mtime still predates the reason, so the "prompt stands" branch holds
        // until some later hook happens to write an activity state. Retract it
        // from TBD's own act rather than waiting for the respawned session's
        // hooks to arrive — they may be seconds away, or lost to a stale `tbd`
        // on the pane's PATH.
        try await db.terminals.clearAwaitingInputReason(id: oldTerminal.id)

        // 3. Respawn IN PLACE — same window id / pane id → the tab and terminal
        //    row survive.
        do {
            try await tmux.respawnWindow(
                server: server,
                windowID: windowID,
                cwd: worktree.localPath,
                shellCommand: spawnCommand,
                env: env,
                sensitiveEnv: sensitiveEnv,
                cols: cols,
                rows: rows
            )
        } catch {
            // Failure path: the row keeps the new profile id (respawn can be
            // retried); the pane surfaces the error. Log clearly and still
            // return the updated row so the app reflects the new account — but
            // hand the failure back so the record classifies it truthfully.
            logger.warning("inPlace swap: respawn failed for terminal \(oldTerminal.id, privacy: .public) window \(windowID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            respawnError = "\(error)"
        }

        subscriptions.broadcast(delta: .terminalSessionUpdated(TerminalSessionDelta(
            terminalID: oldTerminal.id,
            worktreeID: worktree.id,
            sessionID: storedSessionID,
            transcriptPath: oldTerminal.transcriptPath
        )))
        // Update the row's account chip in place — same terminal id, new profile.
        subscriptions.broadcast(delta: .terminalProfileChanged(TerminalProfileDelta(
            terminalID: oldTerminal.id,
            worktreeID: worktree.id,
            newProfileID: newProfileID
        )))

        if scheduleRecapture {
            scheduleSessionRecapture(
                terminalID: oldTerminal.id, paneID: paneID, server: server
            )
        }

        guard let updated = try await db.terminals.get(id: oldTerminal.id) else {
            return (RPCResponse(error: "Terminal vanished after swap"), respawnError)
        }
        logger.info("inPlace swap: terminal \(oldTerminal.id, privacy: .public) switched to profile \(newProfileID?.uuidString ?? "ambient", privacy: .public) in window \(windowID, privacy: .public)")
        return (try RPCResponse(result: updated), respawnError)
    }

    /// Best-effort graceful interrupt of a pane's foreground program before an
    /// in-place respawn: Escape (stop a Claude generation), a brief settle,
    /// then C-c C-c, another settle, then a SIGTERM to the pane pid as a
    /// backstop. Every step is best-effort — failures are logged and ignored,
    /// since the subsequent `respawn-window -k` guarantees termination.
    ///
    /// **Acts on an unverified coordinate (issue #384).** `paneID` comes from
    /// the terminal row, and tmux reuses pane ids, so a stale row aims this at
    /// a live stranger — and unlike `terminal.send`, which now consults
    /// `paneSendTarget` before typing and refuses on disagreement, what lands
    /// here is a SIGTERM and then a forced respawn of that window. The
    /// consultation is not the missing piece: what a *refusal* should do to a
    /// user's account switch or hibernate is a product decision (fail it, mark
    /// the row, or fall back to a coordinate-free path), and belongs in a spec
    /// rather than being bolted on here. Same note on
    /// `HibernationCoordinator`'s copy of this helper.
    private func gracefullyInterruptPane(server: String, paneID: String) async {
        // Escape: ask Claude to stop generating.
        try? await tmux.sendKey(server: server, paneID: paneID, key: "Escape")
        // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
        try? await Task.sleep(for: .milliseconds(150))
        // C-c C-c: interrupt / exit the TUI.
        try? await tmux.sendKey(server: server, paneID: paneID, key: "C-c")
        try? await tmux.sendKey(server: server, paneID: paneID, key: "C-c")
        // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
        try? await Task.sleep(for: .milliseconds(150))
        // SIGTERM the pane pid as a backstop (respawn -k is the real guarantee).
        if let pidStr = try? await tmux.panePID(server: server, paneID: paneID),
           let pid = Int32(pidStr), pid > 0 {
            kill(pid, SIGTERM)
        }
    }

    /// Schedule the post-resume session-id recapture. `claude --resume <id>
    /// --fork-session` (the `.fork` swap path) forks the conversation into a NEW
    /// session file with a fresh UUID; mirror the wake path's pattern — wait ~5s
    /// for Claude to settle, then capture the new id from the pane and persist it
    /// against `terminalID`. (On the `.inPlace` path there is no `--fork-session`,
    /// so the id is unchanged and the recapture is a harmless no-op.)
    private func scheduleSessionRecapture(terminalID: UUID, paneID: String, server: String) {
        SessionRecaptureScheduler(db: db, tmux: tmux).schedule(
            terminalID: terminalID,
            paneID: paneID,
            server: server
        )
    }

    /// Whether a text payload rides behind the `<tbd-dispatch/>` envelope.
    ///
    /// **Daemon-internal, and deliberately not a field on
    /// `TerminalSendParams`.** The envelope's whole value is that an agent
    /// reading one knows the message came from a dispatch rather than from the
    /// person at the keyboard; an envelope any caller could omit over RPC would
    /// hand every caller the ability to type as a human, which is precisely the
    /// property the envelope exists to provide. So suppression is reachable
    /// only from inside this file's own send core, by daemon rails that are
    /// relaying the operator's own words verbatim — and the act is still
    /// written to the actuation log either way, so the record of who typed what
    /// stays complete.
    enum DispatchEnvelopeDisposition {
        /// The default and the only disposition any RPC can ask for.
        case attached
        /// Deliver the caller's bytes with nothing prepended. Reserved for the
        /// queued prompt taken at worktree creation, whose text must reach the
        /// model byte-identical to what the argv path would have delivered
        /// (design 2026-08-10, "The paste path delivers verbatim").
        case suppressed
    }

    func handleTerminalSend(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalSendParams.self, from: paramsData)
        // Queue behind any send already mid-flight to this same terminal; sends
        // to other terminals are unaffected. The whole handler runs inside the
        // lane so the target check and the typing it authorizes cannot be
        // separated by another caller's paste.
        return try await terminalSendSerializer.run(terminalID: params.terminalID) {
            try await self.performTerminalSend(params, actor: actor)
        }
    }

    /// Paste the operator's own words into an agent with no `<tbd-dispatch/>`
    /// envelope — the queued-prompt paste path, and the only caller of
    /// `.suppressed`.
    ///
    /// Reuses the send core rather than reaching for tmux directly, so the pane
    /// consultation, the per-terminal serializer lane and the actuation row all
    /// apply unchanged. Answers whether the bytes reached the pane.
    ///
    /// It does **not** buy the pending-input hibernate veto:
    /// `InputActivityTracker.recordInput` has one caller — the app's own
    /// keystroke stream (`Daemon.swift`) — and nothing in the tmux paste path
    /// touches it. So an unsubmitted queued prompt staged in a composer is
    /// invisible to the idle sweep, exactly like any other daemon-side paste.
    func sendQueuedPromptVerbatim(
        terminalID: UUID, text: String, submit: Bool
    ) async -> Bool {
        let params = TerminalSendParams(terminalID: terminalID, text: text, submit: submit)
        do {
            let response = try await terminalSendSerializer.run(terminalID: terminalID) {
                try await self.performTerminalSend(
                    params, actor: .daemon(rail: ActuationRail.queuedPrompt),
                    envelope: .suppressed)
            }
            return response.success
        } catch {
            logger.warning("""
                queued prompt: send to terminal \(terminalID.uuidString, privacy: .public) failed: \
                \(error, privacy: .public)
                """)
            return false
        }
    }

    private func performTerminalSend(
        _ params: TerminalSendParams, actor: ActuationActor?,
        envelope: DispatchEnvelopeDisposition = .attached
    ) async throws -> RPCResponse {
        // ─── The first of two refusal lines, and the reason they differ ───
        //
        // A malformed payload SHAPE is rejected here, before any row exists, as
        // an ordinary RPC error. `RPCRouter+Actuation.swift` draws this line
        // already: a row must not be written for a request that was never about
        // to be dispatched. None of these combinations names a coherent act —
        // there is no send to record, only a caller that asked for nothing, or
        // for two contradictory things at once.
        //
        // The second line is below, at the flag: `--verify` while delivery
        // verification is off IS a coherent act, one the daemon declined, so it
        // gets a row and a refusal outcome. See there.
        //
        // The CLI validates these same shapes so a human gets a clean message
        // before a socket is opened; the daemon enforces them independently
        // because the CLI is not the only caller.
        let payload: TerminalSendPayload
        switch Self.validateSendShape(params) {
        case .valid(let validated): payload = validated
        case .malformed(let message): return RPCResponse(error: message)
        }

        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            return RPCResponse(error: "Terminal not found: \(params.terminalID)")
        }

        // Look up the worktree to get the tmux server name
        guard let worktree = try await db.worktrees.getLocal(id: terminal.worktreeID) else {
            return RPCResponse(error: "Worktree not found for terminal: \(params.terminalID)")
        }

        // Request row first: the target is resolved and the payload is known,
        // and nothing has touched the pane yet. The paste and the Enter are
        // sub-steps of one send, so they share this one row.
        //
        // The row records the caller's payload VERBATIM and without the
        // envelope (§3, "the log records the message verbatim"). The envelope is
        // transport framing built at delivery, and its id is this row's own id,
        // so storing it would duplicate the row's identifier into its own body.
        let actuationID = try await beginActuation(
            .terminalSend, actor: actor,
            target: .local(worktree: terminal.worktreeID, terminal: terminal.id),
            message: payload.recordedMessage,
            submit: payload.recordedSubmit,
            verify: payload.recordedVerify)

        // ─── The second refusal line: a well-formed act the daemon declines ───
        //
        // `--verify` while `delivery_verification_enabled` is off is a refusal,
        // not a silent downgrade to an unverified send. A caller that asked for
        // evidence must never be answered with a silence that reads like
        // confirmation — that would rebuild, one layer up, the exact
        // silent-failure class §12 exists to end. Nothing is typed, and the row
        // shows the near-miss so the morning can see what the flag stopped.
        //
        // Read per call and only when `--verify` was armed, so an ordinary send
        // pays no config read.
        //
        // Two conditions, because the flag and the machinery it enables are
        // read at different times: the column per call, the verifier once at
        // daemon start. Between flipping the flag on and restarting, the column
        // says yes and there is still nothing to arm — and a send that
        // dispatched with nothing armed would render `unconfirmed` forever,
        // handing the caller a silence that reads like a delivery failure when
        // nothing ever looked. Both conditions therefore refuse, and neither
        // types anything.
        if payload.isVerifyArmed {
            // Only a target with an adapter that can answer may be verified. A
            // shell keeps no transcript at all, and Codex's adapter is a
            // different mechanism §12 describes but this slice does not build —
            // either way the one observation that exists would return
            // `undetermined` every time. Refuse rather than promise evidence the
            // target cannot produce.
            if !Self.supportsDeliveryObservation(terminal) {
                let kindName = (terminal.kind ?? .shell).rawValue
                let message = """
                    terminal.send --verify was refused: terminal \
                    \(terminal.id.uuidString) is a \(kindName) session, and delivery can only \
                    be observed for a Claude session today — nothing was sent. Resend without \
                    --verify.
                    """
                await finishActuation(actuationID, .refused(.notEligible), error: message)
                return RPCResponse(error: message)
            }
            let enabled = (try? await db.config.get())?.deliveryVerificationEnabled ?? false
            if !enabled {
                let message = """
                    terminal.send --verify was refused: delivery verification is disabled \
                    (config.delivery_verification_enabled is off) — nothing was sent. Enable \
                    it with the config.setDeliveryVerification RPC and restart the daemon, or \
                    resend without --verify to accept an unverified send.
                    """
                await finishActuation(actuationID, .refused(.notEligible), error: message)
                return RPCResponse(error: message)
            }
            if deliveryVerifier == nil {
                let message = """
                    terminal.send --verify was refused: delivery verification is enabled but \
                    this daemon has no verifier wired, so the flag was turned on after it \
                    started — nothing was sent. Restart the daemon to arm the observation, or \
                    resend without --verify to accept an unverified send.
                    """
                await finishActuation(actuationID, .refused(.notEligible), error: message)
                return RPCResponse(error: message)
            }
        }

        // Ask the pane about itself before typing into it — the honest-transport
        // check of issue #384 and the dead-pane class beside it. A decline here
        // is a refusal, never a transport failure: the daemon declined without
        // touching the transport. The consultation itself failing is the
        // opposite, and is classified as such.
        let refusal: PaneSendRefusal?
        do {
            refusal = try await consultPaneBeforeTyping(
                terminal: terminal, server: worktree.tmuxServer)
        } catch {
            await finishActuation(actuationID, .transportFailed, error: "\(error)")
            throw error
        }
        if let refusal {
            await finishActuation(actuationID, refusal.outcome, error: refusal.message)
            return RPCResponse(error: refusal.message)
        }

        // What actually reached the pane, envelope included — nil for a payload
        // that pasted nothing (empty text, or keys). Handed to the arming seam
        // below so a retry can re-deliver byte-identically.
        var deliveredPayload: String?

        do {
            switch payload {
            case .text(let text, let submit, _):
                // Deliver the body as an EXPLICIT bracketed paste (load-buffer +
                // paste-buffer -d -p) rather than raw `send-keys -l`. For payloads
                // larger than the pty buffer (~1 KB) the pty splits `send-keys -l` into
                // multiple rapid reads, which a TUI's non-bracketed paste-burst
                // detection mistakes for a paste and coalesces — absorbing the trailing
                // Enter so nothing submits. The explicit `ESC[201~` terminator puts the
                // Enter provably outside the paste. tmux emits the wrappers iff the pane
                // has bracketed-paste mode on — agent TUIs and modern interactive shells
                // both enable it at the prompt; cooked-mode consumers get bare bytes and
                // behave as before. Skip an empty body entirely (don't paste an empty
                // buffer) but still press Enter below if requested.
                //
                // A non-empty text payload to an AGENT rides behind the dispatch
                // envelope (§12): a one-line tag carrying this row's id and the
                // identity the row was attributed to, then the caller's message
                // verbatim. It is attribution the receiving agent can read, and
                // — because a submitted message's verbatim content lands in the
                // transcript JSONL — it is the machine fact a later observation
                // looks for, requiring nothing of the agent. Unconditional along
                // the axis that matters: verified or not, a prefix that appears
                // only sometimes is one no reader can rely on.
                //
                // An EMPTY payload keeps today's behaviour exactly: nothing is
                // pasted, and a bare `--submit` still presses Enter. `tbd
                // terminal send --text "" --submit` is a real way to press Enter
                // and must not start pasting a tag.
                if !text.isEmpty {
                    // ...and it rides every send to an AGENT. A shell is not a
                    // reader of envelopes: it has no transcript to join back to,
                    // and a `--submit` there would execute the tag as a command
                    // line of its own before the caller's text ever ran. Every
                    // sentence §12 uses to justify the envelope is about a
                    // receiving agent and its transcript JSONL; a shell target
                    // satisfies none of them, so prefixing one would be framing
                    // nobody reads, delivered as a syntax error.
                    //
                    // ...and `envelope` is the one axis that can withhold it
                    // from an agent: a daemon rail relaying the operator's own
                    // words must deliver them byte-identically. It is not
                    // reachable from `TerminalSendParams` — see
                    // `DispatchEnvelopeDisposition`.
                    let composed = envelope == .attached && Self.carriesDispatchEnvelope(terminal)
                        ? Self.dispatchEnvelope(
                            id: actuationID, from: (actor ?? .anonymous).dispatchLabel
                        ) + "\n" + text
                        : text
                    try await tmux.pasteText(
                        server: worktree.tmuxServer,
                        paneID: terminal.tmuxPaneID,
                        bytes: Data(composed.utf8)
                    )
                    deliveredPayload = composed
                }

                if submit {
                    try await tmux.sendKey(
                        server: worktree.tmuxServer,
                        paneID: terminal.tmuxPaneID,
                        key: "Enter"
                    )
                }

            case .keys(let names, _):
                // Named keys, one at a time, paced — see `PacedKeySender` for
                // why back-to-back keys get dropped by a redrawing TUI. The
                // `sendKey` call stays here, inside the file the actuation audit
                // covers, and the pacing lives behind the closure.
                try await pacedKeySender.send(names) { key in
                    try await self.tmux.sendKey(
                        server: worktree.tmuxServer,
                        paneID: terminal.tmuxPaneID,
                        key: key
                    )
                }
            }
        } catch {
            await finishActuation(actuationID, .transportFailed, error: "\(error)")
            throw error
        }

        await finishActuation(actuationID, .dispatched)

        // Hand off to the observation — the record's third rung. Reached only
        // from here, only after `.dispatched`, and only for a verify-armed text
        // payload that actually pasted something, so a verify-less send, a
        // refusal and a transport failure all arm nothing. See
        // `DeliveryVerificationArming` for the full contract.
        if payload.isVerifyArmed, let deliveredPayload {
            await deliveryVerifier?.armVerification(
                actuationID: actuationID,
                terminalID: terminal.id,
                sessionID: terminal.claudeSessionID,
                deliveredPayload: deliveredPayload,
                submit: payload.recordedSubmit ?? false)
        }
        return .ok()
    }

    // MARK: - The pane consultation, and the verifier's re-delivery

    /// Consult the pane the send names, and classify the answer.
    ///
    /// `nil` means "proceed" — the pane is alive and either agrees it is this
    /// terminal or claims no identity at all. Anything else is a refusal the
    /// caller records and returns, with the message a human reads.
    ///
    /// tmux's own exit status cannot carry this: `send-keys` into a
    /// `remain-on-exit` dead pane exits 0, and keys sent to a reused pane id
    /// land in a live stranger's composer with no error anywhere (issue #384).
    /// Both answers arrive from ONE read-only `list-panes`, read BEFORE any
    /// byte is written. Throws only when the consultation could not be RUN — a
    /// wedged tmux tripping the subprocess timeout — which is a tmux command
    /// failing, not an answer about the pane.
    ///
    /// Shared by the send path and by `redeliverVerifiedPayload`, so the retry
    /// cannot re-type into a pane the first send would have refused.
    private func consultPaneBeforeTyping(
        terminal: Terminal, server: String
    ) async throws -> PaneSendRefusal? {
        switch try await tmux.paneSendTarget(server: server, paneID: terminal.tmuxPaneID) {
        case .missing:
            return PaneSendRefusal(outcome: .refused(.notFound), message: """
                tmux pane \(terminal.tmuxPaneID) for terminal \(terminal.id.uuidString) \
                no longer exists on server \(server) — nothing was sent
                """)
        case .dead:
            return PaneSendRefusal(outcome: .refused(.notEligible), message: """
                tmux pane \(terminal.tmuxPaneID) for terminal \(terminal.id.uuidString) is \
                dead (its process has exited) — nothing was sent; recreate the terminal's \
                window first
                """)
        case .live(let paneTerminalID):
            guard let paneTerminalID else {
                // Absence is not disagreement. A pane spawned before TBD stamped
                // identities, or by something outside TBD, answers with nothing —
                // and refusing on nothing would turn this fix into a regression
                // for every such pane. Only a POSITIVE disagreement refuses.
                logger.debug("""
                    terminal.send: pane \(terminal.tmuxPaneID, privacy: .public) claims no \
                    terminal identity; proceeding without verifying it is terminal \
                    \(terminal.id.uuidString, privacy: .public)
                    """)
                return nil
            }
            guard paneTerminalID.caseInsensitiveCompare(terminal.id.uuidString)
                != .orderedSame else { return nil }
            return PaneSendRefusal(outcome: .refused(.targetMismatch), message: """
                tmux pane \(terminal.tmuxPaneID) now belongs to terminal \
                \(paneTerminalID), not the requested terminal \(terminal.id.uuidString) \
                — nothing was sent (tmux reuses pane ids, so this coordinate is stale)
                """)
        }
    }

    /// Re-deliver an already-recorded payload, byte-identically, for the
    /// delivery verifier's single evidence-bounded retry (§12).
    ///
    /// **Writes no row of its own, and mints no id.** The retry re-delivers the
    /// identical payload under the identical envelope id, so it is the same
    /// actuation-level intent as the original send — a second request row would
    /// split one intent in two and break the join that makes the ladder
    /// readable. The verifier records this call's *outcome* against the
    /// original request id, which is why the outcome is returned rather than
    /// thrown: a refused or transport-failed retry must be classified as what
    /// it was, not collapsed into "the payload failed".
    ///
    /// It runs the same pane consultation the first send ran, through the same
    /// helper: a minute has passed, and the pane may have died or been reused
    /// since. And it queues in the same per-terminal lane, so a retry can never
    /// splice itself into a concurrent send's paste.
    func redeliverVerifiedPayload(
        terminalID: UUID, sessionID: String?, payload: String, submit: Bool
    ) async -> ActuationOutcome {
        guard let terminal = try? await db.terminals.get(id: terminalID),
              let worktree = try? await db.worktrees.getLocal(id: terminal.worktreeID) else {
            return .refused(.notFound)
        }
        // The kind is re-read too, not just the pane. A `recreateWindow` landing
        // between the observation and this retry can turn an agent terminal into
        // a shell while keeping its id, and the payload we are holding opens
        // with an envelope — which a shell would run as a command line of its
        // own. The eligibility that admitted the first send has to still hold
        // for the second.
        guard Self.supportsDeliveryObservation(terminal) else {
            return .refused(.notEligible)
        }
        // And the conversation is re-checked here, not only at the observation.
        // The gap between the two spans a DB write, two reads and this
        // serializer's queue — long enough for a `/clear` to land in it — and
        // the payload being held is an instruction addressed to the session
        // that is no longer there. A rebind makes this a send to a stranger,
        // which is the one thing the retry must never be.
        //
        // A `nil` expected id is not a mismatch, and this is the same rule
        // `DeliveryVerifier.observe` applies: it means the conversation was not
        // identified when the payload was dispatched — a terminal whose session
        // id had not been recorded yet — so there is no identity to compare and
        // no rebind the comparison could detect. A session id appearing by the
        // time the retry runs is the terminal becoming knowable, not a stranger
        // arriving. Refusing on it would spend the one retry the mechanism gets
        // on an absence that is evidence of nothing. A *known* id that no longer
        // matches is still a stranger, and still refused.
        if let sessionID, terminal.claudeSessionID != sessionID {
            return .refused(.targetMismatch)
        }
        let outcome: ActuationOutcome
        do {
            outcome = try await terminalSendSerializer.run(terminalID: terminalID) {
                if let refusal = try await self.consultPaneBeforeTyping(
                    terminal: terminal, server: worktree.tmuxServer) {
                    return refusal.outcome
                }
                try await self.tmux.pasteText(
                    server: worktree.tmuxServer,
                    paneID: terminal.tmuxPaneID,
                    bytes: Data(payload.utf8))
                if submit {
                    try await self.tmux.sendKey(
                        server: worktree.tmuxServer,
                        paneID: terminal.tmuxPaneID,
                        key: "Enter")
                }
                return .dispatched
            }
        } catch {
            // Either the consultation could not be run or the paste itself
            // failed. Both are the transport, not a decision.
            logger.warning("""
                delivery retry: re-delivery to terminal \(terminalID.uuidString, privacy: .public) \
                failed: \(error, privacy: .public)
                """)
            return .transportFailed
        }
        return outcome
    }

    // MARK: - terminal.send payload shape

    /// The dispatch envelope §12 puts ahead of a non-empty text payload bound
    /// for an agent (see `carriesDispatchEnvelope` for which targets those are).
    ///
    /// `id` is the actuation row's own id — there is no second identifier
    /// namespace, so dispatch, transcript receipt and outcome all join on one
    /// string. `from` comes from `ActuationActor.dispatchLabel`, which is
    /// whitelisted to `[A-Za-z0-9._:-]` and capped, so no rail or project name
    /// can close the tag or open a second attribute.
    static func dispatchEnvelope(id: String, from label: String) -> String {
        "<tbd-dispatch id=\"\(id)\" from=\"\(label)\"/>"
    }

    /// Whether this target is one the envelope means anything to.
    ///
    /// Agent sessions only. The envelope exists so a receiving agent can see who
    /// is addressing it and so a later reader can join a transcript message back
    /// to its actuation row — and a shell has neither property: nothing reads the
    /// tag, no transcript records it, and `--submit` would run it as a command
    /// line of its own. `tbd terminal send` into a plain shell pane is a
    /// supported thing to do (`docs/tmux-integration.md`), so this is a real
    /// target rather than a theoretical one.
    ///
    /// A terminal with no recorded kind is treated as a shell — the same
    /// defaulting the rest of this file uses (`terminal.kind ?? .shell`), and the
    /// conservative direction: it withholds framing rather than typing a tag into
    /// something that may execute it.
    static func carriesDispatchEnvelope(_ terminal: Terminal) -> Bool {
        switch terminal.kind ?? .shell {
        case .claude, .codex: return true
        case .shell: return false
        }
    }

    /// Whether an adapter exists that can actually observe a delivery to this
    /// target — the narrower question `--verify` turns on.
    ///
    /// Claude only, today. §12 is explicit that the envelope-in-the-transcript
    /// read is *the Claude adapter's* implementation of the observation, and
    /// that "the Codex adapter gets the same answer from the app-server
    /// protocol's in-protocol acknowledgement" — a different mechanism, and one
    /// this slice does not build. A Codex session records no Claude-shaped
    /// transcript path, so the one observation that exists would answer
    /// `undetermined` every time.
    ///
    /// So this is the same refusal a shell gets, for the same stated reason:
    /// promising evidence a target cannot produce is the failure this whole
    /// mechanism exists to end. Codex still receives the envelope — attribution
    /// is worth having to any agent, and a composer does not execute it — but it
    /// cannot be verified until its adapter lands.
    static func supportsDeliveryObservation(_ terminal: Terminal) -> Bool {
        (terminal.kind ?? .shell) == .claude
    }

    /// Reject the payload shapes that name no coherent act, before a row exists.
    ///
    /// Returns the validated payload, or the error text the caller sees. Pure
    /// and static so both the daemon path and its tests can reach it without a
    /// database.
    static func validateSendShape(
        _ params: TerminalSendParams
    ) -> TerminalSendShape {
        let submit = params.submit == true
        let verify = params.verify == true

        switch (params.text, params.keys) {
        case (.some, .some):
            // Two payloads in one call. Which one was meant is unknowable, and
            // guessing would type something nobody asked for.
            return .malformed(
                "terminal.send takes exactly one payload: --text or --keys, not both")

        case (.none, .none):
            return .malformed(
                "terminal.send needs a payload: pass --text or --keys")

        case (.none, .some(let keys)):
            // Enter is itself a key. `--submit --keys` asks the daemon to append
            // a keystroke to a key sequence the caller already wrote out in
            // full, which cannot be what was meant — spell it "… Enter".
            if submit {
                return .malformed(
                    "terminal.send --submit is incoherent with --keys (Enter is itself a "
                    + "key — put it in the sequence: --keys \"Escape Enter\")")
            }
            // Keys never reach a transcript, so there is no observation to make
            // and nothing an envelope could be found in (§12).
            if verify {
                return .malformed(
                    "terminal.send --verify cannot be used with --keys: keys reach no "
                    + "transcript, so delivery cannot be observed")
            }
            guard let names = PacedKeySender.tokenize(keys) else {
                return .malformed(
                    "terminal.send --keys must name between 1 and \(PacedKeySender.maxKeys) "
                    + "whitespace-separated tmux keys (for example: --keys \"Escape Enter\")")
            }
            return .valid(.keys(names: names, verbatim: keys))

        case (.some(let text), .none):
            if verify {
                // Text that is never submitted never enters the conversation and
                // so can never appear in a transcript; verifying it would build
                // a machine that reports not-landed every time and then retries.
                // An EMPTY payload fails for the same reason one step earlier —
                // nothing is pasted, so no envelope is ever written to be found.
                // Both are refused rather than downgraded, per the never-answer-
                // a-request-for-evidence-with-silence rule (§12).
                if !submit {
                    return .malformed(
                        "terminal.send --verify requires --submit: text left standing in a "
                        + "composer never enters the conversation, so delivery cannot be "
                        + "observed")
                }
                if text.isEmpty {
                    return .malformed(
                        "terminal.send --verify requires a non-empty --text: an empty payload "
                        + "pastes nothing, so there is no dispatch envelope to observe")
                }
            }
            return .valid(.text(text, submit: submit, verify: verify))
        }
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
        let worktrees = try await db.worktrees.listLocal(status: .active)
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
            message: params.message,
            terminalID: params.terminalID
        )

        subscriptions.broadcast(delta: .notificationReceived(NotificationDelta(
            notificationID: notification.id, worktreeID: notification.worktreeID,
            type: notification.type, message: notification.message,
            terminalID: notification.terminalID
        )))

        return try RPCResponse(result: notification)
    }

    func handleTerminalFocus(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalFocusParams.self, from: paramsData)

        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            return RPCResponse(error: "Unknown terminal: \(params.terminalID.uuidString)")
        }

        let notification = try await db.notifications.create(
            worktreeID: terminal.worktreeID,
            type: .focusRequest,
            message: params.message,
            terminalID: terminal.id
        )

        subscriptions.broadcast(delta: .notificationReceived(NotificationDelta(
            notificationID: notification.id, worktreeID: notification.worktreeID,
            type: notification.type, message: notification.message,
            terminalID: notification.terminalID, activate: params.activate
        )))

        return try RPCResponse(result: notification)
    }

    // MARK: - Notifications List

    func handleNotificationsList() async throws -> RPCResponse {
        let summaries = try await db.notifications.unreadSummaryByWorktree()
        let legacyTypes = summaries.mapValues { $0.type }
        return try RPCResponse(result: NotificationsListResult(
            notifications: legacyTypes,
            summaries: summaries
        ))
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
                let beforeCount = try await db.worktrees.listLocal(repoID: repo.id, status: .active).count
                try await lifecycle.reconcile(repoID: repo.id, actuationLog: actuationLog)
                let afterCount = try await db.worktrees.listLocal(repoID: repo.id, status: .active).count
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
            connectedClients: connectedClientsProvider?() ?? 0,
            executablePath: Self.resolvedExecutablePath
        )
        return try RPCResponse(result: status)
    }

    /// Daemon's own executable path, resolved once at module load. Captures
    /// CWD at startup (rather than at each `daemon.status` RPC) so a later
    /// `chdir` can't make the resolution wrong if `argv[0]` is relative.
    /// Symlinks are followed so we return the real binary path — `cliPath()`
    /// looks for `TBDCLI` next to the actual TBDDaemon binary, not next to
    /// a symlink that points at it.
    private static let resolvedExecutablePath: String? = {
        guard let argv0 = CommandLine.arguments.first, !argv0.isEmpty else { return nil }
        let url: URL
        if argv0.hasPrefix("/") {
            url = URL(fileURLWithPath: argv0)
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            url = URL(fileURLWithPath: argv0, relativeTo: URL(fileURLWithPath: cwd))
        }
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }()

    // MARK: - Resolve Path

    func handleResolvePath(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ResolvePathParams.self, from: paramsData)

        // Walk up from the given path and try to match against known repos/worktrees
        if let resolved = try await resolvePathToRepoOrWorktree(params.path) {
            return try RPCResponse(result: resolved)
        }

        // No match found
        let result = ResolvedPathResult(repoID: nil, worktreeID: nil)
        return try RPCResponse(result: result)
    }

    /// Walk up from `path`, matching each ancestor directory against known
    /// worktrees (preferred) then repos. Returns the first match, or `nil` if
    /// the path doesn't live inside any TBD-tracked repo/worktree. Shared by
    /// `handleResolvePath` and the session-event worktree-ownership guard.
    func resolvePathToRepoOrWorktree(_ path: String) async throws -> ResolvedPathResult? {
        var currentPath = (path as NSString).standardizingPath
        while currentPath != "/" && currentPath != "" {
            if let worktree = try await db.worktrees.findByPath(path: currentPath) {
                return ResolvedPathResult(repoID: worktree.repoID, worktreeID: worktree.id)
            }
            if let repo = try await db.repos.findByPath(path: currentPath) {
                return ResolvedPathResult(repoID: repo.id, worktreeID: nil)
            }
            currentPath = (currentPath as NSString).deletingLastPathComponent
        }
        return nil
    }

    // MARK: - Claude projects roots (transcript sync)

    /// Projects root for a spawn's resolved profile config dir path, falling
    /// back to the router's (injectable) ambient claude dir. Handler-side
    /// counterpart of `TranscriptProjectDirSync.projectsRoot`, routed through
    /// `configDirManager` so tests can isolate via the injection seam.
    func claudeProjectsRoot(profileConfigDirPath: String?) -> URL {
        if let path = profileConfigDirPath, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
        }
        return configDirManager.ambientConfigDirectory
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// Projects root for a terminal's stored profile id (nil = ambient).
    func claudeProjectsRoot(forProfileID profileID: UUID?) -> URL {
        if let profileID {
            return configDirManager.configDirectory(forProfileID: profileID)
                .appendingPathComponent("projects", isDirectory: true)
        }
        return configDirManager.ambientConfigDirectory
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// Worktree-ownership guard shared by every hook bridge that routes on
    /// `TBD_TERMINAL_ID`.
    ///
    /// That variable is injected at terminal creation and INHERITED by every
    /// descendant process — including multi-agent teammates and subprocesses
    /// that run their own Claude session and fire their own hooks. Routing
    /// solely by it lets such a foreign session write to a terminal that is not
    /// its own. Defend by requiring the hook's reported `cwd` to resolve to the
    /// SAME worktree as the target terminal. A mismatch means the event came
    /// from a foreign session living in a different worktree — the caller
    /// rejects it (soft success; hooks are fire-and-forget).
    ///
    /// Self-heal: the guard ACCEPTS the legitimate session's events even when
    /// the terminal's stored pointer is currently foreign, so a hijacked
    /// terminal recovers on its next valid event (e.g. resume/clear).
    ///
    /// One guard, one behavior: every hook bridge gets the same answer,
    /// including the promoted-scratch acceptance, rather than a per-handler
    /// variant that drifts.
    func hookCWDBelongsToTerminal(
        _ cwd: String,
        terminal: Terminal,
        event: String
    ) async throws -> Bool {
        let resolved = try await resolvePathToRepoOrWorktree(cwd)
        var accepted = resolved?.worktreeID == terminal.worktreeID
        // Promotion follow-up: when the terminal's worktree is a promoted
        // scratch row (promotedToRepoID set), its live session now runs in
        // the moved folder — whose path resolves to the NEW repo's main
        // worktree, not the scratch row. That's the same session, not a
        // foreign one: accept when the cwd resolves to the main worktree
        // of the promoted-to repo.
        if !accepted,
           let resolvedWorktreeID = resolved?.worktreeID,
           let ownerWorktree = try await db.worktrees.getLocal(id: terminal.worktreeID),
           let promotedRepoID = ownerWorktree.promotedToRepoID,
           let resolvedWorktree = try await db.worktrees.getLocal(id: resolvedWorktreeID),
           resolvedWorktree.repoID == promotedRepoID,
           resolvedWorktree.status == .main {
            accepted = true
            logger.info("\(event, privacy: .public): accepted post-promote session for terminal \(terminal.id.uuidString, privacy: .public) — cwd resolves to main worktree of promoted repo \(promotedRepoID.uuidString, privacy: .public)")
        }
        if !accepted {
            // The cwd is the one interpolation here that is not TBD's own
            // vocabulary: it is a real checkout path, and in this product those
            // routinely carry an employer, a client or a repository name. Every
            // agent hook reaches this guard, so a `.public` cwd would write that
            // into the system log on an ordinary cadence. The identifiers stay
            // public — they are what the line is for.
            logger.info(
                """
                \(event, privacy: .public): REJECTED foreign session for terminal \
                \(terminal.id.uuidString, privacy: .public) — hook cwd \
                \(cwd, privacy: .private) resolves to worktree \
                \(resolved?.worktreeID?.uuidString ?? "none", privacy: .public) \
                but terminal belongs to worktree \
                \(terminal.worktreeID.uuidString, privacy: .public); \
                event ignored
                """
            )
        }
        return accepted
    }

    /// Bridge for the Claude SessionStart hook. The CLI relays the hook
    /// payload (session_id, transcript_path, source) plus the spawn-time
    /// `TBD_TERMINAL_ID` env to this method. We persist both fields and
    /// broadcast a delta so the app's transcript pane re-targets the new
    /// session file. Unknown terminal IDs are treated as a soft no-op (the
    /// terminal may have been deleted between hook fire and arrival).
    func handleTerminalSessionEvent(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalSessionEventParams.self, from: paramsData)

        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            // Soft success — caller is a fire-and-forget hook, returning an
            // error would just spam stderr inside Claude.
            logger.debug("sessionEvent: unknown terminalID=\(params.terminalID.uuidString, privacy: .public) — ignoring")
            return .ok()
        }
        await sessionCounters.recordHookEvent(terminalID: terminal.id, at: now())

        // `cwd` is optional for backward compatibility — when absent we cannot
        // validate, so we fall back to the old behavior.
        if let cwd = params.cwd, !cwd.isEmpty {
            guard try await hookCWDBelongsToTerminal(cwd, terminal: terminal, event: "sessionEvent")
            else { return .ok() }
        }

        // Sanitize: an empty transcriptPath shouldn't overwrite an existing
        // good value with nil (treat as "not provided"). A non-absolute path
        // is also rejected since that's never how Claude reports it.
        let cleanedPath: String? = {
            guard let p = params.transcriptPath, !p.isEmpty else { return nil }
            guard p.hasPrefix("/") else {
                logger.warning("sessionEvent: ignoring non-absolute transcriptPath \(p, privacy: .public)")
                return nil
            }
            return p
        }()

        try await db.terminals.updateSession(
            id: terminal.id,
            sessionID: params.sessionID,
            transcriptPath: cleanedPath
        )
        // A new session context has started in this pane — a `/clear`, a
        // resume after an in-place profile swap, or a hand relaunch — so a
        // wait reason recorded against the PREVIOUS one is not on screen any
        // more. It has to be retracted here, from the event that establishes
        // it, for two reasons `SessionStateResolver`'s rung 4 makes concrete.
        // A `/clear` points `transcriptPath` at a file Claude Code creates
        // lazily, so the growth fact is nil and "we could not look is not
        // evidence it went away" keeps the dead prompt standing; and the
        // overlay's own `tbd terminal-activity idle` — the rail that would
        // otherwise clear the columns — no-ops when the row already reads idle
        // and can be lost on its own while this call lands.
        //
        // Deliberately NOT `setActivityState`: this event says a session
        // exists, not what it is doing, and `activityState` gates hibernation.
        try await db.terminals.clearAwaitingInputReason(id: terminal.id)
        if terminal.kind == .codex || terminal.label == TerminalLabel.codex {
            // This handler is driven by the session-start hook, which is what
            // told us the session exists and is between turns.
            //
            // `observedAt` from the router's date seam, for the same reason as
            // every other stamp this file writes: `SessionStateResolver`'s
            // rung 4 *compares* it, and the store's default `Date()` is a
            // timestamp nothing outside the store can name.
            try await db.terminals.setActivityState(
                id: terminal.id, activityState: .idle, source: .hookEvent("SessionStart"),
                observedAt: now())
        }

        // Invalidate cached transcript parse for the OLD session file (if any)
        // so a quick re-poll doesn't return stale entries.
        // (TranscriptParseCache keys on filePath, so the new path naturally
        // misses cache and re-parses — no explicit invalidation needed.)

        let source = params.source ?? "unknown"
        logger.info("sessionEvent: terminal \(terminal.id.uuidString, privacy: .public) -> session \(params.sessionID, privacy: .public) (source=\(source, privacy: .public))")

        // The readiness signal for a parked prompt on the paste path. This
        // hook is the machine fact that the agent is up — never the pane's
        // rendered text, which this repo forbids reading for state.
        await pendingPromptCoordinator?.noteSessionReady(
            worktreeID: terminal.worktreeID, terminalID: terminal.id)

        subscriptions.broadcast(delta: .terminalSessionUpdated(TerminalSessionDelta(
            terminalID: terminal.id,
            worktreeID: terminal.worktreeID,
            sessionID: params.sessionID,
            transcriptPath: cleanedPath
        )))
        if terminal.kind == .codex || terminal.label == TerminalLabel.codex {
            subscriptions.broadcast(delta: .terminalActivityUpdated(TerminalActivityDelta(
                terminalID: terminal.id,
                worktreeID: terminal.worktreeID,
                activityState: .idle
            )))
        }
        return .ok()
    }

    /// Bridge for Claude Code's `Notification` hook — the one event that can
    /// say a prompt is on screen *now*.
    ///
    /// The hook entry that feeds this handler carries no matcher, so every
    /// notification type arrives here and every fork lives in this function.
    /// That placement is the design, not an accident: the hook entry sits in a
    /// settings file an operator can edit, so a matcher out there would be a
    /// policy decision TBD could not depend on, while a fork here is compiled
    /// and testable.
    ///
    /// The handler records a fact and changes nothing else. There is no
    /// broadcast: no delta shape carries a wait reason, and inventing one to
    /// carry a fact no surface renders yet would ship app behavior this slice
    /// deliberately does not have.
    func handleTerminalNotificationEvent(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalNotificationEventParams.self, from: paramsData)

        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            // Soft success — the caller is a fire-and-forget hook, and the
            // terminal may have been deleted between fire and arrival. An
            // error response here would be noise nobody reads and a non-zero
            // exit nobody wants in a hook.
            logger.debug("notificationEvent: unknown terminalID=\(params.terminalID.uuidString, privacy: .public) — ignoring")
            return .ok()
        }
        await sessionCounters.recordHookEvent(terminalID: terminal.id, at: now())

        if let cwd = params.cwd, !cwd.isEmpty {
            guard try await hookCWDBelongsToTerminal(cwd, terminal: terminal, event: "notificationEvent")
            else { return .ok() }
        }

        // The classification is a label on the record, computed once here from
        // the verbatim type. An unrecognized or absent type stays unrecognized.
        let reason = AwaitingInputReason(
            message: params.message,
            hookEventName: "Notification",
            raw: params.rawPayload,
            notificationType: params.notificationType)

        // Deliberately NOT `setActivityState`: this hook reports that a prompt
        // was raised, not that the session is still sitting on one, and
        // `activityState` is a *gating* field — `HibernationGate.blockingRail`
        // reads it, so writing `waiting_for_user` from here would silently
        // change which sessions park, on the strength of a message TBD does
        // not parse. `recordAwaitingInputReason` writes the reason columns and
        // leaves the activity columns exactly as they were. The resolver
        // composes `.awaitingInput(reason:)` from this record instead — so if
        // you are here to "fix" a missing state transition, fix it there.
        //
        // `observedAt` comes from the router's date seam, never a bare `Date()`
        // at the write site: a persisted observed-at is data, so it is the date
        // seam rather than a `Clock`.
        try await db.terminals.recordAwaitingInputReason(
            id: terminal.id, reason: reason, observedAt: now())

        // `message` may quote repo content, so it is `.private`; the type and
        // the class are TBD's own closed vocabulary and stay public.
        logger.debug(
            """
            notificationEvent: terminal=\(terminal.id.uuidString, privacy: .public) \
            type=\(params.notificationType ?? "none", privacy: .public) \
            class=\(reason.classification.rawValue, privacy: .public) \
            message=\(params.message, privacy: .private)
            """
        )
        return .ok()
    }

    func handleTerminalActivityEvent(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalActivityEventParams.self, from: paramsData)

        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            logger.debug("activityEvent: unknown terminalID=\(params.terminalID.uuidString, privacy: .public) — ignoring")
            return .ok()
        }

        // §13's hook-event rate. Counted here — before the unchanged-state
        // early return below — because a session emitting the same state over
        // and over is exactly the shape the counter exists to make visible, and
        // a count taken after that guard would report zero for it. One actor
        // hop and an integer add, which is the whole per-event budget.
        await sessionCounters.recordHookEvent(terminalID: terminal.id, at: now())

        // UserPromptSubmit reaches the daemon as activity=working. If a
        // session-limit auto-resume is pending, the user just continued
        // manually — cancel it (spec §Cancellation). Guarded on the mirror
        // field so the common case costs nothing. Note: the actuator's own
        // "continue" also lands here; by then verification usually already
        // moved the row out of pending, and a cancel-vs-sent race only
        // affects the audit status, never causes a second send.
        if params.activityState == .working, terminal.pendingResumeAt != nil {
            if (try? await db.scheduledResumes.cancelPending(terminalID: terminal.id)) == true {
                await limitResumeScheduler?.wake()
            }
        }

        // Stop-hook transcript sync (Stop/StopFailure reach the daemon as
        // activity=idle): when a session finishes a turn and its recorded
        // transcript lives OUTSIDE the project dir derived from the worktree's
        // CURRENT path — the worktree moved/was promoted after the session
        // started — mirror the jsonl + its subagents into the derived dir so
        // a later cwd-scoped `claude --resume` finds the conversation. Runs
        // BEFORE the unchanged-state guard so repeated Stops keep converging.
        // Never rewrites terminal.transcriptPath: the live session keeps
        // appending to the original file; we only copy.
        if params.activityState == .idle,
           let storedPath = terminal.transcriptPath, !storedPath.isEmpty,
           FileManager.default.fileExists(atPath: storedPath),
           let worktree = try? await db.worktrees.getLocal(id: terminal.worktreeID) {
            let derivedDir = TranscriptProjectDirSync.derivedProjectDir(
                worktreePath: worktree.path,
                projectsRoot: claudeProjectsRoot(forProfileID: terminal.profileID)
            )
            let source = URL(fileURLWithPath: storedPath)
            let sourceDirReal = source.deletingLastPathComponent()
                .resolvingSymlinksInPath().standardizedFileURL.path
            let derivedReal = derivedDir.resolvingSymlinksInPath().standardizedFileURL.path
            if sourceDirReal != derivedReal {
                await TranscriptProjectDirSync.syncSessionDetached(
                    jsonl: source, intoProjectDir: derivedDir)
            }
        }

        guard terminal.activityState != params.activityState else {
            return .ok()
        }

        // Every caller of this RPC is an agent hook bridged through
        // `tbd terminal-activity`. The params do not yet carry WHICH hook event
        // fired, so the RPC surface stands in as the source name until a later
        // slice threads the event through — a coarser answer than we want, but
        // a true one, and one no reader can mistake for an observation TBD made
        // itself.
        // `observedAt` from the router's date seam, never the store's default
        // `Date()`. The resolver's rung-4 decision is an ordering comparison
        // between exactly this stamp and the one `recordAwaitingInputReason`
        // writes above, so a test that cannot pin both ends cannot pin the
        // decision at all.
        try await db.terminals.setActivityState(
            id: terminal.id,
            activityState: params.activityState,
            source: .hookEvent(RPCMethod.terminalActivityEvent),
            observedAt: now())
        subscriptions.broadcast(delta: .terminalActivityUpdated(TerminalActivityDelta(
            terminalID: terminal.id,
            worktreeID: terminal.worktreeID,
            activityState: params.activityState
        )))
        return .ok()
    }
    func handleTerminalTranscript(_ paramsData: Data) async throws -> RPCResponse {
        perfTranscriptLog.debug("rpc.handle.start method=terminalTranscript")
        let start = ContinuousClock.now
        let response: RPCResponse
        var responseBytes = 0
        var itemsCount = 0
        defer {
            let elapsed = ContinuousClock.now - start
            let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            perfTranscriptLog.debug("rpc.handle.end method=terminalTranscript elapsed_ms=\(ms, privacy: .public) response_bytes=\(responseBytes, privacy: .public) items=\(itemsCount, privacy: .public)")
        }

        let params = try decoder.decode(TerminalTranscriptParams.self, from: paramsData)

        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            response = RPCResponse(error: "Terminal not found: \(params.terminalID)")
            return response
        }

        guard let sessionID = terminal.claudeSessionID else {
            let result = TerminalTranscriptResult(messages: [], sessionID: nil)
            response = try RPCResponse(result: result)
            responseBytes = response.result?.utf8.count ?? 0
            return response
        }

        guard let worktree = try await db.worktrees.getLocal(id: terminal.worktreeID) else {
            response = RPCResponse(error: "Worktree not found for terminal: \(params.terminalID)")
            return response
        }

        // Prefer the absolute path captured by the SessionStart hook — it's
        // immune to `/clear` and `/compact` rollovers that change the
        // ~/.claude/projects/ subdir away from the cwd-derived guess. Fall
        // back to the legacy projectDir+sessionID resolution for terminals
        // that haven't received a hook event yet (older terminals, or
        // sessions that were already running before the overlay hook was
        // registered).
        let filePath: String
        if let storedPath = terminal.transcriptPath, !storedPath.isEmpty {
            filePath = storedPath
        } else {
            guard let projectDir = ClaudeProjectDirectory.resolve(worktreePath: worktree.path) else {
                let result = TerminalTranscriptResult(messages: [], sessionID: sessionID)
                response = try RPCResponse(result: result)
                responseBytes = response.result?.utf8.count ?? 0
                return response
            }
            filePath = projectDir.appendingPathComponent("\(sessionID).jsonl").path
        }
        let parsed: [TranscriptItem]
        if let tailLimit = params.tailLimit {
            // Tail-first fast open (table pane): JSON-parse only a bounded window
            // of the last lines. Never touch TranscriptParseCache for this path —
            // the tail result is a partial view and must not poison the full cache.
            parsed = TranscriptParser.parseTail(filePath: filePath, limit: tailLimit)
        } else if let cached = await TranscriptParseCache.shared.get(filePath: filePath) {
            parsed = cached
        } else {
            parsed = TranscriptParser.parse(filePath: filePath)
            await TranscriptParseCache.shared.put(filePath: filePath, result: parsed)
        }

        await pendingQuestions.gcExpired(now: Date(), maxAge: .seconds(900))
        let entries = await pendingQuestions.entries(forTerminal: params.terminalID)
        let merged = AskUserQuestionMerger.merge(jsonlItems: parsed, pending: entries)
        for satisfiedID in merged.satisfiedToolUseIDs {
            await pendingQuestions.clear(terminalID: params.terminalID, toolUseID: satisfiedID)
        }
        let messages = merged.items

        let result = TerminalTranscriptResult(messages: messages, sessionID: sessionID)
        response = try RPCResponse(result: result)
        responseBytes = response.result?.utf8.count ?? 0
        itemsCount = messages.count
        return response
    }

    func handleTerminalTranscriptItemFullBody(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalTranscriptItemFullBodyParams.self, from: paramsData)

        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            return RPCResponse(error: "Terminal not found: \(params.terminalID)")
        }
        guard let sessionID = terminal.claudeSessionID,
              let worktree = try await db.worktrees.getLocal(id: terminal.worktreeID) else {
            return try RPCResponse(result: TerminalTranscriptItemFullBodyResult(text: "Output no longer available."))
        }

        // The transcript renders parent-file items only (Task/Agent tool calls
        // and their results live in the parent JSONL), so the full-body lookup
        // scans only the primary session file — subagent JSONLs are never opened.
        let primaryPath: String
        if let storedPath = terminal.transcriptPath, !storedPath.isEmpty {
            primaryPath = storedPath
        } else {
            guard let projectDir = ClaudeProjectDirectory.resolve(worktreePath: worktree.path) else {
                return try RPCResponse(result: TerminalTranscriptItemFullBodyResult(text: "Output no longer available."))
            }
            primaryPath = projectDir.appendingPathComponent("\(sessionID).jsonl").path
        }
        let detail = TranscriptParser.lookupDetail(filePath: primaryPath, itemID: params.itemID)

        // `includeBody: false` only keeps the body off the wire: the body string
        // falls out of the very same single JSONL pass that produces the
        // metadata (an attachment row's payloads must be extracted just to
        // recognize it as one), so there is no parser work to skip.
        return try RPCResponse(result: TerminalTranscriptItemFullBodyResult(
            text: params.includeBody ? (detail.text ?? "Output no longer available.") : "",
            attachment: detail.attachment))
    }
}
