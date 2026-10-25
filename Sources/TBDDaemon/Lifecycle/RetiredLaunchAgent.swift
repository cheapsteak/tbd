import Foundation
import os

/// The launch agent Nightwatch's opt-in scheduler installed, which no current
/// build runs. The daemon unloads it and removes its plist at startup.
///
/// The scheduler was a script in the bundled `nightwatch` skill.
/// `scheduler.sh enable` wrote `$HOME/Library/LaunchAgents/com.nightwatch-tick.plist`
/// — `Label` `com.nightwatch-tick`, `ProgramArguments` `/bin/bash` and the
/// skill's own `scripts/tick-cron.sh`, a `StartInterval` (900 seconds unless
/// given) and `RunAtLoad` — and loaded it with `launchctl load`.
/// `scheduler.sh disable` was the only thing that unloaded it. The plugin
/// writer now removes the skill folder (`PluginDirWriter.retiredSkills`), and
/// with it both the script the job runs and the `disable` command, so a job
/// somebody enabled fails on every interval and nothing else unloads it.
///
/// It acts on that one job, and only when all of these hold:
///
/// - `<launchAgentsDirectory>/com.nightwatch-tick.plist` is a regular file, not
///   a symlink. No other file in the directory is read.
/// - It parses as a property list whose `Label` is exactly `label`.
/// - Its `ProgramArguments` name a path ending in `scriptPathSuffix`. The
///   suffix rather than the whole path, because the scheduler wrote the
///   directory it was run from: the plugin's copy under Application Support,
///   or a copy of the skill installed somewhere else.
/// - Nothing exists at that path. A job whose script is still on disk runs
///   rather than fails, and is somebody's own copy of the skill. The plugin's
///   copy is already gone when this runs, because the daemon writes the
///   plugin first (`Daemon.start`, step 5b).
///
/// Then it boots the job out of the user's GUI domain through `launchctl` and
/// removes the plist — the order `scheduler.sh disable` used. The plist is
/// removed whatever `launchctl` reports: launchd loads it again at every
/// login, so removing it ends the job by the next login even when the unload
/// failed.
///
/// Never throws; each step is logged.
struct RetiredLaunchAgent: Sendable {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "startup")

    static let label = "com.nightwatch-tick"
    static let plistName = "com.nightwatch-tick.plist"
    static let scriptPathSuffix = "/skills/nightwatch/scripts/tick-cron.sh"

    /// `bootout` exit statuses that mean the job was not loaded, so there was
    /// nothing to unload: ESRCH (3, "No such process") and launchctl's own 113
    /// ("Could not find specified service").
    static let notLoadedStatuses: Set<Int32> = [3, 113]

    /// How the unload went. No value stops the plist's removal.
    enum Unload: Equatable, Sendable {
        case unloaded
        case notLoaded
        case failed
    }

    enum Outcome: Equatable, Sendable {
        /// Nothing at the plist's path.
        case absent
        /// A file is there, but it is not the retired job or the script it runs
        /// is still on disk. Nothing was touched and `launchctl` was not run.
        case leftAlone
        /// The plist was removed after an unload that went as `Unload` says.
        case removed(Unload)
        /// The plist could not be removed after an unload that went as
        /// `Unload` says.
        case removalFailed(Unload)
    }

    /// The current user's `~/Library/LaunchAgents` in production, a temporary
    /// directory in tests.
    let launchAgentsDirectory: URL
    /// The uid whose GUI domain the job is booted out of.
    let userID: uid_t
    let launchctl: any LaunchctlRunning

    init(
        launchAgentsDirectory: URL = RetiredLaunchAgent.defaultLaunchAgentsDirectory(),
        userID: uid_t = getuid(),
        launchctl: any LaunchctlRunning = ProductionLaunchctlRunner()
    ) {
        self.launchAgentsDirectory = launchAgentsDirectory
        self.userID = userID
        self.launchctl = launchctl
    }

    /// `~/Library/LaunchAgents`, where the scheduler wrote the plist
    /// (`$HOME/Library/LaunchAgents`).
    static func defaultLaunchAgentsDirectory() -> URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return library.appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    /// Unload the retired job and remove its plist, when the plist is present
    /// and is that job's.
    @discardableResult
    func removeIfPresent() async -> Outcome {
        let plist = launchAgentsDirectory.appendingPathComponent(Self.plistName)
        let path = plist.path

        // `attributesOfItem` does not follow a symlink, so a link is seen as
        // itself and left alone.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            Self.logger.debug("No retired launch agent at \(path, privacy: .public)")
            return .absent
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            Self.logger.info("Left \(path, privacy: .public) alone: it is not a regular file")
            return .leftAlone
        }
        let data: Data
        do {
            data = try Data(contentsOf: plist)
        } catch {
            Self.logger.error(
                "Could not read \(path, privacy: .public), leaving it: \(String(describing: error), privacy: .public)")
            return .leftAlone
        }
        guard let script = Self.retiredScriptPath(inPlist: data) else {
            Self.logger.info("Left \(path, privacy: .public) alone: it is not Nightwatch's tick job")
            return .leftAlone
        }
        if FileManager.default.fileExists(atPath: script) {
            Self.logger.info(
                "Left \(path, privacy: .public) alone: the script it runs is still at \(script, privacy: .public)")
            return .leftAlone
        }

        let unload = await unloadJob()
        do {
            try FileManager.default.removeItem(at: plist)
            Self.logger.notice("Removed retired launch agent \(path, privacy: .public)")
            return .removed(unload)
        } catch {
            Self.logger.error(
                "Failed to remove retired launch agent \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            return .removalFailed(unload)
        }
    }

    /// The script the retired job runs, when `data` is that job's plist: a
    /// property list whose `Label` is exactly `label` and whose
    /// `ProgramArguments` include a path ending in `scriptPathSuffix`. `nil`
    /// for anything else, including bytes that are not a property list.
    static func retiredScriptPath(inPlist data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              dictionary["Label"] as? String == label,
              let arguments = dictionary["ProgramArguments"] as? [String]
        else { return nil }
        return arguments.first { $0.hasSuffix(scriptPathSuffix) }
    }

    /// Boot the job out of `gui/<uid>`. `launchctl load` from a login session
    /// put it in that domain, and launchd loads `~/Library/LaunchAgents` into
    /// it at every login. `bootout` is launchctl(1)'s replacement for the
    /// legacy `unload` the scheduler used, and the service-target form names
    /// the job by label, so it does not depend on launchd reading the plist
    /// again.
    private func unloadJob() async -> Unload {
        let target = "gui/\(userID)/\(Self.label)"
        switch await launchctl.run(["bootout", target]) {
        case .exited(0, _):
            Self.logger.info("Booted out \(target, privacy: .public)")
            return .unloaded
        case .exited(let status, _) where Self.notLoadedStatuses.contains(status):
            Self.logger.info(
                "\(target, privacy: .public) was not loaded (launchctl bootout exit \(status, privacy: .public))")
            return .notLoaded
        case .exited(let status, let stderr):
            Self.logger.error(
                "launchctl bootout \(target, privacy: .public) failed with exit \(status, privacy: .public): \(stderr, privacy: .public)")
            return .failed
        case .timedOut:
            Self.logger.error("launchctl bootout \(target, privacy: .public) timed out")
            return .failed
        case .failedToLaunch(let reason):
            Self.logger.error(
                "Could not run launchctl bootout \(target, privacy: .public): \(reason, privacy: .public)")
            return .failed
        }
    }
}

