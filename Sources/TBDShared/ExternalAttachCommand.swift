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
/// The recipe — an isolated session holding exactly one `link-window`ed window,
/// selected and verified before a client is attached — is `TmuxBridge`'s recipe
/// for TBD's own panels, expressed as one shell statement instead of a sequence
/// of checked `Process` invocations. That is what makes the external client a
/// control rather than a differently-shaped experiment. It is not a literal
/// transcription: `TmuxBridge` classifies each step's failure into a stage for
/// the panel's error UI, and kills any same-named session unconditionally
/// because a panel has no external client to evict. Here a person may already
/// be attached mid-measurement, so a session that already holds the verified
/// window is reused and only a wrong one is rebuilt. What both guarantee is the
/// same and is the part that matters: no client is attached unless the session
/// holds the requested window.
///
/// Rationale for every flag, and the measurement discipline the output exists
/// to serve, lives in
/// `docs/specs/2026-08-27-external-tmux-attach-shortcut-design.md`.
public enum ExternalAttachCommand {

    /// Prefix on every session this command mints. Terminal-keyed names bound
    /// the population at one session per terminal — so it must never collide
    /// with `tbd-view-` (TBD's own panels) or `main` (the daemon's session).
    ///
    /// The prefix alone is **not** the reclamation rule: see
    /// `isGeneratedSessionName(_:)`.
    public static let sessionPrefix = "tbd-ext-"

    /// Width of the terminal-id fragment in a minted name.
    private static let idFragmentLength = 8

    /// The digits `isGeneratedSessionName(_:)` accepts. Spelled out rather
    /// than deferring to `Character.isHexDigit`, which is also true of
    /// full-width and other non-ASCII hex forms — the point of the predicate
    /// is that the accepted alphabet is exactly the one `sessionName(for:)`
    /// can emit, so it must be an explicit set.
    private static let idFragmentDigits = Set("0123456789abcdef")

    /// `tbd-ext-` plus the first eight lowercase hex digits of the terminal's
    /// UUID — short enough to type, and keyed to the terminal so a second
    /// invocation reuses the session rather than minting a sibling.
    public static func sessionName(for terminalID: UUID) -> String {
        sessionPrefix + terminalID.uuidString.prefix(idFragmentLength).lowercased()
    }

    /// Whether `name` is a session `sessionName(for:)` could have minted: the
    /// prefix followed by exactly eight lowercase hex digits, and nothing
    /// else.
    ///
    /// **This, not `hasPrefix(sessionPrefix)`, is the reclamation rule.** It
    /// lives beside the name builder so the rule that mints names and the rule
    /// that reaps them cannot drift apart.
    ///
    /// The prefix alone is not safe to reap on. `TmuxManager`'s conditional
    /// kill hands tmux an inner command *string* that tmux re-parses, and tmux
    /// splits a command string on `;`. A session somebody created by hand on
    /// TBD's own server as `tbd-ext-aa ; kill-server` would therefore turn
    /// that string into `kill-session -t tbd-ext-aa ; kill-server` and take
    /// down the whole server — every TBD terminal for that repo with it
    /// (reproduced on tmux 3.6a). Constraining the accepted shape here means
    /// no such name is ever a candidate, and the single-quoting there is
    /// second-line defense rather than the guarantee.
    ///
    /// It also keeps benign hand-made names — `tbd-ext-notes`, a scratch
    /// `tbd-ext-` session somebody parked a shell in — out of the sweep,
    /// which prefix matching alone did not.
    public static func isGeneratedSessionName(_ name: String) -> Bool {
        guard name.hasPrefix(sessionPrefix) else { return false }
        let fragment = name.dropFirst(sessionPrefix.count)
        return fragment.count == idFragmentLength
            && fragment.allSatisfy(idFragmentDigits.contains)
    }

