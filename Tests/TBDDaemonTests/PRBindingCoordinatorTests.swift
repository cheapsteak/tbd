import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("PRBindingCoordinator")
struct PRBindingCoordinatorTests {

    /// `worktree_pull_request.worktreeID` is a real foreign key onto `worktree`,
    /// and GRDB enables `PRAGMA foreign_keys` by default — so a fixture has to
    /// seed an actual repo + worktree rather than invent a bare UUID.
    private struct Fixture {
        let db: TBDDatabase
        let store: PRBindingStore
        let coordinator: PRBindingCoordinator
        let repoID: UUID

        /// - Parameter gitLabHosts: the hosts the user configured `glab` for.
        ///   Empty — the default — stands for every non-GitLab fleet at once:
        ///   github.com, GitHub Enterprise, Bitbucket, Gitea, Codeberg. `nil` is
        ///   the third answer, the state in which nothing could establish the
        ///   worktree's forge at all.
        init(repo: (owner: String, name: String, host: String)? =
            ("acme", "acme-prod", "github.com"),
             gitLabHosts: Set<String>? = []) async throws {
            db = try TBDDatabase(inMemory: true)
            let created = try await db.repos.create(
                path: "/tmp/prbinding-coord-repo-\(UUID().uuidString)",
                displayName: "acme-prod", defaultBranch: "main")
            repoID = created.id
            store = db.prBindings
            coordinator = PRBindingCoordinator(
                store: store, resolveRepo: { _ in repo },
                isGitLabHost: { _, host in gitLabHosts.map { $0.contains(host.lowercased()) } })
        }

        func newWorktree() async throws -> UUID {
            let suffix = UUID().uuidString
            return try await db.worktrees.create(
                repoID: repoID, name: "wt-\(suffix)", branch: "branch-\(suffix)",
                path: "/tmp/prbinding-coord-wt-\(suffix)", tmuxServer: "tbd-prbinding").id
        }
    }

    private let parsed = ParsedPRURL(
        host: "github.com", owner: "acme", repo: "acme-prod", number: 412,
        url: "https://github.com/acme/acme-prod/pull/412")

