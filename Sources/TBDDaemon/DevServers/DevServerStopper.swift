import Foundation
import TBDShared

struct DevServerStopRequest: Sendable {
    let name: String
    let declared: DeclaredDevServer?
    /// The server's resolved working directory, where `stop` runs.
    let cwd: String
    let commandEnvironment: [String: String]
    let killTargets: [DevServerKillTarget]
    /// Running files describing this server, deleted after a successful stop.
    let runningFilePaths: [String]
}

struct DevServerStopReport: Sendable, Equatable {
    let name: String
    let succeeded: Bool
    let message: String?
}

/// The spec's stop rules, shared by `server.stop` and archive. Closing the
/// server's tab is the caller's job: `server.stop` closes it, archive's own
/// teardown already does.
struct DevServerStopper: Sendable {
    /// The archive hook's budget. The spec bounds only `status`.
    static let stopCommandTimeout: Duration = .seconds(60)

    let killer: DevServerGroupKiller
    let commandRunner: any DevServerCommandRunning
    let stopCommandTimeout: Duration

    init(
        killer: DevServerGroupKiller = DevServerGroupKiller(),
        commandRunner: any DevServerCommandRunning = ProductionDevServerCommandRunner(),
        stopCommandTimeout: Duration = DevServerStopper.stopCommandTimeout
    ) {
        self.killer = killer
        self.commandRunner = commandRunner
        self.stopCommandTimeout = stopCommandTimeout
    }

    func stop(_ request: DevServerStopRequest) async -> DevServerStopReport {
        if let stopCommand = request.declared?.stop {
            // The repo chose its stop path: a failure is reported, never
            // followed by a signal.
            switch await commandRunner.run(
                stopCommand, cwd: request.cwd, environment: request.commandEnvironment,
                timeout: stopCommandTimeout)
            {
            case .exited(0):
                break
            case .exited(let code):
                return failure(request, "stop command exited with code \(code)")
            case .timedOut:
                return failure(request, "stop command did not finish within \(stopCommandTimeout)")
            case .failedToLaunch(let reason):
                return failure(request, "stop command could not run: \(reason)")
            }
        } else {
            var problems: [String] = []
            for target in request.killTargets {
                switch await killer.kill(target) {
                case .survived(let pid, let pgid):
                    problems.append("process \(pid) (group \(pgid)) is still alive after SIGKILL")
                case .refused(_, let reason):
                    problems.append(reason)
                case .notRunning, .terminated, .killed:
                    break
                }
            }
            if !problems.isEmpty { return failure(request, problems.joined(separator: "; ")) }
        }
        for path in request.runningFilePaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        return DevServerStopReport(name: request.name, succeeded: true, message: nil)
    }

    private func failure(_ request: DevServerStopRequest, _ message: String) -> DevServerStopReport {
        DevServerStopReport(name: request.name, succeeded: false, message: message)
    }
}
