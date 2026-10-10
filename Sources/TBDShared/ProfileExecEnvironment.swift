import Foundation

/// How `tbd profile exec` builds its child's environment from its own and the
/// profile's.
///
/// The child inherits the caller's environment, as `env(1)` and `sudo -E` do,
/// so `PATH`, `HOME` and the working tools still reach it. Two steps then make
/// the profile, and only the profile, decide which account the child runs on:
///
/// 1. **Clear** every variable in `clearedKeys` from the inherited environment.
///    Each of them selects a credential, provider, endpoint or model for
///    `claude`, and one the profile does not set itself would otherwise leak
///    through from the caller. The case that matters: a caller that is itself a
///    session on another token profile carries that profile's
///    `CLAUDE_CODE_OAUTH_TOKEN`, which outranks the login inside a signed-in
///    profile's config dir, so without this step the child would run on the
///    caller's account.
/// 2. **Apply** the profile's environment on top.
public enum ProfileExecEnvironment {
    /// Variables cleared from the inherited environment before the profile's
    /// own are applied: `profileKeys` and `otherSelectors`.
    public static let clearedKeys: Set<String> = profileKeys.union(otherSelectors)

    /// Every key the daemon can put in an exec environment for some profile
    /// kind, except `AWS_REGION` and `AWS_PROFILE`. Those are general-purpose:
    /// other tools the child runs read them, and `claude` consults them only
    /// when `CLAUDE_CODE_USE_BEDROCK` is set, which is cleared unless the
    /// profile is a Bedrock one. A test holds this set equal to the keys the
    /// daemon's builder produces, minus those two.
    public static let profileKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CONFIG_DIR",
    ]

    /// Variables no profile sets, each of which still chooses the credential,
    /// provider, endpoint or model a `claude` process uses. Inherited from a
    /// caller, any of them would override or redirect the profile's account,
    /// so they are cleared too. A profile that needs one sets it in its env
    /// overrides, which are applied after the clear. Provider-specific
    /// location settings that other tools also read (`AWS_REGION`,
    /// `CLOUD_ML_REGION`) stay inherited, for the reason given on
    /// `profileKeys`.
    public static let otherSelectors: Set<String> = [
        // Credentials that authenticate ahead of a config dir's login.
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_CUSTOM_HEADERS",
        "AWS_BEARER_TOKEN_BEDROCK",
        // Providers other than the profile's.
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CODE_USE_FOUNDRY",
        "CLAUDE_CODE_SKIP_BEDROCK_AUTH",
        "CLAUDE_CODE_SKIP_VERTEX_AUTH",
        "ANTHROPIC_BEDROCK_BASE_URL",
        "ANTHROPIC_VERTEX_BASE_URL",
        "ANTHROPIC_VERTEX_PROJECT_ID",
        // Models, beside the profile's own ANTHROPIC_MODEL.
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
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
