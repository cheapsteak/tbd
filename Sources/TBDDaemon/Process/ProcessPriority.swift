import Darwin
import Foundation

/// Reads and changes macOS background priority for other processes, natively.
///
/// A seam, so the controller that decides *which* processes to lower is
/// unit-testable without touching a real process. Design:
/// docs/specs/2026-10-21-agent-start-admission-design.md, "Background priority".
///
/// Start times are microseconds since the epoch, compared for exact equality:
/// they identify a process across a pid being reused, and a rounded value could
/// match a stranger.
protocol ProcessPriority: Sendable {
    /// The process's base priority (`pti_priority`), or nil when the pid is gone
    /// or unreadable. A normal process reads 20; one in the background reads 4.
    func basePriority(of pid: pid_t) -> Int32?
    /// Lowers the process to background priority. False when the kernel refused.
    func lowerToBackground(_ pid: pid_t) -> Bool
    /// Restores the process to normal priority. False when the kernel refused.
    func restore(_ pid: pid_t) -> Bool
    /// When the process now holding `pid` started, or nil when it is gone.
    func startTimeMicros(of pid: pid_t) -> Int64?
    /// The pid's parent, or nil when it is gone.
    func parentPID(of pid: pid_t) -> pid_t?
    /// `root` and every descendant, `root` first. Empty when `root` is gone.
    func subtree(of root: pid_t) -> [pid_t]
}

extension ProcessPriority {
    /// Base priority at or below this is already background.
    static var backgroundCeiling: Int32 { 4 }

    func isBackground(_ pid: pid_t) -> Bool? {
        basePriority(of: pid).map { $0 <= Self.backgroundCeiling }
    }
}

/// libproc and `setpriority`, with no subprocess per pid.
///
/// `getpriority(PRIO_DARWIN_PROCESS)` cannot read another process's state (it
/// answers 0 either way), so the state is read from `pti_priority` instead.
struct ProductionProcessPriority: ProcessPriority {
    /// A real tab's tree is a handful of processes; the bounds only keep a
    /// pathological table from holding a sweep.
    static let maximumDepth = 32
    static let maximumProcesses = 4096

    init() {}

    func basePriority(of pid: pid_t) -> Int32? {
        guard pid > 0 else { return nil }
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return info.pti_priority
    }

    func lowerToBackground(_ pid: pid_t) -> Bool {
        pid > 0 && setpriority(PRIO_DARWIN_PROCESS, id_t(pid), PRIO_DARWIN_BG) == 0
    }

    func restore(_ pid: pid_t) -> Bool {
        pid > 0 && setpriority(PRIO_DARWIN_PROCESS, id_t(pid), 0) == 0
    }

    private func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    func startTimeMicros(of pid: pid_t) -> Int64? {
        guard let info = bsdInfo(pid), info.pbi_start_tvsec > 0 else { return nil }
        return Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec)
    }

    func parentPID(of pid: pid_t) -> pid_t? {
        bsdInfo(pid).map { pid_t($0.pbi_ppid) }
    }

    func subtree(of root: pid_t) -> [pid_t] {
        guard bsdInfo(root) != nil else { return [] }
        var result: [pid_t] = [root]
        var seen: Set<pid_t> = [root]
        var frontier: [pid_t] = [root]
        var depth = 0
        while !frontier.isEmpty, depth < Self.maximumDepth, result.count < Self.maximumProcesses {
            var next: [pid_t] = []
            for parent in frontier {
                for child in children(of: parent) where seen.insert(child).inserted {
                    result.append(child)
                    next.append(child)
                }
            }
            frontier = next
            depth += 1
        }
        return result
    }

    /// `proc_listchildpids` answers a pid count, capped by the buffer, so a full
    /// buffer is retried larger.
    private func children(of pid: pid_t) -> [pid_t] {
        var capacity = 64
        while capacity <= Self.maximumProcesses {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let count = Int(proc_listchildpids(
                pid, &buffer, Int32(capacity * MemoryLayout<pid_t>.size)))
            if count <= 0 { return [] }
            if count < capacity { return buffer.prefix(count).filter { $0 > 0 } }
            capacity *= 4
        }
        return []
    }
}
