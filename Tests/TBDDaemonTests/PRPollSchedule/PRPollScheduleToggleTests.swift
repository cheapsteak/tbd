import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// The user-facing switch for `pr_poll_schedule_enabled`: the RPC writes the
/// column, `daemon.capabilities` reports it, and `PRPollDriverSwitch` swaps the
/// running PR driver live — never both running, never a driver started by a
/// write the daemon did not arm.
@Suite("PRPollScheduleToggle")
struct PRPollScheduleToggleTests {
    /// Records every step the switch runs, in order.
    actor StepLog {
        var steps: [String] = []
        func add(_ step: String) { steps.append(step) }
    }

    private static func makeSwitch(_ log: StepLog) -> PRPollDriverSwitch {
        PRPollDriverSwitch(steps: .init(
            startLegacy: { await log.add("startLegacy") },
            stopLegacy: { await log.add("stopLegacy") },
            startSchedule: { await log.add("startSchedule") },
            stopSchedule: { await log.add("stopSchedule") }))
    }

    private static func makeRouterAndDB() throws -> (RPCRouter, TBDDatabase) {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog())
        return (router, db)
    }

    private static func setEnabled(_ router: RPCRouter, _ enabled: Bool) async throws {
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.configSetPRPollScheduleEnabled,
            params: ConfigSetPRPollScheduleEnabledParams(enabled: enabled)))
        #expect(response.success, "\(String(describing: response.error))")
    }

    // MARK: - The switch, on fakes

    @Test func startArmsAndStartsOnlyTheLegacyPoller() async {
        let log = StepLog()
        let sw = Self.makeSwitch(log)
        await sw.start(.legacyPoller)
        #expect(await log.steps == ["startLegacy"])
        #expect(await sw.active == .legacyPoller)
    }

    @Test func startArmsAndStartsOnlyTheScheduler() async {
        let log = StepLog()
        let sw = Self.makeSwitch(log)
        await sw.start(.schedule)
        #expect(await log.steps == ["startSchedule"])
        #expect(await sw.active == .schedule)
    }

    @Test func enablingStopsThePollerThenStartsTheScheduler() async {
        let log = StepLog()
        let sw = Self.makeSwitch(log)
        await sw.start(.legacyPoller)
        await sw.apply(.schedule)
        #expect(await log.steps == ["startLegacy", "stopLegacy", "startSchedule"])
        #expect(await sw.active == .schedule)
    }

    @Test func disablingStopsTheSchedulerThenStartsThePoller() async {
        let log = StepLog()
        let sw = Self.makeSwitch(log)
        await sw.start(.schedule)
        await sw.apply(.legacyPoller)
        #expect(await log.steps == ["startSchedule", "stopSchedule", "startLegacy"])
        #expect(await sw.active == .legacyPoller)
    }

    @Test func enablingTwiceIsANoOp() async {
        let log = StepLog()
        let sw = Self.makeSwitch(log)
        await sw.start(.legacyPoller)
        await sw.apply(.schedule)
        await sw.apply(.schedule)
        #expect(await log.steps == ["startLegacy", "stopLegacy", "startSchedule"])
    }

    @Test func disablingWhileThePollerRunsIsANoOp() async {
        let log = StepLog()
        let sw = Self.makeSwitch(log)
        await sw.start(.legacyPoller)
        await sw.apply(.legacyPoller)
        #expect(await log.steps == ["startLegacy"])
    }

    /// Mock mode, and every router a test builds: nothing armed the switch, so
    /// a flag write starts nothing.
    @Test func applyBeforeStartRunsNothing() async {
        let log = StepLog()
        let sw = Self.makeSwitch(log)
        await sw.apply(.schedule)
        await sw.apply(.legacyPoller)
        #expect(await log.steps.isEmpty)
        #expect(await sw.active == nil)
    }

    /// Concurrent toggles are serialized: whatever order they land in, the
    /// steps alternate stop/start pairs and exactly one driver ends up active.
    @Test func concurrentTogglesNeverLeaveBothRunning() async {
        let log = StepLog()
        let sw = Self.makeSwitch(log)
        await sw.start(.legacyPoller)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask { await sw.apply(i.isMultiple(of: 2) ? .schedule : .legacyPoller) }
            }
        }
        var running: Set<String> = []
        for step in await log.steps {
            switch step {
            case "startLegacy": running.insert("legacy")
            case "stopLegacy": running.remove("legacy")
            case "startSchedule": running.insert("schedule")
            case "stopSchedule": running.remove("schedule")
            default: Issue.record("unexpected step \(step)")
            }
            #expect(running.count <= 1, "both drivers running after \(step)")
        }
        #expect(running.count == 1)
    }

    // MARK: - Through the router

    @Test("config.setPRPollScheduleEnabled method name")
    func methodName() {
        #expect(RPCMethod.configSetPRPollScheduleEnabled == "config.setPRPollScheduleEnabled")
    }

    @Test func theHandlerWritesTheColumnBothWays() async throws {
        let (router, db) = try Self.makeRouterAndDB()
        try await Self.setEnabled(router, true)
        #expect(try await db.config.get().prPollScheduleEnabled == true)
        try await Self.setEnabled(router, false)
        #expect(try await db.config.get().prPollScheduleEnabled == false)
    }

    /// The router a test builds is never armed: the write lands, no driver starts.
    @Test func anUnarmedRouterStartsNoDriverOnWrite() async throws {
        let (router, _) = try Self.makeRouterAndDB()
        try await Self.setEnabled(router, true)
        #expect(await router.prPollScheduler.isRunning == false)
        #expect(await router.prPoller.isRunning == false)
        #expect(await router.activityLedger.isEnabled == false)
        #expect(await router.prPollDriverSwitch.active == nil)
    }

    /// Armed as `Daemon.start()` arms it, the RPC swaps the real drivers both
    /// ways, with the ledger following the scheduler.
    @Test func anArmedRouterSwapsTheRealDriversLive() async throws {
        let (router, _) = try Self.makeRouterAndDB()
        await router.prPollDriverSwitch.start(.legacyPoller)
        #expect(await router.prPoller.isRunning == true)
        #expect(await router.prPollScheduler.isRunning == false)

        try await Self.setEnabled(router, true)
        #expect(await router.prPoller.isRunning == false)
        #expect(await router.prPollScheduler.isRunning == true)
        #expect(await router.activityLedger.isEnabled == true)

        try await Self.setEnabled(router, false)
        #expect(await router.prPollScheduler.isRunning == false)
        #expect(await router.activityLedger.isEnabled == false)
        #expect(await router.prPoller.isRunning == true)

        await router.prPoller.stop()
        await router.prPollScheduler.stop()
    }

    @Test func capabilitiesCarryTheFlagInBothStates() async throws {
        let (router, _) = try Self.makeRouterAndDB()
        for enabled in [true, false] {
            try await Self.setEnabled(router, enabled)
            let response = await router.handle(try RPCRequest(method: RPCMethod.daemonCapabilities))
            let capabilities = try #require(response.result.flatMap {
                try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: Data($0.utf8))
            })
            #expect(capabilities.prPollScheduleEnabled == enabled)
        }
    }

    /// An older daemon sends no field; the app falls through to the shipped default.
    @Test func capabilitiesFromAnOlderDaemonDecodeToTheDefault() throws {
        let decoded = try JSONDecoder().decode(
            DaemonCapabilitiesResult.self, from: Data(#"{"controlModeEnabled":false}"#.utf8))
        #expect(decoded.prPollScheduleEnabled == Config.prPollScheduleDefault)
    }
}
