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

        init(repo: (owner: String, name: String, host: String)? =
            ("acme", "acme-prod", "github.com")) async throws {
            db = try TBDDatabase(inMemory: true)
            let created = try await db.repos.create(
                path: "/tmp/prbinding-coord-repo-\(UUID().uuidString)",
                displayName: "acme-prod", defaultBranch: "main")
            repoID = created.id
            store = db.prBindings
            coordinator = PRBindingCoordinator(store: store, resolveRepo: { _ in repo })
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
    /// This passes against the pre-fix guard too — that is the point: it pins
    /// the binding the fix must not take away. Comparing hosts for plain
    /// equality instead turns it into `.rejectedWrongRepo`.
    @Test("still binds a github.com URL to an enterprise or mirror checkout")
    func bindsGitHubURLAgainstAnotherHostCheckout() async throws {
        for host in ["ghe.acme.example", "gitlab.acme.example"] {
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