    /// The command a user pastes into another emulator, or runs through a
    /// shell as `sh -c "$(tbd terminal attach <worktree> --print)"` or
    /// `eval "$(…)"`.
    ///
    /// **It cannot be piped into `sh`.** `tmux attach` needs a tty on stdin,
    /// and a shell reading its script from a pipe leaves stdin as that pipe, so
    /// the attach dies with `open terminal failed: not a terminal` — after the
    /// setup half has already built the session, and with `destroy-unattached`
    /// riding the attach that just failed, so the session is left behind
    /// client-less. Command substitution from a tty is the working form.
    ///
    /// Two statements joined by `&&`: a verify-or-rebuild that leaves the
    /// terminal-keyed session holding exactly the verified window, and the
    /// attach — which carries `select-window` ahead of it and
    /// `set-option … destroy-unattached on` behind it.
    ///
    /// The shape exists to make one failure impossible: **attaching a person to
    /// anything other than the window they asked for.** Every clause below is
    /// there because some path otherwise ends with a client sitting on the
    /// throwaway `/tmp` shell, believing it is their agent's session.
    ///
    /// - **Verify, then reuse or rebuild.** The guard is not `has-session` but
    ///   an exact comparison of the session's window list against the window
    ///   the daemon just verified. `has-session` reuses a session whose window
    ///   died and was recreated under a new id, which is silent and lands the
    ///   client on a window nobody is using any more. Comparing the list
    ///   instead reuses only a session that actually holds the right window —
    ///   so an external client already attached for a measurement survives a
    ///   second invocation — and rebuilds otherwise.
    /// - **`kill-window -a -t <session>:<window>`**, never `kill-window -t
    ///   <session>:0`. The throwaway window is at index `base-index`, which the
    ///   user's `~/.tmux.conf` sets and `TmuxManager` never fences out (it
    ///   passes no `-f`). Under `set -g base-index 1` the `:0` form fails with
    ///   `can't find window: 0`, tmux abandons the rest of the `\;` chain, and
    ///   the session keeps a stray `/tmp` shell the client can wander into.
    ///   Killing everything *except* the target says what is meant and does not
    ///   depend on the index.
    /// - **`&&` between setup and attach.** A window can die between the
    ///   daemon's probe and the paste — a closed tab, a respawn, a reconcile
    ///   pass, a slow hand. `link-window` then fails, and as two bare
    ///   statements the attach still ran and landed on the throwaway shell,
    ///   with one line of tmux stderr scrolled off by the redraw as the only
    ///   signal. Now the attach cannot run at all unless setup succeeded.
    /// - **The rebuild cleans up after itself.** A build that fails part-way
    ///   would otherwise leave a client-less session holding a bare shell under
    ///   this terminal's own name. `WorktreeLifecycle+Reconcile` is the named
    ///   reconciler and would collect it within the grace period; killing it
    ///   here as well keeps a failed paste from leaving anything at all, and
    ///   the `false` preserves the non-zero status so the attach stays skipped.
    /// - **`select-window` ahead of the attach.** Partly self-correction, and
    ///   partly the last guard: it closes the gap between the verify and the
    ///   attach, because if the window has gone in between, `select-window`
    ///   fails, tmux abandons the chain, and no client is created. The spec's
    ///   reason for *omitting* a `select-window` — never move `main`'s
    ///   current-window pointer, which the daemon's control-mode connection
    ///   depends on — does not apply here: the target is this isolated
    ///   session's own pointer, and `main` is untouched.
    /// - **`-S <socket>`, never `-L <name>`:** a shell exporting a different
    ///   `TMUX_TMPDIR` would resolve the name to a path that does not exist and
    ///   silently start a new, empty server — the user would attach to a blank
    ///   shell and conclude the session was lost, and the stray socket would
    ///   leak permanently (tmux never unlinks a socket when its server exits).
    /// - **`-u` on the attach only**, matching `TmuxBridge.viewerAttachCommand`:
    ///   UTF-8 handling changes the byte stream, so an unmatched flag means the
    ///   two clients are not receiving the same thing.
    /// - **`-f ignore-size`:** the external client never pushes its dimensions,
    ///   so attaching cannot reflow TBD's panel mid-measurement. It is not
    ///   `-r`, so the client stays writable.
    ///
    /// **`destroy-unattached on` rides the attach, and must not be tidied back
    /// into the setup block.** Setting it while the session is still detached
    /// is not a race the attach usually wins — it is a session that is always
    /// already gone. tmux collects an unattached `destroy-unattached on`
    /// session on a server tick, and setting the option is itself enough to
    /// schedule that tick, so the separate `tmux attach` process that follows
    /// it dies with `can't find session:` every single time (measured: 0 of 20
    /// attempts attached). Chaining the `set-option` onto the attach with `\;`
    /// means the option is not set until a client is already there, and the
    /// session then self-destroys on detach exactly as intended.
    ///
    /// **No `set -e`.** The script is meant to be usable under `eval` in a
    /// person's interactive shell, where `set -e` would outlive it and change
    /// how their own shell handles every later failure. Control flow is carried
    /// by `||` and `&&` instead, which is local to this script by construction.
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
        // The session targets carry their `:` / `:@<id>` suffix inside the
        // quotes: `'name:'` and `'name':` are the same word to the shell, and
        // keeping the whole target in one quoted unit reads better.
        let sessionTarget = shellQuoted(sessionName + ":")
        let windowTarget = shellQuoted(sessionName + ":" + windowID)
        return """
            [ "$(tmux -S \(socket) list-windows -t \(session) -F '#{window_id}' 2>/dev/null)" = \(window) ] || {
                tmux -S \(socket) kill-session -t \(session) 2>/dev/null
                tmux -S \(socket) \\
                    new-session -d -s \(session) -c /tmp \\; \\
                    link-window -s \(window) -t \(sessionTarget) \\; \\
                    kill-window -a -t \(windowTarget) \\
                    || { tmux -S \(socket) kill-session -t \(session) 2>/dev/null; false; }
            } && tmux -u -S \(socket) \\
                select-window -t \(windowTarget) \\; \\
                attach -t \(session) -f ignore-size \\; \\
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
