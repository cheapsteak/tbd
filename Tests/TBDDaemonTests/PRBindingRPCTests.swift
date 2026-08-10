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

    init(repo: (owner: String, name: String)?) async throws {
        let db = try TBDDatabase(inMemory: true)
        self.db = db
        let suffix = UUID().uuidString
        let createdRepo = try await db.repos.create(
            path: "/tmp/prbinding-rpc-repo-\(suffix)",
            displayName: "acme-prod", defaultBranch: "main")
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

    func bindings() async throws -> PRBindingsResult {
        let request = try RPCRequest(method: RPCMethod.prBindings,
                                     params: PRBindingsParams(worktreeID: worktreeID))
        return try decode(PRBindingsResult.self, await router.handle(request))
    }

    @discardableResult
    func attach(url: String? = nil, number: Int? = nil,
                source: String? = nil) async throws -> PRAttachResult {
        try await attachRaw(url: url, number: number, source: source)
    }

    /// The unguarded form the "neither url nor number" test drives — it still
    /// throws on an error response, which is the assertion that test makes.
    func attachRaw(url: String?, number: Int?, source: String? = nil) async throws -> PRAttachResult {
        let request = try RPCRequest(
            method: RPCMethod.prAttach,
            params: PRBindingRefParams(worktreeID: worktreeID, url: url,
                                       number: number, source: source))
        return try decode(PRAttachResult.self, await router.handle(request))
    }

    func detach(url: String? = nil, number: Int? = nil) async throws -> Bool {
        let request = try RPCRequest(
            method: RPCMethod.prDetach,
            params: PRBindingRefParams(worktreeID: worktreeID, url: url, number: number))
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
}
