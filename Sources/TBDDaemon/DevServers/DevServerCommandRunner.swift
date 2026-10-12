import Foundation

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
        let merged = ProcessInfo.processInfo.environment.merging(environment) { _, declared in declared }
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
}
