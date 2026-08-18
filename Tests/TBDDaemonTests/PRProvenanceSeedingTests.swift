import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// A worktree created from a PR row carries `Worktree.prNumber` and, before
/// this, no binding — so its PR was invisible to `tbd pr list`, to the toolbar
/// dropdown and to the status-bar chips. Fork PRs are the sharpest case: a fork
/// head never appears in the viewer-authored batch, so branch matching is
/// structurally unable to find them and the stored number is the only handle
/// that exists.
///
/// Two levels are covered here: the coordinator's `seedProvenance` policy, and
/// the poll call site that actually runs it.
@Suite("PR provenance seeding")
struct PRProvenanceSeedingTests {

    // MARK: - Coordinator policy

    /// `worktree_pull_request.worktreeID` is an enforced foreign key, so a
    /// fixture seeds a real repo + worktree rather than inventing a bare UUID.
    private struct Fixture {
        let db: TBDDatabase
        let store: PRBindingStore
        let coordinator: PRBindingCoordinator
        let repoID: UUID

        init(repo: (owner: String, name: String, host: String)? =
            ("acme", "acme-prod", "github.com")) async throws {
            db = try TBDDatabase(inMemory: true)
            let created = try await db.repos.create(
                path: "/tmp/prseed-repo-\(UUID().uuidString)",
                displayName: "acme-prod", defaultBranch: "main")
            repoID = created.id
            store = db.prBindings
            coordinator = PRBindingCoordinator(store: store, resolveRepo: { _ in repo })
        }

        func newWorktree(prNumber: Int? = nil) async throws -> UUID {
            let suffix = UUID().uuidString
            return try await db.worktrees.create(
                repoID: repoID, name: "wt-\(suffix)", branch: "branch-\(suffix)",
                path: "/tmp/prseed-wt-\(suffix)", tmuxServer: "tbd-prseed",
                prNumber: prNumber).id
        }
    }

    private let parsed = ParsedPRURL(
        host: "github.com", owner: "acme", repo: "acme-prod", number: 412,
        url: "https://github.com/acme/acme-prod/pull/412")

    @Test("a worktree with a PR number and no binding gets exactly one manual binding")
    func seedsOneManualBinding() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree(prNumber: 412)

