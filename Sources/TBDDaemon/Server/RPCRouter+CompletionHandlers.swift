import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "completions.rpc")

extension RPCRouter {

    /// `terminal.completions` — what slash commands, skills and subagents this
    /// terminal's Claude session knows.
    ///
    /// The app never probes for itself: the daemon holds each session's profile
    /// config directory, spawn environment, working directory and pid, and the
    /// app does not link the daemon library.
    ///
    /// Gated on `transcript_composer_enabled`, and the refusal is an ERROR rather
    /// than an empty inventory. An empty list is a real answer — a session with
    /// no commands — and a caller must not read "the feature is off" as "this
    /// session knows nothing".
    ///
    /// **The probe's environment is the session's, assembled the way the spawn
    /// path assembles it** — `ClaudeSpawnCommandBuilder.build` plus the
    /// free-form overrides its callers layer underneath it. The daemon's own
    /// environment is the base (the tmux server the session runs under inherited
    /// it from this process), then the free-form overrides in the builder's own
    /// precedence — global < repo < profile, `EnvOverrideResolver.merge` — and
    /// then `CLAUDE_CONFIG_DIR` on top, because the builder layers its routing
    /// env over the free-form one so a stray override cannot redirect a session.
    ///
    /// **A probe needs no credentials and adds none of its own.** The builder's
    /// remaining keys are deliberately not reproduced here: an API key, an OAuth
    /// token, a base URL or a model choice change the auth path without changing
    /// the command list, and injecting a key into an OAuth profile's environment
    /// was measured to *lose* three subscription-gated commands. A profile whose
    /// own `envOverrides` carry a key or an endpoint keeps them, because that is
    /// the environment its session runs in.
    func handleTerminalCompletions(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalCompletionsParams.self, from: paramsData)

        let config = try await db.config.get()
        guard config.transcriptComposerEnabled else {
            return RPCResponse(error:
                "terminal.completions is unavailable: the transcript composer is disabled "
                + "(config.transcript_composer_enabled is off). Enable it in Settings → "
                + "General → Claude, or with the config.setTranscriptComposerEnabled RPC.")
        }

        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            return RPCResponse(error: "Terminal not found: \(params.terminalID)")
        }
        guard (terminal.kind ?? .shell) == .claude else {
            return RPCResponse(error:
                "terminal.completions applies to Claude sessions only; terminal "
                + "\(params.terminalID) is a \((terminal.kind ?? .shell).rawValue) session.")
        }
        guard let worktree = try await db.worktrees.getLocal(id: terminal.worktreeID) else {
            return RPCResponse(error:
                "Worktree not found for terminal: \(params.terminalID)")
        }

        // The profile's own config directory decides the answer as much as the
        // binary does — user commands, skills, agents and plugin enablement all
        // live there. Resolved through the manager the spawn path uses, so the
        // probe reads the directory the session actually runs against.
        var profile: ResolvedModelProfile?
        if let profileID = terminal.profileID {
            profile = try? await modelProfileResolver.loadByID(profileID)
        }
        // A profile with no isolated directory (bedrock, or an api-key profile
        // whose secret has gone) runs against the host store, which is what
        // `ambientConfigDirectory` names. NOT the home directory: the scan and
        // the staleness fingerprint both read `<configDir>/commands` and
        // friends, and `$HOME/commands` is nobody's config.
        let configDir = configDirManager.resolveConfigDir(for: profile)
            ?? configDirManager.ambientConfigDirectory.path

        // The middle scope of the env-override merge. A scratch worktree has no
        // repo row and contributes nothing.
        var repo: Repo?
        if let repoID = worktree.repoID {
            repo = try? await db.repos.get(id: repoID)
        }

        // The pane's pid, when tmux can say. Best effort: an unreadable pid only
        // means the pin falls back to the resolved executable, which the service
        // does silently by design.
        var panePID: Int32?
        if terminal.transport == .tmux, !terminal.tmuxPaneID.isEmpty,
           let raw = try? await tmux.panePID(
               server: worktree.tmuxServer, paneID: terminal.tmuxPaneID) {
            panePID = Int32(raw)
        }

        var environment = ProcessInfo.processInfo.environment
        environment.merge(
            EnvOverrideResolver.merge(
                global: config.envOverrides,
                repo: repo?.envOverrides,
                profile: profile?.envOverrides)
        ) { _, override in override }
        environment["CLAUDE_CONFIG_DIR"] = configDir

        let result = await completionInventory.inventory(
            for: CompletionInventoryService.Request(
                terminalID: terminal.id,
                childPID: terminal.childPID,
                panePID: panePID,
                configDir: configDir,
                worktreePath: worktree.path,
                environment: environment))

        logger.debug("""
        completions: terminal=\(terminal.id.uuidString, privacy: .public) \
        source=\(result.source.rawValue, privacy: .public) \
        freshness=\(result.freshness.rawValue, privacy: .public) \
        commands=\(result.commands.count, privacy: .public)
        """)
        return try RPCResponse(result: result)
    }
}
