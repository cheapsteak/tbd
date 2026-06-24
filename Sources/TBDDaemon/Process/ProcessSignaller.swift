import Foundation

/// Injectable seam over OS process operations so reaper logic is unit-testable
/// without sending real signals or shelling out to `ps`. Mirrors TmuxManager's
/// dryRun-injection pattern.
public protocol ProcessSignaller: Sendable {
    /// True if the pid exists. Uses `kill(pid, 0)`: 0 => alive; EPERM => alive
    /// but owned by another uid (still "alive"); ESRCH => dead.
    func isAlive(_ pid: Int32) -> Bool
    /// Send SIGTERM. Targets the process group when `pid` is a group leader
    /// (tmux panes are `setsid` leaders, so this reaps in-group children too);
    /// otherwise signals just the pid.
    func terminate(_ pid: Int32)
    /// Send SIGKILL with the same group-vs-single semantics as `terminate`.
    func forceKill(_ pid: Int32)
    /// Pids whose parent pid == `serverPID` (one generation; tmux panes are
    /// direct children of the server process).
    func children(ofServerPID serverPID: Int32) -> [Int32]
    /// Full command line of the pid (for the TBD ownership fingerprint), or nil.
    func commandLine(_ pid: Int32) -> String?
}

public struct ProductionProcessSignaller: ProcessSignaller {
    public init() {}

    public func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if Foundation.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public func terminate(_ pid: Int32) { signal(pid, SIGTERM) }
    public func forceKill(_ pid: Int32) { signal(pid, SIGKILL) }

    private func signal(_ pid: Int32, _ sig: Int32) {
        guard pid > 1 else { return }  // never signal pid<=1
        // Group-kill only when pid is its own group leader, so we never signal
        // an unrelated process group by accident.
        if getpgid(pid) == pid {
            _ = Foundation.kill(-pid, sig)
        } else {
            _ = Foundation.kill(pid, sig)
        }
    }

    public func children(ofServerPID serverPID: Int32) -> [Int32] {
        guard let out = Self.runPS(["-axo", "pid=,ppid="]) else { return [] }
        var result: [Int32] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, let p = Int32(parts[0]), let pp = Int32(parts[1]) else { continue }
            if pp == serverPID { result.append(p) }
        }
        return result
    }

    public func commandLine(_ pid: Int32) -> String? {
        // `-ww` disables column-width truncation. Without it, some macOS
        // versions cap the command column at the terminal/`COLUMNS` width even
        // when stdout is a pipe, clipping the TBD fingerprint markers off the
        // tail of a long `claude`/`codex` invocation.
        Self.runPS(["-ww", "-o", "command=", "-p", String(pid)])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runPS(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        // Discard stderr to nullDevice: an undrained Pipe could deadlock if ps
        // wrote enough to fill the pipe buffer while we block on stdout below.
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
