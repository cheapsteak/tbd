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

    actor Column {
        var value: PRPollDriver.Kind?
        func set(_ kind: PRPollDriver.Kind) { value = kind }
    }

    /// A runner probe whose calls block on a gate until released.
    actor RunProbe {
        var calls = 0
        var finished = 0
        var inFlight = 0
        var maxInFlight = 0
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func enter() {
            calls += 1
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
        }
        func leave() {
            inFlight -= 1
            finished += 1
        }
        func waitForGate() async {
            if isOpen { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
            }
        }
        func release() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
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

    @Test func enablingStopsThePollerThenStartsTheScheduler() async throws {
        let log = StepLog()
        let sw = Self.makeSwitch(log)
        await sw.start(.legacyPoller)
        try await sw.apply(.schedule)
        #expect(await log.steps == ["startLegacy", "stopLegacy", "startSchedule"])
        #expect(await sw.active == .schedule)
    }

    @Test func disablingStopsTheSchedulerThenStartsThePoller() async throws {
        let log = StepLog()
        let sw = Self.makeSwitch(log)
        await sw.start(.schedule)
        try await sw.apply(.legacyPoller)
        #expect(await log.steps == ["startSchedule", "stopSchedule", "startLegacy"])
        #expect(await sw.active == .legacyPoller)
    }

    @Test func enablingTwiceIsANoOp() async throws {
        let log = StepLog()
        let sw = Self.makeSwitch(log)
        await sw.start(.legacyPoller)
        try await sw.apply(.schedule)
        try await sw.apply(.schedule)
        #expect(await log.steps == ["startLegacy", "stopLegacy", "startSchedule"])
    }

    @Test func disablingWhileThePollerRunsIsANoOp() async throws {
        let log = StepLog()
        let sw = Self.makeSwitch(log)
        await sw.start(.legacyPoller)
        try await sw.apply(.legacyPoller)
        #expect(await log.steps == ["startLegacy"])
    }

    /// Mock mode, and every router a test builds: nothing armed the switch, so
    /// a flag write starts nothing.
    @Test func applyBeforeStartRunsNothing() async throws {
        let log = StepLog()
        let sw = Self.makeSwitch(log)
        try await sw.apply(.schedule)
        try await sw.apply(.legacyPoller)
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
                group.addTask { _ = try? await sw.apply(i.isMultiple(of: 2) ? .schedule : .legacyPoller) }
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

    /// A second start (the arming path with a driver already active) swaps
    /// to a different kind.
    @Test func aSecondStartWithTheOtherKindSwaps() async {
        let log = StepLog()
        let sw = Self.makeSwitch(log)
        await sw.start(.legacyPoller)
        await sw.start(.schedule)
        #expect(await log.steps == ["startLegacy", "stopLegacy", "startSchedule"])
        #expect(await sw.active == .schedule)
    }

    /// The other branch: a second start with the same kind does nothing.
    @Test func aSecondStartWithTheSameKindIsANoOp() async {
        let log = StepLog()
        let sw = Self.makeSwitch(log)
        await sw.start(.schedule)
        await sw.start(.schedule)
        #expect(await log.steps == ["startSchedule"])
        #expect(await sw.active == .schedule)
    }

    /// Start-up reads the persisted kind inside the serialized section, so a
    /// toggle racing it cannot leave the driver disagreeing with the column. A
    /// write that lands while the switch is unarmed only persists — and the
    /// start that follows reads it and arms the matching driver. The reverse
    /// order swaps the armed driver. Either way the two agree.
    @Test func startArmsTheDriverTheColumnNamesWhicheverOrderAToggleLands() async throws {
        // Toggle first, while unarmed: it persists, and start reads it.
        do {
            let log = StepLog()
            let sw = Self.makeSwitch(log)
            let column = Column()
            try await sw.apply(.schedule) { await column.set(.schedule) }
            #expect(await sw.active == nil)
            await sw.start(readKind: { await column.value ?? .legacyPoller })
            #expect(await log.steps == ["startSchedule"])
            #expect(await sw.active == .schedule)
            #expect(await sw.active == column.value)
        }
        // Start first: it arms from the column, and the toggle swaps.
        do {
            let log = StepLog()
            let sw = Self.makeSwitch(log)
            let column = Column()
            await sw.start(readKind: { await column.value ?? .legacyPoller })
            try await sw.apply(.schedule) { await column.set(.schedule) }
            #expect(await log.steps == ["startLegacy", "stopLegacy", "startSchedule"])
            #expect(await sw.active == column.value)
        }
        // Concurrent: whichever lands first, the driver matches the column.
        for _ in 0..<5 {
            let log = StepLog()
            let sw = Self.makeSwitch(log)
            let column = Column()
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await sw.start(readKind: {
                        await Task.yield()
                        return await column.value ?? .legacyPoller
                    })
                }
                group.addTask {
                    _ = try? await sw.apply(.schedule) {
                        await Task.yield()
                        await column.set(.schedule)
                    }
                }
            }
            #expect(await sw.active == .schedule)
            #expect(await sw.active == column.value)
        }
    }

    /// Shutdown stops both drivers and disarms: a toggle landing afterwards
    /// still writes its column but starts nothing.
    @Test func stopAllDisarmsSoALaterApplyOnlyPersists() async throws {
        let log = StepLog()
        let sw = Self.makeSwitch(log)
        await sw.start(.legacyPoller)
        await sw.stopAll()
        #expect(await sw.active == nil)
        let column = Column()
        try await sw.apply(.schedule) { await column.set(.schedule) }
        #expect(await column.value == .schedule)
        #expect(await log.steps == ["startLegacy", "stopLegacy", "stopSchedule"])
    }

    /// A failed write throws and switches nothing.
    @Test func aFailedPersistThrowsAndSwitchesNothing() async {
        struct Boom: Error {}
        let log = StepLog()
        let sw = Self.makeSwitch(log)
        await sw.start(.legacyPoller)
        await #expect(throws: Boom.self) {
            try await sw.apply(.schedule) { throw Boom() }
        }
        #expect(await log.steps == ["startLegacy"])
        #expect(await sw.active == .legacyPoller)
    }

    /// The write happens inside the serialized section: concurrent opposite
    /// toggles always end with the running driver matching the column.
    @Test func concurrentOppositeAppliesEndWithTheDriverMatchingTheColumn() async {
        for _ in 0..<5 {
            let log = StepLog()
            let sw = Self.makeSwitch(log)
            let column = Column()
            await sw.start(.legacyPoller)
            await withTaskGroup(of: Void.self) { group in
                for kind in [PRPollDriver.Kind.schedule, .legacyPoller, .schedule, .legacyPoller] {
                    group.addTask {
                        _ = try? await sw.apply(kind) {
                            // A suspension between the write and the switch,
                            // where a concurrent call could interleave if the
                            // two were not one section.
                            await Task.yield()
                            await column.set(kind)
                        }
                    }
                }
            }
            #expect(await sw.active == column.value)
        }
    }

    // MARK: - A stop waits for the pass in flight

    /// `stopAndWait` returns only after a `run` that was in flight finishes,
    /// and a `start` right after it never overlaps that run.
    @Test func schedulerStopAndWaitWaitsForTheRunInFlight() async {
        let dates = TestDateSource()
        let probe = RunProbe()
        let facts = [PRPollWorktreeFacts(
            worktreeID: UUID(), active: true, discoverable: true,
            bindings: [PRPollBindingFact(
                key: PRPollKey(host: "github.com", owner: "acme", repo: "acme-prod", number: 1),
                state: .blocked)])]
        let s = PRPollScheduler(
            facts: { facts },
            run: { _ in
                await probe.enter()
                await probe.waitForGate()
                await probe.leave()
            },
            now: dates.provider)

        await s.start()
        #expect(await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await probe.calls == 1
        } == .satisfied)

        let stopper = Task { () -> Int in
            await s.stopAndWait()
            return await probe.finished
        }
        // The stop has begun (it clears the loop first) while the run is held.
        #expect(await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await s.isRunning == false
        } == .satisfied)
        await probe.release()
        #expect(await stopper.value == 1, "the stop returned before the run in flight finished")

        dates.advance(by: 3600)
        await s.start()
        #expect(await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await probe.finished == 2
        } == .satisfied)
        #expect(await probe.maxInFlight == 1, "two runs overlapped")
        await s.stopAndWait()
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
        // Cleanup must run even when a step throws: real loops left running
        // would outlive the test. `defer` cannot await, hence the do/catch.
        do {
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
        } catch {
            await router.prPollDriverSwitch.stopAll()
            throw error
        }

        await router.prPollDriverSwitch.stopAll()
        #expect(await router.prPoller.isRunning == false)
        #expect(await router.prPollScheduler.isRunning == false)
    }

    /// Two concurrent RPCs with opposite values, against an armed router:
    /// whatever order they land in, the running driver matches the column.
    @Test func concurrentRPCsLeaveTheColumnAndTheDriverAgreeing() async throws {
        let (router, db) = try Self.makeRouterAndDB()
        await router.prPollDriverSwitch.start(.legacyPoller)
        await withTaskGroup(of: Void.self) { group in
            for enabled in [true, false] {
                group.addTask {
                    guard let request = try? RPCRequest(
                        method: RPCMethod.configSetPRPollScheduleEnabled,
                        params: ConfigSetPRPollScheduleEnabledParams(enabled: enabled))
                    else { return }
                    _ = await router.handle(request)
                }
            }
        }
        // Read everything, then stop unconditionally, then judge: a throwing
        // read must not leave real loops running in the test process.
        let column = try? await db.config.get().prPollScheduleEnabled
        let schedulerRunning = await router.prPollScheduler.isRunning
        let pollerRunning = await router.prPoller.isRunning
        await router.prPollDriverSwitch.stopAll()
        let persisted = try #require(column)
        #expect(schedulerRunning == persisted)
        #expect(pollerRunning == !persisted)
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
