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

    /// Settings-row caption. For oauth profiles this replaces the static
    /// "Run /login once" prefix of `ModelProfile.detailCaption` with the live
    /// identity fragment while keeping the endpoint details (via baseURL ·
    /// model) in the same order. Other kinds fall back to `detailCaption`.
    static func settingsCaption(for entry: ModelProfileWithUsage) -> String? {
        let profile = entry.profile
        guard profile.kind == .oauth else { return profile.detailCaption }
        var parts: [String] = []
        if let identity = identityCaption(kind: profile.kind, loginIdentity: entry.loginIdentity) {
            parts.append(identity)
        }
        if let baseURL = profile.baseURL { parts.append("via \(baseURL)") }
        if let model = profile.model, !model.isEmpty { parts.append(model) }
        return parts.joined(separator: " · ")
    }
}
