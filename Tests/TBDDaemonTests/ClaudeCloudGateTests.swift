import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

// Tier 2: in-memory GRDB plus fakes; no subprocess, no real `claude`.
@Suite("ClaudeCloudGate")
struct ClaudeCloudGateTests: ~Copyable {
    let db: TBDDatabase
    let dir: URL
    let registryURL: URL

    init() throws {
        let localDB = try TBDDatabase(inMemory: true)
        let localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        let localRegistryURL = localDir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "fake", "exec": "/nonexistent"}]"#
            .write(to: localRegistryURL, atomically: true, encoding: .utf8)
        db = localDB
        dir = localDir
        registryURL = localRegistryURL
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    /// The cloud provider is present in the manager — modelling a daemon that
    /// booted with BOTH flags on — so the only thing that can refuse a cloud
    /// verb in these tests is the gate itself.
    private func router(cloud: FakeProviderInvoker) -> RPCRouter {
        let manager = RemoteProviderManager(
            db: db, subscriptions: StateSubscriptionManager(),
            runner: ProviderDispatcher(
                subprocess: FakeProviderInvoker(script: []),
                builtIns: [ClaudeCloudProvider.name: cloud]),
            registryURL: registryURL,
            builtInProviders: [
                RemoteProviderConfig(name: ClaudeCloudProvider.name, exec: "/opt/acme/claude")
            ])
        return RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            subscriptions: StateSubscriptionManager(),
            remoteManager: manager, actuationLog: makeTestActuationLog())
    }

    private func call(_ router: RPCRouter, _ method: String, _ params: String) async -> RPCResponse {
        await router.handle(RPCRequest(method: method, params: params))
    }

    private let cloudParams = #"{"provider": "claude-cloud", "sessionID": "s", "text": "t", "title": "t", "paramsJSON": "{}", "pinned": true, "exitCode": 1}"#
    private let otherParams = #"{"provider": "fake", "sessionID": "s", "text": "t", "title": "t", "paramsJSON": "{}", "pinned": true, "exitCode": 1}"#

    private let gatedMethods = [
        "remote.create", "remote.stop", "remote.send", "remote.log",
        "remote.rename", "remote.dismiss", "remote.setPin", "remote.reportAttachExit",
    ]

    /// Combination 1 of 4: outer OFF, inner OFF.
    @Test func bothFlagsOffRefusesWithTheOuterMessage() async throws {
        let cloud = FakeProviderInvoker(script: [])
        let r = router(cloud: cloud)
        for method in gatedMethods {
            let response = await call(r, method, cloudParams)
            #expect(response.error == "remote backends disabled", "\(method)")
        }
        #expect(cloud.calls.isEmpty)
    }

    /// Combination 2 of 4: outer OFF, inner ON. The outer gate still wins —
    /// the inner flag is a second gate INSIDE the first, never a bypass.
    @Test func theInnerFlagAloneNeverBypassesTheOuterGate() async throws {
        try await db.config.setClaudeCloud(true)
        let cloud = FakeProviderInvoker(script: [])
        let r = router(cloud: cloud)
        for method in gatedMethods {
            let response = await call(r, method, cloudParams)
            #expect(response.error == "remote backends disabled", "\(method)")
        }
        #expect(cloud.calls.isEmpty)
    }

    /// Combination 3 of 4: outer ON, inner OFF. This is the case the inner
    /// gate exists for — a user who turned cloud off after boot.
    @Test func theOuterFlagAloneRefusesEveryCloudVerb() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let cloud = FakeProviderInvoker(script: [])
        let r = router(cloud: cloud)
        for method in gatedMethods {
            let response = await call(r, method, cloudParams)
            #expect(response.error == "claude cloud sessions disabled", "\(method)")
        }
        #expect(cloud.calls.isEmpty, "no cloud verb may be invoked while the inner flag is off")
    }

    /// The discriminating half of combination 3: a NON-cloud provider is
    /// untouched by the inner gate, so the gate did not become a second outer
    /// flag.
    @Test func aNonCloudProviderIsUnaffectedByTheInnerGate() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let r = router(cloud: FakeProviderInvoker(script: []))
        let response = await call(r, "remote.dismiss", otherParams)
        #expect(response.success)
    }

    /// Combination 4 of 4: both ON — the verb reaches the provider.
    @Test func bothFlagsOnLetsACloudVerbThrough() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setClaudeCloud(true)
        let cloud = FakeProviderInvoker(script: [providerOK("{}")])
        let r = router(cloud: cloud)
        let response = await call(r, "remote.send", cloudParams)
        #expect(response.success)
        #expect(cloud.calls == [["send", "s"]])
    }
}
