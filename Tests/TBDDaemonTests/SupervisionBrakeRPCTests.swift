import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// Thread-safe collector for broadcast StateDeltas, mirroring the pattern in
/// `GCHandlersTests` / `RPCRouterWorktreeCreateBroadcastTests`.
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

/// RPC surface for the supervision fleet brake (design 2026-07-26 §3, §7):
/// the `config.setSupervisionEnabled` verb, its round-trip through
/// `config.get`, and its broadcast so every other client sees the same value
/// immediately (§7: "all surfaces must see the same value immediately after
/// a change").
@Suite("Supervision brake RPC")
struct SupervisionBrakeRPCTests {

    private func makeRouter(db: TBDDatabase, subscriptions: StateSubscriptionManager = StateSubscriptionManager())
        -> RPCRouter
    {
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

    private func setSupervisionEnabled(_ router: RPCRouter, enabled: Bool) async throws {
        let request = try RPCRequest(
            method: RPCMethod.configSetSupervisionEnabled,
            params: ConfigSetSupervisionEnabledParams(enabled: enabled))
        let response = await router.handle(request)
        #expect(response.success)
    }

    // MARK: - config.setSupervisionEnabled

    @Test("config.setSupervisionEnabled persists the release")
    func setEnabledPersists() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db)
        try await setSupervisionEnabled(router, enabled: true)
        #expect(try await db.config.get().supervisionEnabled == true)
    }

    @Test("config.setSupervisionEnabled persists an explicit brake")
    func setDisabledPersists() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db)
        try await setSupervisionEnabled(router, enabled: false)
        #expect(try await db.config.get().supervisionEnabled == false)
        // …and it is a real 0, not a NULL that merely resolves to the default.
        let stored = try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)?.supervision_enabled
        }
        #expect(stored == false)
    }

    @Test("config.get reports the brake OFF by default")
    func defaultsOff() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db)
        let response = await router.handle(RPCRequest(method: RPCMethod.configGet))
        let result = try response.decodeResult(Config.self)
        #expect(result.supervisionEnabled == false)
    }

    // MARK: - Broadcast (§7: "all surfaces must see the same value immediately")

    @Test("config.setSupervisionEnabled flips the config and broadcasts")
    func setSupervisionEnabledFlipsConfigAndBroadcasts() async throws {
        let db = try TBDDatabase(inMemory: true)
        let subs = StateSubscriptionManager()
        let deltas = BroadcastDeltas()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let router = makeRouter(db: db, subscriptions: subs)

        #expect(try await db.config.get().supervisionEnabled == false, "default is braked")

        try await setSupervisionEnabled(router, enabled: true)

        #expect(try await db.config.get().supervisionEnabled == true)
        let modelProfilesChangedCount = deltas.snapshot().filter {
            if case .modelProfilesChanged = $0 { return true }; return false
        }.count
        #expect(modelProfilesChangedCount == 1)
    }

    // MARK: - Codable back-compat

    @Test("Config JSON without supervisionEnabled decodes to the shipped default")
    func configDecodeBackCompat() throws {
        let result = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(result.supervisionEnabled == Config.supervisionEnabledDefault)
    }
}
