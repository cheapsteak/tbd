import Darwin
import Foundation

/// Validates that a pid recorded in the daemon pid file really is a live
/// TBDDaemon process.
///
/// The pid file alone cannot be trusted: it survives reboots, and after a
/// reboot the recorded pid can be recycled by an arbitrary unrelated process.
/// A bare `kill(pid, 0) == 0` check then reports "daemon running", the app
/// skips spawning its sibling daemon, and every connect to the dead socket
/// fails with no recovery path. Checking the pid's executable name via
/// libproc closes that hole.
enum DaemonLiveness {
    /// Last path component every real daemon binary has, wherever it was
    /// built (`<worktree>/.build/debug/TBDDaemon`, a bundle sibling, ...).
    static let daemonExecutableName = "TBDDaemon"

    /// True when `pid` is a live process whose executable's last path
    /// component is `TBDDaemon`.
    ///
    /// `isAlive` and `executablePath` are injection seams so both branches
    /// are unit-testable without real processes; production callers use the
    /// defaults (`kill(pid, 0)` + `proc_pidpath`).
    static func isLiveTBDDaemon(
        pid: pid_t,
        isAlive: (pid_t) -> Bool = { kill($0, 0) == 0 },
        executablePath: (pid_t) -> String? = processExecutablePath
    ) -> Bool {
        guard pid > 0 else { return false }
        guard isAlive(pid) else { return false }
        guard let path = executablePath(pid), !path.isEmpty else { return false }
        return (path as NSString).lastPathComponent == daemonExecutableName
    }

    /// Parse the daemon pid file's contents. Nil when malformed. Pure — the
    /// caller reads the file so tests never need one on disk.
    static func pid(fromPidFileContents contents: String) -> pid_t? {
        pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Resolve a pid's executable path via libproc's `proc_pidpath`.
    /// Nil when the pid is dead or the kernel refuses (e.g. another user's
    /// process) — callers must treat that as "not our daemon".
    static func processExecutablePath(pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN); the macro itself is
        // unavailable to Swift's Clang importer.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
