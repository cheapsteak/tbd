import Foundation
import TBDShared

public struct PIDFile: Sendable {
    let path: String

    public init(path: String? = nil) {
        // See HookResolver — keep cross-module `TBDConstants` access inside
        // this module to avoid Xcode 26.3 unsafeMutableAddressor link failures.
        self.path = path ?? TBDConstants.pidFilePath
    }

    public func write() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        try "\(pid)".write(toFile: path, atomically: true, encoding: .utf8)
    }

    public func read() -> pid_t? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = pid_t(content.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return pid
    }

    /// Stale when the recorded pid is not a *live TBDDaemon*. A bare
    /// `kill(pid, 0)` is insufficient: after a reboot the recorded pid can be
    /// recycled by an unrelated process, which would read as "daemon alive" and
    /// leave the dead socket in place — so a freshly-spawned daemon aborts (see
    /// Daemon.start's existing-pid gate). Verify the executable name too.
    public func isStale(
        isLiveDaemon: (pid_t) -> Bool = { ProcessLiveness.isLiveNamedProcess(pid: $0, name: ProcessLiveness.daemonExecutableName) }
    ) -> Bool {
        guard let pid = read() else { return false }
        return !isLiveDaemon(pid)
    }

    public func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Remove the pid file only if it still names *this* process.
    ///
    /// A handover puts two daemons on one pid file for a moment: the successor
    /// writes its own pid over the file first, so that every spurious spawn in
    /// the gap — the app's two-second poller, a stray `restart.sh` — meets a
    /// file naming a live daemon and exits at the gate. The predecessor then
    /// shuts down. An unconditional `remove()` there deletes the *successor's*
    /// claim, reopening exactly the race the successor-first write closes.
    ///
    /// Returns whether the file was ours, so callers can chain other
    /// process-owned artifacts off the same answer.
    @discardableResult
    public func removeIfOwned(pid: pid_t = ProcessInfo.processInfo.processIdentifier) -> Bool {
        guard let recorded = read() else { return false }
        guard recorded == pid else { return false }
        try? FileManager.default.removeItem(atPath: path)
        return true
    }

    public func cleanupIfStale() {
        if isStale() {
            remove()
            try? FileManager.default.removeItem(atPath: TBDConstants.socketPath)
        }
    }
}
