import Testing
import Foundation
@testable import TBDShared

/// Task 9d (remote worktrees inside repo sections). Covers
/// `RemoteRepoMatching`'s URL normalization and repo resolution — the
/// deterministic (not heuristic) matching of a provider's `meta["repo"]`
/// against locally registered repos' `remoteURL`.
@Suite("RemoteRepoMatching")
struct RemoteRepoMatchingTests {

    // MARK: - normalizedKey — shapes that MUST match each other

    @Test func normalizedKey_httpsURL() {
        #expect(RemoteRepoMatching.normalizedKey("https://github.com/acme/api") == "acme/api")
    }

    @Test func normalizedKey_httpsURLWithDotGitSuffix() {
        #expect(RemoteRepoMatching.normalizedKey("https://github.com/acme/api.git") == "acme/api")
    }

    @Test func normalizedKey_scpLikeSSHSyntax() {
        #expect(RemoteRepoMatching.normalizedKey("git@github.com:acme/api.git") == "acme/api")
    }

    @Test func normalizedKey_sshSchemeURL() {
        #expect(RemoteRepoMatching.normalizedKey("ssh://git@github.com/acme/api.git") == "acme/api")
    }

    @Test func normalizedKey_bareOrgName() {
        #expect(RemoteRepoMatching.normalizedKey("acme/api") == "acme/api")
    }

    @Test func normalizedKey_trailingSlash() {
        #expect(RemoteRepoMatching.normalizedKey("https://github.com/acme/api/") == "acme/api")
    }

    @Test func normalizedKey_isCaseInsensitive() {
        #expect(RemoteRepoMatching.normalizedKey("https://github.com/Acme/API") == "acme/api")
    }

    @Test func normalizedKey_differentHostsStillNormalizeTheSame() {
        // Deliberate: host is excluded from the comparison key so a bare
        // "org/name" from a provider that reports no host still matches a
        // fully-qualified local remoteURL. See the type's doc comment for
        // the accepted tradeoff.
        let github = RemoteRepoMatching.normalizedKey("https://github.com/acme/api")
        let gitlab = RemoteRepoMatching.normalizedKey("https://gitlab.example.com/acme/api")
        #expect(github == gitlab)
    }

    // MARK: - normalizedKey — must NOT collapse to the same key

    @Test func normalizedKey_differentRepoNameUnderSameOrgIsDifferentKey() {
        let a = RemoteRepoMatching.normalizedKey("acme/api")
        let b = RemoteRepoMatching.normalizedKey("acme/api-tools")
        #expect(a != b)
    }

    @Test func normalizedKey_differentOrgSameRepoNameIsDifferentKey() {
        let a = RemoteRepoMatching.normalizedKey("acme/api")
        let b = RemoteRepoMatching.normalizedKey("other-org/api")
        #expect(a != b)
    }

    @Test func normalizedKey_emptyStringIsNil() {
        #expect(RemoteRepoMatching.normalizedKey("") == nil)
    }

    @Test func normalizedKey_blankStringIsNil() {
        #expect(RemoteRepoMatching.normalizedKey("   ") == nil)
    }

    @Test func normalizedKey_singleSegmentIsNil() {
        // No org component to compare — ambiguous, not a match candidate.
        #expect(RemoteRepoMatching.normalizedKey("just-a-name") == nil)
    }

    // MARK: - displayKey — same parsing as normalizedKey, casing preserved

    @Test func displayKey_preservesOriginalCasing() {
        // Fix pass 1 (task-10 review finding 6): unlike `normalizedKey`,
        // `displayKey` must NOT lowercase — a provider using the prefilled
        // value verbatim (e.g. cloning against a case-sensitive host) needs
        // the repo's real casing.
        #expect(RemoteRepoMatching.displayKey("https://github.com/Acme/API") == "Acme/API")
    }

    @Test func displayKey_stripsDotGitSuffixLikeNormalizedKey() {
        #expect(RemoteRepoMatching.displayKey("https://github.com/Acme/API.git") == "Acme/API")
    }

    @Test func displayKey_scpLikeSSHSyntax() {
        #expect(RemoteRepoMatching.displayKey("git@github.com:Acme/API.git") == "Acme/API")
    }

    @Test func displayKey_bareOrgNameUnchanged() {
        #expect(RemoteRepoMatching.displayKey("Acme/API") == "Acme/API")
    }

    @Test func displayKey_emptyStringIsNil() {
        #expect(RemoteRepoMatching.displayKey("") == nil)
    }

    @Test func displayKey_singleSegmentIsNil() {
        #expect(RemoteRepoMatching.displayKey("just-a-name") == nil)
    }

    @Test func displayKey_andNormalizedKey_agreeCaseInsensitively() {
        // The two must stay in lockstep on WHICH url parses and WHAT
        // segments it finds — only casing differs. This is what keeps
        // matching (`normalizedKey` on both sides) correct even though the
        // prefill (`displayKey`) now shows the original casing.
        let display = RemoteRepoMatching.displayKey("https://github.com/Acme/API")
        let normalized = RemoteRepoMatching.normalizedKey("https://github.com/Acme/API")
        #expect(display?.lowercased() == normalized)
    }

    // MARK: - resolveRepoID

    private func repo(id: UUID = UUID(), remoteURL: String?) -> Repo {
        Repo(id: id, path: "/tmp/r-\(id.uuidString.prefix(6))", remoteURL: remoteURL,
             displayName: "r", defaultBranch: "main")
    }

