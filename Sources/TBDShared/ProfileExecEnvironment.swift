import Foundation

/// How `tbd profile exec` builds its child's environment from its own and the
/// profile's.
///
/// The child inherits the caller's environment, as `env(1)` and `sudo -E` do,
/// so `PATH`, `HOME` and the working tools still reach it. Two steps then make
/// the profile, and only the profile, decide which account the child runs on:
///
/// 1. **Clear** every variable in `clearedKeys` from the inherited environment.
///    Each of them selects an account, credential or endpoint for `claude`, and
///    one the profile does not set itself would otherwise leak through from the
///    caller. The case that matters: a caller that is itself a session on
///    another token profile carries that profile's `CLAUDE_CODE_OAUTH_TOKEN`,
///    which outranks the login inside a signed-in profile's config dir, so
///    without this step the child would run on the caller's account.
/// 2. **Apply** the profile's environment on top.
public enum ProfileExecEnvironment {
    /// Variables cleared from the inherited environment before the profile's
    /// own are applied.
    ///
    /// Every key the daemon can put in an exec environment for any profile
    /// kind is here, except `AWS_REGION` and `AWS_PROFILE`. Those are
    /// general-purpose: other tools the child runs read them, and `claude`
    /// consults them only when `CLAUDE_CODE_USE_BEDROCK` is set, which is
    /// cleared unless the profile is a Bedrock one. `ANTHROPIC_AUTH_TOKEN` is
    /// set by no profile, but it authenticates `claude` ahead of a config
    /// dir's login just as the other credentials do. A test fences this set
    /// against the keys the daemon's builder produces.
    public static let clearedKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CONFIG_DIR",
    ]

    /// The child's environment: `inherited` without `clearedKeys`, with
    /// `profile` applied on top.
    public static func compose(
        inherited: [String: String],
        profile: [String: String]
    ) -> [String: String] {
        var env = inherited.filter { !clearedKeys.contains($0.key) }
        env.merge(profile) { _, fromProfile in fromProfile }
        return env
    }
}
