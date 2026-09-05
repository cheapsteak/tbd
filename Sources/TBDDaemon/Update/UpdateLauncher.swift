import Foundation
import os
import TBDShared

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private let launcherLogger = Logger(subsystem: "com.tbd.daemon", category: "update")

/// Everything needed to start `scripts/update.sh --auto`, decided without
/// spawning anything.
///
/// Separated from the spawn so the decision — which executable, which
/// arguments, which log, what `PATH` the script will see — is assertable in a
/// unit test. Testing that the child *survives* the daemon is not a unit test's
/// job; testing that the argv is right is.
public struct UpdateLaunchPlan: Sendable, Equatable {
    /// The binary actually executed. `/usr/bin/nohup`, not the script:
    /// `nohup` makes the child ignore `SIGHUP`, which is the one signal a
    /// terminating parent's session teardown would otherwise deliver to an
    /// update that must outlive the daemon it is replacing.
    public let executablePath: String
    /// `[<script>, "--auto"]`.
    public let arguments: [String]
    /// The script the arguments name, kept separately so a caller can check it
    /// exists before spawning.
    public let scriptPath: String
    /// Where the child's stdout and stderr are appended.
    public let logPath: String
    /// The child's environment.
    public let environment: [String: String]

    public init(
        executablePath: String,
        arguments: [String],
        scriptPath: String,
        logPath: String,
        environment: [String: String]
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.scriptPath = scriptPath
        self.logPath = logPath
        self.environment = environment
    }
}

/// Builds and runs the detached `scripts/update.sh --auto` the `auto` mode
/// launches.
public enum UpdateLauncher {
    /// Path of the update script inside a source worktree.
    public static func scriptPath(inSourceWorktree worktree: String) -> String {
        URL(fileURLWithPath: worktree, isDirectory: true)
            .appendingPathComponent("scripts")
            .appendingPathComponent("update.sh").path
    }

    /// Directories prepended to the child's `PATH` when they are missing.
    ///
    /// The daemon does not always have a usable `PATH`: when LaunchServices
    /// relaunches the app at login it ignores the bundle's `LSEnvironment`, and
    /// the daemon then inherits `/usr/bin:/bin:/usr/sbin:/sbin` — a `PATH` with
    /// no Homebrew, hence no modern git and no `swift`. An update that cannot
    /// build is worse than one that never started, so the launch repairs the
    /// `PATH` rather than depending on the launcher's.
    public static let pathFallbacks = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Decide how to launch the update for a build rooted at `sourceWorktree`.
    public static func plan(
        sourceWorktree: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UpdateLaunchPlan {
        let script = scriptPath(inSourceWorktree: sourceWorktree)
        var childEnv = environment
        childEnv["PATH"] = augmentedPath(environment["PATH"])
        return UpdateLaunchPlan(
            executablePath: "/usr/bin/nohup",
            arguments: [script, "--auto"],
            scriptPath: script,
            logPath: TBDConstants.updateLogPath(environment: environment),
            environment: childEnv)
    }

    /// `path` with every missing fallback directory appended, order preserved
    /// and nothing dropped. Appended rather than prepended: an operator who put
    /// a directory on `PATH` deliberately outranks our guess about Homebrew.
    public static func augmentedPath(_ path: String?) -> String {
        let existing = (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        var result = existing
        for fallback in pathFallbacks where !result.contains(fallback) {
            result.append(fallback)
        }
        return result.joined(separator: ":")
    }

    /// Spawn the plan, appending output to its log.
    ///
    /// - Returns: true when the child started. False when the script is
    ///   missing, the log could not be opened, or the spawn failed — all of
    ///   which are logged, and none of which the caller retries: a failed
    ///   attempt is not tried again until `main` moves (see `UpdateChecker`).
    @discardableResult
    public static func launch(
        _ plan: UpdateLaunchPlan,
        fileManager: FileManager = .default
    ) -> Bool {
        guard fileManager.isExecutableFile(atPath: plan.scriptPath) else {
            launcherLogger.error(
                "update: no executable script at \(plan.scriptPath, privacy: .public)")
            return false
        }
        let logURL = URL(fileURLWithPath: plan.logPath)
        do {
            try fileManager.createDirectory(
                at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            launcherLogger.error(
                "update: cannot create \(logURL.deletingLastPathComponent().path, privacy: .public): \(error, privacy: .public)")
            return false
        }
        // `O_APPEND`, not a seek to the end. The child and its subprocesses
        // inherit this descriptor for their whole run, while the script's own
        // `log()` appends through a separate open on every line. A descriptor
        // positioned once at spawn writes at that frozen offset forever, so
        // anything `log()` wrote in between gets overwritten — corrupting the
        // record exactly when an unattended update went wrong and the log is
        // the only witness. Append mode makes every write seek to the current
        // end atomically: the offset follows the file, not the moment of the
        // spawn. `O_CREAT` also covers the file's first creation, so no
        // separate `createFile` step is needed.
        let fd = open(plan.logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else {
            let reason = String(cString: strerror(errno))
            launcherLogger.error(
                "update: cannot open \(plan.logPath, privacy: .public) for append: \(reason, privacy: .public)")
            return false
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executablePath)
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.currentDirectoryURL = URL(
            fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        process.standardOutput = handle
        process.standardError = handle
        // Never inherit the daemon's stdin: a script that reads from it would
        // block forever, and `--auto` is non-interactive by contract.
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? handle.close()
            launcherLogger.error(
                "update: failed to launch \(plan.scriptPath, privacy: .public): \(error, privacy: .public)")
            return false
        }
        // The handle is duplicated into the child; this process is done with it.
        try? handle.close()
        launcherLogger.notice(
            "update: launched \(plan.scriptPath, privacy: .public) --auto, logging to \(plan.logPath, privacy: .public)")
        return true
    }
}
