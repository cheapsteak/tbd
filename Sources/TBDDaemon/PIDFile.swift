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

    public func cleanupIfStale() {
        if isStale() {
            remove()
            try? FileManager.default.removeItem(atPath: TBDConstants.socketPath)
        }
    }
}
