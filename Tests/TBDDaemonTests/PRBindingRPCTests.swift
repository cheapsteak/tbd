import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// Drives the `pr.bindings` / `pr.attach` / `pr.detach` handlers through the
/// real `RPCRouter`, so param decoding and result encoding are exercised rather
/// than the coordinator being called directly.
///
/// `worktree_pull_request.worktreeID` is an enforced foreign key, so the harness
/// seeds a real repo and worktree instead of inventing a bare UUID. The
/// worktree's own `owner/name` comes from the router's injected
/// `prBindingRepoResolver` seam — production resolves it with `gh repo view`
/// behind `PRStatusManager`'s TTL cache, which a unit test must not spawn.
private struct PRBindingRPCHarness {
    enum HarnessError: Error, CustomStringConvertible {
        case rpcFailed(String)

        var description: String {
            switch self {
            case .rpcFailed(let message): return "RPC failed: \(message)"
            }
        }
    }

    let db: TBDDatabase
    let router: RPCRouter
    let worktreeID: UUID
    let repoID: UUID

    init(repo: (owner: String, name: String)?) async throws {
        let db = try TBDDatabase(inMemory: true)
        self.db = db
        let suffix = UUID().uuidString
        let createdRepo = try await db.repos.create(
            path: "/tmp/prbinding-rpc-repo-\(suffix)",
            displayName: "acme-prod", defaultBranch: "main")
        repoID = createdRepo.id
        worktreeID = try await db.worktrees.create(
            repoID: createdRepo.id, name: "wt-\(suffix)", branch: "branch-\(suffix)",
            path: "/tmp/prbinding-rpc-wt-\(suffix)", tmuxServer: "tbd-prbinding-rpc").id
        router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            prBindingRepoResolver: { _ in repo },
            actuationLog: makeTestActuationLog())
    }

    /// A second (third, …) worktree in the same repo, so the batched
    /// `pr.bindingsAll` can be asserted across more than one.
    func addWorktree() async throws -> UUID {
        let suffix = UUID().uuidString
        return try await db.worktrees.create(
            repoID: repoID, name: "wt-\(suffix)", branch: "branch-\(suffix)",
            path: "/tmp/prbinding-rpc-wt-\(suffix)", tmuxServer: "tbd-prbinding-rpc").id
    }

    func bindings() async throws -> PRBindingsResult {
        let request = try RPCRequest(method: RPCMethod.prBindings,
                                     params: PRBindingsParams(worktreeID: worktreeID))
        return try decode(PRBindingsResult.self, await router.handle(request))
    }

    /// The batched read the app polls — no worktree parameter at all.
    func bindingsAll() async throws -> PRBindingsAllResult {
        let request = RPCRequest(method: RPCMethod.prBindingsAll)
        return try decode(PRBindingsAllResult.self, await router.handle(request))
    }

    @discardableResult
    func attach(url: String? = nil, number: Int? = nil,
                source: String? = nil, worktreeID: UUID? = nil) async throws -> PRAttachResult {
        try await attachRaw(url: url, number: number, source: source, worktreeID: worktreeID)
    }

    /// The unguarded form the "neither url nor number" test drives — it still
    /// throws on an error response, which is the assertion that test makes.
    func attachRaw(url: String?, number: Int?, source: String? = nil,
                   worktreeID: UUID? = nil) async throws -> PRAttachResult {
        let request = try RPCRequest(
            method: RPCMethod.prAttach,
            params: PRBindingRefParams(worktreeID: worktreeID ?? self.worktreeID, url: url,
                                       number: number, source: source))
        return try decode(PRAttachResult.self, await router.handle(request))
    }

    @discardableResult
    func detach(url: String? = nil, number: Int? = nil,
                worktreeID: UUID? = nil) async throws -> Bool {
        let request = try RPCRequest(
            method: RPCMethod.prDetach,
            params: PRBindingRefParams(worktreeID: worktreeID ?? self.worktreeID,
                                       url: url, number: number))
        return try decode(PRDetachResult.self, await router.handle(request)).detached
    }

    private func decode<R: Decodable>(_ type: R.Type, _ response: RPCResponse) throws -> R {
        guard response.success else {
            throw HarnessError.rpcFailed(response.error ?? "no error message")
        }
        return try response.decodeResult(type)
    }
}

