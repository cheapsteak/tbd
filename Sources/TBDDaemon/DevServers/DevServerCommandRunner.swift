import Foundation
import TBDShared

enum DevServerCommandOutcome: Sendable, Equatable {
    case exited(Int32)
    case timedOut
    case failedToLaunch(String)
}

/// Runs a declared `stop` or `status` command with `sh -c`.
protocol DevServerCommandRunning: Sendable {
    func run(_ command: String, cwd: String, environment: [String: String], timeout: Duration) async
        -> DevServerCommandOutcome
}

struct ProductionDevServerCommandRunner: DevServerCommandRunning {
    let clock: any Clock<Duration>

    init(clock: any Clock<Duration> = ContinuousClock()) { self.clock = clock }

    func run(_ command: String, cwd: String, environment: [String: String], timeout: Duration) async
        -> DevServerCommandOutcome
    {
        let merged = Self.processEnvironment(declared: environment)
        do {
            switch try await runBoundedProcess(
                executable: "/bin/sh", arguments: ["-c", command], currentDirectory: cwd,
                environment: merged, timeout: timeout, clock: clock)
            {
            case .completed(let status, _, _): return .exited(status)
            case .signaled(let signal, _, _): return .exited(128 + signal)
            case .timedOut: return .timedOut
            }
        } catch {
            return .failedToLaunch(String(describing: error))
        }
    }

    /// The daemon's environment overlaid with the declared one, with the
    /// common package-manager directories appended to `PATH`: a daemon
    /// relaunched by LaunchServices can carry launchd's bare `PATH`, on which
    /// a `stop` or `status` that names `npx`, `docker` or `lsof` would fail
    /// as "not found" and read as a stopped server.
    static func processEnvironment(
        declared: [String: String],
        inheriting base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var merged = base.merging(declared) { _, declared in declared }
        let home = merged["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        merged["PATH"] = ExecutableSearchPath.augmented(merged["PATH"], homeDirectory: home)
        return merged
    }
}
