import Darwin
import Foundation

/// Verifies that a pid refers to a live process whose executable has a given
/// last path component — the canonical "is this really our process?" check.
///
/// A bare `kill(pid, 0) == 0` is not enough: a pid recorded in a file (e.g. the
/// daemon pid file) survives reboots, and after a reboot the recorded pid can be
/// recycled by an arbitrary unrelated process. `kill` then reports "alive", so a
/// stale pid file reads as a running daemon — the socket is never cleaned, and a
/// freshly-spawned daemon aborts thinking one already runs. Checking the pid's
/// executable name via libproc closes that hole. Lives in TBDShared so both the
/// daemon (`PIDFile`, `Daemon`) and the app (`DaemonLiveness`) share one
/// implementation across the module boundary (the daemon cannot import TBDApp).
public enum ProcessLiveness {
    /// Last path component every real daemon binary has, wherever it was built
    /// (`<worktree>/.build/debug/TBDDaemon`, a bundle sibling, ...).
    public static let daemonExecutableName = "TBDDaemon"

    /// True when `pid` is a live process whose executable's last path component
    /// equals `name`.
    ///
    /// `isAlive` and `executablePath` are injection seams so both branches are
    /// unit-testable without real processes; production callers use the
    /// defaults (`kill(pid, 0)` + `proc_pidpath`).
    public static func isLiveNamedProcess(
        pid: pid_t,
        name: String,
        isAlive: (pid_t) -> Bool = { kill($0, 0) == 0 },
        executablePath: (pid_t) -> String? = ProcessLiveness.executablePath
    ) -> Bool {
        guard pid > 0 else { return false }
        guard isAlive(pid) else { return false }
        guard let path = executablePath(pid), !path.isEmpty else { return false }
        return (path as NSString).lastPathComponent == name
    }

    /// Resolve a pid's executable path via libproc's `proc_pidpath`.
    /// Nil when the pid is dead or the kernel refuses (e.g. another user's
    /// process) — callers must treat that as "not our process".
    public static func executablePath(pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN); the macro itself is
        // unavailable to Swift's Clang importer.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        // proc_pidpath NUL-terminates at `length`; truncate to the path's
        // actual bytes before decoding so trailing zero-fill from the oversized
        // buffer isn't folded into the string.
        let pathBytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: pathBytes, as: UTF8.self)
    }
}
