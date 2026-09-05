import Foundation
import TBDShared

/// The base environment any process the daemon spawns starts from: a holder
/// job, or a tmux server.
///
/// A daemon's environment describes the program that launched the daemon as
/// much as it describes the machine. `scripts/restart.sh` is usually run from
/// inside a Claude Code session, so the daemon inherits that session's exported
/// identity — and every process the daemon forks would inherit it in turn.
///
/// That inheritance is not cosmetic. An interactive Claude Code that finds
/// `CLAUDE_CODE_CHILD_SESSION` in its environment concludes it is a nested
/// child of another session: it writes no row into the cross-session peer
/// registry (`$CLAUDE_CONFIG_DIR/sessions/<pid>.json`), and it disables session
/// persistence, so the session gets no transcript either. The session runs
/// fine and is invisible to everything that reads those two surfaces.
///
/// TBD's own per-terminal exports do the same damage to TBD's own surfaces, and
/// the incarnation id is the load-bearing one. `AgentProcessEnvironment.replacement`
/// exports `TBD_TERMINAL_INCARNATION_ID` on every woken or restarted agent, so a
/// daemon restarted from such a session carries it; nothing on a fresh spawn
/// overwrites it, because the export prefix sets only `TBD_TERMINAL_ID` and
/// `TBD_WORKTREE_ID`. A fresh terminal row has no incarnation, so the guard in
/// `TerminalStore.applySessionStart` (`record.sessionIncarnationID ==
/// reportedIncarnationID?.uuidString`) fails and the job's SessionStart,
/// SessionEnd and activity hooks are all dropped: no session id, no transcript
/// path, activity never updates. An inherited `TBD_CLI_PATH` is the same shape
/// one layer down — it points the job's hooks (`"${TBD_CLI_PATH-tbd}"`) at
/// whichever worktree's CLI the launcher happened to be given.
///
/// Claude Code has a second question it can ask on the tmux transport: when
/// `$TMUX` is set it probes the tmux server's global environment for the same
/// marker, and a marker found there is ambient — the server's, not this
/// session's — so it is ignored. That probe is why the tmux path never showed
/// the Claude-side symptom, and the holder transport, having no tmux server for
/// the probe to ask, showed it immediately. TBD's own incarnation guard has no
/// such probe, so the tmux server needs the scrub too, for TBD's markers.
/// Stripping Claude's from the server as well costs nothing *on a server the
/// daemon creates*: no pane predates that spawn, so it leaves panes with no
/// marker at all, which is what the probe was there to simulate. It is not free
/// on a server repaired in place, where panes already hold their own copy — see
/// `serverRepairableMarkers`. Removing the markers at the source is what makes
/// the two transports behave alike.
///
/// **What belongs in the set.** One criterion across all four groups: the
/// identity of the process that launched the daemon — its session, its
/// terminal, its pane, its trace. Never machine, user, or installation
/// configuration. The set is the whole list, not half of one:
/// `Daemon.scrubInheritedTBDEnv` applies it to the daemon's own environment at
/// startup, so every child the daemon spawns through plain inheritance loses
/// the same names these two spawn seams strip explicitly. Claude Code
/// configuration a user may deliberately set in their login environment
/// (`CLAUDE_CODE_USE_BEDROCK` and anything like it) is not identity, and
/// neither is TBD's own installation configuration.
/// `TBD_HOME` and `TBD_SOCKET_PATH` name *which installation* everything
/// belongs to — the holder rendezvous directory derives from `TBD_HOME`, and so
/// does the socket a `tbd` invocation inside the job reaches for — so a job that
/// lost them would answer to a different installation than the daemon that
/// spawned it. All of it must keep flowing to the job exactly as the tmux path
/// delivers it.
///
/// `CLAUDE_CONFIG_DIR` is the one name whose *value* decides, because both
/// kinds of value share it. TBD injects one per spawn for a profile-bound
/// Claude session, naming a directory under this installation's profiles root
/// (`ClaudeSpawnCommandBuilder`, `ClaudeProfileConfigDirManager`); a
/// profile-less spawn injects nothing, so a daemon restarted from a
/// profile-bound session would otherwise hand its launcher's profile — that
/// profile's credential and settings — to every profile-less job. Only TBD
/// itself writes a value under that directory, so such a value is per-spawn
/// identity by construction and is dropped. Any other value is the user's own
/// configuration, which TBD honours (`ClaudeTrustSeeder` resolves it), and is
/// kept.
///
/// **TERM is pinned rather than inherited**, for a related but distinct reason:
/// it describes the terminal a job draws into, not the program that launched
/// the daemon. The tmux path does not inherit it either, because
/// `TmuxManager.ensureServer` sets `default-terminal xterm-256color` on every
/// server and so every pane gets that value. The holder transport pins the same
/// one: otherwise a daemon restarted from another terminal emulator hands the
/// job that emulator's TERM — a terminfo the holder's reader may not implement —
/// and a daemon the app launched itself has no TERM at all. Two sibling helpers
/// pin the same value: `TerminalPanelView.makeViewerEnvironment` strips
/// `TMUX`/`TMUX_PANE` and pins TERM for the grouped-session viewer, and
/// `BoundedProcessClaudeSpawner.invocationEnvironment` pins it when it runs a
/// child under a pseudo-terminal.
///
/// **The scrub applies to the inherited base only.** Values the spawn itself
/// decided — `sensitiveEnv`: profile env overrides, auth and routing — are
/// merged on top afterwards and win, so a deliberate override of one of these
/// names, TERM and a profile-bound `CLAUDE_CONFIG_DIR` included, reaches the job
/// unharmed.
enum SpawnBaseEnvironment {
    /// Claude Code's per-session exports. Claude Code's own child-session env
    /// builder injects the last three alongside the first four, and its
    /// shell-snapshot list treats them as session-scoped: an inherited
    /// CLAUDE_EFFORT silently sets the new session's effort level, and an
    /// inherited TRACEPARENT parents every span into the launcher's dead
    /// trace.
    static let claudeCodeSessionMarkers: Set<String> = [
        "CLAUDECODE",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_CODE_BRIDGE_SESSION_ID",
        "CLAUDE_CODE_EXECPATH",
        "CLAUDE_PID",
        "AI_AGENT",
        "CLAUDE_EFFORT",
        "TRACEPARENT",
    ]

