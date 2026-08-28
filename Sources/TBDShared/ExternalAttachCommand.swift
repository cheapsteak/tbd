import Foundation

/// Composes the shell snippet that attaches an *external* terminal emulator —
/// iTerm2, Terminal.app, Ghostty — to the tmux window a TBD terminal already
/// owns, so somebody else's renderer can be put next to SwiftTerm's on the
/// identical byte stream.
///
/// Pure: no I/O, no daemon dependency, no process environment. The daemon
/// resolves the socket path and verifies the window (see
/// `handleTerminalAttachCommand`); everything past that is this string.
///
/// The recipe — an isolated session holding exactly one `link-window`ed window
/// — is the same one `TmuxBridge` uses for TBD's own panels, which is what
/// makes the external client a control rather than a differently-shaped
/// experiment. Rationale for every flag, and the measurement discipline the
/// output exists to serve, lives in
/// `docs/specs/2026-08-27-external-tmux-attach-shortcut-design.md`.
public enum ExternalAttachCommand {

    /// Prefix on every session this command mints. Terminal-keyed names bound
    /// the population at one session per terminal, and the reconciler that
    /// reclaims them matches on this exact prefix — so it must never collide
    /// with `tbd-view-` (TBD's own panels) or `main` (the daemon's session).
    public static let sessionPrefix = "tbd-ext-"

    /// `tbd-ext-` plus the first eight lowercase hex digits of the terminal's
    /// UUID — short enough to type, and keyed to the terminal so a second
    /// invocation reuses the session rather than minting a sibling.
    public static func sessionName(for terminalID: UUID) -> String {
        sessionPrefix + terminalID.uuidString.prefix(8).lowercased()
    }

    /// The command a user pastes into another emulator, or pipes into `sh`.
    ///
    /// Three logical lines: a `has-session` guard that makes the whole thing
    /// idempotent, the session-creating fallback, and the attach — which
    /// carries `set-option … destroy-unattached on` chained onto it.
    ///
    /// - `-S <socket>`, never `-L <name>`: a shell exporting a different
    ///   `TMUX_TMPDIR` would resolve the name to a path that does not exist and
    ///   silently start a new, empty server — the user would attach to a blank
    ///   shell and conclude the session was lost, and the stray socket would
    ///   leak permanently (tmux never unlinks a socket when its server exits).
    /// - `-u` on the attach only, matching `TmuxBridge.viewerAttachCommand`:
    ///   UTF-8 handling changes the byte stream, so an unmatched flag means the
    ///   two clients are not receiving the same thing.
    /// - `-f ignore-size`: the external client never pushes its dimensions, so
    ///   attaching cannot reflow TBD's panel mid-measurement. It is not `-r`,
    ///   so the client stays writable.
    /// - `destroy-unattached on`: reclaims the session the instant the last
    ///   client leaves. The reconciler carries the cases this misses.
    ///
    /// **The option rides the attach, and must not be tidied back into the
    /// setup block.** Setting it while the session is still detached is not a
    /// race the attach usually wins — it is a session that is always already
    /// gone. tmux collects an unattached `destroy-unattached on` session on a
    /// server tick, and setting the option is itself enough to schedule that
    /// tick, so the separate `tmux attach` process that follows it dies with
    /// `can't find session:` every single time (measured: 0 of 20 attempts
    /// attached). Chaining the `set-option` onto the attach with `\;` means the
    /// option is not set until a client is already there, and the session then
    /// self-destroys on detach exactly as intended. The mechanism is pinned by
    /// `destroyUnattachedReapsBeforeAnyClientCanArrive` in
    /// `Tests/TBDDaemonLiveTests/ExternalAttachCommandLiveTests.swift`.
    ///
    /// Every interpolated value is single-quoted: a socket path containing a
    /// space must not produce a broken script.
    ///
    /// Returned without a trailing newline — a caller printing it adds one.
    public static func script(
        socketPath: String,
        sessionName: String,
        windowID: String
    ) -> String {
        let socket = shellQuoted(socketPath)
        let session = shellQuoted(sessionName)
        let window = shellQuoted(windowID)
        // The session targets carry their `:` / `:0` suffix inside the quotes:
        // `'name:0'` and `'name':0` are the same word to the shell, and keeping
        // the whole target in one quoted unit reads better.
        let sessionTarget = shellQuoted(sessionName + ":")
        let windowZeroTarget = shellQuoted(sessionName + ":0")
        return """
            tmux -S \(socket) has-session -t \(session) 2>/dev/null || \\
            tmux -S \(socket) \\
                new-session -d -s \(session) -c /tmp \\; \\
                link-window -s \(window) -t \(sessionTarget) \\; \\
                kill-window -t \(windowZeroTarget)
            tmux -u -S \(socket) attach -t \(session) -f ignore-size \\; \\
                set-option -t \(session) destroy-unattached on
            """
    }

    /// POSIX single-quoting: wrap in `'…'` and rewrite each embedded `'` as
    /// `'\''`. Total — there is no character a single-quoted word interprets —
    /// so a socket path holding a space, a `$`, or a quote survives verbatim.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
