import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

private final class AutoCreateNotesBroadcastRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [StateDelta] = []

    func append(_ delta: StateDelta) {
        lock.lock()
        defer { lock.unlock() }
        deltas.append(delta)
    }

    func snapshot() -> [StateDelta] {
        lock.lock()
        defer { lock.unlock() }
        return deltas
    }
}

@Suite("Auto-create notes RPC")
struct AutoCreateNotesRPCTests {
    private func makeRouter(
        db: TBDDatabase,
        subscriptions: StateSubscriptionManager = StateSubscriptionManager()
    ) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            subscriptions: subscriptions,
            actuationLog: makeTestActuationLog()
        )
    }

    @Test("setter persists both values and broadcasts each change")
    func setterPersistsAndBroadcasts() async throws {
        let db = try TBDDatabase(inMemory: true)
        let subscriptions = StateSubscriptionManager()
        let recorder = AutoCreateNotesBroadcastRecorder()
        subscriptions.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                recorder.append(delta)
            }
            return true
        }
        let router = makeRouter(db: db, subscriptions: subscriptions)

        for enabled in [false, true] {
            let request = try RPCRequest(
                method: RPCMethod.configSetAutoCreateNotes,
                params: ConfigSetAutoCreateNotesParams(enabled: enabled)
            )
            let response = await router.handle(request)
            #expect(response.success)
            #expect(try await db.config.get().autoCreateNotesEnabled == enabled)
        }

        let broadcasts = recorder.snapshot().filter {
            if case .modelProfilesChanged = $0 { return true }
            return false
        }
        #expect(broadcasts.count == 2)
    }

    @Test("model-profile list carries the resolved setting")
    func modelProfileListCarriesSetting() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAutoCreateNotes(false)
        let router = makeRouter(db: db)

        let response = await router.handle(RPCRequest(method: RPCMethod.modelProfileList))
        #expect(response.success)
        let result = try response.decodeResult(ModelProfileListResult.self)
        #expect(result.autoCreateNotesEnabled == false)
    }

    @Test("legacy model-profile list JSON defaults automatic notes on")
    func legacyListDefaultsOn() throws {
        let json = Data(#"{"profiles":[],"globalEnvOverrides":{}}"#.utf8)
        let result = try JSONDecoder().decode(ModelProfileListResult.self, from: json)
        #expect(result.autoCreateNotesEnabled == true)
    }
}