@Suite("PR binding RPC")
struct PRBindingRPCTests {

    @Test("pr.attach with a URL binds and pr.bindings returns it")
    func attachThenList() async throws {
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod"))
        let attach = try await harness.attach(url: "https://github.com/acme/acme-prod/pull/412")
        #expect(attach.outcome == "bound")
        #expect(attach.binding?.number == 412)

        let listed = try await harness.bindings()
        #expect(listed.bindings.map(\.number) == [412])
    }

    @Test("pr.attach accepts a bare number and resolves the worktree's repo")
    func attachByNumber() async throws {
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod"))
        let attach = try await harness.attach(number: 77)
        #expect(attach.binding?.url == "https://github.com/acme/acme-prod/pull/77")
    }

    @Test("pr.attach reports a wrong-repo rejection instead of binding")
    func attachWrongRepo() async throws {
        let harness = try await PRBindingRPCHarness(repo: ("acme", "other-repo"))
        let attach = try await harness.attach(url: "https://github.com/acme/acme-prod/pull/412")
        #expect(attach.outcome == "rejectedWrongRepo")
        #expect(attach.detail == "acme/acme-prod")
        #expect(attach.binding == nil)
        #expect(try await harness.bindings().bindings.isEmpty)
    }

    @Test("pr.detach tombstones and pr.bindings stops returning it")
    func detach() async throws {
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod"))
        _ = try await harness.attach(number: 412)
        #expect(try await harness.detach(number: 412))
        #expect(try await harness.bindings().bindings.isEmpty)

        // The tombstone is what makes the detach durable: an automatic source
        // must not bring the PR back on the next hook fire.
        let rebind = try await harness.attach(number: 412, source: PRBindingSource.hook.rawValue)
        #expect(rebind.outcome == "tombstoned")
        #expect(try await harness.bindings().bindings.isEmpty)
    }

    /// The app cannot otherwise tell "nothing is bound" from "the user unbound
    /// everything", and the two need opposite treatment: the first keeps the
    /// worktree's cached single `prStatus` on screen (the offline-`gh` case),
    /// the second must drop it.
    @Test("pr.bindings reports how many bindings are tombstoned")
    func bindingsReportDetachedCount() async throws {
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod"))
        #expect(try await harness.bindings().detachedCount == 0)

        _ = try await harness.attach(number: 412)
        _ = try await harness.attach(number: 413)
        var listed = try await harness.bindings()
        #expect(listed.bindings.map(\.number) == [412, 413])
        #expect(listed.detachedCount == 0)

        #expect(try await harness.detach(number: 412))
        listed = try await harness.bindings()
        #expect(listed.bindings.map(\.number) == [413])
        #expect(listed.detachedCount == 1)

        // Detaching the LAST one is the regression case: an empty list with a
        // non-zero count.
        #expect(try await harness.detach(number: 413))
        listed = try await harness.bindings()
        #expect(listed.bindings.isEmpty)
        #expect(listed.detachedCount == 2)

        // A manual attach revives the tombstone, and the count follows.
        _ = try await harness.attach(number: 413)
        listed = try await harness.bindings()
        #expect(listed.bindings.map(\.number) == [413])
        #expect(listed.detachedCount == 1)
    }

    // MARK: - pr.bindingsAll

    /// The batched read exists because the app cannot name the worktrees worth
    /// asking about: a hook-bound PR sits on a branch its worktree never checked
    /// out, so it appears in no branch-derived status cache and a per-worktree
    /// fan-out never reaches it. One call reports the whole table.
    @Test("pr.bindingsAll returns several worktrees' bindings in one call")
    func bindingsAllAcrossWorktrees() async throws {
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod"))
        let second = try await harness.addWorktree()
        try await harness.attach(number: 412)
        try await harness.attach(number: 413)
        try await harness.attach(number: 500, worktreeID: second)

        let all = try await harness.bindingsAll()
        #expect(all.worktrees.count == 2)
        let byWorktree = Dictionary(uniqueKeysWithValues:
            all.worktrees.map { ($0.worktreeID, $0) })
        #expect(byWorktree[harness.worktreeID]?.bindings.map(\.number) == [412, 413])
        #expect(byWorktree[second]?.bindings.map(\.number) == [500])
        #expect(byWorktree[harness.worktreeID]?.detachedCount == 0)
        #expect(byWorktree[second]?.detachedCount == 0)
    }

