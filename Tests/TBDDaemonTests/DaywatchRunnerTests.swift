import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
import TBDShared

// MARK: - Fake Executor for Testing

/// Fake executor that captures calls and allows stubbing exit codes and behavior.
actor FakeDaywatchExecutor: DaywatchExecuting {
    struct JudgeWakeCall: Sendable {
        let act: Bool
    }

    private(set) var tickCallCount: Int = 0
    private(set) var judgeWakeCalls: [JudgeWakeCall] = []
    private(set) var tickExitCode: Int32 = 0

    init(tickExitCode: Int32 = 0) {
        self.tickExitCode = tickExitCode
    }

    func runTick() async -> Int32 {
        tickCallCount += 1
        return tickExitCode
    }

    func setTickExitCode(_ code: Int32) {
        tickExitCode = code
    }

    func wakeJudge(act: Bool) async {
        judgeWakeCalls.append(JudgeWakeCall(act: act))
    }
}

// MARK: - Fake DeskSessionManager for Testing

/// Fake desk session manager that records calls for testing desk-gated branches.
/// Conforms to DeskSessionManaging protocol for use with DaywatchRunner.
actor FakeDeskSessionManager: DeskSessionManaging {
    enum EnsureBehavior {
        case succeed
        case failOnce
        case alwaysFail
    }

    struct NudgeCall: Sendable {
        let worktreeID: UUID
        let act: Bool
    }

    struct WrapUpCall: Sendable {
        let worktreeID: UUID
    }

    private(set) var ensureCalls: [NightwatchMode] = []
    private(set) var nudgeCalls: [NudgeCall] = []
    private(set) var wrapUpCalls: [WrapUpCall] = []
    private(set) var closeCalls: Int = 0

    private(set) var lastEnsuredWorktreeID: UUID?
    private var deskID: UUID? // Cached desk ID — reused across mode switches
    private var ensureBehavior: EnsureBehavior = .succeed
    private var ensureFailureCount: Int = 0

    init(ensureBehavior: EnsureBehavior = .succeed) {
        self.ensureBehavior = ensureBehavior
    }

    func ensureDeskSession(mode: NightwatchMode) async throws -> Worktree {
        ensureCalls.append(mode)

        // Handle failure behavior
        switch ensureBehavior {
        case .failOnce:
            if ensureFailureCount == 0 {
                ensureFailureCount += 1
                struct TestError: Error, CustomStringConvertible {
                    let description = "Fake desk ensure failed (once)"
                }
                throw TestError()
            }
        case .alwaysFail:
            struct TestError: Error, CustomStringConvertible {
                let description = "Fake desk ensure failed (always)"
            }
            throw TestError()
        case .succeed:
            break
        }

        // Reuse desk ID across calls (models real behavior: desk is idempotent/persisted across mode switches)
        if deskID == nil {
            deskID = UUID()
        }
        lastEnsuredWorktreeID = deskID!

        // Create a real Worktree with minimal test values (repoID: nil makes it scratch)
        return Worktree(
            id: deskID!,
            repoID: nil,
            name: "watch-desk",
            displayName: "Watch Desk",
            branch: "main",
            path: "/tmp/test-desk",
            status: .active,
            createdAt: Date(),
            tmuxServer: "test-tmux"
        )
    }

    func nudgeDeskSession(worktreeID: UUID, act: Bool) async {
        nudgeCalls.append(NudgeCall(worktreeID: worktreeID, act: act))
    }

    func postShiftWrapUp(worktreeID: UUID) async {
        wrapUpCalls.append(WrapUpCall(worktreeID: worktreeID))
    }

    func closeDeskSession() async {
        closeCalls += 1
    }
}

// MARK: - Tests

/// Tier 1 — single-tick and mode-transition behavior. Every assertion here is
/// on a synchronous effect of `apply()`/`runOnce()`; the tests that start the
/// background loop never assert on anything its asynchronous ticks touch, so
/// the loop parking on a real 1000 s sleep is inert. These deliberately pass
/// **no** clock, so they also cover the production default-clock construction
/// path.
@Suite("DaywatchRunner single tick")
struct DaywatchRunnerSingleTickTests {

