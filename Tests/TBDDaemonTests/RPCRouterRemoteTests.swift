import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("RPCRouter remote.* handlers")
struct RPCRouterRemoteTests {
    let db: TBDDatabase
    let subs: StateSubscriptionManager
    let registryURL: URL

    init() throws {
        db = try TBDDatabase(inMemory: true)
        subs = StateSubscriptionManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpc-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        registryURL = dir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "fake", "exec": "/nonexistent"}]"#
            .write(to: registryURL, atomically: true, encoding: .utf8)
    }

    /// `manager: nil` models the daemon booting with the flag off (case b of
    /// the flag gate — no manager was ever constructed). Passing a manager
    /// models the daemon booting with the flag on.
    private func router(manager: RemoteProviderManager?) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
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
}
