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
    /// Send SIGTERM to **exactly this pid**, never to its process group.
    ///
    /// For callers that have already enumerated the set they mean to signal
    /// and must not exceed it. `terminate`'s group escalation is a superset of
    /// the process *group*, not of that set: a group can hold a process the
    /// caller deliberately excluded, and on a reused pid `getpgid` resolves to
    /// a stranger's group entirely.
    func terminateProcessOnly(_ pid: Int32)
    /// Send SIGKILL to exactly this pid, never to its process group.
    func forceKillProcessOnly(_ pid: Int32)
    /// Pids whose parent pid == `serverPID` (one generation; tmux panes are
    /// direct children of the server process).
    func children(ofServerPID serverPID: Int32) -> [Int32]
    /// Full command line of the pid (for the TBD ownership fingerprint), or nil.
    func commandLine(_ pid: Int32) -> String?
    /// `ps -o stat=` for the pid (e.g. "S+", "Ss"), or nil when the pid is
    /// gone. The trailing `+` marks the tty's foreground process group.
    func stat(_ pid: Int32) -> String?
    /// When the process now holding this pid started, or nil when that cannot
    /// be read (the pid is gone, or `ps` answered something unparseable).
    ///
    /// This is the anti-pid-reuse fact, and the reason it is a protocol
    /// requirement rather than a convenience: a caller killing by a pid it
    /// recorded earlier has no other way to tell its own process from a
    /// stranger that inherited the number. **Nil must be read as "not the same
    /// process"** by every such caller — never as "close enough".
    ///
    /// The value survives `execve`, which is what makes it usable here: a
    /// holder's job is spawned as a login shell and may replace its image with
    /// the agent binary moments later, and its start time does not move when
    /// it does.
    func startTime(_ pid: Int32) -> Date?
}

public extension ProcessSignaller {
    /// Defaults so adding these requirements does not break a conformer that
    /// has no use for the distinction: only an implementation that reaches a
    /// real `kill(2)` can widen a signal to a process group in the first
    /// place, so for everyone else the pid-exact door and the ordinary one are
    /// the same door.
    func terminateProcessOnly(_ pid: Int32) { terminate(pid) }
    func forceKillProcessOnly(_ pid: Int32) { forceKill(pid) }
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

    public func terminateProcessOnly(_ pid: Int32) { signalPIDOnly(pid, SIGTERM) }
    public func forceKillProcessOnly(_ pid: Int32) { signalPIDOnly(pid, SIGKILL) }

    private func signalPIDOnly(_ pid: Int32, _ sig: Int32) {
        guard pid > 1 else { return }  // never signal pid<=1
        _ = Foundation.kill(pid, sig)
    }

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

    public func stat(_ pid: Int32) -> String? {
        Self.runPS(["-o", "stat=", "-p", String(pid)])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func startTime(_ pid: Int32) -> Date? {
        guard pid > 0, let raw = Self.runPS(["-o", "lstart=", "-p", String(pid)]) else { return nil }
        return Self.parseLstart(raw)
    }

    /// Parses `ps -o lstart=` — "Tue Sep  1 14:02:47 2026", in the machine's
    /// local time zone.
    ///
    /// The day-of-month is space-padded to two columns, so the string carries a
    /// run of two spaces for the first nine days of every month. Collapsing all
    /// whitespace before parsing is what keeps this from working for three
    /// weeks and then failing on the first of the month.
    static func parseLstart(_ raw: String) -> Date? {
        let normalized = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return lstartFormatter.date(from: normalized)
    }

    /// `en_US_POSIX` because the field's weekday and month names are C-locale
    /// abbreviations regardless of what the user's locale is set to.
    private static let lstartFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()

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
