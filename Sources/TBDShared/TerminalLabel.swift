/// Canonical labels the daemon assigns to terminals it creates. The app keys
/// classification decisions (pre-session banner, primary-terminal detection,
/// startup recovery) off these labels, so daemon and app must agree.
public enum TerminalLabel {
    /// Blocking `preSession` hook terminal (WorktreeLifecycle+PreSession).
    public static let preSession = "pre-session"
    /// Parallel `setup` hook terminal (spawnPrimaryTerminals in WorktreeLifecycle+Create).
    public static let setup = "setup"
    /// Plain shell terminal.
    public static let shell = "shell"
    /// Claude Code agent terminal.
    public static let claudeCode = "Claude Code"
    /// Codex agent terminal.
    public static let codex = "Codex"
    /// Profile login-session terminal (Settings → "Open login session"):
    /// a Claude session pinned to an OAuth profile, spawned so the user can
    /// run `/login` into the profile's isolated config dir. The daemon
    /// auto-types `/login` into terminals carrying this label, and the app
    /// dedupes "Open login session" clicks against it.
    public static let login = "login"
}
