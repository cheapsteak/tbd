import Foundation
import TBDShared

/// A running file a stop may delete, with the process it names.
struct DevServerStopRunningFile: Sendable, Equatable {
    let path: String
    let pid: Int32
    /// The start time the file recorded.
    let startTime: Date
}

struct DevServerStopRequest: Sendable {
    let name: String
    let declared: DeclaredDevServer?
    /// The server's resolved working directory, where `stop` runs.
    let cwd: String
    let commandEnvironment: [String: String]
    let killTargets: [DevServerKillTarget]
    /// Processes that look like the server's but could not be verified as
    /// it; each fails a signalling stop.
    let unverifiable: [String]
    /// The server reads running (or unknown) only through its `status`
    /// command: no running tab, no live running file. Without a declared
    /// `stop` there is then nothing TBD may signal.
    let runningOnlyByStatus: Bool
    /// Running files describing this server. A successful stop deletes each
    /// once the process it names is gone; one whose process outlives the stop
    /// is kept, for the liveness check and OrphanGC's stale-file sweep.
    let runningFiles: [DevServerStopRunningFile]
}

struct DevServerStopReport: Sendable, Equatable {
    let name: String
    let succeeded: Bool
    let message: String?
}

/// The spec's stop rules, shared by `server.stop` and archive. Closing the
/// server's tab is the caller's job: `server.stop` closes it, archive's own
/// teardown already does.
///
/// Repo code runs only on a user gesture. `server.stop` is one and runs a
/// declared `stop`; archive can fire unattended (auto-archive on merge), so
/// it passes `allowRepoCommands: false`, and its requests carry only the
/// server's TBD tab as a kill target, never a running file's pid.
struct DevServerStopper: Sendable {
    /// The same 60-second budget the archive hook gets.
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

    /// `allowRepoCommands` false never runs a declared `stop`: the request's
    /// kill targets are signalled as if none were declared, and a server with
    /// nothing TBD may signal is left running.
    func stop(_ request: DevServerStopRequest, allowRepoCommands: Bool = true) async -> DevServerStopReport {
        var notes: [String] = []
        if allowRepoCommands, let stopCommand = request.declared?.stop {
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
            if request.runningOnlyByStatus, request.killTargets.isEmpty, request.unverifiable.isEmpty {
                if request.declared?.stop != nil {
                    return failure(request, """
                        left running: \(request.name) can be stopped only by its declared `stop` command, \
                        and TBD runs repo commands only on a user gesture
                        """)
                }
                return failure(request, """
                    nothing to stop: \(request.name) reads running only through its `status` command \
                    and TBD has no process for it; declare a `stop` command
                    """)
            }
            var problems = request.unverifiable
            for target in request.killTargets {
                switch await killer.kill(target) {
                case .survived(let pid, let pgid):
                    problems.append("process \(pid) (group \(pgid)) is still alive after SIGKILL")
                case .survivedAlone(let pid, _):
                    problems.append("process \(pid) is still alive after SIGKILL")
                case .refused(let reason):
                    problems.append(reason)
                case .terminatedAlone(let pid, let pgid), .killedAlone(let pid, let pgid):
                    notes.append("""
                        pid \(pid) does not lead its own process group (it is in group \(pgid)), \
                        so only that process was signalled
                        """)
                case .notRunning, .terminated, .killed:
                    break
                }
            }
            if !problems.isEmpty { return failure(request, problems.joined(separator: "; ")) }
        }
        // A declared `stop` that exits 0 proves nothing about the process
        // (it may only ask a supervisor to stop it), so each file goes only
        // once the pid it names is gone or now names another process.
        for file in request.runningFiles {
            if isRunning(file) {
                notes.append("pid \(file.pid) named by the running file is still alive, so the file was kept")
            } else {
                try? FileManager.default.removeItem(atPath: file.path)
            }
        }
        return DevServerStopReport(
            name: request.name, succeeded: true, message: notes.isEmpty ? nil : notes.joined(separator: "; "))
    }

    private func isRunning(_ file: DevServerStopRunningFile) -> Bool {
        guard let info = killer.signalling.processInfo(file.pid), !info.isZombie else { return false }
        return abs(info.startTime.timeIntervalSince(file.startTime)) <= DevServerRunningFileStore.startTimeTolerance
    }

    private func failure(_ request: DevServerStopRequest, _ message: String) -> DevServerStopReport {
        DevServerStopReport(name: request.name, succeeded: false, message: message)
    }
}
