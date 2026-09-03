import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// `remote.create`'s `seed` field — the capability-gated way a new session
/// begins with a retained conversation as its history
/// (`docs/remote-provider-contract.md` § `create`).
///
/// Every test here reads the composed stdin rather than the response, because
/// the whole of `seed` is what reaches the provider: a body missing the field,
/// or carrying it in the wrong place, produces a perfectly healthy-looking
/// session with none of the caller's conversation in it.
///
/// Tier 2: in-memory GRDB plus a fake provider invoker, no real subprocess.
/// Wiring mirrors `RPCRouterRemoteExchangeTests` — `describe` is popped first,
/// so scripts read `[describe, create, list]`.
@Suite("RPCRouter remote.create seed")
struct RPCRouterRemoteSeedTests: ~Copyable {
    let db: TBDDatabase
    let subs: StateSubscriptionManager
    let dir: URL
    let registryURL: URL

    init() throws {
        let localDB = try TBDDatabase(inMemory: true)
        let localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpc-remote-seed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        let localRegistryURL = localDir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "agentbox", "exec": "/nonexistent"}]"#
            .write(to: localRegistryURL, atomically: true, encoding: .utf8)
        db = localDB
        subs = StateSubscriptionManager()
        dir = localDir
        registryURL = localRegistryURL
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private func router(invoker: FakeProviderInvoker) async -> RPCRouter {
        let manager = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL,
            actuationLog: makeTestActuationLog())
        await manager.loadRegistryAndDescribe()
        return RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver(),
                subscriptions: subs),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            subscriptions: subs,
            remoteManager: manager, actuationLog: makeTestActuationLog())
    }

    private func call(_ router: RPCRouter, _ method: String, _ params: String) async -> RPCResponse {
        await router.handle(RPCRequest(method: method, params: params))
    }

    private func describeDeclaring(_ capabilities: [String]) -> ProviderResult {
        let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ", ")
        return providerOK(#"{"contract_versions": [1], "name": "agentbox", "capabilities": [\#(caps)]}"#)
    }

    private let createdSession = #"{"id": "new-1", "state": "starting"}"#
    private let emptyList = #"{"complete": true, "sessions": []}"#

    /// The composed `create` stdin, decoded.
    private func sentBody(_ invoker: FakeProviderInvoker) throws -> [String: Any] {
        let stdin = try #require(invoker.stdinsSnapshot().compactMap { $0 }.first)
        return try #require(try JSONSerialization.jsonObject(with: stdin) as? [String: Any])
    }

    // MARK: - Sent when declared

    @Test func createSendsSeedWhenTheProviderDeclaresIt() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["seed"]), providerOK(createdSession), providerOK(emptyList),
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.create",
            #"{"provider": "agentbox", "paramsJSON": "{}", "seedRetainedKey": "opaque-key"}"#)
        #expect(response.success)
        let body = try sentBody(invoker)
        let seed = try #require(body["seed"] as? [String: Any])
        #expect(seed["retained_key"] as? String == "opaque-key")
    }

    /// The field is a top-level sibling of `params` and `idempotency_key`, and
    /// emphatically not a member of `params` — which is the provider's own
    /// free-form set, where a contract field would be indistinguishable from a
    /// provider-defined one.
    @Test func seedIsATopLevelSiblingAndNeverAMemberOfParams() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["seed"]), providerOK(createdSession), providerOK(emptyList),
        ])
        let r = await router(invoker: invoker)
        let request = #"{"provider": "agentbox", "paramsJSON": "{\"repo\": \"acme/api\"}", "seedRetainedKey": "opaque-key"}"#
        #expect(await call(r, "remote.create", request).success)
        let body = try sentBody(invoker)
        #expect(body.keys.sorted() == ["idempotency_key", "params", "seed"])
        let params = try #require(body["params"] as? [String: Any])
        #expect(params.keys.contains("seed") == false)
        #expect(params["repo"] as? String == "acme/api",
                "the caller's own params must survive the seed field verbatim")
    }

    /// A key is opaque: a caller MUST NOT parse, construct or pattern-match
    /// one, so it may hold a quote or a backslash. Interpolated raw, such a key
    /// would produce a malformed body the provider rejects with no indication
    /// of why.
    @Test func createEscapesAnOpaqueSeedKey() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["seed"]), providerOK(createdSession), providerOK(emptyList),
        ])
        let r = await router(invoker: invoker)
        // A key carrying a quote and a backslash, escaped once for the RPC
        // params string and therefore twice here.
        #expect(await call(r, "remote.create",
            #"{"provider": "agentbox", "paramsJSON": "{}", "seedRetainedKey": "a\"b\\c"}"#).success)
        let body = try sentBody(invoker)
        let seed = try #require(body["seed"] as? [String: Any])
        #expect(seed["retained_key"] as? String == #"a"b\c"#)
    }

    // MARK: - Refused when undeclared

    /// The discriminating half is `invoker.calls`: the contract requires a
    /// provider to ignore stdin fields it does not recognize, so a `seed` sent
    /// to a provider that never declared it would exit 0 with an empty session
    /// the caller believed carried its conversation. Nothing may be spawned.
    @Test func createRefusesSeedWhenTheProviderHasNotDeclaredIt() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [describeDeclaring(["stop", "log"])])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.create",
            #"{"provider": "agentbox", "paramsJSON": "{}", "seedRetainedKey": "opaque-key"}"#)
        #expect(response.success == false)
        #expect(response.error?.contains("seed") == true)
        #expect(invoker.calls == [["describe"]])
    }

    /// A provider with no cached `describe` reads as declaring nothing, so a
    /// seeded create refuses rather than failing open.
    @Test func createRefusesSeedWhenTheProviderHasNoCachedDescribe() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(exitCode: 1, stdout: Data(), stderr: "describe failed"),
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.create",
            #"{"provider": "agentbox", "paramsJSON": "{}", "seedRetainedKey": "opaque-key"}"#)
        #expect(response.success == false)
        #expect(response.error?.contains("seed") == true)
        #expect(invoker.calls == [["describe"]])
    }

    // MARK: - Absent when nothing was asked for

    /// An unseeded create is unchanged: no `seed` key at all, not a null one.
    /// A provider reading `"seed": null` would have to decide what an explicit
    /// nothing means.
    @Test func createSendsNoSeedFieldWhenNoKeyWasSupplied() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["seed"]), providerOK(createdSession), providerOK(emptyList),
        ])
        let r = await router(invoker: invoker)
        #expect(await call(r, "remote.create",
                          #"{"provider": "agentbox", "paramsJSON": "{}"}"#).success)
        let body = try sentBody(invoker)
        #expect(body.keys.sorted() == ["idempotency_key", "params"])
    }

    /// And a provider that declares nothing is still perfectly able to take an
    /// unseeded create — the gate is on the field, never on `create` itself.
    @Test func createWithoutASeedKeyIsUngatedByTheCapability() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring([]), providerOK(createdSession), providerOK(emptyList),
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.create",
                                  #"{"provider": "agentbox", "paramsJSON": "{}"}"#)
        #expect(response.success)
        #expect(invoker.calls == [["describe"], ["create"], ["list"]])
    }
}
