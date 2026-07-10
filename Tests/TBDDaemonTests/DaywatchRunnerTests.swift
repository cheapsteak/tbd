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

    private(set) var ensureCalls: [NightwatchMode] = []
    private(set) var nudgeCalls: [NudgeCall] = []
    private(set) var closeCalls: Int = 0

    private(set) var lastEnsuredWorktreeID: UUID?
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

        // Return a valid Worktree for testing
        let deskID = UUID()
        lastEnsuredWorktreeID = deskID
        // Create a real Worktree with minimal test values (repoID: nil makes it scratch)
        return Worktree(
            id: deskID,
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

    @Test("close-on-stop: apply(.off) closes desk session")
    func testCloseOnStop() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        let desker = FakeDeskSessionManager()
        let runner = DaywatchRunner(executor: executor, deskSessionManager: desker, interval: 1000)

        // Start in daywatch
        await runner.apply(mode: .daywatch)
        var closeCalls = await desker.closeCalls
        #expect(closeCalls == 0, "No close yet")

        // Switch to off
        await runner.apply(mode: .off)
        closeCalls = await desker.closeCalls
        #expect(closeCalls == 1, "Should close desk on .off")
    }

    @Test("ensure-on-switch: mode switch ensures desk with new mode")
    func testEnsureOnModeSwitch() async {
        let executor = FakeDaywatchExecutor(tickExitCode: 0)
        let desker = FakeDeskSessionManager()
        let runner = DaywatchRunner(executor: executor, deskSessionManager: desker, interval: 1000)

        // Start in daywatch
        await runner.apply(mode: .daywatch)
        var ensureCalls = await desker.ensureCalls
        #expect(ensureCalls.count == 1)
        #expect(ensureCalls[0] == .daywatch)

        // Switch to nightwatch
        await runner.apply(mode: .nightwatch)
        ensureCalls = await desker.ensureCalls
        #expect(ensureCalls.count == 2)
        #expect(ensureCalls[1] == .nightwatch)
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
