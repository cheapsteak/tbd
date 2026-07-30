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
    /// Shared parsing behind both `normalizedKey` (matching) and
    /// `displayKey` (prefill) — the one place that understands a git remote
    /// URL's (`https://`, `ssh://`, or scp-like `user@host:org/name`) or bare
    /// `org/name` string's shape. Returns the raw, un-lowercased (org, name)
    /// pair, or nil when fewer than two non-empty path segments are present
    /// — nothing meaningful to compare/display.
    private static func segments(_ raw: String) -> (org: String, name: String)? {
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
        return (org, name)
    }

    /// Normalizes a git remote URL (`https://`, `ssh://`, or scp-like
    /// `user@host:org/name` syntax) or a bare `org/name` string to a
    /// lowercase "org/name" comparison key. Returns nil when fewer than two
    /// non-empty path segments are present — nothing meaningful to compare.
    public static func normalizedKey(_ raw: String) -> String? {
        guard let (org, name) = segments(raw) else { return nil }
        return "\(org.lowercased())/\(name.lowercased())"
    }

    /// Same parsing as `normalizedKey`, but preserves the source's original
    /// casing ("Acme/API" stays "Acme/API" rather than becoming
    /// "acme/api") — for DISPLAY/PREFILL contexts
    /// (`RemoteCreateFormLogic.repoPrefill`), where a provider that uses the
    /// value verbatim (e.g. cloning against a case-sensitive host) needs the
    /// repo's real casing. MATCHING must keep using `normalizedKey` on both
    /// sides — this is display-only and intentionally not used by
    /// `resolveRepoID`.
    public static func displayKey(_ raw: String) -> String? {
        guard let (org, name) = segments(raw) else { return nil }
        return "\(org)/\(name)"
    }

    /// Resolves `metaRepo` (a provider's `meta["repo"]` value) against
    /// `repos` by comparing normalized keys. Returns the first matching
    /// repo's id in `repos` order, or nil when `metaRepo` is nil/blank,
    /// unparseable, or no repo matches.
    ///
    /// Two passes, in this order — an exact `remoteURL` match must never lose
    /// to the rename fallback, which is why this cannot be a single loop:
    ///
    /// 1. Exact: the provider's `org/name` equals the repo's `remoteURL`
    ///    `org/name`. This is the normal case and the only one before renames
    ///    were considered.
    /// 2. Renamed-repo fallback: the **org** still agrees, and the provider's
    ///    `name` equals the repo's local directory name. See
    ///    `renamedRepoFallbackID` for why that is a real signal rather than a
    ///    guess.
    public static func resolveRepoID(metaRepo: String?, repos: [Repo]) -> UUID? {
        guard let metaRepo, let target = segments(metaRepo) else { return nil }
        let targetKey = "\(target.org.lowercased())/\(target.name.lowercased())"

        for repo in repos {
            guard let remoteURL = repo.remoteURL, let key = normalizedKey(remoteURL) else { continue }
            if key == targetKey { return repo.id }
        }
        return renamedRepoFallbackID(target: target, repos: repos)
    }

    /// Second pass of `resolveRepoID`: tolerate a repo that has been **renamed
    /// on the host** since the provider learned its name.
    ///
    /// A provider reports whatever name it clones by, and a host like GitHub
    /// keeps serving the old name via a redirect indefinitely — so a provider
    /// can go on reporting `acme/old-name` long after the repo became
    /// `acme/new-name`, and pass 1 will never match it. Resolving the redirect
    /// would mean a network call from a pure matching function, so instead we
    /// use a signal already on disk: **a rename on the host does not rename
    /// anyone's local clone directory**, so the directory usually still
    /// carries the old name — the same name the provider is reporting.
    ///
    /// Deliberately kept narrow, because this is the one heuristic in an
    /// otherwise deterministic matcher:
    ///
    /// - The org must still match the repo's `remoteURL`, so this can only
    ///   ever pair repos already known to live under the same owner. It cannot
    ///   introduce a cross-org match.
    /// - Only the directory's own name is compared, never a path prefix.
    /// - It runs only after pass 1 found nothing, so it can never override a
    ///   real `remoteURL` match.
    ///
    /// Like pass 1, this returns the **first** match in `repos` order rather
    /// than treating several as ambiguous. The same repo registered at two
    /// paths is ordinary (a primary clone plus a worktree root), and it is
    /// exactly the shape this fallback sees — both clones keep the old
    /// directory name, so both match. Pass 1 already resolves that case by
    /// taking the first; refusing to choose here would only mean the sessions
    /// stay ungrouped for the users most likely to hit a rename.
    private static func renamedRepoFallbackID(
        target: (org: String, name: String), repos: [Repo]
    ) -> UUID? {
        let wantOrg = target.org.lowercased()
        let wantName = target.name.lowercased()

        return repos.first { repo in
            guard let remoteURL = repo.remoteURL,
                  let local = segments(remoteURL),
                  local.org.lowercased() == wantOrg else { return false }
            // Compare against the clone's directory name, not its remote name.
            let directory = (repo.path as NSString).lastPathComponent.lowercased()
            return directory == wantName
        }?.id
    }
}