        let outcome = await fixture.coordinator.seedProvenance(worktreeID: wt, parsed: parsed)
        guard case .bound(let binding) = outcome else {
            Issue.record("expected .bound, got \(outcome)"); return
        }
        #expect(binding.number == 412)
        #expect(binding.source == .manual)
        let listed = try await fixture.store.list(worktreeID: wt)
        #expect(listed.count == 1)
        #expect(listed.map(\.source) == [.manual])
    }

    @Test("seeding twice still yields one binding")
    func seedingIsIdempotent() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree(prNumber: 412)

        let first = await fixture.coordinator.seedProvenance(worktreeID: wt, parsed: parsed)
        guard case .bound(let bound) = first else {
            Issue.record("expected .bound, got \(first)"); return
        }
        let second = await fixture.coordinator.seedProvenance(worktreeID: wt, parsed: parsed)
        guard case .alreadyBound = second else {
            Issue.record("expected .alreadyBound, got \(second)"); return
        }
        let listed = try await fixture.store.list(worktreeID: wt)
        #expect(listed.count == 1)
        // The same row, not a replacement: seeding never rewrites what is there.
        #expect(listed.first?.id == bound.id)
        #expect(listed.first?.boundAt == bound.boundAt)
    }

    /// The trap this seam exists for. `.manual` is the one source allowed to
    /// clear a tombstone, and seeding is reconciled on every poll — so a plain
    /// `bind(source: .manual)` here would undo a `tbd pr detach` within seconds.
    @Test("seeding does not revive a binding the user detached")
    func seedingDoesNotReviveDetached() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree(prNumber: 412)
        _ = await fixture.coordinator.seedProvenance(worktreeID: wt, parsed: parsed)
        #expect(try await fixture.coordinator.detach(worktreeID: wt, parsed: parsed))
        #expect(try await fixture.store.list(worktreeID: wt).isEmpty)

        // Every subsequent poll re-runs the seed; none of them may bring it back.
        for _ in 0..<3 {
            let outcome = await fixture.coordinator.seedProvenance(worktreeID: wt, parsed: parsed)
            guard case .tombstoned = outcome else {
                Issue.record("expected .tombstoned, got \(outcome)"); return
            }
            #expect(try await fixture.store.list(worktreeID: wt).isEmpty)
        }
        // The tombstone itself survives — it is what makes the detach durable.
        #expect(try await fixture.store.list(worktreeID: wt, includeDetached: true).count == 1)
        #expect(try await fixture.store.list(worktreeID: wt, includeDetached: true)
            .first?.detached == true)

        // And an explicit re-attach still works: seeding is inert, not a lock.
        let reattached = await fixture.coordinator.bind(worktreeID: wt, parsed: parsed,
                                                        source: .manual)
        guard case .bound = reattached else {
            Issue.record("expected .bound, got \(reattached)"); return
        }
        #expect(try await fixture.store.list(worktreeID: wt).count == 1)
    }

    @Test("a PR number whose PR belongs to a different repo is rejected, not bound")
    func seedingRejectsWrongRepo() async throws {
        let fixture = try await Fixture(repo: ("acme", "other-repo", "github.com"))
        let wt = try await fixture.newWorktree(prNumber: 412)

        let outcome = await fixture.coordinator.seedProvenance(worktreeID: wt, parsed: parsed)
        guard case .rejectedWrongRepo(let named) = outcome else {
            Issue.record("expected .rejectedWrongRepo, got \(outcome)"); return
        }
        #expect(named == "acme/acme-prod")
        #expect(try await fixture.store.list(worktreeID: wt, includeDetached: true).isEmpty)
    }

    // MARK: - The poll call site

    /// Drives the real `pr.list` handler, so the assertion is that seeding
    /// actually runs from the poll rather than that a helper works in isolation.
    ///
    /// `gh` is stubbed to answer nothing — the seed must not depend on a live
    /// PR lookup, only on the stored number and the worktree's own repo.
    private struct PollHarness {
        let db: TBDDatabase
        let router: RPCRouter
        let repoID: UUID

        init(repo: (owner: String, name: String, host: String)? =
            ("acme", "acme-prod", "github.com")) async throws {
            let db = try TBDDatabase(inMemory: true)
            self.db = db
            let created = try await db.repos.create(
                path: "/tmp/prseed-poll-repo-\(UUID().uuidString)",
                displayName: "acme-prod", defaultBranch: "main")
            repoID = created.id
            router = RPCRouter(
                db: db,
                lifecycle: WorktreeLifecycle(
                    db: db, git: GitManager(),
                    tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
                tmux: TmuxManager(dryRun: true),
                startTime: Date(),
                prManager: PRStatusManager(ghRunner: { _, _ in nil }),
                prBindingRepoResolver: { _ in repo },
                actuationLog: makeTestActuationLog())
        }

        func newWorktree(prNumber: Int? = nil) async throws -> UUID {
            let suffix = UUID().uuidString
            return try await db.worktrees.create(
                repoID: repoID, name: "wt-\(suffix)", branch: "branch-\(suffix)",
                path: "/tmp/prseed-poll-wt-\(suffix)", tmuxServer: "tbd-prseed-poll",
                prNumber: prNumber).id
        }

        /// One poll pass, driven the way the daemon drives it. `pr.list` is
        /// serve-only — `PRPoller` owns the clock and the pass — so a test that
        /// polled through the RPC would seed nothing.
        @discardableResult
        func poll() async -> Bool {
            do {
                try await router.runPollPass()
                return true
            } catch {
                return false
            }
        }
    }

    @Test("the poll pass seeds a binding from Worktree.prNumber")
    func pollSeedsFromStoredNumber() async throws {
        let harness = try await PollHarness()
        let wt = try await harness.newWorktree(prNumber: 412)

        #expect(await harness.poll())

        let listed = try await harness.db.prBindings.list(worktreeID: wt)
        #expect(listed.count == 1)
        #expect(listed.first?.number == 412)
        #expect(listed.first?.source == .manual)
        #expect(listed.first?.url == "https://github.com/acme/acme-prod/pull/412")
    }

    @Test("a worktree with no PR number is left unbound by the poll")
    func pollSeedsNothingWithoutNumber() async throws {
        let harness = try await PollHarness()
        let wt = try await harness.newWorktree(prNumber: nil)

        #expect(await harness.poll())

        #expect(try await harness.db.prBindings.list(worktreeID: wt,
                                                     includeDetached: true).isEmpty)
    }

    @Test("repeated polls keep exactly one seeded binding")
    func pollSeedingIsIdempotent() async throws {
        let harness = try await PollHarness()
        let wt = try await harness.newWorktree(prNumber: 412)

        for _ in 0..<3 { #expect(await harness.poll()) }

        #expect(try await harness.db.prBindings.list(worktreeID: wt).count == 1)
    }

    @Test("a poll does not re-seed a provenance PR the user detached")
    func pollDoesNotReviveDetached() async throws {
        let harness = try await PollHarness()
        let wt = try await harness.newWorktree(prNumber: 412)
        #expect(await harness.poll())

        let detach = try RPCRequest(
            method: RPCMethod.prDetach,
            params: PRBindingRefParams(worktreeID: wt, number: 412))
        #expect(try await harness.router.handle(detach)
            .decodeResult(PRDetachResult.self).detached)
        #expect(try await harness.db.prBindings.list(worktreeID: wt).isEmpty)

        #expect(await harness.poll())

        #expect(try await harness.db.prBindings.list(worktreeID: wt).isEmpty)
        #expect(try await harness.db.prBindings.list(worktreeID: wt,
                                                     includeDetached: true).count == 1)
    }

    @Test("the poll leaves a PR number unbound when the worktree's repo is unresolvable")
    func pollDefersUnknownRepo() async throws {
        let harness = try await PollHarness(repo: nil)
        let wt = try await harness.newWorktree(prNumber: 412)

        #expect(await harness.poll())

        // Deferred, not tombstoned: nothing is written, so a later poll that can
        // name the repo still seeds.
        #expect(try await harness.db.prBindings.list(worktreeID: wt,
                                                     includeDetached: true).isEmpty)
    }
}