/// What one `launchctl` invocation came to.
enum LaunchctlOutcome: Equatable, Sendable {
    /// It exited with `status`; `stderr` is what it printed there, trimmed.
    case exited(status: Int32, stderr: String)
    /// It ran past the runner's deadline and was killed.
    case timedOut
    /// It could not be started.
    case failedToLaunch(String)
}

/// Runs `launchctl` with the given arguments. The seam that keeps tests from
/// running the real one.
protocol LaunchctlRunning: Sendable {
    func run(_ arguments: [String]) async -> LaunchctlOutcome
}

/// Runs `/bin/launchctl` through `runBoundedProcess`, so a `launchctl` that
/// hangs is killed at the deadline instead of holding its caller. `bootout`
/// waits for a running job to exit; the deadline leaves room for that.
struct ProductionLaunchctlRunner: LaunchctlRunning {
    static let executable = "/bin/launchctl"
    static let timeout: Duration = .seconds(30)

    let clock: any Clock<Duration>

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    func run(_ arguments: [String]) async -> LaunchctlOutcome {
        let outcome: BoundedProcessOutcome
        do {
            outcome = try await runBoundedProcess(
                executable: Self.executable, arguments: arguments, currentDirectory: nil,
                timeout: Self.timeout, clock: clock)
        } catch {
            return .failedToLaunch(String(describing: error))
        }
        switch outcome {
        case .completed(let status, _, let stderr):
            return .exited(status: status, stderr: Self.text(stderr))
        case .signaled(let signal, _, let stderr):
            return .exited(status: 128 + signal, stderr: Self.text(stderr))
        case .timedOut:
            return .timedOut
        }
    }

    private static func text(_ data: Data) -> String {
        (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
