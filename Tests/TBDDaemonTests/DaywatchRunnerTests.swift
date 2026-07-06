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

    func setTickExitCode(_ code: Int32) {
        self.tickExitCode = code
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
}
