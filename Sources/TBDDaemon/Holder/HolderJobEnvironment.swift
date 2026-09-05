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
/// The tmux transport needs no scrub because Claude Code has a second question
/// it can ask there: when `$TMUX` is set it probes the tmux server's global
/// environment for the same marker, and a marker found there is ambient — the
/// server's, not this session's — so it is ignored. The holder transport has no
/// tmux server for that probe to ask, so the inherited marker reads as real.
/// Removing it at the source is what makes the two transports behave alike.
///
/// **What belongs in the set.** Variables that identify the *enclosing session
/// or pane* — this session's id, its messaging socket, the pane it is drawn in.
/// Claude Code *configuration* a user may deliberately set in their login
/// environment (`CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_USE_BEDROCK`, and anything
/// like them) is not identity and must keep flowing to the job exactly as the
/// tmux path delivers it.
///
/// **The scrub applies to the inherited base only.** Values the spawn itself
/// decided — `sensitiveEnv`: profile env overrides, auth and routing — are
/// merged on top afterwards and win, so a deliberate override of one of these
/// names reaches the job unharmed.
enum HolderJobEnvironment {
    /// The names that describe whatever launched the daemon rather than the
    /// machine the daemon runs on.
    static let enclosingSessionMarkers: Set<String> = [
        // Claude Code's per-session exports.
        "CLAUDECODE",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_CODE_BRIDGE_SESSION_ID",
        "CLAUDE_CODE_EXECPATH",
        "CLAUDE_PID",
        // The enclosing tmux pane's coordinates.
        "TMUX",
        "TMUX_PANE",
    ]

    /// `base` with the enclosing session's markers removed. Everything else —
    /// PATH, SHELL, locale, the user's own Claude Code configuration — passes
    /// through untouched.
    static func inheriting(_ base: [String: String]) -> [String: String] {
        base.filter { !enclosingSessionMarkers.contains($0.key) }
    }
}
