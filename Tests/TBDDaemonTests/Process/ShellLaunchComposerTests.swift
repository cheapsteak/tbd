import Foundation
import Testing
@testable import TBDDaemonLib

/// The composition every spawn path launches through, pinned directly rather
/// than through a transport's builder: the tmux builders and the pty-holder
/// launch both call it, so its tests must not depend on either one.
/// Expectations are hardcoded strings, not derived from the code under test.
@Suite("ShellLaunchComposer")
struct ShellLaunchComposerTests {
    // MARK: - envExportPrefixed

    @Test("an empty env passes the command through unchanged")
    func emptyEnvPassesCommandThrough() {
        #expect(ShellLaunchComposer.envExportPrefixed("claude", env: [:]) == "claude")
        #expect(ShellLaunchComposer.envExportPrefixed("claude --resume", env: [:])
            == "claude --resume")
    }

    @Test("one single-quoted export per entry, in front of the command")
    func oneExportPerEntry() {
        #expect(ShellLaunchComposer.envExportPrefixed(
            "claude", env: ["TBD_TERMINAL_ID": "abc-123"])
            == "export TBD_TERMINAL_ID='abc-123'; claude")
        #expect(ShellLaunchComposer.envExportPrefixed(
            "claude --resume", env: ["CLAUDE_CONFIG_DIR": "/tmp/profile"])
            == "export CLAUDE_CONFIG_DIR='/tmp/profile'; claude --resume")
    }

    /// Sorted by key, so `TBD_PROMPT_INSTRUCTIONS` (a repo's user-authored
    /// text) always lands before `TBD_TERMINAL_ID` — the order the pane
    /// identity resolver's anchoring is designed around.
    @Test("entries are emitted sorted by key")
    func entriesSortedByKey() {
        let command = ShellLaunchComposer.envExportPrefixed("claude", env: [
            "TBD_TERMINAL_ID": "abc-123",
            "CLAUDE_CONFIG_DIR": "/tmp/profile",
            "TBD_PROMPT_INSTRUCTIONS": "be brief",
        ])
        #expect(command == "export CLAUDE_CONFIG_DIR='/tmp/profile'; "
            + "export TBD_PROMPT_INSTRUCTIONS='be brief'; "
            + "export TBD_TERMINAL_ID='abc-123'; claude")
    }

    /// A value's `'` is escaped as `'\''`, so it cannot close the quoting
    /// early. The `TBD_TERMINAL_ID` export anchor relies on exactly this: a
    /// decoy assignment inside a value comes out with an escaped quote, never
    /// as a second clean `export TBD_TERMINAL_ID='<value>'`.
    @Test("a single quote in a value is escaped as '\\''")
    func singleQuoteInValueIsEscaped() {
        #expect(ShellLaunchComposer.envExportPrefixed(
            "claude", env: ["TBD_PROMPT_INSTRUCTIONS": "don't"])
            == #"export TBD_PROMPT_INSTRUCTIONS='don'\''t'; claude"#)
        #expect(ShellLaunchComposer.envExportPrefixed(
            "claude", env: ["TBD_PROMPT_INSTRUCTIONS": "export TBD_TERMINAL_ID='decoy'"])
            == #"export TBD_PROMPT_INSTRUCTIONS='export TBD_TERMINAL_ID='\''decoy'\'''; claude"#)
    }

    // MARK: - shellFlags(forShell:)

    @Test("the flag choice per shell family")
    func shellFlagsPerShellFamily() {
        // Each branch of the flag choice, with hardcoded expectations: csh and
        // tcsh reject -l when combined with -c (measured: "Unknown option: `-l'"),
        // so they keep the pre-login-shell -i -c. Every other shell gets the
        // interactive login -i -l -c. Flags are separate argv elements, never
        // clustered, because some shells (e.g. nushell) reject GNU-style
        // clustering while accepting the individual flags.
        #expect(ShellLaunchComposer.shellFlags(forShell: "/bin/tcsh") == ["-i", "-c"])
        #expect(ShellLaunchComposer.shellFlags(forShell: "/bin/csh") == ["-i", "-c"])
        // The lowercased basename decides, not the full path or its case.
        #expect(ShellLaunchComposer.shellFlags(forShell: "/usr/local/bin/tcsh") == ["-i", "-c"])
        #expect(ShellLaunchComposer.shellFlags(forShell: "/bin/TCSH") == ["-i", "-c"])
        #expect(ShellLaunchComposer.shellFlags(forShell: "/opt/weird/wrappers/deep/path/csh") == ["-i", "-c"])
        #expect(ShellLaunchComposer.shellFlags(forShell: "/bin/zsh") == ["-i", "-l", "-c"])
        #expect(ShellLaunchComposer.shellFlags(forShell: "/bin/bash") == ["-i", "-l", "-c"])
        #expect(ShellLaunchComposer.shellFlags(forShell: "/opt/homebrew/bin/fish") == ["-i", "-l", "-c"])
        // Degenerate paths fall into the default branch rather than crashing.
        #expect(ShellLaunchComposer.shellFlags(forShell: "") == ["-i", "-l", "-c"])
        #expect(ShellLaunchComposer.shellFlags(forShell: "/") == ["-i", "-l", "-c"])
        #expect(ShellLaunchComposer.shellFlags(forShell: "/bin/") == ["-i", "-l", "-c"])
    }

    // MARK: - shellInvocation

    @Test("with no SHELL in the environment, the shell is /bin/zsh")
    func shellInvocationFallsBackToZsh() {
        #expect(ShellLaunchComposer.shellInvocation("claude", environment: [:])
            == ["/bin/zsh", "-i", "-l", "-c", "claude"])
    }

    /// The command is one final positional argument, whatever it contains,
    /// and the flags are the ones `shellFlags(forShell:)` picks for SHELL.
    @Test("SHELL, its flags, then the command as the last argument")
    func shellInvocationUsesSHELLAndItsFlags() {
        #expect(ShellLaunchComposer.shellInvocation(
            "claude --resume", environment: ["SHELL": "/bin/zsh"])
            == ["/bin/zsh", "-i", "-l", "-c", "claude --resume"])
        #expect(ShellLaunchComposer.shellInvocation(
            "claude --resume", environment: ["SHELL": "/bin/tcsh"])
            == ["/bin/tcsh", "-i", "-c", "claude --resume"])
    }

    /// The two together, as every spawn path composes them: the env prefix
    /// rides inside the command string, after the shell's startup files.
    @Test("an env-prefixed command is the single final argument")
    func composedLaunch() {
        let command = ShellLaunchComposer.envExportPrefixed(
            "claude", env: ["TBD_TERMINAL_ID": "abc-123"])
        #expect(ShellLaunchComposer.shellInvocation(command, environment: ["SHELL": "/bin/zsh"])
            == ["/bin/zsh", "-i", "-l", "-c", "export TBD_TERMINAL_ID='abc-123'; claude"])
    }
}
