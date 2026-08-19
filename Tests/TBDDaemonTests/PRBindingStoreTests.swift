import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("PRBindingStore")
struct PRBindingStoreTests {

    /// `worktree_pull_request.worktreeID` is a real foreign key onto `worktree`,
    /// and GRDB enables `PRAGMA foreign_keys` by default — so a fixture has to
    /// seed an actual repo + worktree rather than invent a bare UUID.
    private struct Fixture {
        let db: TBDDatabase
        let store: PRBindingStore
        let repoID: UUID

        init() async throws {
            db = try TBDDatabase(inMemory: true)
            let repo = try await db.repos.create(
                path: "/tmp/prbinding-repo-\(UUID().uuidString)",
                displayName: "acme-prod", defaultBranch: "main")
            repoID = repo.id
            store = db.prBindings
        }

        func newWorktree() async throws -> UUID {
            let suffix = UUID().uuidString
            return try await db.worktrees.create(
                repoID: repoID, name: "wt-\(suffix)", branch: "branch-\(suffix)",
                path: "/tmp/prbinding-wt-\(suffix)", tmuxServer: "tbd-prbinding").id
        }
    }

    private func binding(_ number: Int, worktreeID: UUID,
                         source: PRBindingSource = .hook,
                         state: PRMergeableState? = nil) -> PRBinding {
        let url = "https://github.com/acme/acme-prod/pull/\(number)"
        return PRBinding(
            worktreeID: worktreeID, owner: "acme", repo: "acme-prod",
            number: number, url: url,
            status: state.map { PRStatus(number: number, url: url, state: $0) },
            source: source)
    }

