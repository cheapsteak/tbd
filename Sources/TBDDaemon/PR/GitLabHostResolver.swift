import Foundation
import os

/// Behavior seam for the `glab` subprocess, mirroring `GHRunner`. Production
/// leaves it nil and shells out; tests inject a runner so host derivation can
/// be driven without a `glab` binary. `nil` means "glab did not launch".
typealias GLRunner = @Sendable (_ args: [String], _ repoPath: String) async -> GHCommandResult?

/// Answers "is this host a GitLab instance?" by reading what the user already
/// told `glab`.
///
/// The declaration and the capability are one precondition: a host appears in
/// `glab auth status` only because someone ran `glab auth login --hostname`,
/// and that same act is what makes API calls work. So TBD can never conclude
/// "this is GitLab" for a host it then cannot query.
///
/// Only the host LIST is read. The per-host verdict text is not trustworthy —
/// a working host has been observed printing "Logged in" and "Invalid token"
/// together while every call succeeded — so authentication is proven by a call
/// succeeding, never by this output.
actor GitLabHostResolver {
    private let glRunner: GLRunner?
    private var cachedHosts: Set<String>?
    private static let log = Logger(subsystem: "com.tbd.daemon", category: "pr.gitlab")

    init(glRunner: GLRunner? = nil) {
        self.glRunner = glRunner
    }

    func isGitLabHost(_ host: String, repoPath: String) async -> Bool {
        // github.com short-circuits before any subprocess, so a GitHub-only
        // fleet never spawns glab.
        let normalized = host.lowercased()
        guard normalized != "github.com" else { return false }
        return await hosts(repoPath: repoPath).contains(normalized)
    }

    /// Only a non-empty derivation is cached. An empty set is never an
    /// observation that the fleet has no GitLab hosts — `fetchHosts` returns it
    /// just as readily when `glab` is absent, fails to launch, or prints
    /// something unparseable — so remembering it would mean a user who runs
    /// `glab auth login --hostname …` after the daemon started, or one
    /// transient failure on the first poll after boot, gets no GitLab until the
    /// next restart, with no message anywhere. The spec's "cached for the
    /// daemon run, so nothing needs invalidating" reasons about caching a
    /// derived truth; it does not license caching a failure to derive.
    ///
    /// Retrying costs nothing on the fleet this cache exists for: `github.com`
    /// short-circuits in `isGitLabHost` before reaching here, so a GitHub-only
    /// fleet still spawns no `glab` at all. Only a host that is neither
    /// `github.com` nor a declared GitLab host re-probes, and it does so
    /// precisely because the answer for it is still unknown.
    private func hosts(repoPath: String) async -> Set<String> {
        if let cachedHosts { return cachedHosts }
        let resolved = await fetchHosts(repoPath: repoPath)
        guard !resolved.isEmpty else { return resolved }
        cachedHosts = resolved
        return resolved
    }

    private func fetchHosts(repoPath: String) async -> Set<String> {
        guard let glRunner else { return [] }
        // The exit status is ignored deliberately: glab exits 1 when ANY
        // configured host fails to authenticate, so a perfectly good setup
        // reports failure whenever an unused gitlab.com entry shares the config.
        guard let result = await glRunner(["auth", "status"], repoPath) else {
            Self.log.debug("glab did not launch; no GitLab hosts derived")
            return []
        }
        let parsed = Set(Self.parseAuthStatusHosts(result.stdout + "\n" + result.stderr)
            .map { $0.lowercased() })
        Self.log.debug("derived GitLab hosts: \(parsed.sorted().joined(separator: ","), privacy: .public)")
        return parsed
    }

    /// Host names are the flush-left lines; everything glab knows about a host
    /// is indented beneath it.
    static func parseAuthStatusHosts(_ output: String) -> [String] {
        var out: [String] = []
        // Split on any newline, and trim newlines as well as spaces. CRLF is
        // the reason for both. Swift reads "\r\n" as ONE Character, so
        // `split(separator: "\n")` finds no separator in CRLF output at all and
        // hands the whole transcript back as a single "line" — which the
        // no-spaces guard then rejects, leaving no hosts and GitLab silently
        // off with no error anywhere. `\r` alone would survive
        // `.whitespaces` too, which is spaces and tabs only.
        for line in output.split(whereSeparator: \.isNewline) {
            guard let first = line.first, !first.isWhitespace else { continue }
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // A hostname line has no spaces and at least one dot.
            guard !candidate.isEmpty, !candidate.contains(" "), candidate.contains(".") else { continue }
            if !out.contains(candidate) { out.append(candidate) }
        }
        return out
    }
}
