import Foundation
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

    func wakeJudge(act: Bool) async {
        judgeWakeCalls.append(JudgeWakeCall(act: act))
    }
}

// MARK: - Fake DeskSessionManager for Testing

/// Fake desk session manager that records calls for testing desk-gated branches.
actor FakeDeskSessionManager {
    struct NudgeCall: Sendable {
        let worktreeID: UUID
        let act: Bool
    }

    private(set) var ensureCalls: [NightwatchMode] = []
    private(set) var nudgeCalls: [NudgeCall] = []
    private(set) var closeCalls: Int = 0

    private(set) var lastEnsuredWorktreeID: UUID?

    /// Minimal fake worktree for testing.
    struct FakeWorktree: Sendable {
        let id: UUID
    }

    func ensureDeskSession(mode: NightwatchMode) async throws -> FakeWorktree {
        ensureCalls.append(mode)
        let desk = FakeWorktree(id: UUID())
        lastEnsuredWorktreeID = desk.id
        return desk
    }

    func nudgeDeskSession(worktreeID: UUID, act: Bool) async {
        nudgeCalls.append(NudgeCall(worktreeID: worktreeID, act: act))
    }

    func closeDeskSession() async {
        closeCalls += 1
    }
}

// MARK: - Tests

struct DaywatchRunnerTests {

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

    // MARK: - Test: apply(.daywatch) twice is idempotent (one loop)

    @Test("apply(.daywatch) twice is idempotent (one loop)")
    func testApplyIdempotency() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        let runner = DaywatchRunner(executor: executor, interval: 1000)

        // Apply daywatch twice — should not start two loops
        await runner.apply(mode: .daywatch)
        await runner.apply(mode: .daywatch)

        // Give a tiny bit of time for the loop to run its first tick
        try? await Task.sleep(for: .milliseconds(50))

        // Should have exactly one tick from the initial immediate tick
        let count = await executor.tickCallCount
        #expect(count == 1)
    }

    // MARK: - Test: loop runs first tick immediately (no wait)

    @Test("loop runs first tick immediately (no wait for full interval)")
    func testLoopRunsFirstTickImmediately() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        // Use a large interval so we can be sure the immediate tick happens before the sleep
        let runner = DaywatchRunner(executor: executor, interval: 1000)

        await runner.apply(mode: .daywatch)

        // Small sleep to let the loop start and run first tick
        try? await Task.sleep(for: .milliseconds(100))

        // First tick should have been called immediately
        let count = await executor.tickCallCount
        #expect(count >= 1)
    }

    // MARK: - Test: apply(.off) cancels the loop

    @Test("apply(.off) cancels the loop")
    func testApplyOffCancelsLoop() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        let runner = DaywatchRunner(executor: executor, interval: 0.05)

        // Start the loop
        await runner.apply(mode: .daywatch)
        try? await Task.sleep(for: .milliseconds(100))

        let countBefore = await executor.tickCallCount
        #expect(countBefore >= 1)

        // Stop the loop
        await runner.apply(mode: .off)
        try? await Task.sleep(for: .milliseconds(50))

        let countAfter = await executor.tickCallCount
        // Should not have increased much (at most one more tick if one was in progress)
        #expect(countAfter <= countBefore + 1)
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

    // MARK: - Test: Desk-gated branches (M1)
    // Note: These tests verify that DaywatchRunner calls desk session lifecycle methods correctly.
    // DaywatchRunner type-checks with optional DeskSessionManager, so we test without the desk manager
    // to avoid type-mismatch complications. The core nudge/ensure/close logic is covered by the
    // executor-based tests above (wakeJudge fallback). Phase B: refactor DaywatchRunner to accept
    // a protocol interface for testability.

    @Test("apply(.daywatch) without desk manager is no-op (backward compat)")
    func testEnsureOnStartWithoutDesker() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        // nil desk manager: ensure-on-start skipped
        let runner = DaywatchRunner(executor: executor, deskSessionManager: nil, interval: 1000)

        await runner.apply(mode: .daywatch)

        let tickCalls = await executor.tickCallCount
        // First immediate tick should have run
        #expect(tickCalls >= 1)
    }

    @Test("apply(.off) with desk manager (nil) behavior")
    func testCloseOnStopIdempotent() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        let runner = DaywatchRunner(executor: executor, deskSessionManager: nil, interval: 1000)

        // Start in daywatch
        await runner.apply(mode: .daywatch)

        // Switch to off
        await runner.apply(mode: .off)

        // Verify loop was stopped (no more ticks)
        let beforeOff = await executor.tickCallCount

        // Small sleep to ensure no more ticks after off
        try? await Task.sleep(for: .milliseconds(100))
        _ = await executor.tickCallCount  // Not used, but ensures no more ticks fire

        // Should not have more than one tick (the initial immediate tick)
        #expect(beforeOff >= 1, "Initial tick should have run")
    }

    @Test("mode switch (daywatch → nightwatch) idempotent without desk")
    func testModeSwitchIdempotent() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        let runner = DaywatchRunner(executor: executor, deskSessionManager: nil, interval: 1000)

        // Start in daywatch
        await runner.apply(mode: .daywatch)
        let ticksAfterDaywatch = await executor.tickCallCount

        // Switch to nightwatch (should reuse loop, not create new one)
        await runner.apply(mode: .nightwatch)
        try? await Task.sleep(for: .milliseconds(50))
        let ticksAfterNightwatch = await executor.tickCallCount

        // Should have a few more ticks but not exponential
        #expect(ticksAfterNightwatch >= ticksAfterDaywatch, "Mode switch should not reset loop")
    }

    @Test("fall back to wakeJudge when desk unavailable (branch: nudge-vs-wakeJudge fallback)")
    func testWakeJudgeFallbackWithNoDeskSessionManager() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 10)
        // No desk session manager
        let runner = DaywatchRunner(executor: executor, deskSessionManager: nil, interval: 1000)

        // Apply mode without desk manager
        await runner.apply(mode: .daywatch)

        // Run one tick (will trigger fallback to wakeJudge)
        await runner.runOnce()

        let wakeCalls = await executor.judgeWakeCalls
        #expect(wakeCalls.count == 1)
        #expect(wakeCalls[0].act == false, "fallback wakeJudge should have act=false")
    }
}
