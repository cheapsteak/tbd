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
