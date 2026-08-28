import Foundation
import Testing
@testable import TBDShared

/// The composer is a pure function, so its output is pinned WHOLE — one exact
/// string comparison against the snippet in
/// `docs/specs/2026-08-27-external-tmux-attach-shortcut-design.md`, not a
/// scattering of substring checks. Substring checks would pass a script whose
/// pieces are all present in the wrong order, missing a `\;`, or missing the
/// `||` that makes the whole thing idempotent — every one of which is a broken
/// command a user would paste into a shell.
@Suite("ExternalAttachCommand")
struct ExternalAttachCommandTests {

    // MARK: - Session naming

    @Test("the session name is the prefix plus the first eight hex digits, lowercased")
    func sessionNameIsTerminalKeyed() {
        let terminalID = UUID(uuidString: "5A2B3C4D-1111-2222-3333-444455556666")!
        #expect(ExternalAttachCommand.sessionName(for: terminalID) == "tbd-ext-5a2b3c4d")
    }

    @Test("the prefix is the one the reconciler matches on, and collides with neither TBD session kind")
    func prefixIsDistinct() {
        #expect(ExternalAttachCommand.sessionPrefix == "tbd-ext-")
        // `tbd-view-` is a TBD panel's own session and `main` is the daemon's.
        // A sweep keyed on this prefix must never reach either.
        #expect(!"tbd-view-5a2b3c4d".hasPrefix(ExternalAttachCommand.sessionPrefix))
        #expect(!"main".hasPrefix(ExternalAttachCommand.sessionPrefix))
        #expect(ExternalAttachCommand.sessionName(for: UUID())
            .hasPrefix(ExternalAttachCommand.sessionPrefix))
    }

    // MARK: - The script, whole

    @Test("the composed script is exactly the spec's snippet")
    func scriptMatchesSpecVerbatim() {
        let script = ExternalAttachCommand.script(
            socketPath: "/tmp/tmux-501/tbd-1a2b3c4d",
            sessionName: "tbd-ext-5a2b3c4d",
            windowID: "@7")
        #expect(script == """
            tmux -S '/tmp/tmux-501/tbd-1a2b3c4d' has-session -t 'tbd-ext-5a2b3c4d' 2>/dev/null || \\
            tmux -S '/tmp/tmux-501/tbd-1a2b3c4d' \\
                new-session -d -s 'tbd-ext-5a2b3c4d' -c /tmp \\; \\
                link-window -s '@7' -t 'tbd-ext-5a2b3c4d:' \\; \\
                kill-window -t 'tbd-ext-5a2b3c4d:0'
            tmux -u -S '/tmp/tmux-501/tbd-1a2b3c4d' attach -t 'tbd-ext-5a2b3c4d' -f ignore-size \\; \\
                set-option -t 'tbd-ext-5a2b3c4d' destroy-unattached on
            """)
    }

    @Test("no trailing newline, so a caller decides how the script is terminated")
    func scriptHasNoTrailingNewline() {
        let script = ExternalAttachCommand.script(
            socketPath: "/tmp/tmux-501/tbd-1a2b3c4d",
            sessionName: "tbd-ext-5a2b3c4d",
            windowID: "@7")
        #expect(!script.hasSuffix("\n"))
    }

    // MARK: - Quoting

    @Test("a socket path containing a space stays one shell word")
    func spaceInSocketPathStaysQuoted() {
        // A `TMUX_TMPDIR` holding a space is ordinary on macOS.
        // Unquoted, the shell would split this into two arguments and `-S`
        // would take only the first half.
        let script = ExternalAttachCommand.script(
            socketPath: "/tmp/tbd fence/tmux-501/tbd-1a2b3c4d",
            sessionName: "tbd-ext-5a2b3c4d",
            windowID: "@7")
        #expect(script == """
            tmux -S '/tmp/tbd fence/tmux-501/tbd-1a2b3c4d' has-session -t 'tbd-ext-5a2b3c4d' 2>/dev/null || \\
            tmux -S '/tmp/tbd fence/tmux-501/tbd-1a2b3c4d' \\
                new-session -d -s 'tbd-ext-5a2b3c4d' -c /tmp \\; \\
                link-window -s '@7' -t 'tbd-ext-5a2b3c4d:' \\; \\
                kill-window -t 'tbd-ext-5a2b3c4d:0'
            tmux -u -S '/tmp/tbd fence/tmux-501/tbd-1a2b3c4d' attach -t 'tbd-ext-5a2b3c4d' -f ignore-size \\; \\
                set-option -t 'tbd-ext-5a2b3c4d' destroy-unattached on
            """)
    }

    @Test("a socket path containing a single quote closes and reopens the quoting")
    func singleQuoteInSocketPathIsEscaped() {
        // The one character a single-quoted word cannot hold. Getting this
        // wrong does not merely break the command — it ends the quoted string
        // early and hands the rest of the path to the shell as code.
        #expect(ExternalAttachCommand.shellQuoted("/tmp/me's tmux/sock")
            == #"'/tmp/me'\''s tmux/sock'"#)
    }

    @Test("a dollar sign is not expanded, because single quotes interpret nothing")
    func dollarSignSurvivesVerbatim() {
        #expect(ExternalAttachCommand.shellQuoted("/tmp/$HOME/sock") == "'/tmp/$HOME/sock'")
    }
}
