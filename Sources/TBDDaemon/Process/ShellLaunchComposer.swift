import Foundation

/// How a terminal's program is launched through the user's shell: the
/// `export KEY='value'; ` prefix that carries the `env` map, and the
/// `$SHELL <flags> <command>` argv that runs it.
///
/// Transport-neutral on purpose. The tmux spawn builders
/// (`TmuxManager.newWindowCommand`, `TmuxManager.respawnWindowCommand`) and
/// the pty-holder launch (`WorktreeLifecycle.holderLaunch`) all compose
/// through here, so the two transports start the *same* program in the
/// *same* shell, and the per-shell flag choice cannot fork between them.
enum ShellLaunchComposer {
    /// Prefix `shellCommand` with one `export KEY='value'; ` per `env` entry,
    /// sorted by key, single-quoting each value with the standard `'\''`
    /// escape for an embedded quote.
    ///
    /// Shared by every spawn path deliberately.
    /// `TmuxManager.resolvePaneTerminalID` reads a pane's identity back out of
    /// exactly this text, anchored on `TmuxManager.terminalIDExportAnchor`,
    /// and that anchor is only safe while every spawn path emits the
    /// identical shape. Two independently maintained copies could drift and
    /// reopen the forgery hole on one path.
    static func envExportPrefixed(_ shellCommand: String, env: [String: String]) -> String {
        var envPrefix = ""
        for (key, value) in env.sorted(by: { $0.key < $1.key }) {
            envPrefix += "export \(key)=\(shellEscape(value)); "
        }
        return envPrefix.isEmpty ? shellCommand : "\(envPrefix)\(shellCommand)"
    }

    /// Shell flags for spawning the user's shell with a command string,
    /// chosen by the shell's lowercased basename (the same derivation as
    /// `CLIInstaller.shellRCAndExport`, so "/bin/TCSH" and wrapper paths
    /// behave consistently across both). Flags are separate argv elements
    /// (`-i -l -c`, never clustered `-ilc`): some shells (e.g. nushell)
    /// accept the individual flags but reject GNU-style clustering, and a
    /// rejected spawn kills every pane silently. csh and tcsh cannot combine
    /// -l with -c at all (tcsh accepts -l only as its sole argument), so
    /// they keep the pre-login-shell `-i -c`; every other shell gets
    /// `-i -l -c` (interactive login shell, see
    /// docs/specs/2026-08-19-login-shell-panes-design.md).
    ///
    /// Measured on this macOS host (2026-08-19), separate flags behaving
    /// identically to the clustered forms:
    ///   zsh  -i -l -c 'echo ok' -> ok, exit 0 (same as -ilc)
    ///   bash -i -l -c 'echo ok' -> ok, exit 0 (same as -ilc)
    ///   dash -i -l -c 'echo ok' -> ok, exit 0 (same as -ilc)
    ///   tcsh -i -c 'echo ok' -> ok, exit 0 (same as -ic);
    ///        tcsh -i -l -c -> exit 1, "Unknown option: `-l'"
    ///   csh  -i -c 'echo ok' -> ok, exit 0 (same as -ic);
    ///        csh  -i -l -c -> exit 1, "Unknown option: `-l'"
    ///   (fish not installed to measure)
    static func shellFlags(forShell shellPath: String) -> [String] {
        let basename = (shellPath as NSString).lastPathComponent.lowercased()
        switch basename {
        case "csh", "tcsh":
            return ["-i", "-c"]
        default:
            return ["-i", "-l", "-c"]
        }
    }

    /// The `[shell] + flags + [command]` argv every spawn path runs. Shared
    /// for the same drift-hazard reason as `envExportPrefixed`: the tmux
    /// builders and the holder launch must spawn through the identical shell
    /// invocation, and the per-shell flag choice (`shellFlags(forShell:)`)
    /// must not fork between them. The defaulted `environment` parameter is
    /// the test seam for the SHELL read, matching the
    /// `TBDConstants.*(environment:)` idiom.
    static func shellInvocation(
        _ fullCommand: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let userShell = environment["SHELL"] ?? "/bin/zsh"
        return [userShell] + shellFlags(forShell: userShell) + [fullCommand]
    }
}
