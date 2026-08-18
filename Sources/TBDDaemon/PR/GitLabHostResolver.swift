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

    /// Date seam for the one timestamp this actor keeps: when `glab` last ran
    /// and named no host. It is compared, not slept on, so it is data and takes
    /// `now:` rather than a `Clock` (`Duration` is behavior, `Date` is data).
    /// This actor schedules nothing, so it has no clock at all.
    private let now: @Sendable () -> Date

    private var cachedHosts: Set<String>?

    /// When `glab` last ran to completion and named no host, or nil if that has
    /// not happened (or the answer has since aged out).
    private var lastEmptyStatusAt: Date?

    private static let log = Logger(subsystem: "com.tbd.daemon", category: "pr.gitlab")

    /// How long "glab ran and named no host" is believed before it is asked
    /// again.
    ///
    /// This is the only knob trading two costs against each other. Below it
    /// sits the poll cadence — `GitPollCadence.prInterval` is 30 s in the
    /// foreground, and every distinct worktree path on the tick asks this
    /// actor — so a window of one full interval already collapses a fleet's
    /// worth of `glab auth status` spawns per tick into one. Above it sits how
    /// long a user who has just run `glab auth login --hostname …` waits for
    /// TBD to notice. Five minutes is ten foreground ticks of silence for a
    /// wait no longer than the background poll interval itself.
    static let emptyStatusLifetime: TimeInterval = 300

    init(glRunner: GLRunner? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.glRunner = glRunner
        self.now = now
    }

    func isGitLabHost(_ host: String, repoPath: String) async -> Bool {
        // github.com short-circuits before any subprocess, so a GitHub-only
        // fleet never spawns glab.
        let normalized = host.lowercased()
        guard normalized != "github.com" else { return false }
        return await hosts(repoPath: repoPath).contains(normalized)
    }

    /// Three outcomes, remembered for three different spans, because they are
    /// three different facts.
    ///
    /// **A non-empty derivation is cached for the resolver's life.** It is a
    /// derived truth about a declaration the user made; nothing invalidates it.
    ///
    /// **`glab` failing to launch is never remembered.** It is not an
    /// observation that the fleet has no GitLab hosts, just a failure to ask —
    /// the binary is absent, or one exec failed transiently. Remembering it
    /// would mean a user who installs `glab` mid-run, or one bad first poll
    /// after boot, gets no GitLab until the next restart with no message
    /// anywhere. Retrying costs nothing in the case that dominates: `glab`
    /// absent resolves to a static nil path, so no subprocess is spawned at
    /// all.
    ///
    /// **`glab` running and naming no host ages out after
    /// `emptyStatusLifetime`.** That one *is* an observation, and it is the
    /// steady state of every fleet with `glab` installed and no GitLab host
    /// configured — so re-deriving it per call means one subprocess per
    /// worktree per poll tick, forever, for an answer that has not changed.
    /// It cannot be cached for the run either: the same user is one
    /// `glab auth login --hostname …` away from making it wrong. A bounded
    /// window is what both facts allow, and it is bounded on the side that
    /// matters — the answer is at worst `emptyStatusLifetime` stale, never
    /// stale until restart.
    ///
    /// Note also that `github.com` short-circuits in `isGitLabHost` before
    /// reaching here, so none of this is on a pure GitHub.com fleet's path. It
    /// is on a GitHub Enterprise, Bitbucket, gitea or codeberg fleet's path,
    /// which is why the empty answer has to be cheap.
    private func hosts(repoPath: String) async -> Set<String> {
        if let cachedHosts { return cachedHosts }
        if let lastEmptyStatusAt, !isStale(lastEmptyStatusAt) { return [] }

        guard let derived = await fetchHosts(repoPath: repoPath) else {
            Self.log.debug("glab did not launch; no GitLab hosts derived")
            return []
        }
        guard !derived.isEmpty else {
            lastEmptyStatusAt = now()
            return []
        }
        cachedHosts = derived
        return derived
    }

    /// `abs`, because the wall clock this reads can step backwards. A magnitude
    /// test makes a backwards jump re-derive early — the safe direction —
    /// rather than pinning the empty answer in place until the clock catches up.
    private func isStale(_ stamp: Date) -> Bool {
        abs(now().timeIntervalSince(stamp)) >= Self.emptyStatusLifetime
    }

    /// The host list `glab` named, or nil if `glab` did not launch — a
    /// distinction the caller pays attention to, so it must not collapse here.
    private func fetchHosts(repoPath: String) async -> Set<String>? {
        guard let glRunner else { return nil }
        // The exit status is ignored deliberately: glab exits 1 when ANY
        // configured host fails to authenticate, so a perfectly good setup
        // reports failure whenever an unused gitlab.com entry shares the config.
        guard let result = await glRunner(["auth", "status"], repoPath) else { return nil }
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
