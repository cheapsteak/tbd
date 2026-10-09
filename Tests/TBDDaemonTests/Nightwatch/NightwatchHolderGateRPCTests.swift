import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// The RPC surface for the rule that a Nightwatch watch mode and the
/// pty-holder transport are never both on: `nightwatch.setMode` refuses a
/// watch mode while the holder is enabled, and `config.setPtyHolderEnabled`
/// refuses turning the holder on while a watch mode is active. Both switches
/// have to refuse, because either one alone leaves a path to the combination
/// `NightwatchHolderGate` exists to make unreachable.
///
/// **A watch mode is refused by the hazard, not by the flag.** The daemon asks
/// its own registry whether it can start a holder at all, so these fixtures say
/// which daemon they mean: `makeRouterAndDB(holderSupported:)` wires a
/// spawn-capable registry when the refusal is the subject, and leaves the
/// registry nil when the subject is a daemon that cannot spawn one. Nothing is
/// launched either way — `canSpawn` is decided in `init` from the spawner's
/// mere presence.
@Suite("Nightwatch/holder gate RPC")
struct NightwatchHolderGateRPCTests {

    private func makeRouterAndDB(
        holderSupported: Bool = true
    ) throws -> (RPCRouter, TBDDatabase) {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog()
        )
        if holderSupported {
            router.holderRegistry = HolderRegistry(
                owner: HolderOwnerToken(rawValue: "acme-installation"),
                environment: ["TBD_HOME": "/tmp/tbd-nhg-\(UUID().uuidString.prefix(8))"],
                listTerminals: { [] },
                spawner: HolderSpawner(
                    executableURL: URL(fileURLWithPath: "/nonexistent/TBDHolder")))
        }
        return (router, db)
    }

    private func setMode(_ router: RPCRouter, _ mode: NightwatchMode) async throws -> RPCResponse {
        await router.handle(try RPCRequest(
            method: RPCMethod.nightwatchSetMode, params: NightwatchSetModeParams(mode: mode)))
    }

    private func setHolder(_ router: RPCRouter, _ enabled: Bool) async throws -> RPCResponse {
        await router.handle(try RPCRequest(
            method: RPCMethod.configSetPtyHolderEnabled,
            params: ConfigSetPtyHolderEnabledParams(enabled: enabled)))
    }

    // MARK: - nightwatch.setMode

    @Test(arguments: NightwatchMode.allCases)
    func holderOffAcceptsEveryMode(mode: NightwatchMode) async throws {
        let (router, db) = try makeRouterAndDB()
        try await db.config.setPtyHolderEnabled(false)
        let response = try await setMode(router, mode)
        #expect(response.success, "error: \(response.error ?? "nil")")
        #expect(try await db.config.get().nightwatchMode == mode)
    }

    @Test func holderOnAcceptsOff() async throws {
        let (router, db) = try makeRouterAndDB()
        try await db.config.setPtyHolderEnabled(true)
        let response = try await setMode(router, .off)
        #expect(response.success)
        #expect(try await db.config.get().nightwatchMode == .off)
    }

    @Test(arguments: [NightwatchMode.daywatch, .nightwatch])
    func holderOnRefusesWatchModesAndWritesNothing(mode: NightwatchMode) async throws {
        let (router, db) = try makeRouterAndDB()
        try await db.config.setPtyHolderEnabled(true)
        let response = try await setMode(router, mode)
        #expect(!response.success)
        #expect(response.error == NightwatchHolderGate.modeRefusal)
        #expect(try await db.config.get().nightwatchMode == .off)
    }

    /// The flag on, but this daemon cannot start a holder — the state the
    /// graduated default makes ordinary, since the flag reads on without
    /// anybody choosing it. No holder-backed session can exist here, so the
    /// watch mode is accepted and written. A gate that asked only the flag
    /// would refuse Nightwatch on every such install.
    @Test(arguments: [NightwatchMode.daywatch, .nightwatch])
    func anUnsupportedDaemonAcceptsAWatchModeWithTheFlagOn(mode: NightwatchMode) async throws {
        let (router, db) = try makeRouterAndDB(holderSupported: false)
        try await db.config.setPtyHolderEnabled(true)
        #expect(try await db.config.get().ptyHolderEnabled == true)
        let response = try await setMode(router, mode)
        #expect(response.success, "error: \(response.error ?? "nil")")
        #expect(try await db.config.get().nightwatchMode == mode)
    }

    // MARK: - config.setPtyHolderEnabled

    @Test func modeOffLetsTheHolderTurnOn() async throws {
        let (router, db) = try makeRouterAndDB()
        let response = try await setHolder(router, true)
        #expect(response.success)
        #expect(try await db.config.get().ptyHolderEnabled == true)
    }

    @Test(arguments: [NightwatchMode.daywatch, .nightwatch])
    func activeModeRefusesTurningTheHolderOnAndWritesNothing(mode: NightwatchMode) async throws {
        let (router, db) = try makeRouterAndDB()
        try await db.config.setNightwatchMode(mode)
        let response = try await setHolder(router, true)
        #expect(!response.success)
        #expect(response.error == NightwatchHolderGate.holderRefusal)
        let stored = try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)?.pty_holder_enabled
        }
        #expect(stored == nil, "a refused flip must leave the column untouched (still NULL)")
    }

    @Test(arguments: NightwatchMode.allCases)
    func turningTheHolderOffIsNeverRefused(mode: NightwatchMode) async throws {
        let (router, db) = try makeRouterAndDB()
        try await db.config.setNightwatchMode(mode)
        let response = try await setHolder(router, false)
        #expect(response.success)
        #expect(try await db.config.get().ptyHolderEnabled == false)
    }
}