    /// TBD's own per-process exports, identifying the terminal, worktree, or
    /// hook event the daemon was launched FROM. The four prompt layers are the
    /// launcher terminal's system-prompt text, composed per spawn by
    /// `SystemPromptBuilder.promptLayers`. `TBD_HANDOVER_FROM_PID` names the
    /// predecessor daemon a handover is taking over from; `Daemon.start()`
    /// reads it at the single-instance gate several steps before the startup
    /// scrub runs, so dropping it for children costs that read nothing.
    /// Installation-wide configuration (TBD_HOME, TBD_SOCKET_PATH) is
    /// deliberately not here.
    static let tbdProcessMarkers: Set<String> = [
        "TBD_TERMINAL_ID",
        "TBD_TERMINAL_INCARNATION_ID",
        "TBD_WORKTREE_ID",
        "TBD_CLI_PATH",
        "TBD_EVENT",
        "TBD_WORKTREE_NAME",
        "TBD_WORKTREE_PATH",
        "TBD_REPO_PATH",
        "TBD_BRANCH",
        "TBD_PROMPT_CONTEXT",
        "TBD_PROMPT_INSTRUCTIONS",
        "TBD_PROMPT_RENAME",
        "TBD_PROMPT_SCRATCH",
        "TBD_HANDOVER_FROM_PID",
    ]

