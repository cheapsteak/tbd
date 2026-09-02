import Foundation
import TBDShared

/// App-side presentation of a model profile's login identity — the
/// `ModelProfileWithUsage.loginIdentity` email the daemon reads from the
/// profile's isolated config dir at list time.
///
/// Pure string composition, extracted from the views (Settings rows, the "+"
/// new-tab menu, the menu-bar profile switcher) so the badge/caption/suffix
/// rules are unit-testable without UI.
///
/// A nil identity is ambiguous: the profile may genuinely need `/login`, or
/// the daemon may predate the field. The two are indistinguishable, so the
/// nil-case copy is phrased as an observation ("no login detected") rather
/// than a hard claim.
enum ProfileLoginPresentation {
    /// Trimmed, non-empty identity — nil when the daemon reported no login.
    static func normalizedIdentity(_ loginIdentity: String?) -> String? {
        guard let trimmed = loginIdentity?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// True when this is an oauth profile with no detected login — the state
    /// that warrants the "needs /login" hint and the one-click login affordance.
    ///
    /// Deliberately false for `.oauthToken` whatever `loginIdentity` says. A
    /// token profile authenticates by its stored `claude setup-token`, and a
    /// `/login` run inside its config dir would be shadowed by that token
    /// anyway — the injected `CLAUDE_CODE_OAUTH_TOKEN` outranks a stored
    /// credential. Offering the affordance would advertise a step that
    /// changes nothing, which is the very friction this kind removes.
    static func needsLogin(kind: CredentialKind, loginIdentity: String?) -> Bool {
        kind == .oauth && normalizedIdentity(loginIdentity) == nil
    }

    /// Short suffix for menu rows: " — <email>" / " — needs /login" for oauth
    /// profiles, "" for every other kind. Kept terse — NSMenu width is precious.
    static func menuTitleSuffix(kind: CredentialKind, loginIdentity: String?) -> String {
        guard kind == .oauth else { return "" }
        if let identity = normalizedIdentity(loginIdentity) { return " — \(identity)" }
        return " — needs /login"
    }

    /// Full menu-row title for a profile entry.
    static func menuItemTitle(for entry: ModelProfileWithUsage) -> String {
        entry.profile.tabDisplayName
            + menuTitleSuffix(kind: entry.profile.kind, loginIdentity: entry.loginIdentity)
    }

    /// Identity fragment for the Settings row caption. nil for non-oauth kinds.
    static func identityCaption(kind: CredentialKind, loginIdentity: String?) -> String? {
        guard kind == .oauth else { return nil }
        if let identity = normalizedIdentity(loginIdentity) { return "Logged in as \(identity)" }
        return "No login detected — run /login once"
    }

    /// `Token •••• 4f2a` — the credential fragment of a token profile's
    /// Settings caption, built from the last-four tail the daemon computes at
    /// list time (the app never holds the secret).
    ///
    /// Honest about *which* credential is installed without claiming an
    /// identity TBD cannot verify — the profile endpoint 403s for setup
    /// tokens — and enough to tell two token profiles apart.
    ///
    /// nil when no tail arrived: an older daemon, or a profile whose secret
    /// file has gone missing. Neither warrants inventing a tail.
    static func maskedTokenCaption(tokenTail: String?) -> String? {
        guard let tail = normalizedIdentity(tokenTail) else { return nil }
        return "Token •••• \(tail)"
    }

    /// True when a token profile's stored token was rejected by the API — the
    /// usage probe got 401/403 and recorded `.needsLogin`. Drives the row's
    /// warning caption and its inline "Replace token…" affordance.
    ///
    /// Never true for another kind: `.needsLogin` on an `.oauth` profile means
    /// "run /login again", which is a different repair with a different
    /// affordance.
    static func tokenRejected(for entry: ModelProfileWithUsage) -> Bool {
        entry.profile.kind == .oauthToken
            && entry.usageSnapshot?.statusKind == .needsLogin
    }

    /// Settings-row caption. For oauth profiles this replaces the static
    /// "Run /login once" prefix of `ModelProfile.detailCaption` with the live
    /// identity fragment while keeping the endpoint details (via baseURL ·
    /// model) in the same order. Token profiles lead with the masked tail in
    /// that same slot. Other kinds fall back to `detailCaption`.
    static func settingsCaption(for entry: ModelProfileWithUsage) -> String? {
        let profile = entry.profile
        switch profile.kind {
        case .oauth:
            var parts: [String] = []
            if let identity = identityCaption(kind: profile.kind,
                                              loginIdentity: entry.loginIdentity) {
                parts.append(identity)
            }
            parts.append(contentsOf: endpointFragments(profile))
            return parts.joined(separator: " · ")
        case .oauthToken:
            // No identity line: the profile endpoint is 403 for setup tokens,
            // so there is no email to show. That is a real limitation of the
            // credential, not a gap to paper over.
            var parts: [String] = []
            if let masked = maskedTokenCaption(tokenTail: entry.tokenTail) {
                parts.append(masked)
            }
            parts.append(contentsOf: endpointFragments(profile))
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .apiKey, .bedrock:
            return profile.detailCaption
        }
    }

    /// The "via <baseURL>" / "<model>" tail shared by the oauth and token
    /// caption shapes, in that order.
    private static func endpointFragments(_ profile: ModelProfile) -> [String] {
        var parts: [String] = []
        if let baseURL = profile.baseURL { parts.append("via \(baseURL)") }
        if let model = profile.model, !model.isEmpty { parts.append(model) }
        return parts
    }
}
