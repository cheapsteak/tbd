import Foundation
import os
import TBDShared

private let remoteLogger = Logger(subsystem: "com.tbd.daemon", category: "remote")

public struct ProviderResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: String
    /// The provider died of an uncaught signal rather than exiting, so it has
    /// no exit status and `exitCode` holds the signal number, which is what it
    /// held before this field existed. Every verb but one reads it as the
    /// non-zero exit it looks like. `remote.sendMessage` reads it as an unknown
    /// outcome: a provider killed mid-send may already have pressed Enter.
    public var terminatedBySignal: Bool = false

    /// Classified from the exit code AND the error object's `code`, so a
    /// provider that names `auth_expired` while exiting 1 still lands in
    /// `.authNeeded` with its remediation — see
    /// `ProviderFailureClass.classify(exitCode:error:)` for the union rule.
    public var failureClass: ProviderFailureClass? {
        ProviderFailureClass.classify(exitCode: exitCode, error: decodedError)
    }
    /// The contract error object, when the failing verb emitted one. A verb
    /// SHOULD emit this on stdout but may not — unparseable stdout decodes to
    /// `nil` rather than throwing, so callers always have the exit-code
    /// classification as a fallback.
    public var decodedError: ProviderErrorObject? {
        (try? JSONDecoder().decode(ProviderErrorEnvelope.self, from: stdout))?.error
    }
    /// `provider` is carried into the decode purely so a contract diagnostic
    /// can name whose output it was reading — with several providers
    /// registered, "some inventory is malformed" is not actionable.
    public func decoded<T: Decodable>(_ type: T.Type, provider: String? = nil) throws -> T {
        try JSONDecoder.forRemoteProvider(provider).decode(T.self, from: stdout)
    }
}

public enum ProviderRunError: LocalizedError, Sendable {
    case timeout(verb: String)

    public var errorDescription: String? {
        switch self {
        case .timeout(let verb):
            return "remote provider verb '\(verb)' did not finish before its deadline"
        }
    }
}

public protocol RemoteProviderInvoking: Sendable {
    /// - Parameter contractVersion: the major `RemoteProviderManager` negotiated
    ///   for this provider. Passed rather than read from a constant so both
    ///   conformances — the subprocess runner and any in-process built-in —
    ///   announce the same value the daemon agreed to.
    func run(_ config: RemoteProviderConfig, verb: [String], stdin: Data?,
             timeout: TimeInterval, contractVersion: Int) async throws -> ProviderResult
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

    /// The environment one provider invocation runs under. Pure and static so
    /// the emitted contract major is assertable without a spawn — this is one
    /// of the daemon's two emitters, and the two disagreeing is exactly the
    /// defect the negotiation work exists to close.
    public static func invocationEnvironment(
        base: [String: String], contractVersion: Int
    ) -> [String: String] {
        var env = base
        env["TBD_CONTRACT_VERSION"] = String(contractVersion)
        return env
    }

    /// The name a log line or timeout message gives an invocation: the verb,
    /// plus its subcommand for `transcript`, whose four subcommands are four
    /// different operations (`RemoteVerb`). Operands never appear — a session
    /// id, cursor or key is not part of what was run.
    public static func verbName(_ verb: [String]) -> String {
        guard let first = verb.first else { return "?" }
        if first == "transcript", verb.count > 1 {
            return "\(first) \(verb[1])"
        }
        return first
    }

    public func run(_ config: RemoteProviderConfig, verb: [String], stdin: Data?,
                    timeout: TimeInterval, contractVersion: Int) async throws -> ProviderResult {
        let env = Self.invocationEnvironment(
            base: ProcessInfo.processInfo.environment, contractVersion: contractVersion)
        let verbName = Self.verbName(verb)

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
            return Self.result(
                config: config, verbName: verbName, status: status,
                stdout: stdoutData, stderr: stderrData, signaled: false)
        case let .signaled(signal, stdoutData, stderrData):
            remoteLogger.error(
                "provider \(config.name, privacy: .public) \(verbName, privacy: .public) died of signal \(signal, privacy: .public)")
            return Self.result(
                config: config, verbName: verbName, status: signal,
                stdout: stdoutData, stderr: stderrData, signaled: true)
        }
    }

    private static func result(
        config: RemoteProviderConfig, verbName: String, status: Int32,
        stdout: Data, stderr stderrData: Data, signaled: Bool
    ) -> ProviderResult {
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        if !stderr.isEmpty {
            remoteLogger.debug(
                "provider \(config.name, privacy: .public) \(verbName, privacy: .public) stderr: \(stderr, privacy: .public)")
        }
        return ProviderResult(exitCode: status, stdout: stdout, stderr: stderr, terminatedBySignal: signaled)
    }
}
