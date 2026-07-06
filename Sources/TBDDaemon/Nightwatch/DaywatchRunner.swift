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
    /// Safe no-op if `claude` binary is not found.
    public func wakeJudge(act: Bool) async {
        let prompt = act
            ? "Run the nightwatch judge: process queue/decisions.jsonl and fire approved actions."
            : "Run the nightwatch judge: process queue/decisions.jsonl and batch to for-adam.md (act=false)."

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["claude"]
        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let claudePath = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !claudePath.isEmpty else {
                logger.debug("claude binary not found; judge wake is a no-op")
                return
            }

            let judge = Process()
            judge.executableURL = URL(fileURLWithPath: claudePath)
            judge.arguments = ["-p", prompt, "--model", "claude-sonnet-5"]
            judge.standardOutput = FileHandle.nullDevice
            judge.standardError = FileHandle.nullDevice

            try judge.run()
            // Don't wait — let it run detached.
        } catch {
            logger.debug("Failed to wake judge: \(error.localizedDescription, privacy: .public)")
            // Best-effort; don't crash.
        }
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
    private let now: @Sendable () -> Date

    // MARK: - State

    private var currentMode: NightwatchMode = .off
    private var loopTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        executor: DaywatchExecuting,
        interval: TimeInterval = 15 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.executor = executor
        self.interval = interval
        self.now = now
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

    // MARK: - Private loop

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                // Cancelled during sleep
                return
            }

            if Task.isCancelled { return }

            // Run one tick
            let exitCode = await executor.runTick()

            // If exit code is 10, judgment is queued — wake the judge
            if exitCode == 10 {
                let act = (currentMode == .nightwatch)
                await executor.wakeJudge(act: act)
                logger.debug("Tick queued judgment; woke judge (act=\(act))")
            } else if exitCode == 0 {
                logger.debug("Tick completed (no judgment queued)")
            } else {
                logger.warning("Tick failed with exit code \(exitCode, privacy: .public)")
            }
        }
    }
}