    // MARK: - Test: runOnce() with exit code 0 does not wake judge

    @Test("runOnce with exit code 0 → tick counted, judge not woken")
    func testRunOnceExitCode0() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        let runner = DaywatchRunner(executor: executor, interval: 60)

        await runner.runOnce(mode: .daywatch)

        #expect(await executor.tickCallCount == 1)
        #expect(await executor.judgeWakeCalls.isEmpty)
    }

    // MARK: - Test: runOnce() with exit code 10 in daywatch mode wakes judge with act=false

    @Test("runOnce with exit code 10 in daywatch → wakeJudge(act: false)")
    func testRunOnceExitCode10Daywatch() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 10)
        let runner = DaywatchRunner(executor: executor, interval: 60)

        await runner.runOnce(mode: .daywatch)

        #expect(await executor.tickCallCount == 1)
        let wakeCalls = await executor.judgeWakeCalls
        #expect(wakeCalls.count == 1)
        #expect(wakeCalls[0].act == false)
    }

    // MARK: - Test: runOnce() with exit code 10 in nightwatch mode wakes judge with act=true

    @Test("runOnce with exit code 10 in nightwatch → wakeJudge(act: true)")
    func testRunOnceExitCode10Nightwatch() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 10)
        let runner = DaywatchRunner(executor: executor, interval: 60)

        await runner.runOnce(mode: .nightwatch)

        #expect(await executor.tickCallCount == 1)
        let wakeCalls = await executor.judgeWakeCalls
        #expect(wakeCalls.count == 1)
        #expect(wakeCalls[0].act == true)
    }

    // MARK: - Test: runOnce() with other exit codes does not wake judge

    @Test("runOnce with non-zero, non-10 exit code → tick counted, judge not woken")
    func testRunOnceOtherExitCode() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 1)
        let runner = DaywatchRunner(executor: executor, interval: 60)

        await runner.runOnce(mode: .daywatch)

        #expect(await executor.tickCallCount == 1)
        #expect(await executor.judgeWakeCalls.isEmpty)
    }

    // MARK: - Test: apply(.off) when never started is idempotent

    @Test("apply(.off) when never started is idempotent")
    func testApplyOffWhenNeverStartedIsIdempotent() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        let runner = DaywatchRunner(executor: executor, interval: 60)

        // Apply off immediately (never started)
        await runner.apply(mode: .off)

        // No ticks should have been called
        #expect(await executor.tickCallCount == 0)
        #expect(await executor.judgeWakeCalls.isEmpty)
    }

    // MARK: - Test: mode switching (daywatch → nightwatch)

    @Test("mode switching: daywatch → nightwatch changes judge behavior")
    func testModeSwitching() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 10)
        let runner = DaywatchRunner(executor: executor, interval: 1000)

        // Run one tick in daywatch mode
        await runner.runOnce(mode: .daywatch)

        var wakeCalls = await executor.judgeWakeCalls
        #expect(wakeCalls.count == 1)
        #expect(wakeCalls[0].act == false, "daywatch should pass act=false")

        // Run another tick in nightwatch mode
        await runner.runOnce(mode: .nightwatch)

        wakeCalls = await executor.judgeWakeCalls
        #expect(wakeCalls.count == 2)
        #expect(wakeCalls[1].act == true, "nightwatch should pass act=true")
    }

    // MARK: - Test: Desk-gated branches (MEDIUM 1 + MEDIUM 2)

    @Test("ensure-on-start: apply(.daywatch) ensures desk session")
    func testEnsureOnStart() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        let desker = FakeDeskSessionManager()
        let runner = DaywatchRunner(executor: executor, deskSessionManager: desker, interval: 1000)

        await runner.apply(mode: .daywatch)

        let ensureCalls = await desker.ensureCalls
        #expect(ensureCalls.count == 1)
        #expect(ensureCalls[0] == .daywatch)
    }

    @Test("wrap-up-on-stop: apply(.off) posts shift wrap-up (non-destructive)")
    func testWrapUpOnStop() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        let desker = FakeDeskSessionManager()
        let runner = DaywatchRunner(executor: executor, deskSessionManager: desker, interval: 1000)

        // Start in daywatch
        await runner.apply(mode: .daywatch)
        var wrapUpCalls = await desker.wrapUpCalls
        #expect(wrapUpCalls.isEmpty, "No wrap-up yet")

        // Switch to off
        await runner.apply(mode: .off)
        wrapUpCalls = await desker.wrapUpCalls
        #expect(wrapUpCalls.count == 1, "Should post wrap-up on .off")

        // Verify desk was NOT closed (stays active for user review)
        let closeCalls = await desker.closeCalls
        #expect(closeCalls == 0, "Desk should NOT be closed (left active for user review)")
    }

    @Test("ensure-on-switch: mode switch ensures desk with new mode (reuses same desk)")
    func testEnsureOnModeSwitch() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        let desker = FakeDeskSessionManager()
        let runner = DaywatchRunner(executor: executor, deskSessionManager: desker, interval: 1000)

        // Start in daywatch
        await runner.apply(mode: .daywatch)
        var ensureCalls = await desker.ensureCalls
        #expect(ensureCalls.count == 1)
        #expect(ensureCalls[0] == .daywatch)
        let deskID1 = await desker.lastEnsuredWorktreeID
        #expect(deskID1 != nil)

        // Switch to nightwatch
        await runner.apply(mode: .nightwatch)
        ensureCalls = await desker.ensureCalls
        #expect(ensureCalls.count == 2)
        #expect(ensureCalls[1] == .nightwatch)
        let deskID2 = await desker.lastEnsuredWorktreeID

        // CRITICAL: Mode switch must REUSE the same desk and terminal, not respawn.
        // The per-tick judgePrompt carries the mode, so initial frame is one-time only.
        #expect(deskID2 == deskID1, "Mode switch should reuse same desk (not respawn terminal)")
    }

    @Test("nudge-on-tick-10: exit code 10 nudges desk with correct act flag (daywatch)")
    func testNudgeDaywatch() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 10)
        let desker = FakeDeskSessionManager()
        let runner = DaywatchRunner(executor: executor, deskSessionManager: desker, interval: 1000)

        // Deterministic: runOnce(mode:) ensures the desk via the retry path and
        // ticks exactly once — no background loop (apply() would race its
        // immediate first tick against this explicit one).
        await runner.runOnce(mode: .daywatch)

        let nudgeCalls = await desker.nudgeCalls
        #expect(nudgeCalls.count == 1)
        #expect(nudgeCalls[0].act == false, "daywatch nudge should have act=false")
    }

    @Test("nudge-on-tick-10: exit code 10 nudges desk with correct act flag (nightwatch)")
    func testNudgeNightwatch() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 10)
        let desker = FakeDeskSessionManager()
        let runner = DaywatchRunner(executor: executor, deskSessionManager: desker, interval: 1000)

        // Deterministic single tick — see daywatch variant for rationale.
        await runner.runOnce(mode: .nightwatch)

        let nudgeCalls = await desker.nudgeCalls
        #expect(nudgeCalls.count == 1)
        #expect(nudgeCalls[0].act == true, "nightwatch nudge should have act=true")
    }

    @Test("MEDIUM 2: retry ensure on next tick if initial ensure failed")
    func testRetryEnsureOnFailure() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        let desker = FakeDeskSessionManager(ensureBehavior: .failOnce)
        let runner = DaywatchRunner(executor: executor, deskSessionManager: desker, interval: 1000)

        // Deterministic: first runOnce hits the ensure (fails once), second retries.
        // No apply() — its background loop's immediate tick would race these counts.
        await runner.runOnce(mode: .daywatch)
        var ensureCalls = await desker.ensureCalls
        #expect(ensureCalls.count == 1, "First ensure call should have failed")

        await runner.runOnce(mode: .daywatch)
        ensureCalls = await desker.ensureCalls
        #expect(ensureCalls.count == 2, "Should retry ensure on next tick")
    }

    @Test("nudge falls back to wakeJudge when desk unavailable")
    func testWakeJudgeFallback() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 10)
        // No desk session manager — fallback to wakeJudge
        let runner = DaywatchRunner(executor: executor, deskSessionManager: nil, interval: 1000)

        // Deterministic: no apply() — its loop's tick-on-start would race this
        // explicit tick (same fix as the nudge/retry tests above).
        await runner.runOnce(mode: .daywatch)

        let wakeCalls = await executor.judgeWakeCalls
        #expect(wakeCalls.count == 1)
        #expect(wakeCalls[0].act == false, "fallback wakeJudge should have act=false")
    }

}

