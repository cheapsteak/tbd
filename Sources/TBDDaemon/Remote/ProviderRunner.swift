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
/// All the mechanism — starvation-proof watchdog thread, the authoritative
/// monotonic-clock deadline check, incremental concurrent pipe draining
/// (stdout doesn't deadlock behind stderr or behind process exit — the
/// contract's `log` verb routinely returns more than the ~64KB darwin pipe
/// buffer), no-EOF-wait, single-resume guard — lives in the shared
/// `runBoundedProcess` (`BoundedProcessRunner.swift`), the same engine
/// `GitManager.run` and `TmuxManager.runExternalCommand` use. This only maps
/// the outcome to `ProviderResult` / `ProviderRunError`.
public struct ProviderRunner: RemoteProviderInvoking {
    public init() {}

    public func run(_ config: RemoteProviderConfig, verb: [String], stdin: Data?,
                    timeout: TimeInterval) async throws -> ProviderResult {
        var env = ProcessInfo.processInfo.environment
        env["TBD_CONTRACT_VERSION"] = "1"
        let verbName = verb.first ?? "?"

        switch try await runBoundedProcess(
            executable: config.exec,
            arguments: (config.args ?? []) + verb,
            currentDirectory: nil,
            environment: env,
            stdin: stdin,
            timeout: .seconds(timeout)
        ) {
        case .timedOut:
            throw ProviderRunError.timeout(verb: verbName)
        case let .completed(status, stdoutData, stderrData):
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            if !stderr.isEmpty {
                remoteLogger.debug(
                    "provider \(config.name, privacy: .public) \(verbName, privacy: .public) stderr: \(stderr, privacy: .public)")
            }
            return ProviderResult(exitCode: status, stdout: stdoutData, stderr: stderr)
        }
    }
}
