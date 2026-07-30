import Darwin
import Foundation
import TBDShared

/// Validates that a pid recorded in the daemon pid file really is a live
/// TBDDaemon process.
///
/// The pid file alone cannot be trusted: it survives reboots, and after a
/// reboot the recorded pid can be recycled by an arbitrary unrelated process.
/// A bare `kill(pid, 0) == 0` check then reports "daemon running", the app
/// skips spawning its sibling daemon, and every connect to the dead socket
/// fails with no recovery path. Checking the pid's executable name via
/// libproc closes that hole — the shared implementation lives in
/// `TBDShared.ProcessLiveness` so the daemon (`PIDFile`, `Daemon`) applies the
/// identical check without importing TBDApp.
enum DaemonLiveness {
    /// Last path component every real daemon binary has, wherever it was
    /// built (`<worktree>/.build/debug/TBDDaemon`, a bundle sibling, ...).
    static let daemonExecutableName = ProcessLiveness.daemonExecutableName

    /// True when `pid` is a live process whose executable's last path
    /// component is `TBDDaemon`.
    ///
    /// `isAlive` and `executablePath` are injection seams so both branches
    /// are unit-testable without real processes; production callers use the
    /// defaults (`kill(pid, 0)` + `proc_pidpath`).
    static func isLiveTBDDaemon(
        pid: pid_t,
        isAlive: (pid_t) -> Bool = { kill($0, 0) == 0 },
        executablePath: (pid_t) -> String? = ProcessLiveness.executablePath
    ) -> Bool {
        ProcessLiveness.isLiveNamedProcess(
            pid: pid,
            name: daemonExecutableName,
            isAlive: isAlive,
            executablePath: executablePath
        )
    }

    /// Parse the daemon pid file's contents. Nil when malformed. Pure — the
    /// caller reads the file so tests never need one on disk.
    static func pid(fromPidFileContents contents: String) -> pid_t? {
        pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Resolve a pid's executable path via libproc's `proc_pidpath`.
    static func processExecutablePath(pid: pid_t) -> String? {
        ProcessLiveness.executablePath(pid: pid)
    }
}