// MARK: - Loop tests (virtual time)

/// Tier 1 — the background loop, driven entirely by virtual time. Virtual time
/// makes the *production* interval free, so these run `defaultInterval` rather
/// than a shrunken test pacing: the timings asserted are the shipped ones.
///
/// CLOCK: `EventDrivenTestClock` with its **strict** waits
/// (`docs/specs/2026-08-13-poller-suite-clock-migration-design.md`). This is a
/// poller — tick, sleep, tick — so every advance past the first is a re-arm,
/// and a missed arming that merely recorded an issue would advance virtual time
/// against an empty ledger and desync the rest of the test into a hang. The
/// strict waits throw at the first miss, naming the step.
///
/// Its `advance` does no yielding of any kind, which is the property to keep in
/// mind when reading the assertions below: a *positive* fact about a resumed
/// task is claimed only after an event that happens-after it (the loop's
/// re-park), and both *negative* count reads — "no tick a millisecond early"
/// and "no ticks after `apply(.off)`" — pay an explicit `settle()` where the
/// predecessor leaned on `TestClock.advance`'s incidental megaYield. The one
/// negative that pays none is `hasSleeper == false`, which needs no scheduling
/// turn to become true and justifies itself where it stands.
@Suite("DaywatchRunner loop", .clockDriven)
struct DaywatchRunnerLoopTests {

