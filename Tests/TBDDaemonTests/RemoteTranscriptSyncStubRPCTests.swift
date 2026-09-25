import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// `remote.transcriptSync` and `remote.sendMessage` are routed and gated like
/// every provider-named verb before their bodies exist: the backends gate
/// refuses first, and past it the call is refused as not implemented without
/// any provider verb being invoked.
///
/// Tier 2: in-memory GRDB plus a fake provider invoker, no real subprocess.
@Suite("RemoteTranscriptSync stub RPCs")
struct RemoteTranscriptSyncStubRPCTests: ~Copyable {
    let db: TBDDatabase
    let subs: StateSubscriptionManager
    let dir: URL
    let registryURL: URL

    init() throws {
        let localDB = try TBDDatabase(inMemory: true)
        let localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpc-remote-transcript-sync-\(UUID().uuidString)")
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

    private func router(invoker: FakeProviderInvoker) -> RPCRouter {
        let manager = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL,
            actuationLog: makeTestActuationLog())
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

    private let params = #"{"provider": "agentbox", "sessionID": "s-1", "text": "hello"}"#

    private var methods: [String] { [RPCMethod.remoteTranscriptSync, RPCMethod.remoteSendMessage] }

    @Test func refusedWhileRemoteBackendsAreOff() async throws {
        let invoker = FakeProviderInvoker(script: [])
        let r = router(invoker: invoker)
        for method in methods {
            let response = await r.handle(RPCRequest(method: method, params: params))
            #expect(response.error == "remote backends disabled", "\(method)")
        }
        #expect(invoker.callsSnapshot().isEmpty)
    }

    @Test func refusedAsNotImplementedWithoutInvokingTheProvider() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setRemoteTranscriptEnabled(true)
        let invoker = FakeProviderInvoker(script: [])
        let r = router(invoker: invoker)
        for method in methods {
            let response = await r.handle(RPCRequest(method: method, params: params))
            #expect(response.success == false, "\(method)")
            #expect(response.error == "\(method) is not implemented yet", "\(method)")
        }
        #expect(invoker.callsSnapshot().isEmpty)
    }
}