    @Test("binds a PR in the worktree's own repo")
    func bindsOwnRepo() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        let outcome = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed, source: .hook)
        guard case .bound(let binding) = outcome else {
            Issue.record("expected .bound, got \(outcome)"); return
        }
        #expect(binding.number == 412)
        #expect(binding.source == .hook)
        #expect(try await fixture.store.list(worktreeID: wt).count == 1)
    }

    @Test("rejects a PR belonging to a different repo")
    func rejectsWrongRepo() async throws {
        let fixture = try await Fixture(repo: ("acme", "other-repo", "github.com"))
        let wt = try await fixture.newWorktree()
        let outcome = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed, source: .hook)
        guard case .rejectedWrongRepo(let named) = outcome else {
            Issue.record("expected .rejectedWrongRepo, got \(outcome)"); return
        }
        #expect(named == "acme/acme-prod")
        #expect(try await fixture.store.list(worktreeID: wt).isEmpty)
    }

    @Test("repo comparison is case-insensitive")
    func repoCaseInsensitive() async throws {
        let fixture = try await Fixture(repo: ("ACME", "ACME-PROD", "github.com"))
        let wt = try await fixture.newWorktree()
        let outcome = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed, source: .hook)
        guard case .bound = outcome else {
            Issue.record("expected .bound, got \(outcome)"); return
        }
    }

    /// Extraction is the production source of every `ParsedPRURL` a hook or a
    /// URL-shaped attach binds, so the host under test is the one the extractor
    /// really reports rather than one this file made up.
    private func parseOne(_ url: String) throws -> ParsedPRURL {
        try #require(PRBindingExtractor.parsePRURLs(in: url).first)
    }

    /// The wrong-repo guard used to compare `owner`/`name` and nothing else,
    /// which was inert only while every parsed URL was on `github.com`. Now that
    /// a GitLab merge-request URL carries its own captured host, two different
    /// projects that merely share an `owner/name` across two hosts would bind to
    /// each other — and a foreign merge then satisfies `allResolved` and
    /// auto-archives the worktree.
    ///
    /// Against the guard as it stood, both rows below returned `.bound` and
    /// wrote a row.
    @Test("rejects a merge request whose captured host is not the worktree's")
    func rejectsRequestFromAnotherHost() async throws {
        let cases: [(own: (owner: String, name: String, host: String), url: String, detail: String)] = [
            // Cross-forge: the hole this closes.
            (("acme", "acme-prod", "github.com"),
             "https://git.acme.example/acme/acme-prod/-/merge_requests/412",
             "git.acme.example/acme/acme-prod"),
            // Same forge, two instances — one org name on two GitLab hosts.
            (("acme", "acme-prod", "gitlab.acme.example"),
             "https://git.other.example/acme/acme-prod/-/merge_requests/412",
             "git.other.example/acme/acme-prod"),
        ]
        for testCase in cases {
            let fixture = try await Fixture(repo: testCase.own)
            let wt = try await fixture.newWorktree()
            let parsed = try parseOne(testCase.url)
            let outcome = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed,
                                                         source: .hook)
            guard case .rejectedWrongRepo(let named) = outcome else {
                Issue.record("expected .rejectedWrongRepo for \(testCase.url), got \(outcome)")
                continue  // each row is an independent case; don't mask the second
            }
            // Owner and name agree here, so the rejection has to name the host
            // or it reads as a repo rejecting itself.
            #expect(named == testCase.detail)
            #expect(try await fixture.store.list(worktreeID: wt, includeDetached: true).isEmpty)
        }
    }

    /// The other half of the trade-off, and the reason the host check is not a
    /// plain equality: `PRBindingExtractor`'s GitHub pattern is host-locked, so
    /// `github.com` is a constant it supplies for every GitHub URL rather than
    /// an observation about the forge. A GitHub Enterprise or self-hosted-mirror
    /// checkout with the same `owner/name` may therefore still take such a URL,
    /// which is what `RemoteRepoMatching` documents as a deliberately tolerated
    /// collision.
    ///
    /// Neither host below is configured for `glab`, which is what makes them
    /// *not* GitLab — the exemption survives on that answer, not on the shape of
    /// their names. These two stand for every non-GitLab fleet off github.com:
    /// GitHub Enterprise, Bitbucket, Gitea, Codeberg, and a mirror.
    @Test("still binds a github.com URL to an enterprise or mirror checkout")
    func bindsGitHubURLAgainstAnotherHostCheckout() async throws {
        for host in ["ghe.acme.example", "git.acme.example"] {
            let fixture = try await Fixture(repo: ("acme", "acme-prod", host))
            let wt = try await fixture.newWorktree()
            let outcome = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed,
                                                         source: .manual)
            guard case .bound(let binding) = outcome else {
                Issue.record("expected .bound on \(host), got \(outcome)"); continue
            }
            // The URL's host is what gets recorded — the binding is re-queried
            // by `(host, owner, repo, number)` and must reach the real request.
            #expect(binding.host == "github.com")
        }
    }

    /// Where that exemption stops, and the collision it would otherwise leave
    /// open. This worktree's host speaks GitLab, so its requests live there and
    /// a `github.com` pull request sharing an `owner/name` is a different
    /// project by construction. Binding it would poll a stranger's PR through
    /// `gh` and let that stranger's merge auto-archive this worktree.
    ///
    /// Against the exemption as it stood — unconditional on any `github.com`
    /// URL — this returned `.bound` and wrote a row.
    @Test("rejects a github.com URL on a checkout whose own host speaks GitLab")
    func rejectsGitHubURLAgainstGitLabCheckout() async throws {
        let fixture = try await Fixture(repo: ("acme", "acme-prod", "gitlab.acme.example"),
                                        gitLabHosts: ["gitlab.acme.example"])
        let wt = try await fixture.newWorktree()
        let outcome = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed,
                                                     source: .hook)
        guard case .rejectedWrongRepo(let named) = outcome else {
            Issue.record("expected .rejectedWrongRepo, got \(outcome)"); return
        }
        // Owner and name agree, so the rejection has to name the host.
        #expect(named == "github.com/acme/acme-prod")
        #expect(try await fixture.store.list(worktreeID: wt, includeDetached: true).isEmpty)
    }

    /// The third answer. A worktree whose forge nothing could establish gets no
    /// binding invented for it: the two ways to be wrong are not symmetric, and
    /// a deferral writes nothing and is retried on the next poll or attach,
    /// while a bind can auto-archive this worktree on a stranger's merge.
    @Test("defers a github.com URL when the checkout's forge cannot be determined")
    func defersWhenForgeUndetermined() async throws {
        let fixture = try await Fixture(repo: ("acme", "acme-prod", "git.acme.example"),
                                        gitLabHosts: nil)
        let wt = try await fixture.newWorktree()
        let outcome = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed,
                                                     source: .hook)
        guard case .deferredUnknownRepo = outcome else {
            Issue.record("expected .deferredUnknownRepo, got \(outcome)"); return
        }
        #expect(try await fixture.store.list(worktreeID: wt, includeDetached: true).isEmpty)
    }

    /// A worktree already on the URL's own host never reaches the forge
    /// question at all — the hosts are equal, so nothing is asked and no `glab`
    /// subprocess could be spawned. Pinned because an undetermined forge now
    /// defers, and a guard that asked first would turn every github.com bind
    /// into a deferral wherever the answer is unavailable.
    @Test("a matching host binds without consulting the forge")
    func matchingHostSkipsForgeQuestion() async throws {
        let fixture = try await Fixture(gitLabHosts: nil)
        let wt = try await fixture.newWorktree()
        let outcome = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed, source: .hook)
        guard case .bound = outcome else {
            Issue.record("expected .bound, got \(outcome)"); return
        }
    }

    /// Hostnames are case-insensitive, so a resolver that reports the host with
    /// the casing `gh repo view`'s URL happened to use must not reject an
    /// otherwise identical merge request. Comparing the raw strings fails here.
    @Test("host comparison is case-insensitive")
    func hostCaseInsensitive() async throws {
        let fixture = try await Fixture(repo: ("acme", "acme-prod", "Git.ACME.Example"))
        let wt = try await fixture.newWorktree()
        let parsed = try parseOne("https://git.acme.example/acme/acme-prod/-/merge_requests/412")
        let outcome = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed, source: .hook)
        guard case .bound = outcome else {
            Issue.record("expected .bound, got \(outcome)"); return
        }
    }

    @Test("defers rather than rejects when the repo cannot be resolved")
    func defersUnknownRepo() async throws {
        let fixture = try await Fixture(repo: nil)
        let wt = try await fixture.newWorktree()
        let outcome = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed, source: .hook)
        guard case .deferredUnknownRepo = outcome else {
            Issue.record("expected .deferredUnknownRepo, got \(outcome)"); return
        }
        #expect(try await fixture.store.list(worktreeID: wt).isEmpty)
    }

    @Test("re-binding an existing PR reports alreadyBound")
    func alreadyBound() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        _ = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed, source: .hook)
        let second = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed, source: .branch)
        guard case .alreadyBound = second else {
            Issue.record("expected .alreadyBound, got \(second)"); return
        }
        // The first source still owns the row.
        #expect(try await fixture.store.list(worktreeID: wt).map(\.source) == [.hook])
    }

    @Test("an automatic source cannot revive a tombstone")
    func automaticCannotRevive() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        _ = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed, source: .hook)
        #expect(try await fixture.coordinator.detach(worktreeID: wt, parsed: parsed))

        for source: PRBindingSource in [.hook, .branch] {
            let outcome = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed,
                                                         source: source)
            guard case .tombstoned = outcome else {
                Issue.record("expected .tombstoned for \(source), got \(outcome)"); return
            }
            #expect(try await fixture.store.list(worktreeID: wt).isEmpty)
        }
        #expect(try await fixture.store.list(worktreeID: wt, includeDetached: true).count == 1)
    }

    @Test("a manual attach revives a tombstone")
    func manualRevives() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        _ = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed, source: .hook)
        _ = try await fixture.coordinator.detach(worktreeID: wt, parsed: parsed)
        let outcome = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed,
                                                     source: .manual)
        guard case .bound(let revived) = outcome else {
            Issue.record("expected .bound, got \(outcome)"); return
        }
        #expect(!revived.detached)
        #expect(revived.number == 412)
        #expect(try await fixture.store.list(worktreeID: wt).count == 1)
    }

    // MARK: - Detach

    /// The status bar renders a chip for a worktree whose only PR evidence is
    /// the cached `Worktree.prStatus` — a synthetic binding that by design never
    /// reaches the database. A detach that only ever UPDATEd would match no row
    /// there, leave `detachedCount` at zero, and the chip would come straight
    /// back. So detach asserts rather than edits: with nothing on record it
    /// writes the tombstone itself.
    @Test("detaching a PR nothing ever bound inserts a manual tombstone")
    func detachInsertsTombstoneOnMiss() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        #expect(try await fixture.store.list(worktreeID: wt, includeDetached: true).isEmpty)

        #expect(try await fixture.coordinator.detach(worktreeID: wt, parsed: parsed))

        #expect(try await fixture.store.list(worktreeID: wt).isEmpty)
        let recorded = try await fixture.store.list(worktreeID: wt, includeDetached: true)
        #expect(recorded.count == 1)
        #expect(recorded.first?.number == 412)
        #expect(recorded.first?.detached == true)
        // A tombstone with no prior row records nothing but a user's decision.
        #expect(recorded.first?.source == .manual)
        #expect(recorded.first?.url == parsed.url)
    }

    @Test("detaching an already-tombstoned PR adds no row and does not error")
    func detachTwiceIsIdempotent() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        #expect(try await fixture.coordinator.detach(worktreeID: wt, parsed: parsed))

        // Reports "changed nothing" — the PR is already detached — rather than
        // duplicating the row or tripping the unique index.
        #expect(try await fixture.coordinator.detach(worktreeID: wt, parsed: parsed) == false)
        #expect(try await fixture.store.list(worktreeID: wt, includeDetached: true).count == 1)
    }

    @Test("detaching a live binding still tombstones the row it already has")
    func detachTombstonesALiveRow() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        _ = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed, source: .hook)

        #expect(try await fixture.coordinator.detach(worktreeID: wt, parsed: parsed))

        let recorded = try await fixture.store.list(worktreeID: wt, includeDetached: true)
        #expect(recorded.count == 1)
        #expect(recorded.first?.detached == true)
        // Insert-on-miss must not have fired: the original row is still the
        // hook's, not a fresh manual one.
        #expect(recorded.first?.source == .hook)
    }

    /// A tombstone for a PR outside the worktree's own repo would be permanent:
    /// `bind` rejects a wrong-repo reference before it ever reaches the row, so
    /// `pr.attach` could not clear it, and the `detachedCount` it leaves
    /// suppresses the legacy-status fallback for that worktree forever. So the
    /// insert arm carries the same repo guard `bind` does — one mistyped
    /// `tbd pr detach <other-repo-url>` must not retire a worktree's real PR
    /// indicator with no way back.
    @Test("detaching an unbound PR from another repo records nothing")
    func detachDoesNotTombstoneAForeignUnboundPR() async throws {
        let fixture = try await Fixture(repo: ("acme", "other-repo"))
        let wt = try await fixture.newWorktree()

        #expect(try await fixture.coordinator.detach(worktreeID: wt, parsed: parsed) == false)

        // Nothing written at all — in particular no tombstone, so detachedCount
        // stays zero and the legacy-status fallback keeps working.
        #expect(try await fixture.store.list(worktreeID: wt, includeDetached: true).isEmpty)
    }

    /// The guard covers creation, not modification. A row that already exists
    /// is this worktree's own record of the PR, and detaching it must work
    /// whatever the repo resolves to now — otherwise a repo rename would strand
    /// every binding made before it.
    @Test("detaching an existing row works even when the repo no longer matches")
    func detachTombstonesAnExistingRowRegardlessOfRepo() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        _ = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed, source: .hook)

        let renamed = PRBindingCoordinator(store: fixture.store,
                                           resolveRepo: { _ in ("acme", "renamed-repo") })
        #expect(try await renamed.detach(worktreeID: wt, parsed: parsed))

        #expect(try await fixture.store.list(worktreeID: wt).isEmpty)
        #expect(try await fixture.store.list(worktreeID: wt, includeDetached: true).count == 1)
    }

    /// The gesture stays reversible whichever way the tombstone got there.
    @Test("a manual attach clears a tombstone that insert-on-miss created")
    func attachClearsAnInsertedTombstone() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        #expect(try await fixture.coordinator.detach(worktreeID: wt, parsed: parsed))

        // An automatic source still may not revive it — insert-on-miss creates
        // a real tombstone, not a weaker one.
        let auto = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed, source: .branch)
        guard case .tombstoned = auto else {
            Issue.record("expected .tombstoned, got \(auto)"); return
        }

        let outcome = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed, source: .manual)
        guard case .bound(let revived) = outcome else {
            Issue.record("expected .bound, got \(outcome)"); return
        }
        #expect(!revived.detached)
        #expect(try await fixture.store.list(worktreeID: wt).map(\.number) == [412])
    }

    // MARK: - Heal

    @Test("a heal removes a branch binding and leaves hook and manual ones alone")
    func healRemovesOnlyBranchBindings() async throws {
        for source in PRBindingSource.allCases {
            let fixture = try await Fixture()
            let wt = try await fixture.newWorktree()
            _ = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed, source: source)

            let removed = await fixture.coordinator.healBranchMatch(worktreeID: wt, parsed: parsed)

            #expect(removed == (source == .branch), "source \(source.rawValue)")
            let remaining = try await fixture.store.list(worktreeID: wt, includeDetached: true)
            // A hook binding is direct evidence this session created the PR and a
            // manual one is the user's explicit statement; neither is undone by
            // an inference drawn from branch names.
            #expect(remaining.count == (source == .branch ? 0 : 1), "source \(source.rawValue)")
        }
    }

    @Test("a heal deletes rather than tombstones, so a later correct match can re-bind")
    func healDeletesRatherThanTombstoning() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        _ = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed, source: .branch)
        #expect(await fixture.coordinator.healBranchMatch(worktreeID: wt, parsed: parsed))
        // Nothing on record at all — a tombstone here would permanently block
        // re-binding if the heal's branch evidence was wrong.
        #expect(try await fixture.store.list(worktreeID: wt, includeDetached: true).isEmpty)

        let rebound = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed,
                                                     source: .branch)
        guard case .bound = rebound else {
            Issue.record("expected .bound, got \(rebound)"); return
        }
    }

    @Test("healing a PR this worktree never bound is a no-op")
    func healUnknownPRIsHarmless() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        #expect(await fixture.coordinator.healBranchMatch(worktreeID: wt, parsed: parsed) == false)
    }
}