    /// Tombstoned rows are excluded from the live lists but still counted, and a
    /// worktree whose bindings are ALL tombstoned still has to appear — an empty
    /// live list with a non-zero count is what suppresses the app's
    /// legacy-status fallback, so a detach is not silently undone.
    @Test("pr.bindingsAll excludes tombstoned rows and still reports a tombstone-only worktree")
    func bindingsAllReportsTombstones() async throws {
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod"))
        let tombstonedOnly = try await harness.addWorktree()
        try await harness.attach(number: 412)
        try await harness.attach(number: 413)
        try await harness.attach(number: 500, worktreeID: tombstonedOnly)
        #expect(try await harness.detach(number: 413))
        #expect(try await harness.detach(number: 500, worktreeID: tombstonedOnly))

        let all = try await harness.bindingsAll()
        let byWorktree = Dictionary(uniqueKeysWithValues:
            all.worktrees.map { ($0.worktreeID, $0) })
        #expect(byWorktree[harness.worktreeID]?.bindings.map(\.number) == [412])
        #expect(byWorktree[harness.worktreeID]?.detachedCount == 1)
        // Present, with nothing live and one tombstone.
        #expect(byWorktree[tombstonedOnly]?.bindings.isEmpty == true)
        #expect(byWorktree[tombstonedOnly]?.detachedCount == 1)
    }

    /// A worktree with neither a live binding nor a tombstone says nothing, so
    /// the response does not grow one entry per worktree in the fleet.
    @Test("pr.bindingsAll omits a worktree that has no bindings at all")
    func bindingsAllOmitsUnboundWorktrees() async throws {
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod"))
        _ = try await harness.addWorktree()
        #expect(try await harness.bindingsAll().worktrees.isEmpty)

        try await harness.attach(number: 412)
        let all = try await harness.bindingsAll()
        #expect(all.worktrees.map(\.worktreeID) == [harness.worktreeID])
    }

    @Test("pr.detach of an unbound PR reports false rather than erroring")
    func detachUnknown() async throws {
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod"))
        #expect(try await harness.detach(number: 999) == false)
    }

    @Test("pr.attach with neither url nor number is an RPC error")
    func attachMissingArgs() async throws {
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod"))
        await #expect(throws: (any Error).self) {
            _ = try await harness.attachRaw(url: nil, number: nil)
        }
    }

    @Test("a bare number whose repo is not resolvable yet defers instead of calling it invalid")
    func attachByNumberDefersOnUnknownRepo() async throws {
        // The state a worktree is in for the first seconds of its life. The
        // user's input is perfectly valid, so telling them it "is not a PR
        // number or a GitHub PR URL" sends them looking for a typo.
        let harness = try await PRBindingRPCHarness(repo: nil)
        let attach = try await harness.attach(number: 412)
        #expect(attach.outcome == "deferredUnknownRepo")
        #expect(attach.binding == nil)
        #expect(try await harness.bindings().bindings.isEmpty)
    }

    @Test("a malformed url is still reported as unusable input")
    func attachRejectsMalformedURL() async throws {
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod"))
        await #expect(throws: (any Error).self) {
            _ = try await harness.attachRaw(url: "https://example.com/not/a/pr", number: nil)
        }
    }

    @Test("pr.detach of a bare number whose repo is unresolvable says so rather than reporting not-bound")
    func detachByNumberDefersOnUnknownRepo() async throws {
        let harness = try await PRBindingRPCHarness(repo: nil)
        await #expect(throws: (any Error).self) {
            _ = try await harness.detach(number: 412)
        }
    }

    @Test("pr.detach of an already-detached PR reports false")
    func detachTwiceReportsFalse() async throws {
        // `updateAll` counts matched rows, so the second detach used to print
        // "Detached." for a no-op.
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod"))
        _ = try await harness.attach(number: 412)
        #expect(try await harness.detach(number: 412))
        #expect(try await harness.detach(number: 412) == false)
    }
}
