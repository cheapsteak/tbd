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

    /// Run tick.py; return exit code.
    public func runTick() async -> Int32 {
        let tickPath = skillDir + "/scripts/tick.py"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [tickPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            logger.error("Failed to run tick.py: \(error.localizedDescription, privacy: .public)")
            return -1
        }
    }

    /// Wake the judge: spawn `claude --model claude-sonnet-5 <prompt>`.
    /// Sets up working directory to the skill dir and provides absolute queue paths.
    /// Safe no-op if `claude` binary is not found.
    public func wakeJudge(act: Bool) async {
        let prompt = act
            ? "Run the nightwatch judge: process \(skillDir)/queue/decisions.jsonl and fire approved actions."
            : "Run the nightwatch judge: process \(skillDir)/queue/decisions.jsonl and batch to \(skillDir)/queue/for-adam.md (act=false)."

        // Find claude binary in standard locations
        let claudePath = findExecutable("claude")
        guard !claudePath.isEmpty && claudePath != "/usr/bin/env" else {
            logger.warning("claude binary not found; judge wake is a no-op")
            return
        }

        let judge = Process()
        judge.executableURL = URL(fileURLWithPath: claudePath)
        judge.arguments = ["-p", prompt, "--model", "claude-sonnet-5"]
        judge.currentDirectoryURL = URL(fileURLWithPath: skillDir)
        judge.standardOutput = FileHandle.nullDevice
        judge.standardError = FileHandle.nullDevice

        do {
            try judge.run()
            // Don't wait — let it run detached.
        } catch {
            logger.warning("Failed to wake judge: \(error.localizedDescription, privacy: .public)")
            // Best-effort; don't crash.
        }
    }

    /// Helper: find an executable in standard locations.
    /// Returns the full path if found, or an empty string otherwise.
    private func findExecutable(_ name: String) -> String {
        for path in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return ""
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
            logger.info("Stopped daywatch runner (was in mode \(self.currentMode.rawValue, privacy: .public))")
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
