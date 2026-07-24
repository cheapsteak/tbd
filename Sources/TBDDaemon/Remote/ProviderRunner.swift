import Foundation
import os
import TBDShared

private let remoteLogger = Logger(subsystem: "com.tbd.daemon", category: "remote")

public enum ProviderFailureClass: Sendable, Equatable {
    case permanent, contractBug, transient, authNeeded

    init?(exitCode: Int32) {
        switch exitCode {
        case 0: return nil
        case 2: self = .contractBug
        case 3: self = .transient
        case 4: self = .authNeeded
        default: self = .permanent   // 1 and anything undeclared
        }
    }
}

public struct ProviderResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: String

    public var failureClass: ProviderFailureClass? { ProviderFailureClass(exitCode: exitCode) }
    /// The contract error object, when the failing verb emitted one. A verb
    /// SHOULD emit this on stdout but may not — unparseable stdout decodes to
    /// `nil` rather than throwing, so callers always have the exit-code
    /// classification as a fallback.
    public var decodedError: ProviderErrorObject? {
        (try? JSONDecoder().decode(ProviderErrorEnvelope.self, from: stdout))?.error
    }
    public func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: stdout)
    }
}

public enum ProviderRunError: Error, Sendable {
    case timeout(verb: String)
}

public protocol RemoteProviderInvoking: Sendable {
    func run(_ config: RemoteProviderConfig, verb: [String], stdin: Data?,
             timeout: TimeInterval) async throws -> ProviderResult
}

/// Spawns the provider executable, feeds it `stdin`, and captures stdout /
/// stderr under a hard deadline.
///
/// stdout and stderr are drained concurrently with the child's execution via
/// `readabilityHandler` (the same mechanism and the same shared
/// `PipeDataAccumulator` / `ContinuationGuard` / `SubprocessWatchdog` helpers
/// `runBoundedProcess` uses in `BoundedProcessRunner.swift`). A `terminationHandler`
/// that instead calls `readDataToEndOfFile()` deadlocks the moment a child
/// writes more than the ~64KB darwin pipe buffer: the child blocks on the full
/// pipe, so it never exits, so the termination handler that would drain it
/// never fires. The contract's `log` verb returns raw scrollback (thousands of
/// lines) and routinely exceeds that buffer, so this is not a theoretical
/// concern.
public struct ProviderRunner: RemoteProviderInvoking {
    public init() {}

    public func run(_ config: RemoteProviderConfig, verb: [String], stdin: Data?,
                    timeout: TimeInterval) async throws -> ProviderResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.exec)
        process.arguments = (config.args ?? []) + verb
        var env = ProcessInfo.processInfo.environment
        env["TBD_CONTRACT_VERSION"] = "1"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        let outAccumulator = PipeDataAccumulator()
        let errAccumulator = PipeDataAccumulator()
        let verbName = verb.first ?? "?"

        // Drain both pipes independently as chunks arrive, concurrently with
        // the child's execution — never blocked behind each other or behind
        // process exit.
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            if !outAccumulator.readAvailable(from: handle) { handle.readabilityHandler = nil }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            if !errAccumulator.readAvailable(from: handle) { handle.readabilityHandler = nil }
        }

        // Detaches the drain handlers and snapshots both pipes without
        // blocking on EOF, then closes the parent read ends. Idempotent and
        // safe to call from whichever resume path wins.
        @Sendable func snapshot() -> (Data, Data) {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let out = outAccumulator.finish(handle: outPipe.fileHandleForReading)
            let err = errAccumulator.finish(handle: errPipe.fileHandleForReading)
            return (out, err)
        }

        let state = ContinuationGuard()

        return try await withCheckedThrowingContinuation { continuation in
            let deadlineToken = SubprocessWatchdog.shared.schedule(after: .seconds(timeout)) {
                guard state.claim() else { return }
                _ = snapshot()
                let pid = process.processIdentifier
                if pid > 0 {
                    kill(pid, SIGTERM)
                    SubprocessWatchdog.shared.schedule(after: .milliseconds(500)) {
                        if process.isRunning { kill(pid, SIGKILL) }
                    }
                }
                continuation.resume(throwing: ProviderRunError.timeout(verb: verbName))
            }

            process.terminationHandler = { finished in
                // The child already exited; everything it wrote is captured
                // by snapshot() without waiting for EOF.
                let (out, err) = snapshot()
                guard state.claim() else { return }   // watchdog already won → timed out
                SubprocessWatchdog.shared.cancel(deadlineToken)
                let stderr = String(data: err, encoding: .utf8) ?? ""
                if !stderr.isEmpty {
                    remoteLogger.debug(
                        "provider \(config.name, privacy: .public) \(verbName, privacy: .public) stderr: \(stderr, privacy: .public)")
                }
                continuation.resume(returning: ProviderResult(
                    exitCode: finished.terminationStatus, stdout: out, stderr: stderr))
            }

            do {
                try process.run()
            } catch {
                _ = snapshot()
                guard state.claim() else { return }
                SubprocessWatchdog.shared.cancel(deadlineToken)
                continuation.resume(throwing: error)
                return
            }

            if let stdin {
                inPipe.fileHandleForWriting.write(stdin)
            }
            inPipe.fileHandleForWriting.closeFile()
        }
    }
}