    /// Codex's per-session exports. `CODEX_CI` puts a session into
    /// noninteractive mode and `CODEX_THREAD_ID` names the launcher's thread,
    /// so `CodexHomeManager` already unsets both in the shell command it builds
    /// for a Codex pane.
    static let codexSessionMarkers: Set<String> = [
        "CODEX_CI",
        "CODEX_THREAD_ID",
    ]

    /// The enclosing tmux pane's coordinates.
    static let tmuxPaneMarkers: Set<String> = [
        "TMUX",
        "TMUX_PANE",
    ]

    /// The names that describe whatever launched the daemon rather than the
    /// machine the daemon runs on.
    static let enclosingSessionMarkers: Set<String> = claudeCodeSessionMarkers
        .union(tbdProcessMarkers)
        .union(codexSessionMarkers)
        .union(tmuxPaneMarkers)

    /// The subset an *existing* tmux server's global environment may have
    /// stripped in place, rather than only on a server the daemon creates.
    ///
    /// Claude Code's markers are deliberately absent. A marker in the server's
    /// global environment is what makes the copy a running pane already holds
    /// read as ambient rather than as this session's, so removing the global
    /// copy would make a `claude` started later in a pane that predates the
    /// repair conclude it is a nested child — the very failure the scrub
    /// exists to prevent. Those markers therefore stay until the server is
    /// recycled, by which time no pane predates the scrub. `TMUX` and
    /// `TMUX_PANE` are absent because the server sets them itself for every
    /// pane it creates, so they are the server's own rather than a launcher's
    /// identity baked in at spawn.
    static var serverRepairableMarkers: Set<String> {
        tbdProcessMarkers.union(codexSessionMarkers)
    }

    /// The terminal type every pane gets on the tmux path, which
    /// `TmuxManager.ensureServer` sets as the server's `default-terminal`.
    private static let pinnedTerm = "xterm-256color"

    /// `base` with the enclosing session's markers removed, a TBD-minted
    /// profile config dir removed, and TERM pinned to what tmux gives a pane;
    /// everything else passes through untouched.
    ///
    /// An empty `CLAUDE_CONFIG_DIR` is dropped rather than passed on. Every
    /// reader of that name in this tree — `TBDConstants.configDir`,
    /// `ClaudeTrustSeeder.ensureTrusted`, `claudeProjectsRoot` — guards on
    /// `!isEmpty` and falls back as though the name were unset, so handing a
    /// job the empty string only invites a `URL(fileURLWithPath:)` on it
    /// somewhere further down.
    static func inheriting(_ base: [String: String]) -> [String: String] {
        var environment = base.filter { !enclosingSessionMarkers.contains($0.key) }
        if let configDir = environment["CLAUDE_CONFIG_DIR"],
           configDir.isEmpty || isTBDMintedProfileDir(configDir, base: base) {
            environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        }
        environment["TERM"] = pinnedTerm
        return environment
    }

    /// Whether `value` names a directory TBD minted for one profile — that is,
    /// one under the profiles root of the installation `base` itself names, so
    /// a daemon fenced onto a scratch `TBD_HOME` judges against that fence
    /// rather than the developer's real one. Pure string comparison on
    /// standardized paths; the filesystem is never consulted, since the
    /// directory may not exist yet and a spawn must not wait on a stat.
    ///
    /// Internal rather than private because the same by-value judgment is made
    /// in two other places: `Daemon.scrubInheritedTBDEnv` against the daemon's
    /// own environment, and `TmuxManager.configDirRepairNeeded` against what an
    /// existing tmux server reports for its global environment.
    static func isTBDMintedProfileDir(_ value: String, base: [String: String]) -> Bool {
        guard !value.isEmpty else { return false }
        let profilesRoot = TBDConstants.configDir(environment: base)
            .appendingPathComponent("profiles", isDirectory: true)
            .standardizedFileURL.path
        let candidate = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path
        return candidate == profilesRoot || candidate.hasPrefix(profilesRoot + "/")
    }
}
