import Foundation
import Testing
import TestSupport

@testable import TBDDaemonLib
@testable import TBDShared

/// `agents.background` through the router: the flag gates `on` and nothing else.
@Suite("AgentBackgroundRouter")
struct AgentBackgroundRouterTests {

    private func makeRouter(_ db: TBDDatabase, fake: FakeProcessPriority) -> RPCRouter {
        let tmux = TmuxManager(dryRun: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux, startTime: Date(), actuationLog: makeTestActuationLog())
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-agent-background-\(UUID().uuidString).json").path
        router.agentBackground = AgentBackgroundController(
            priority: fake, roots: { [100] }, statePath: path)
        return router
    }

    private func table() -> FakeProcessPriority {
        let fake = FakeProcessPriority()
        fake.add(100, parent: 1)
        fake.add(101, parent: 100)
        return fake
    }

    private func call(_ router: RPCRouter, _ params: AgentsBackgroundParams) async throws -> RPCResponse {
        try await router.handleAgentsBackground(JSONEncoder().encode(params))
    }

    @Test func onIsRefusedWhileTheFlagIsOffAndNamesTheCommandThatTurnsItOn() async throws {
        let db = try TBDDatabase(inMemory: true)
        let fake = table()
        let router = makeRouter(db, fake: fake)

        let response = try await call(router, AgentsBackgroundParams(action: .on, durationSeconds: 60))

        #expect(!response.success)
        #expect(response.error?.contains("tbd config set agent-background on") == true)
        #expect(fake.loweredPIDs.isEmpty)
    }

    @Test func onLowersWhileTheFlagIsOnAndOffAndStatusWorkAfterItIsTurnedOff() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAgentBackgroundEnabled(true)
        let fake = table()
        let router = makeRouter(db, fake: fake)

        let on = try await call(router, AgentsBackgroundParams(action: .on, durationSeconds: 60))
        #expect(on.success)
        #expect(try on.decodeResult(AgentsBackgroundResult.self).loweredCount == 2)

        try await db.config.setAgentBackgroundEnabled(false)
        let status = try await call(router, AgentsBackgroundParams(action: .status))
        #expect(try status.decodeResult(AgentsBackgroundResult.self).active)

        let off = try await call(router, AgentsBackgroundParams(action: .off))
        #expect(off.success)
        #expect(try off.decodeResult(AgentsBackgroundResult.self).active == false)
        #expect(Set(fake.restoredPIDs) == [100, 101])
    }

    @Test func turningTheFlagOffEndsALiveLeaseAndRestores() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAgentBackgroundEnabled(true)
        let fake = table()
        let router = makeRouter(db, fake: fake)
        let on = try await call(router, AgentsBackgroundParams(action: .on, durationSeconds: 60))
        #expect(on.success)

        let setOff = try await router.handleConfigSetAgentBackgroundEnabled(
            JSONEncoder().encode(ConfigSetAgentBackgroundEnabledParams(enabled: false)))

        #expect(setOff.success)
        #expect(Set(fake.restoredPIDs) == [100, 101])
        let status = try await call(router, AgentsBackgroundParams(action: .status))
        #expect(try status.decodeResult(AgentsBackgroundResult.self).active == false)
    }

    @Test func aLeaseOverTwoHoursIsAnErrorWithTheLimit() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAgentBackgroundEnabled(true)
        let router = makeRouter(db, fake: table())

        let response = try await call(router, AgentsBackgroundParams(action: .on, durationSeconds: 7201))

        #expect(!response.success)
        #expect(response.error?.contains("7200") == true)
    }

    @Test func onWithoutADurationIsAnError() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAgentBackgroundEnabled(true)
        let router = makeRouter(db, fake: table())

        let response = try await call(router, AgentsBackgroundParams(action: .on))

        #expect(!response.success)
    }
}