    @Test func resolveRepoID_matchesHTTPSAgainstBareOrgName() {
        let target = repo(remoteURL: "https://github.com/acme/api")
        let other = repo(remoteURL: "https://github.com/acme/other")
        let resolved = RemoteRepoMatching.resolveRepoID(metaRepo: "acme/api", repos: [other, target])
        #expect(resolved == target.id)
    }

    @Test func resolveRepoID_matchesSCPStyleAgainstHTTPS() {
        let target = repo(remoteURL: "git@github.com:acme/api.git")
        let resolved = RemoteRepoMatching.resolveRepoID(metaRepo: "https://github.com/acme/api", repos: [target])
        #expect(resolved == target.id)
    }

    @Test func resolveRepoID_nilMetaRepoResolvesToNil() {
        let target = repo(remoteURL: "https://github.com/acme/api")
        #expect(RemoteRepoMatching.resolveRepoID(metaRepo: nil, repos: [target]) == nil)
    }

    @Test func resolveRepoID_noRepoHasAMatchingRemoteURL() {
        let repos = [repo(remoteURL: "https://github.com/acme/other"),
                     repo(remoteURL: nil)]
        #expect(RemoteRepoMatching.resolveRepoID(metaRepo: "acme/api", repos: repos) == nil)
    }

    @Test func resolveRepoID_mismatchedNameDoesNotMatch() {
        let repos = [repo(remoteURL: "https://github.com/acme/api-tools")]
        #expect(RemoteRepoMatching.resolveRepoID(metaRepo: "acme/api", repos: repos) == nil)
    }

    @Test func resolveRepoID_mismatchedOrgDoesNotMatch() {
        let repos = [repo(remoteURL: "https://github.com/other-org/api")]
        #expect(RemoteRepoMatching.resolveRepoID(metaRepo: "acme/api", repos: repos) == nil)
    }

    // MARK: - resolveRepoID — renamed-repo fallback
    //
    // A provider keeps reporting the name it clones by, and the host serves
    // that old name via a redirect long after a rename. The local clone's
    // DIRECTORY is not renamed by that, so it still carries the old name.

    private func repo(id: UUID = UUID(), remoteURL: String?, path: String) -> Repo {
        Repo(id: id, path: path, remoteURL: remoteURL, displayName: "r", defaultBranch: "main")
    }

    @Test func resolveRepoID_matchesRenamedRepoViaDirectoryName() {
        // Host renamed acme/old-name -> acme/api; the clone directory did not follow.
        let target = repo(remoteURL: "https://github.com/acme/api", path: "/repos/old-name")
        let resolved = RemoteRepoMatching.resolveRepoID(metaRepo: "acme/old-name", repos: [target])
        #expect(resolved == target.id)
    }

    @Test func resolveRepoID_exactRemoteMatchBeatsRenameFallback() {
        // Ordered so the fallback candidate comes FIRST: a single-pass loop
        // would return it and lose the real match.
        let decoy = repo(remoteURL: "https://github.com/acme/api", path: "/repos/old-name")
        let exact = repo(remoteURL: "https://github.com/acme/old-name", path: "/repos/whatever")
        let resolved = RemoteRepoMatching.resolveRepoID(metaRepo: "acme/old-name",
                                                        repos: [decoy, exact])
        #expect(resolved == exact.id)
    }

    @Test func resolveRepoID_renameFallbackRequiresSameOrg() {
        // Directory name agrees but the owner does not — must NOT match, or the
        // fallback would invent cross-org matches pass 1 forbids.
        let repos = [repo(remoteURL: "https://github.com/other-org/api", path: "/repos/old-name")]
        #expect(RemoteRepoMatching.resolveRepoID(metaRepo: "acme/old-name", repos: repos) == nil)
    }

    @Test func resolveRepoID_renameFallbackIgnoresPathPrefix() {
        // Only the directory's own name counts; a parent segment must not match.
        let repos = [repo(remoteURL: "https://github.com/acme/api", path: "/old-name/checkout")]
        #expect(RemoteRepoMatching.resolveRepoID(metaRepo: "acme/old-name", repos: repos) == nil)
    }

    @Test func resolveRepoID_renameFallbackIsCaseInsensitive() {
        // Both sides are lowercased before comparing; nothing else pins that,
        // and directory casing is whatever the person who cloned it typed.
        let target = repo(remoteURL: "https://github.com/Acme/api", path: "/repos/Old-Name")
        let resolved = RemoteRepoMatching.resolveRepoID(metaRepo: "acme/old-name", repos: [target])
        #expect(resolved == target.id)
    }

    @Test func resolveRepoID_renameFallbackTakesFirstWhenRepoRegisteredTwice() {
        // The real shape: one repo cloned twice (primary + worktree root), both
        // directories keeping the old name. Pass 1 resolves duplicates by taking
        // the first, so this must too rather than refusing to choose.
        let first = repo(remoteURL: "https://github.com/acme/api", path: "/primary/old-name")
        let second = repo(remoteURL: "git@github.com:acme/api.git", path: "/worktrees/old-name")
        let resolved = RemoteRepoMatching.resolveRepoID(metaRepo: "acme/old-name",
                                                        repos: [first, second])
        #expect(resolved == first.id)
    }
}
