import Foundation
import os

/// Answers "may TBD aim `gh` at this host?" by reading the hosts the user has
/// already authenticated `gh` to (`gh auth status`).
///
/// This is a credential boundary, not a forge classifier. A binding's host
/// comes from a URL a remote-lane provider supplied, so it is untrusted, and
/// `gh api --hostname <host>` sends a credential to whatever host it names —
/// for any host other than github.com, `GH_ENTERPRISE_TOKEN` /
/// `GITHUB_ENTERPRISE_TOKEN` from the environment when set. Asking only hosts
/// `gh` already holds a login for means a provider can never make TBD post a
/// token to a host of its choosing; a host outside the list runs nothing and
/// its binding stays unobserved.
///
/// github.com is always allowed and never spawns a subprocess: it is the
/// default host every GitHub query has always used.
///
/// Like `GitLabHostResolver`, only the host LIST is read; the per-host verdict
/// text is not treated as proof that a token works.
actor GitHubHostResolver {
    private let ghRunner: PRStatusManager.GHRunner?

    /// Date seam for when the host list was last read. Compared, not slept
    /// on, so it is data and takes `now:` rather than a `Clock`.
    private let now: @Sendable () -> Date

    private var cachedHosts: Set<String>?
    private var cachedAt: Date?

    private static let log = Logger(subsystem: "com.tbd.daemon", category: "pr.github")

    /// How long a host list `gh` produced is believed before it is read again.
    ///
    /// Every launched answer ages out — empty or not — because a user is one
    /// `gh auth login --hostname …` away from changing it, and a non-empty
    /// list is the norm here (github.com is on it), so caching it for the
    /// daemon's life would hide a newly added Enterprise login until restart.
    /// The window matches `GitLabHostResolver.emptyStatusLifetime`: a fleet's
    /// worth of per-tick lookups collapse into one subprocess, and a new login
    /// is noticed within one background poll interval.
    static let hostListLifetime: TimeInterval = GitLabHostResolver.emptyStatusLifetime

    init(ghRunner: PRStatusManager.GHRunner? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ghRunner = ghRunner
        self.now = now
    }

    func isAuthenticatedHost(_ host: String, repoPath: String) async -> Bool {
        let normalized = host.lowercased()
        if normalized.isEmpty || normalized == "github.com" { return true }
        return await hosts(repoPath: repoPath).contains(normalized)
    }

    /// `gh` failing to launch is never remembered — it is a failure to ask,
    /// not an observation — and answers the empty set, so nothing is queried.
    private func hosts(repoPath: String) async -> Set<String> {
        if let cachedHosts, let cachedAt,
           abs(now().timeIntervalSince(cachedAt)) < Self.hostListLifetime {
            return cachedHosts
        }
        guard let ghRunner, let result = await ghRunner(["auth", "status"], repoPath) else {
            Self.log.debug("gh did not launch; no authenticated GitHub hosts derived")
            return []
        }
        // The exit status is ignored: gh exits 1 when ANY configured host fails
        // to authenticate. Same flush-left host layout as `glab auth status`.
        let parsed = Set(GitLabHostResolver.parseAuthStatusHosts(result.stdout + "\n" + result.stderr)
            .map { $0.lowercased() })
        Self.log.debug("derived gh-authenticated hosts: \(parsed.sorted().joined(separator: ","), privacy: .public)")
        cachedHosts = parsed
        cachedAt = now()
        return parsed
    }
}
