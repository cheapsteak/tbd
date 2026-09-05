import Foundation

/// The base environment a holder-transport job starts from.
///
/// A daemon's environment describes the program that launched the daemon as
/// much as it describes the machine. `scripts/restart.sh` is usually run from
/// inside a Claude Code session, so the daemon inherits that session's exported
/// identity — and every job the daemon forks would inherit it in turn.
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
/// The tmux transport needs no scrub because Claude Code has a second question
/// it can ask there: when `$TMUX` is set it probes the tmux server's global
/// environment for the same marker, and a marker found there is ambient — the
/// server's, not this session's — so it is ignored. The holder transport has no
/// tmux server for that probe to ask, so the inherited marker reads as real.
/// Removing it at the source is what makes the two transports behave alike.
///
/// **What belongs in the set.** One criterion across all three groups: the
/// identity of the process that launched the daemon — its session, its
/// terminal, its pane, its trace. Never machine, user, or installation
/// configuration. Claude Code configuration a user may deliberately set in
/// their login environment (`CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_USE_BEDROCK`, and
/// anything like them) is not identity, and neither is TBD's own installation
/// configuration. `TBD_HOME` and `TBD_SOCKET_PATH` name *which installation*
/// everything belongs to — the holder rendezvous directory derives from
/// `TBD_HOME`, and so does the socket a `tbd` invocation inside the job reaches
/// for — so a job that lost them would answer to a different installation than
/// the daemon that spawned it. All of it must keep flowing to the job exactly
/// as the tmux path delivers it.
///
/// **TERM is pinned rather than inherited**, for a related but distinct reason:
/// it describes the terminal a job draws into, not the program that launched
/// the daemon. The tmux path never inherits it, because `TmuxManager.ensureServer`
/// sets `default-terminal xterm-256color` on every server and so every pane gets
/// that value. The holder transport pins the same one: otherwise a daemon
/// restarted from another terminal emulator hands the job that emulator's TERM —
/// a terminfo the holder's reader may not implement — and a daemon the app
/// launched itself has no TERM at all. The sibling helpers
/// `TerminalPanelView.makeViewerEnvironment` and
/// `ClaudeCloudSpawning.invocationEnvironment` strip TMUX and pin TERM together
/// in the same shape.
///
/// **The scrub applies to the inherited base only.** Values the spawn itself
/// decided — `sensitiveEnv`: profile env overrides, auth and routing — are
/// merged on top afterwards and win, so a deliberate override of one of these
/// names, TERM included, reaches the job unharmed.
enum HolderJobEnvironment {
    /// The names that describe whatever launched the daemon rather than the
    /// machine the daemon runs on.
    static let enclosingSessionMarkers: Set<String> = [
        // Claude Code's per-session exports. Claude Code's own child-session
        // env builder injects the last three alongside the first four, and its
        // shell-snapshot list treats them as session-scoped: an inherited
        // CLAUDE_EFFORT silently sets the new session's effort level, and an
        // inherited TRACEPARENT parents every span into the launcher's dead
        // trace.
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
        // TBD's own per-process exports, identifying the terminal, worktree, or
        // hook event the daemon was launched FROM. Installation-wide
        // configuration (TBD_HOME, TBD_SOCKET_PATH) is deliberately not here.
        "TBD_TERMINAL_ID",
        "TBD_TERMINAL_INCARNATION_ID",
        "TBD_WORKTREE_ID",
        "TBD_CLI_PATH",
        "TBD_EVENT",
        "TBD_WORKTREE_NAME",
        "TBD_WORKTREE_PATH",
        "TBD_REPO_PATH",
        "TBD_BRANCH",
        // The enclosing tmux pane's coordinates.
        "TMUX",
        "TMUX_PANE",
    ]

    /// The terminal type every pane gets on the tmux path, which
    /// `TmuxManager.ensureServer` sets as the server's `default-terminal`.
    private static let pinnedTerm = "xterm-256color"

    /// `base` with the enclosing session's markers removed and TERM pinned to
    /// what tmux gives a pane; everything else passes through untouched.
    static func inheriting(_ base: [String: String]) -> [String: String] {
        var environment = base.filter { !enclosingSessionMarkers.contains($0.key) }
        environment["TERM"] = pinnedTerm
        return environment
    }
}
