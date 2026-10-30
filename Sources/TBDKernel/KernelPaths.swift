import Foundation

/// The three paths the helper programs resolve: the config directory, the
/// holders directory inside it, and the host Claude store. Each honors its
/// environment override. `TBDConstants` forwards its members of the same names
/// here, so the logic exists once.
public enum KernelPaths {
    /// Base config directory resolved from the given environment dictionary.
    /// Honors `TBD_HOME`; falls back to `~/tbd` when the key is absent or empty.
    public static func configDir(environment: [String: String]) -> URL {
        if let override = environment["TBD_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("tbd")
    }

    /// Directory holding one socket and one lock file per live pty holder:
    /// `~/tbd/holders`. Honors TBD_HOME.
    ///
    /// Deliberately shallow and directly under the config dir: every holder
    /// socket path must fit Darwin's ~104-byte `sun_path`, and nesting is the
    /// thing that breaks that budget first. `HolderRendezvous` composes the
    /// per-session names inside it and enforces the budget.
    public static func holdersDir(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        configDir(environment: environment).appendingPathComponent("holders")
    }

    /// The host Claude store — `TBD_CLAUDE_HOST_HOME` when set, `~/.claude`
    /// otherwise — resolved from the given environment dictionary.
    ///
    /// **The single resolution point for that override, package-wide.** It
    /// lives in `TBDKernel` because the peer helper's `ShadowPeerRecordStore`
    /// resolves it, and `TBDConstants` forwards to it for `TBDApp`, which does
    /// not link `TBDDaemonLib`:
    /// `LegacyHookSettingsPath` hand-built `homeDirectoryForCurrentUser/.claude`
    /// for a dialog body, which is display-only today but shows the wrong path
    /// under any override and is the exact shape of the leak
    /// `LegacyHookScanner.globalSettingsPath` had.
    /// `ClaudeProfileConfigDirManager.resolveHostBaseDirectory` delegates here.
    public static func claudeHostHome(environment: [String: String]) -> URL {
        if let override = environment["TBD_CLAUDE_HOST_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }
}
