import Foundation

/// Merges free-form env overrides across scopes. Precedence: global < repo <
/// profile (a more specific scope wins collisions). Pure — unit-test seam for
/// the precedence rule. NOTE: the Claude builder's auth/routing env is layered
/// ON TOP of this result at spawn time (see WorktreeLifecycle+Create), so it is
/// never overridden by free-form vars.
enum EnvOverrideResolver {
    static func merge(
        global: [String: String]?,
        repo: [String: String]?,
        profile: [String: String]?
    ) -> [String: String] {
        var merged = global ?? [:]
        if let repo { merged.merge(repo) { _, new in new } }
        if let profile { merged.merge(profile) { _, new in new } }
        return merged
    }
}