    @Test("inserts and lists a binding")
    func insertAndList() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        _ = try await fixture.store.upsert(binding(1, worktreeID: wt))
        let listed = try await fixture.store.list(worktreeID: wt)
        #expect(listed.count == 1)
        #expect(listed[0].number == 1)
        #expect(listed[0].source == .hook)
    }

    @Test("re-binding the same PR keeps the original source and boundAt")
    func dedupeKeepsFirst() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        let first = try await fixture.store.upsert(binding(1, worktreeID: wt, source: .hook))
        _ = try await fixture.store.upsert(binding(1, worktreeID: wt, source: .branch))
        _ = try await fixture.store.upsert(binding(1, worktreeID: wt, source: .manual))
        let listed = try await fixture.store.list(worktreeID: wt)
        #expect(listed.count == 1)
        #expect(listed[0].source == .hook)
        #expect(listed[0].boundAt == first?.boundAt)
    }

    @Test("owner and repo dedupe case-insensitively")
    func dedupeCaseInsensitive() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        let lower = binding(1, worktreeID: wt)
        _ = try await fixture.store.upsert(lower)
        let upper = PRBinding(worktreeID: wt, owner: "ACME", repo: "ACME-PROD",
                              number: 1, url: lower.url, source: .manual)
        _ = try await fixture.store.upsert(upper)
        #expect(try await fixture.store.list(worktreeID: wt).count == 1)
    }

    @Test("detach tombstones rather than deletes, and re-bind does not resurrect")
    func detachTombstones() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        let b = binding(1, worktreeID: wt)
        _ = try await fixture.store.upsert(b)
        #expect(try await fixture.store.setDetached(worktreeID: wt, identityKey: b.identityKey,
                                                    detached: true))
        #expect(try await fixture.store.list(worktreeID: wt).isEmpty)
        #expect(try await fixture.store.list(worktreeID: wt, includeDetached: true).count == 1)

        // an automatic source must not bring it back
        _ = try await fixture.store.upsert(binding(1, worktreeID: wt, source: .branch))
        #expect(try await fixture.store.list(worktreeID: wt).isEmpty)
    }

    @Test("attach clears a tombstone")
    func attachClearsTombstone() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        let b = binding(1, worktreeID: wt)
        _ = try await fixture.store.upsert(b)
        _ = try await fixture.store.setDetached(worktreeID: wt, identityKey: b.identityKey,
                                                detached: true)
        #expect(try await fixture.store.setDetached(worktreeID: wt, identityKey: b.identityKey,
                                                    detached: false))
        #expect(try await fixture.store.list(worktreeID: wt).count == 1)
    }

    @Test("detaching an unknown PR reports false")
    func detachUnknown() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        #expect(try await fixture.store.setDetached(
            worktreeID: wt,
            identityKey: "github.com\u{1}acme\u{1}acme-prod\u{1}9",
            detached: true) == false)
    }

    @Test("the cap evicts a terminal binding")
    func capEvictsTerminal() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        // 19 open + 1 merged = 20
        for n in 1...19 {
            _ = try await fixture.store.upsert(binding(n, worktreeID: wt, state: .mergeable))
        }
        _ = try await fixture.store.upsert(binding(20, worktreeID: wt, state: .merged))
        #expect(try await fixture.store.list(worktreeID: wt).count == 20)

        _ = try await fixture.store.upsert(binding(21, worktreeID: wt, state: .pending))
        let listed = try await fixture.store.list(worktreeID: wt)
        #expect(listed.count == 20)
        #expect(!listed.contains { $0.number == 20 })   // the merged one was evicted
        #expect(listed.contains { $0.number == 21 })
    }

    @Test("with nothing evictable the new binding is dropped")
    func capDropsWhenNoneEvictable() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        for n in 1...20 {
            _ = try await fixture.store.upsert(binding(n, worktreeID: wt, state: .mergeable))
        }
        let result = try await fixture.store.upsert(binding(21, worktreeID: wt, state: .pending))
        #expect(result == nil)
        let listed = try await fixture.store.list(worktreeID: wt)
        #expect(listed.count == 20)
        #expect(!listed.contains { $0.number == 21 })
    }

    @Test("tombstones do not count against the cap")
    func tombstonesDoNotCount() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        for n in 1...20 {
            _ = try await fixture.store.upsert(binding(n, worktreeID: wt, state: .mergeable))
        }
        let first = binding(1, worktreeID: wt)
        _ = try await fixture.store.setDetached(worktreeID: wt, identityKey: first.identityKey,
                                                detached: true)
        #expect(try await fixture.store.upsert(
            binding(21, worktreeID: wt, state: .pending)) != nil)
        #expect(try await fixture.store.list(worktreeID: wt).count == 20)
    }

    @Test("updateObservation round-trips a PRStatus")
    func updateStatus() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        let stored = try #require(try await fixture.store.upsert(binding(1, worktreeID: wt)))
        let status = PRStatus(number: 1, url: stored.url, state: .checksFailed,
                              reason: "Checks failing")
        try await fixture.store.updateObservation(bindingID: stored.id, status: status)
        #expect(try await fixture.store.list(worktreeID: wt).first?.status == status)
    }

    @Test("updateObservation persists the branch refs a refresh observed")
    func updateObservationStoresRefs() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        let stored = try #require(try await fixture.store.upsert(binding(1, worktreeID: wt)))
        #expect(stored.headBranch == nil)

        let status = PRStatus(number: 1, url: stored.url, state: .mergeable)
        try await fixture.store.updateObservation(
            bindingID: stored.id, status: status,
            headBranch: "tbd/fix-login-timeout", baseRef: "main")
        let listed = try await fixture.store.list(worktreeID: wt).first
        #expect(listed?.headBranch == "tbd/fix-login-timeout")
        #expect(listed?.baseRef == "main")

        // A later pass that resolved no refs (transient failure) must not blank
        // the columns the CLI renders.
        try await fixture.store.updateObservation(bindingID: stored.id, status: status)
        let kept = try await fixture.store.list(worktreeID: wt).first
        #expect(kept?.headBranch == "tbd/fix-login-timeout")
        #expect(kept?.baseRef == "main")
    }

    @Test("setDetached reports false when the state did not actually change")
    func setDetachedReportsRealChange() async throws {
        // `updateAll` counts MATCHED rows, so the naive `> 0` made `tbd pr
        // detach` on an already-detached PR print "Detached."
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        let b = binding(1, worktreeID: wt)
        _ = try await fixture.store.upsert(b)

        #expect(try await fixture.store.setDetached(worktreeID: wt, identityKey: b.identityKey,
                                                    detached: true))
        #expect(try await fixture.store.setDetached(worktreeID: wt, identityKey: b.identityKey,
                                                    detached: true) == false)
        // Attaching a live binding is likewise a no-op, and says so.
        #expect(try await fixture.store.setDetached(worktreeID: wt, identityKey: b.identityKey,
                                                    detached: false))
        #expect(try await fixture.store.setDetached(worktreeID: wt, identityKey: b.identityKey,
                                                    detached: false) == false)
    }

    @Test("deleteBranchBinding removes only a branch-sourced row")
    func deleteBranchBindingIsSourceScoped() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        let branch = binding(1, worktreeID: wt, source: .branch)
        let hook = binding(2, worktreeID: wt, source: .hook)
        let manual = binding(3, worktreeID: wt, source: .manual)
        for candidate in [branch, hook, manual] { _ = try await fixture.store.upsert(candidate) }

        #expect(try await fixture.store.deleteBranchBinding(
            worktreeID: wt, identityKey: branch.identityKey))
        #expect(try await fixture.store.deleteBranchBinding(
            worktreeID: wt, identityKey: hook.identityKey) == false)
        #expect(try await fixture.store.deleteBranchBinding(
            worktreeID: wt, identityKey: manual.identityKey) == false)

        // A hard delete, not a tombstone: nothing is left on record, so a later
        // correct branch match can re-bind.
        #expect(try await fixture.store.list(worktreeID: wt, includeDetached: true)
            .map(\.number) == [2, 3])
    }

    @Test("bindings for two worktrees do not mix")
    func perWorktreeIsolation() async throws {
        let fixture = try await Fixture()
        let a = try await fixture.newWorktree()
        let b = try await fixture.newWorktree()
        _ = try await fixture.store.upsert(binding(1, worktreeID: a))
        _ = try await fixture.store.upsert(binding(2, worktreeID: b))
        #expect(try await fixture.store.list(worktreeID: a).map(\.number) == [1])
        #expect(try await fixture.store.list(worktreeID: b).map(\.number) == [2])
        #expect(try await fixture.store.listAll().count == 2)
    }

    @Test("list returns bind order")
    func bindOrder() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        for n in [30, 10, 20] { _ = try await fixture.store.upsert(binding(n, worktreeID: wt)) }
        #expect(try await fixture.store.list(worktreeID: wt).map(\.number) == [30, 10, 20])
    }

    @Test("a nested namespace survives the identity key, the parse and the unique index")
    func nestedNamespaceIdentityRoundTrip() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        let url = "https://git.acme.example/acme/platform/backend/api-gateway/-/merge_requests/412"
        let nested = PRBinding(
            worktreeID: wt, host: "git.acme.example",
            owner: "acme/platform/backend", repo: "api-gateway", number: 412,
            url: url, source: .manual)
        // Four parts even though the namespace contains slashes — the key is
        // \u{1}-delimited, so `/` is ordinary data.
        #expect(nested.identityKey.split(separator: "\u{1}").count == 4)
        _ = try await fixture.store.upsert(nested)
        _ = try await fixture.store.upsert(nested)   // idempotent under the unique index
        let loaded = try await fixture.store.list(worktreeID: wt)
        #expect(loaded.count == 1)
        #expect(loaded[0].owner == "acme/platform/backend")
        #expect(loaded[0].repo == "api-gateway")

        let parsed = PRStatusManager.parseOwnerRepo(fromURL: loaded[0].url)
        #expect(parsed?.owner == loaded[0].owner)
        #expect(parsed?.name == loaded[0].repo)
    }

    @Test("two projects differing only in namespace depth are distinct bindings")
    func namespaceDepthDistinguishes() async throws {
        let fixture = try await Fixture()
        let wt = try await fixture.newWorktree()
        func nested(owner: String) -> PRBinding {
            PRBinding(worktreeID: wt, host: "git.acme.example",
                      owner: owner, repo: "api", number: 1,
                      url: "https://git.acme.example/\(owner)/api/-/merge_requests/1",
                      source: .manual)
        }
        _ = try await fixture.store.upsert(nested(owner: "acme"))
        _ = try await fixture.store.upsert(nested(owner: "acme/platform"))
        #expect(try await fixture.store.list(worktreeID: wt).count == 2)
    }
}