    @Test("loop runs its first tick immediately, before any time passes")
    func testFirstTickIsImmediate() async throws {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        let clock = EventDrivenTestClock()
        let runner = DaywatchRunner(
            executor: executor, interval: DaywatchRunner.defaultInterval, clock: clock)

        await runner.apply(mode: .daywatch)

        // The loop parking on the interval sleep proves — sequentially, since
        // the tick precedes the sleep in runLoop() — that tick 1 completed.
        // Zero advance is the claim: "immediately" means no time passed.
        try await clock.requireSleeperArmed()
        #expect(await executor.tickCallCount == 1)
    }

    @Test("loop ticks again at exactly the production interval")
    func testSubsequentTicksAtInterval() async throws {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        let clock = EventDrivenTestClock()
        let runner = DaywatchRunner(
            executor: executor, interval: DaywatchRunner.defaultInterval, clock: clock)

        await runner.apply(mode: .daywatch)
        try await clock.requireSleeperArmed()
        #expect(await executor.tickCallCount == 1)

        // One millisecond short of the interval must not fire. A **plain**
        // advance on purpose, and it is sound only because the strict wait
        // above established that the loop's sleeper is registered — that is
        // what this step depends on and what the wait above now guarantees.
        await clock.advance(by: .seconds(DaywatchRunner.defaultInterval) - .milliseconds(1))
        // Negative assertion, so it gets a real settle first: this clock's
        // advance never runs a resumed task's code for us, and a tick that
        // fired a millisecond early would otherwise not have had the chance to
        // show up before the count is read (one-sided as ever — a
        // pathologically late tick can false-pass, never false-fail).
        await settle()
        #expect(await executor.tickCallCount == 1)

        // The final millisecond does. Wait for the re-park: that is tick 2 done.
        try await clock.requireAdvanceWhenArmed(by: .milliseconds(1))
        try await clock.requireSleeperArmed()
        #expect(await executor.tickCallCount == 2)

        // And it keeps its cadence, not just the one extra tick.
        try await clock.requireAdvanceWhenArmed(by: .seconds(DaywatchRunner.defaultInterval))
        try await clock.requireSleeperArmed()
        #expect(await executor.tickCallCount == 3)
    }

