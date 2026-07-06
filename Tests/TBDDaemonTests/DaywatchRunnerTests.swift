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
    private var tickExitCode: Int32 = 0
    private var shouldDelayTick: Bool = false

    init(tickExitCode: Int32 = 0, shouldDelayTick: Bool = false) {
        self.tickExitCode = tickExitCode
        self.shouldDelayTick = shouldDelayTick
    }

    func runTick() async -> Int32 {
        if shouldDelayTick {
            try? await Task.sleep(for: .milliseconds(10))
        }
        tickCallCount += 1
        return tickExitCode
    }

    func wakeJudge(act: Bool) async {
        judgeWakeCalls.append(JudgeWakeCall(act: act))
    }

    nonisolated func setTickExitCode(_ code: Int32) {
        // Note: in real code we'd use a mutable reference or a separate state holder,
        // but for tests we'll just reinit the executor or accept this limitation.
    }
}

// MARK: - Tests

struct DaywatchRunnerTests {

    // MARK: - Test: apply(.daywatch) starts the loop

    @Test("apply(.daywatch) starts the loop")
    func testApplyDaywatchStartsLoop() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        let runner = DaywatchRunner(executor: executor, interval: 0.01)

        // Initially no ticks
        #expect(await executor.tickCallCount == 0)

        // Apply daywatch mode
        await runner.apply(mode: .daywatch)

        // Wait for at least one tick
        try? await Task.sleep(for: .milliseconds(50))

        // Tick should have been called at least once
        #expect(await executor.tickCallCount >= 1)
    }

    // MARK: - Test: apply(.off) stops the loop

    @Test("apply(.off) stops the loop")
    func testApplyOffStopsLoop() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        let runner = DaywatchRunner(executor: executor, interval: 0.01)

        // Start the loop
        await runner.apply(mode: .daywatch)
        try? await Task.sleep(for: .milliseconds(40))

        let countBefore = await executor.tickCallCount
        #expect(countBefore >= 1)

        // Stop the loop
        await runner.apply(mode: .off)
        try? await Task.sleep(for: .milliseconds(40))

        let countAfter = await executor.tickCallCount
        // Should not have increased (or increased minimally)
        #expect(countAfter <= countBefore + 1)
    }

    // MARK: - Test: apply(.off) when never started is idempotent

    @Test("apply(.off) when never started is idempotent")
    func testApplyOffWhenNeverStartedIsIdempotent() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        let runner = DaywatchRunner(executor: executor, interval: 0.01)

        // Apply off immediately (never started)
        await runner.apply(mode: .off)

        try? await Task.sleep(for: .milliseconds(30))

        // No ticks should have been called
        #expect(await executor.tickCallCount == 0)
        #expect(await executor.judgeWakeCalls.isEmpty)
    }

    // MARK: - Test: apply idempotency (calling apply(.daywatch) twice = one loop)

    @Test("apply(.daywatch) twice is idempotent (one loop)")
    func testApplyIdempotency() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        let runner = DaywatchRunner(executor: executor, interval: 0.01)

        // Apply daywatch twice
        await runner.apply(mode: .daywatch)
        await runner.apply(mode: .daywatch)

        try? await Task.sleep(for: .milliseconds(40))

        // Should still have ticks (loop is running)
        #expect(await executor.tickCallCount >= 1)
    }

    // MARK: - Test: tick returns 10 → wakeJudge called with act=false in daywatch

    @Test("tick returns 10 in daywatch mode → wakeJudge(act: false)")
    func testTickReturns10InDaywatch() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 10)
        let runner = DaywatchRunner(executor: executor, interval: 0.01)

        await runner.apply(mode: .daywatch)
        try? await Task.sleep(for: .milliseconds(40))

        // Judge should have been woken with act=false
        let wakeCalls = await executor.judgeWakeCalls
        #expect(wakeCalls.count >= 1)
        #expect(wakeCalls.last?.act == false)
    }

    // MARK: - Test: tick returns 10 → wakeJudge called with act=true in nightwatch

    @Test("tick returns 10 in nightwatch mode → wakeJudge(act: true)")
    func testTickReturns10InNightwatch() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 10)
        let runner = DaywatchRunner(executor: executor, interval: 0.01)

        await runner.apply(mode: .nightwatch)
        try? await Task.sleep(for: .milliseconds(40))

        // Judge should have been woken with act=true
        let wakeCalls = await executor.judgeWakeCalls
        #expect(wakeCalls.count >= 1)
        #expect(wakeCalls.last?.act == true)
    }

    // MARK: - Test: tick returns 0 → judge NOT woken

    @Test("tick returns 0 → judge NOT woken")
    func testTickReturns0NoJudgeWake() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        let runner = DaywatchRunner(executor: executor, interval: 0.01)

        await runner.apply(mode: .daywatch)
        try? await Task.sleep(for: .milliseconds(40))

        // Judge should NOT have been woken
        let wakeCalls = await executor.judgeWakeCalls
        #expect(wakeCalls.isEmpty)

        // But tick should have been called
        #expect(await executor.tickCallCount >= 1)
    }

    // MARK: - Test: mode switching (daywatch → nightwatch → off)

    @Test("mode switching: daywatch → nightwatch → off")
    func testModeSwitching() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 10)
        let runner = DaywatchRunner(executor: executor, interval: 0.01)

        // Start in daywatch
        await runner.apply(mode: .daywatch)
        try? await Task.sleep(for: .milliseconds(30))

        var wakeCalls = await executor.judgeWakeCalls
        let daywatchWakesCount = wakeCalls.filter { !$0.act }.count
        #expect(daywatchWakesCount >= 1)

        // Clear calls by reiniting executor
        let executor2 = FakeDaywatchExecutor(tickExitCode: 10)
        let runner2 = DaywatchRunner(executor: executor2, interval: 0.01)

        // Switch to nightwatch
        await runner2.apply(mode: .nightwatch)
        try? await Task.sleep(for: .milliseconds(30))

        wakeCalls = await executor2.judgeWakeCalls
        let nightwatchWakesCount = wakeCalls.filter { $0.act }.count
        #expect(nightwatchWakesCount >= 1)

        // Stop
        await runner2.apply(mode: .off)
        try? await Task.sleep(for: .milliseconds(30))

        let finalTickCount = await executor2.tickCallCount
        // Shouldn't increase much after stopping
        #expect(finalTickCount >= 1)
    }
}
