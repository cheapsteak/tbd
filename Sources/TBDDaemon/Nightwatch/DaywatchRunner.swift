import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "nightwatch.daywatch")

/// Protocol for injecting executor behavior (tick + judge wake).
/// Allows tests to stub out real subprocess execution.
public protocol DaywatchExecuting: Sendable {
    /// Run one tick cycle; return exit code (0 = silent-ok, 10 = judgment queued).
    func runTick() async -> Int32
    /// Wake the judge to process queued decisions.
    /// `act` = true: auto-fire actions (nightwatch mode); false: batch/surface only (daywatch mode).
    func wakeJudge(act: Bool) async
}

/// Real executor: runs tick.py and judge.py via Process.
public struct ProcessDaywatchExecutor: DaywatchExecuting {
    private let skillDir: String

    public init(skillDir: String) {
        self.skillDir = skillDir
    }

    /// Run tick.py with a 5-minute timeout; return exit code.
    /// Uses terminationHandler to avoid blocking a Swift-concurrency thread indefinitely.
    public func runTick() async -> Int32 {
        let tickPath = skillDir + "/scripts/tick.py"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [tickPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let exitCode = await withCheckedContinuation { continuation in
            // Use a final class to hold the mutable state safely across async boundaries.
            // The lock protects the check-and-set of `finished` so that exactly one
            // of {terminationHandler, timeout} resumes the continuation (no double-resume).
            struct LockState {
                var finished = false
            }
            final class State: @unchecked Sendable {
                let lock = os.OSAllocatedUnfairLock(initialState: LockState())
            }
            let state = State()

            process.terminationHandler = { p in
                state.lock.withLock { s in
                    if !s.finished {
                        s.finished = true
                        continuation.resume(returning: p.terminationStatus)
                    }
                }
            }

            do {
                try process.run()
            } catch {
                logger.error("Failed to run tick.py: \(error.localizedDescription, privacy: .public)")
                continuation.resume(returning: -1)
                return
            }

            // Set up a 5-minute deadline. The timeout Task's check-and-set is also protected
            // by the lock, so only one of {termination, timeout} will successfully resume.
            Task {
                try await Task.sleep(for: .seconds(5 * 60))
                state.lock.withLock { s in
                    if !s.finished {
                        s.finished = true
                        logger.warning("tick.py exceeded 5-minute deadline; killed")
                        process.terminate()
                        continuation.resume(returning: -2)
                    }
                }
            }
        }

        return exitCode
    }

    /// Judgment queuing intentional interim no-op: ticks detect and record judgment requirements (exit 10),
    /// but daemon does NOT spawn a judge subprocess yet. Actuation is deferred to Phase A visible-worker
    /// rewrite, which will spawn TBD workers through the daemon's real primitives (ClaudeSpawnCommandBuilder,
    /// WorktreeLifecycle), providing proper plugin-dir, cwd, and permission posture instead of this interim
    /// headless approach. Removes token-burn loop and hardcoded prompt/model/policy-in-mechanism.
    public func wakeJudge(act: Bool) async {
        logger.notice("Judgment queued (act=\(act, privacy: .public)); actuation deferred to Phase A visible-worker rewrite.")
    }
}

/// Autonomous background loop that runs nightwatch ticks and wakes the judge
/// when a judgment is needed. Mirrors the poller pattern (ClaudeUsagePoller).
public actor DaywatchRunner {

    // MARK: - Constants

    /// Default tick interval (15 minutes in production, overrideable for tests).
    public static let defaultInterval: TimeInterval = 15 * 60

    // MARK: - Dependencies

    private let executor: DaywatchExecuting
    private let interval: TimeInterval

    // MARK: - State

    private var currentMode: NightwatchMode = .off
    private var loopTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        executor: DaywatchExecuting,
        interval: TimeInterval = 15 * 60
    ) {
        self.executor = executor
        self.interval = interval
    }

    // MARK: - Public API

    /// Apply a mode change: start the loop for .daywatch/.nightwatch, stop for .off.
    /// Idempotent.
    public func apply(mode: NightwatchMode) async {
        let wasRunning = currentMode != .off
        let shouldRun = mode != .off
        let previousMode = currentMode

        currentMode = mode

        if shouldRun && !wasRunning {
            // Start the loop
            loopTask = Task { [weak self] in
                await self?.runLoop()
            }
            logger.info("Started daywatch runner in mode \(mode.rawValue, privacy: .public)")
        } else if !shouldRun && wasRunning {
            // Stop the loop
            loopTask?.cancel()
            loopTask = nil
            logger.info("Stopped daywatch runner (was in mode \(previousMode.rawValue, privacy: .public))")
        }
        // else: no-op (already in desired state)
    }

    // MARK: - Testable single tick

    /// Run one tick cycle: execute tick.py and conditionally wake the judge.
    /// This method contains the core logic that the background loop drives repeatedly.
    /// - Parameter mode: If provided, use this mode instead of the actor's currentMode.
    ///   Useful for testing without starting the background loop.
    public func runOnce(mode: NightwatchMode? = nil) async {
        let effectiveMode = mode ?? currentMode

        // Run one tick
        let exitCode = await executor.runTick()

        // If exit code is 10, judgment is queued — wake the judge
        if exitCode == 10 {
            let act = (effectiveMode == .nightwatch)
            await executor.wakeJudge(act: act)
            logger.debug("Tick queued judgment; woke judge (act=\(act))")
        } else if exitCode == 0 {
            logger.debug("Tick completed (no judgment queued)")
        } else {
            logger.warning("Tick failed with exit code \(exitCode, privacy: .public)")
        }
    }

    // MARK: - Private loop

    private func runLoop() async {
        // Run one tick immediately on start (don't wait for the first interval)
        if !Task.isCancelled {
            await runOnce()
        }

        // Then sleep and loop
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                // Cancelled during sleep
                return
            }

            if Task.isCancelled { return }

            await runOnce()
        }
    }
}
