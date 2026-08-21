/// Canonical labels the daemon assigns to terminals it creates. The app keys
/// classification decisions (pre-session banner, primary-terminal detection,
/// startup recovery) off these labels, so daemon and app must agree.
///
/// These are **identities the daemon assigns**, never text a caller supplies.
/// A row wearing one is a claim about how it was spawned, and consumers on both
/// sides of the socket read it as such — so free text arriving over RPC (a
/// `terminal.create` `cmd`, say) must pass through `userSupplied(_:)` before it
/// can become a row's label.
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
    /// run `/login` into the profile's isolated config dir. The daemon spawns
    /// it with an auto-`/login` pump attached and the app dedupes "Open login
    /// session" clicks against this label.
    public static let login = "login"

    /// Every identity above, as one set: the labels a caller may not claim.
    ///
    /// Membership is exact — these strings *are* the identities, and every
    /// consumer compares them with `==`. A command that merely resembles one
    /// (`codex` beside `Codex`) is a different string and stays a plain label.
    public static let reserved: Set<String> = [
        preSession, setup, shell, claudeCode, codex, login,
    ]

    /// A caller-supplied label, or `nil` when it claims one of the identities
    /// above.
    ///
    /// The trade is deliberate: a colliding label is dropped rather than
    /// refused, because the label is a tab title and turning away an otherwise
    /// valid spawn over the wording of its command would cost more than the
    /// generic title the row falls back to.
    public static func userSupplied(_ candidate: String?) -> String? {
        guard let candidate, !reserved.contains(candidate) else { return nil }
        return candidate
    }
}