    @Test("duplicate same-mode apply starts exactly one loop")
    func testDuplicateApplyStartsOneLoop() async throws {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        let clock = EventDrivenTestClock()
        let runner = DaywatchRunner(
            executor: executor, interval: DaywatchRunner.defaultInterval, clock: clock)

        await runner.apply(mode: .daywatch)
        await runner.apply(mode: .daywatch)

        // Two loops would each tick immediately; exactly one tick means one loop —
        // but the second loop's first tick is async and a count read can miss it,
        // so the cadence below is the discriminating assertion: over one interval
        // a single loop ticks exactly once more, while two loops would reach 4.
        try await clock.requireSleeperArmed()
        #expect(await executor.tickCallCount == 1)

        try await clock.requireAdvanceWhenArmed(by: .seconds(DaywatchRunner.defaultInterval))
        try await clock.requireSleeperArmed()
        #expect(await executor.tickCallCount == 2)
    }

    @Test("apply(.off) cancels the loop: no sleeper remains, no further ticks")
    func testApplyOffCancelsLoop() async throws {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        let clock = EventDrivenTestClock()
        let runner = DaywatchRunner(
            executor: executor, interval: DaywatchRunner.defaultInterval, clock: clock)

        await runner.apply(mode: .daywatch)
        try await clock.requireAdvanceWhenArmed(by: .seconds(DaywatchRunner.defaultInterval))
        try await clock.requireSleeperArmed()
        #expect(await executor.tickCallCount == 2)

        await runner.apply(mode: .off)

        // The loop's timer is gone, and reading that synchronously is exact
        // here rather than a snapshot race: `apply(.off)` calls `cancel()`, and
        // a cancellation handler runs *on the cancelling task* while the loop
        // sits suspended — this clock's handler removes the ledger entry under
        // its own lock before `cancel()` returns. No scheduling turn is
        // involved, so no megaYield is needed to make it true (the predecessor
        // needed `checkSuspension()`'s for exactly that reason). Nor can a
        // sleeper reappear later: `sleep` opens with `checkCancellation()`, so
        // a loop that had not yet reached its sleep registers nothing either.
        #expect(clock.hasSleeper == false, "apply(.off) must leave no timer armed")

        // Bare advance on purpose: nothing may be sleeping, so an arming wait
        // would wait for a sleeper that must never come.
        await clock.advance(by: .seconds(DaywatchRunner.defaultInterval * 3))
        await settle()
        #expect(await executor.tickCallCount == 2)
    }

    @Test("concurrent same-mode apply: one transition, loop intact")
    func testConcurrentSameModeApply() async throws {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        let desker = FakeDeskSessionManager()
        let clock = EventDrivenTestClock()
        let runner = DaywatchRunner(
            executor: executor, deskSessionManager: desker,
            interval: DaywatchRunner.defaultInterval, clock: clock)

        // Two racing apply(.daywatch) from .off — the gate serializes them; the
        // second must be a genuine no-op, not a false supersession that closes
        // the first call's desk and leaves mode=on with no loop.
        async let a: Void = runner.apply(mode: .daywatch)
        async let b: Void = runner.apply(mode: .daywatch)
        _ = await (a, b)

        let ensureCalls = await desker.ensureCalls
        let closeCalls = await desker.closeCalls
        #expect(ensureCalls.count == 1, "duplicate same-mode apply must not re-ensure")
        #expect(closeCalls == 0, "no orphan-close on duplicate apply")

        // Pin the loop's first tick (exit 0, no nudge) as *completed* before
        // restubbing the exit code. Otherwise the async first tick can observe
        // exit 10 and nudge, making the count below 2 instead of 1.
        try await clock.requireSleeperArmed()

        // The transition really completed: a tick with exit 10 nudges the desk.
        await executor.setTickExitCode(10)
        await runner.runOnce()
        let nudges = await desker.nudgeCalls
        #expect(nudges.count == 1, "loop state intact after duplicate apply")

        await runner.apply(mode: .off)
        #expect(await desker.wrapUpCalls.count == 1, "Should post wrap-up on .off")
    }
}
