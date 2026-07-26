import Foundation

/// Deterministic (not heuristic) matching of a provider-reported
/// `meta["repo"]` string (`docs/remote-provider-contract.md` § Session
/// object — `repo`/`branch` are well-known optional `meta` keys a caller MAY
/// interpret) against TBD's locally registered repos.
///
/// Both sides are normalized to a lowercase "org/name" comparison key by
/// stripping scheme, any `user@` prefix, host, trailing `.git`, and trailing
/// slash — so `git@github.com:acme/api.git`, `https://github.com/acme/api`,
/// and a bare `acme/api` all normalize to the same key ("acme/api") and
/// therefore match each other.
///
/// Deliberately NOT matched: two repos whose org OR name differ at all
/// (`acme/api` vs `acme/api-tools`, or `acme/api` vs `other-org/api`) —
/// every non-host path segment must agree exactly, case-insensitively, with
/// no prefix/suffix leniency. Host is intentionally excluded from the
/// comparison (a provider that only reports a bare `acme/api`, with no host,
/// must still match a local repo's fully-qualified `remoteURL`) — the
/// accepted tradeoff is that two distinct repos sharing the same org/name on
/// two different hosts (e.g. a self-hosted GitLab mirror of a GitHub repo)
/// would collide. The contract does not attempt to solve that; it's rare
/// enough in practice to accept.
public enum RemoteRepoMatching {
    /// Normalizes a git remote URL (`https://`, `ssh://`, or scp-like
    /// `user@host:org/name` syntax) or a bare `org/name` string to a
    /// lowercase "org/name" comparison key. Returns nil when fewer than two
    /// non-empty path segments are present — nothing meaningful to compare.
    public static func normalizedKey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var s = trimmed
        if let schemeRange = s.range(of: "://") {
            s = String(s[schemeRange.upperBound...])
        } else if let colonIndex = s.firstIndex(of: ":") {
            // scp-like syntax ("git@host:org/name") uses ':' where a URL
            // would use '/' before the path — normalize it so both split
            // into path segments the same way below.
            s.replaceSubrange(colonIndex...colonIndex, with: "/")
        }

        // Taking only the LAST TWO "/"-separated segments is what makes the
        // host (and any `user@` prefix riding along with it in the first
        // segment) fall out for free — no separate stripping step needed.
        let parts = s.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let org = parts[parts.count - 2]
        var name = parts[parts.count - 1]
        if name.lowercased().hasSuffix(".git") {
            name = String(name.dropLast(4))
        }
        guard !org.isEmpty, !name.isEmpty else { return nil }
        return "\(org.lowercased())/\(name.lowercased())"
    }

    /// Resolves `metaRepo` (a provider's `meta["repo"]` value) against
    /// `repos` by comparing normalized keys. Returns the first matching
    /// repo's id in `repos` order, or nil when `metaRepo` is nil/blank,
    /// unparseable, or no repo's `remoteURL` normalizes to the same key.
    public static func resolveRepoID(metaRepo: String?, repos: [Repo]) -> UUID? {
        guard let metaRepo, let targetKey = normalizedKey(metaRepo) else { return nil }
        for repo in repos {
            guard let remoteURL = repo.remoteURL, let key = normalizedKey(remoteURL) else { continue }
            if key == targetKey { return repo.id }
        }
        return nil
    }
}
