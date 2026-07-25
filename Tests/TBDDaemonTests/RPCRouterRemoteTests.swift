import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

/// Thread-safe collector for broadcast StateDeltas. Mirrors the pattern in
/// `RemoteProviderManagerTests`'s private `BroadcastDeltas` (not reusable
/// here — it's `private` to that file).
private final class BroadcastDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [StateDelta] = []

    func append(_ delta: StateDelta) {
        lock.lock(); defer { lock.unlock() }
        deltas.append(delta)
    }

    func snapshot() -> [StateDelta] {
        lock.lock(); defer { lock.unlock() }
        return deltas
    }
}

// Tier 2: in-memory GRDB + a fake provider invoker, no real subprocess.
@Suite("RPCRouter remote.* handlers")
struct RPCRouterRemoteTests: ~Copyable {
    let db: TBDDatabase
    let subs: StateSubscriptionManager
    let dir: URL
    let registryURL: URL

    init() throws {
        // All throwing work happens on locals before any stored property is
        // assigned — a noncopyable struct can't leave itself partially
        // initialized if a later throw fires (compiler-enforced).
        let localDB = try TBDDatabase(inMemory: true)
        let localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpc-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        let localRegistryURL = localDir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "fake", "exec": "/nonexistent"}]"#
            .write(to: localRegistryURL, atomically: true, encoding: .utf8)
        db = localDB
        subs = StateSubscriptionManager()
        dir = localDir
        registryURL = localRegistryURL
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    /// `manager: nil` models the daemon booting with the flag off (case b of
    /// the flag gate — no manager was ever constructed). Passing a manager
    /// models the daemon booting with the flag on. Passes the suite's own
    /// `subs` through (rather than letting `RPCRouter` default-construct its
    /// own `StateSubscriptionManager`) so broadcast assertions observe the
    /// same object the test subscribed to.
    private func router(manager: RemoteProviderManager?) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            subscriptions: subs,
            remoteManager: manager)
    }

    private func router(invoker: FakeProviderInvoker) -> RPCRouter {
        let manager = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL)
        return router(manager: manager)
    }

    private func call(_ router: RPCRouter, _ method: String, _ params: String = "{}") async -> RPCResponse {
        await router.handle(RPCRequest(method: method, params: params))
    }

    @Test func remoteVerbsErrorWhenFlagOff() async throws {
        let r = router(invoker: FakeProviderInvoker(script: []))
        for method in ["remote.providers", "remote.sessions", "remote.create",
                       "remote.stop", "remote.send", "remote.log", "remote.dismiss"] {
            let response = await call(r, method,
                #"{"provider": "fake", "sessionID": "x", "text": "t", "paramsJSON": "{}"}"#)
            #expect(response.success == false, "expected \(method) to be gated")
            #expect(response.error == "remote backends disabled")
        }
    }

    /// Case (b) of the flag gate: the flag is ON in the DB (a user flipped
    /// it via `config.setRemoteBackends`) but the router has no manager
    /// because the daemon booted with the flag off and hasn't restarted.
    /// Must degrade to the same clear error as case (a), not crash or
    /// silently no-op.
    @Test func remoteVerbsErrorWhenManagerNilEvenIfFlagOn() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let r = router(manager: nil)
        for method in ["remote.providers", "remote.sessions", "remote.create",
                       "remote.stop", "remote.send", "remote.log", "remote.dismiss"] {
            let response = await call(r, method,
                #"{"provider": "fake", "sessionID": "x", "text": "t", "paramsJSON": "{}"}"#)
            #expect(response.success == false, "expected \(method) to be gated")
            #expect(response.error == "remote backends disabled")
        }
    }

    @Test func sessionsReturnsMirrorWhenFlagOn() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "fake",
            sessions: [RemoteSessionPayload(id: "a", state: .running)], now: Date())
        let r = router(invoker: FakeProviderInvoker(script: []))
        let response = await call(r, "remote.sessions")
        #expect(response.success)
        let result = try response.decodeResult(RemoteSessionsResult.self)
        #expect(result.sessions.map(\.payload.id) == ["a"])
    }

    @Test func createPassesParamsThroughAndReturnsSession() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"id": "new-1", "state": "starting"}"#)
        ])
        let r = router(invoker: invoker)
        let response = await call(r, "remote.create",
            #"{"provider": "fake", "paramsJSON": "{\"repo\": \"acme/api\"}"}"#)
        #expect(response.success)
        #expect(invoker.calls == [["create"]])
        let session = try response.decodeResult(RemoteSessionPayload.self)
        #expect(session.id == "new-1")
    }

    /// The exact create body is the whole point of `remote.create`'s
    /// contract — the caller's `params` must survive verbatim, and exactly
    /// one `idempotency_key` must be minted. This was previously unasserted:
    /// `createPassesParamsThroughAndReturnsSession` above only checks the
    /// verb name.
    @Test func createBodyContainsCallerParamsAndOneIdempotencyKey() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"id": "new-1", "state": "starting"}"#)
        ])
        let r = router(invoker: invoker)
        let response = await call(r, "remote.create",
            #"{"provider": "fake", "paramsJSON": "{\"repo\": \"acme/api\"}"}"#)
        #expect(response.success)
        let stdin = try #require(invoker.stdinsSnapshot().first ?? nil)
        let body = try #require(
            try JSONSerialization.jsonObject(with: stdin) as? [String: Any])
        let params = try #require(body["params"] as? [String: Any])
        #expect(params["repo"] as? String == "acme/api")
        let key = try #require(body["idempotency_key"] as? String)
        #expect(!key.isEmpty)
        // Exactly one key in the body — not e.g. duplicated under another name.
        #expect(body.keys.sorted() == ["idempotency_key", "params"])
    }

    /// A timeout on the first `create` call must retry exactly once, with
    /// the SAME idempotency key — a fresh key on retry would defeat
    /// provider-side dedupe and double-create a remote session.
    @Test func createRetriesOnceOnTimeoutWithIdenticalStdin() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(outcomes: [
            .timeout,
            .result(providerOK(#"{"id": "new-1", "state": "starting"}"#)),
        ])
        let r = router(invoker: invoker)
        let response = await call(r, "remote.create",
            #"{"provider": "fake", "paramsJSON": "{}"}"#)
        #expect(response.success)
        #expect(invoker.calls == [["create"], ["create"]],
                "a timeout must produce exactly two create calls")
        let stdins = invoker.stdinsSnapshot()
        #expect(stdins.count == 2)
        #expect(stdins[0] == stdins[1],
                "the retry must reuse the SAME idempotency key, not mint a fresh one")
    }

    /// A timeout on both attempts must surface a readable message, not the
    /// raw `ProviderRunError` enum description.
    @Test func createSurfacesTimeoutMessageWhenBothAttemptsTimeOut() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(outcomes: [.timeout, .timeout])
        let r = router(invoker: invoker)
        let response = await call(r, "remote.create",
            #"{"provider": "fake", "paramsJSON": "{}"}"#)
        #expect(response.success == false)
        #expect(response.error?.contains("timeout(verb:") == false)
        #expect(response.error?.contains("fake") == true)
    }

    @Test func createRejectsNonObjectParamsJSON() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let r = router(invoker: FakeProviderInvoker(script: []))
        let response = await call(r, "remote.create",
            #"{"provider": "fake", "paramsJSON": "[1,2,3]"}"#)
        #expect(response.success == false)
        #expect(response.error?.contains("JSON object") == true)
    }

    @Test func createNormalizesEmptyParamsJSONToEmptyObject() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"id": "new-1", "state": "starting"}"#)
        ])
        let r = router(invoker: invoker)
        let response = await call(r, "remote.create", #"{"provider": "fake", "paramsJSON": ""}"#)
        #expect(response.success)
        let stdin = try #require(invoker.stdinsSnapshot().first ?? nil)
        let body = try #require(try JSONSerialization.jsonObject(with: stdin) as? [String: Any])
        #expect((body["params"] as? [String: Any])?.isEmpty == true)
    }

    @Test func createSurfacesProviderErrorMessage() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(exitCode: 1,
                stdout: Data(#"{"error": {"code": "invalid_params", "message": "branch required"}}"#.utf8),
                stderr: "")
        ])
        let r = router(invoker: invoker)
        let response = await call(r, "remote.create",
            #"{"provider": "fake", "paramsJSON": "{}"}"#)
        #expect(response.success == false)
        #expect(response.error?.contains("branch required") == true)
    }

    @Test func logDecodesRawBytes() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(exitCode: 0, stdout: Data("line1\nline2\n".utf8), stderr: "")
        ])
        let r = router(invoker: invoker)
        let response = await call(r, "remote.log",
            #"{"provider": "fake", "sessionID": "a", "lines": 100}"#)
        #expect(response.success)
        let result = try response.decodeResult(RemoteLogResult.self)
        #expect(result.text == "line1\nline2\n")
        #expect(invoker.calls == [["log", "a", "--lines", "100"]])
    }

    @Test func stopAdoptsReturnedSessionIntoMirror() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"id": "a", "state": "exited", "exit_code": 0}"#)
        ])
        let r = router(invoker: invoker)
        let response = await call(r, "remote.stop", #"{"provider": "fake", "sessionID": "a"}"#)
        #expect(response.success)
        #expect(invoker.calls == [["stop", "a"]])
        let rows = try await db.remoteSessions.list()
        #expect(rows.first?.decodedPayload?.state == .exited)
    }

    @Test func sendDeliversTextAsStdin() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(exitCode: 0, stdout: Data(), stderr: "")
        ])
        let r = router(invoker: invoker)
        let response = await call(r, "remote.send",
            #"{"provider": "fake", "sessionID": "a", "text": "hello agent"}"#)
        #expect(response.success)
        #expect(invoker.calls == [["send", "a"]])
        #expect(invoker.stdinsSnapshot().first ?? nil == Data("hello agent".utf8))
    }

    @Test func dismissMarksRowDismissedAndBroadcastsChange() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "fake", sessions: [RemoteSessionPayload(id: "a", state: .running)], now: Date())
        let deltas = BroadcastDeltas()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let r = router(invoker: FakeProviderInvoker(script: []))
        let response = await call(r, "remote.dismiss", #"{"provider": "fake", "sessionID": "a"}"#)
        #expect(response.success)
        let rows = try await db.remoteSessions.list()
        #expect(rows.first?.dismissed == true)
        let changeBroadcasts = deltas.snapshot().filter {
            if case .remoteSessionsChanged = $0 { return true }
            return false
        }
        #expect(changeBroadcasts.count == 1, "dismiss must broadcast a change delta")
    }

    /// Dismissing an already-dismissed row (or an unknown session) changes
    /// nothing — no pointless broadcast, matching the store's other paths
    /// (`applySnapshot`/`markGone`) which gate broadcasts on `changed`.
    @Test func dismissDoesNotBroadcastWhenNothingChanged() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let deltas = BroadcastDeltas()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let r = router(invoker: FakeProviderInvoker(script: []))
        let response = await call(r, "remote.dismiss", #"{"provider": "fake", "sessionID": "nonexistent"}"#)
        #expect(response.success)
        let changeBroadcasts = deltas.snapshot().filter {
            if case .remoteSessionsChanged = $0 { return true }
            return false
        }
        #expect(changeBroadcasts.isEmpty)
    }

    @Test func configToggleRoundTrips() async throws {
        let r = router(invoker: FakeProviderInvoker(script: []))
        let response = await call(r, "config.setRemoteBackends", #"{"enabled": true}"#)
        #expect(response.success)
        let config = try await db.config.get()
        #expect(config.remoteBackendsEnabled == true)
    }

    @Test func configToggleOffLeavesFlagFalse() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let r = router(invoker: FakeProviderInvoker(script: []))
        let response = await call(r, "config.setRemoteBackends", #"{"enabled": false}"#)
        #expect(response.success)
        let config = try await db.config.get()
        #expect(config.remoteBackendsEnabled == false)
    }

    // MARK: - daemon.capabilities

    @Test func capabilitiesReportsFlagOffAndNotLiveByDefault() async throws {
        let r = router(manager: nil)
        let response = await call(r, "daemon.capabilities")
        let result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.remoteBackendsEnabled == false)
        #expect(result.remoteBackendsLive == false)
    }

    /// The state a later task's settings copy depends on distinguishing:
    /// flag flipped on via RPC, but the router still holds the manager it
    /// was constructed with (nil) because the daemon hasn't restarted.
    @Test func capabilitiesReportsFlagOnButNotLiveWithoutRestart() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let r = router(manager: nil)
        let response = await call(r, "daemon.capabilities")
        let result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.remoteBackendsEnabled == true)
        #expect(result.remoteBackendsLive == false)
    }

    @Test func capabilitiesReportsLiveWhenManagerPresent() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let r = router(invoker: FakeProviderInvoker(script: []))
        let response = await call(r, "daemon.capabilities")
        let result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.remoteBackendsEnabled == true)
        #expect(result.remoteBackendsLive == true)
    }

    // MARK: - wire-value pin (item 5: ProviderHealth raw values are a wire
    // contract app tasks match on; a case rename would silently break them)

    @Test func providerHealthRawValuesArePinnedOnTheWire() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(
                exitCode: 4,
                stdout: Data(#"{"error": {"code": "auth_expired", "message": "expired"}}"#.utf8),
                stderr: ""),
        ])
        let manager = RemoteProviderManager(db: db, subscriptions: subs, runner: invoker, registryURL: registryURL)
        await manager.pollOnce(provider: RemoteProviderConfig(name: "fake", exec: "/x"))
        let statuses = await manager.providerStatuses()
        let status = try #require(statuses.first)
        #expect(status.health == .needsAuth)
        let encoded = try JSONEncoder().encode(status)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains(#""health":"needs_auth""#),
                "ProviderHealth.needsAuth's raw wire value must stay \"needs_auth\" — app code matches on it literally")
    }
}
