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
/// worktree's own `owner/name/host` comes from the router's injected
/// `prBindingRepoResolver` seam — production resolves it with `gh repo view`
/// (or the `origin` remote) behind `PRStatusManager`'s TTL cache, which a unit
/// test must not spawn.
///
/// `gitLabHosts` is the other injected fact: composing a URL for a bare number
/// asks `PRStatusManager` which hosts speak GitLab, and the injecting init
/// answers from a set rather than from `glab auth status`. A harness that names
/// no host therefore stands for every non-GitLab fleet at once — github.com,
/// GitHub Enterprise, Bitbucket, Gitea, Codeberg.
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

    init(repo: (owner: String, name: String, host: String)?,
         gitLabHosts: Set<String> = []) async throws {
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
            // `ghRunner` is required by the injecting init and must never be
            // reached from these paths; failing loudly is the assertion that it
            // is not.
            prManager: PRStatusManager(
                ghRunner: { _, _ in
                    Issue.record("pr.attach must not spawn gh")
                    return nil
                },
                gitLabHosts: gitLabHosts),
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

    /// A remote lane's row in the same repo. It exists — so a binding's foreign
    /// key holds and the injected repo resolver still answers for it — but it
    /// has no directory on this machine, which is the state in which the forge
    /// cannot be determined.
    func addRemoteWorktree() async throws -> UUID {
        let suffix = UUID().uuidString
        return try await db.worktrees.createRemote(
            repoID: repoID, name: "remote-\(suffix)", branch: "branch-\(suffix)",
            provider: "acme-cloud", sessionID: "session-\(suffix)").id
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
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod", "github.com"))
        let attach = try await harness.attach(url: "https://github.com/acme/acme-prod/pull/412")
        #expect(attach.outcome == "bound")
        #expect(attach.binding?.number == 412)

        let listed = try await harness.bindings()
        #expect(listed.bindings.map(\.number) == [412])
    }

    @Test("pr.attach accepts a bare number and resolves the worktree's repo")
    func attachByNumber() async throws {
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod", "github.com"))
        let attach = try await harness.attach(number: 77)
        #expect(attach.binding?.url == "https://github.com/acme/acme-prod/pull/77")
    }

    /// The bug this closes: a bare number on a GitLab checkout used to compose
    /// `https://github.com/<namespace>/<project>/pull/<n>` — a github.com URL
    /// for a repo that does not exist there, bound and then polled forever.
    @Test("pr.attach by number composes a merge-request URL on a GitLab host")
    func attachByNumberGitLab() async throws {
        let harness = try await PRBindingRPCHarness(
            repo: ("acme/platform", "api-gateway", "git.acme.example"),
            gitLabHosts: ["git.acme.example"])
        let attach = try await harness.attach(number: 412)
        #expect(attach.outcome == "bound")
        #expect(attach.binding?.url
                == "https://git.acme.example/acme/platform/api-gateway/-/merge_requests/412")
        #expect(attach.binding?.host == "git.acme.example")
        #expect(attach.binding?.owner == "acme/platform")
        #expect(attach.binding?.repo == "api-gateway")
    }

    /// A namespace nests arbitrarily on GitLab, and every level of it belongs
    /// to the owner — the project is only ever the last segment.
    @Test("pr.attach by number keeps a deeply nested GitLab namespace intact")
    func attachByNumberNestedNamespace() async throws {
        let harness = try await PRBindingRPCHarness(
            repo: ("acme/platform/backend", "api-gateway", "git.acme.example"),
            gitLabHosts: ["git.acme.example"])
        let attach = try await harness.attach(number: 7)
        #expect(attach.binding?.url
                == "https://git.acme.example/acme/platform/backend/api-gateway/-/merge_requests/7")
        #expect(attach.binding?.owner == "acme/platform/backend")
    }

    /// A self-hosted host is not github.com, so the composed URL must stay on
    /// the worktree's own host rather than silently naming github.com — which
    /// is what the hardcoded composition did.
    ///
    /// It must equally not become a merge request. "Not github.com" is not
    /// evidence of GitLab: GitHub Enterprise, Bitbucket, Gitea and Codeberg all
    /// live on their own hosts and all serve `/pull/<n>`. Only a host the
    /// resolver actually names gets GitLab's shape, and this harness names
    /// none, so `/pull/` is the whole answer — and the URL is asserted entire,
    /// because a prefix check passes for a merge-request URL too.
    @Test("pr.attach by number composes /pull/ for a self-hosted non-GitLab host")
    func attachByNumberSelfHostedPullRequest() async throws {
        for host in ["github.acme.example", "bitbucket.acme.example", "codeberg.org"] {
            let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod", host))
            let attach = try await harness.attach(number: 412)
            #expect(attach.outcome == "bound")
            #expect(attach.binding?.url == "https://\(host)/acme/acme-prod/pull/412")
            #expect(attach.binding?.host == host)
        }
    }

    /// The same host, classified both ways, so the branch is pinned rather than
    /// the string: `git.acme.example` is a merge request only when the resolver
    /// names it GitLab.
    @Test("pr.attach by number follows the resolver, not the hostname")
    func attachByNumberFollowsTheResolver() async throws {
        let unknown = try await PRBindingRPCHarness(
            repo: ("acme", "acme-prod", "git.acme.example"))
        #expect(try await unknown.attach(number: 412).binding?.url
                == "https://git.acme.example/acme/acme-prod/pull/412")

        let known = try await PRBindingRPCHarness(
            repo: ("acme", "acme-prod", "git.acme.example"),
            gitLabHosts: ["git.acme.example"])
        #expect(try await known.attach(number: 412).binding?.url
                == "https://git.acme.example/acme/acme-prod/-/merge_requests/412")
    }

    /// The forge shape comes from a second lookup, independent of the repo
    /// resolver: the worktree's own directory is where `glab` reads its
    /// configuration from, and a worktree with no local row — a remote lane, or
    /// one deleted between the two awaits — has no directory here to ask in.
    /// Nothing has then answered "GitLab" or "not GitLab", and either shape is
    /// a guess.
    ///
    /// `/pull/<n>` is the damaging guess, which is why the resolver here names
    /// the host as GitLab while the worktree is remote: composing GitHub's
    /// shape then persists a binding whose URL 404s and whose label reads "PR".
    /// So the call defers, exactly as it does when the repo cannot be named —
    /// and the repo *is* nameable here, so the deferral can only come from the
    /// forge lookup.
    @Test("pr.attach by number defers when the worktree's forge cannot be determined")
    func attachByNumberUndeterminedForge() async throws {
        let harness = try await PRBindingRPCHarness(
            repo: ("acme", "acme-prod", "git.acme.example"),
            gitLabHosts: ["git.acme.example"])
        let remote = try await harness.addRemoteWorktree()
        let attach = try await harness.attach(number: 412, worktreeID: remote)
        #expect(attach.outcome == "deferredUnknownRepo")
        #expect(attach.binding == nil)
    }

    /// github.com short-circuits inside the resolver before any subprocess, so
    /// the unchanged GitHub shape is not merely the fallback here — it is the
    /// answer a GitHub fleet reaches without asking anything.
    @Test("pr.attach by number on github.com composes /pull/ even with GitLab hosts known")
    func attachByNumberGitHubUnchanged() async throws {
        let harness = try await PRBindingRPCHarness(
            repo: ("acme", "acme-prod", "github.com"),
            gitLabHosts: ["git.acme.example"])
        #expect(try await harness.attach(number: 412).binding?.url
                == "https://github.com/acme/acme-prod/pull/412")
    }

    /// The status bar names a PR by whatever its chip holds, and a chip lifted
    /// from a cached `Worktree.prStatus` can hold a url `PRBindingExtractor`
    /// will not accept — its pattern is host-locked to `https://github.com/`,
    /// so on a worktree hosted anywhere else EVERY synthetic chip is in that
    /// state. Sending url and number together is only worth anything if a url
    /// that does not parse falls through to the number instead of failing.
    @Test("a reference whose url does not parse falls through to its number")
    func unparseableURLFallsThroughToNumber() async throws {
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod", "github.com"))

        #expect(try await harness.detach(
            url: "https://git.acme-corp.example/acme/acme-prod/pull/412", number: 412))

        // Resolved against the worktree's own repo, exactly as a bare number is.
        let recorded = try await harness.db.prBindings.list(
            worktreeID: harness.worktreeID, includeDetached: true)
        #expect(recorded.count == 1)
        #expect(recorded.first?.number == 412)
        #expect(recorded.first?.url == "https://github.com/acme/acme-prod/pull/412")
    }

    @Test("a reference with an unparseable url and no number is still an error")
    func unparseableURLWithoutNumberIsAnError() async throws {
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod", "github.com"))
        // Nothing is guessed — the fallthrough adds a second chance, not a
        // default.
        await #expect(throws: (any Error).self) {
            try await harness.detach(url: "not a pr url at all")
        }
    }

    @Test("pr.attach reports a wrong-repo rejection instead of binding")
    func attachWrongRepo() async throws {
        let harness = try await PRBindingRPCHarness(repo: ("acme", "other-repo", "github.com"))
        let attach = try await harness.attach(url: "https://github.com/acme/acme-prod/pull/412")
        #expect(attach.outcome == "rejectedWrongRepo")
        #expect(attach.detail == "acme/acme-prod")
        #expect(attach.binding == nil)
        #expect(try await harness.bindings().bindings.isEmpty)
    }

    /// The router half of the cross-forge guard: the coordinator only knows a
    /// worktree's forge because the router hands it a closure over the same
    /// `glab`-derived answer `pr.attach <number>` composes URLs from. A closure
    /// wired to the wrong thing — or to nothing — passes every coordinator-level
    /// test and still binds here.
    @Test("pr.attach of a github.com URL is rejected on a GitLab checkout")
    func attachGitHubURLOnGitLabCheckout() async throws {
        let harness = try await PRBindingRPCHarness(
            repo: ("acme", "acme-prod", "git.acme.example"),
            gitLabHosts: ["git.acme.example"])
        let attach = try await harness.attach(url: "https://github.com/acme/acme-prod/pull/412")
        #expect(attach.outcome == "rejectedWrongRepo")
        // Owner and name match, so the host is the whole disagreement.
        #expect(attach.detail == "github.com/acme/acme-prod")
        #expect(attach.binding == nil)
        #expect(try await harness.bindings().bindings.isEmpty)
    }

    /// The same URL on a self-hosted host that speaks no GitLab still binds —
    /// the exemption a host-locked GitHub pattern earns, and the reason the
    /// rejection above is keyed on the declared forge rather than on the
    /// hostname not being github.com.
    @Test("pr.attach of a github.com URL still binds on a non-GitLab self-hosted checkout")
    func attachGitHubURLOnEnterpriseCheckout() async throws {
        let harness = try await PRBindingRPCHarness(
            repo: ("acme", "acme-prod", "ghe.acme.example"),
            gitLabHosts: ["git.acme.example"])
        let attach = try await harness.attach(url: "https://github.com/acme/acme-prod/pull/412")
        #expect(attach.outcome == "bound")
        #expect(attach.binding?.host == "github.com")
    }

    @Test("pr.detach tombstones and pr.bindings stops returning it")
    func detach() async throws {
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod", "github.com"))
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
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod", "github.com"))
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
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod", "github.com"))
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
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod", "github.com"))
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
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod", "github.com"))
        _ = try await harness.addWorktree()
        #expect(try await harness.bindingsAll().worktrees.isEmpty)

        try await harness.attach(number: 412)
        let all = try await harness.bindingsAll()
        #expect(all.worktrees.map(\.worktreeID) == [harness.worktreeID])
    }

    /// The last leg of the title's round trip: the column reaches the app as a
    /// field on the binding `pr.bindings` returns, so the status bar can say
    /// what `#412` actually is.
    @Test("pr.bindings carries a stored title")
    func bindingsCarryTitle() async throws {
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod", "github.com"))
        let attached = try await harness.attach(number: 412)
        let bindingID = try #require(attached.binding?.id)
        #expect(attached.binding?.title == nil)

        try await harness.db.prBindings.updateObservation(
            bindingID: bindingID,
            status: PRStatus(number: 412, url: "https://github.com/acme/acme-prod/pull/412",
                             state: .mergeable),
            title: "Fix the login timeout")

        #expect(try await harness.bindings().bindings.first?.title == "Fix the login timeout")
    }

    /// A worktree with no bindings but a cached `Worktree.prStatus` renders a
    /// synthetic chip, and the app's untrack gesture detaches it by number. If
    /// that matched no row and reported failure, `detachedCount` would stay
    /// zero, the legacy-status fallback would keep the chip on screen, and the
    /// control would silently decline. So the detach records the tombstone —
    /// and the non-zero count is the signal the app reads.
    @Test("pr.detach of an unbound PR tombstones it and raises detachedCount")
    func detachUnbound() async throws {
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod", "github.com"))
        #expect(try await harness.detach(number: 999))

        let listed = try await harness.bindings()
        #expect(listed.bindings.isEmpty)
        #expect(listed.detachedCount == 1)

        // Durable, exactly like any other tombstone: an automatic source may
        // not bring the PR back on the next poll or hook fire.
        let rebind = try await harness.attach(number: 999, source: PRBindingSource.branch.rawValue)
        #expect(rebind.outcome == "tombstoned")
        // And a manual attach still reverses it.
        #expect(try await harness.attach(number: 999).outcome == "bound")
        #expect(try await harness.bindings().detachedCount == 0)
    }

    @Test("pr.attach with neither url nor number is an RPC error")
    func attachMissingArgs() async throws {
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod", "github.com"))
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
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod", "github.com"))
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
        let harness = try await PRBindingRPCHarness(repo: ("acme", "acme-prod", "github.com"))
        _ = try await harness.attach(number: 412)
        #expect(try await harness.detach(number: 412))
        #expect(try await harness.detach(number: 412) == false)
    }
}
