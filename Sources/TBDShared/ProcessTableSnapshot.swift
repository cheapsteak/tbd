import Darwin
import Foundation
import TBDKernel

/// One read of the kernel's process table: every live pid's parent, and when it
/// started.
///
/// **One read answers a whole question.** A caller that asks "which of these
/// processes descends from which of those" takes one snapshot and walks it, so
/// every pid it compares was observed at the same instant. Asking the kernel
/// once per pid instead would cost a syscall per hop per process and compare
/// facts read at different moments, which is exactly where a pid that exits
/// mid-question gets mistaken for one that never existed.
///
/// A value, not a live view: nothing here re-reads the kernel, so tests build
/// one from a literal table and the code under test cannot tell the
/// difference.
public struct ProcessTableSnapshot: Sendable, Equatable {
    /// What the table says about one pid.
    public struct Entry: Sendable, Equatable {
        public let parent: pid_t
        /// Nil when the kernel reported no start time for it.
        public let startedAt: Date?

        public init(parent: pid_t, startedAt: Date?) {
            self.parent = parent
            self.startedAt = startedAt
        }
    }

    public let entries: [pid_t: Entry]

    public init(entries: [pid_t: Entry]) {
        self.entries = entries
    }

    /// The deepest walk `ancestry(of:)` takes. A real chain from a TBD tab's
    /// job to an agent is a handful of hops (holder → shell → launcher →
    /// agent); the bound exists so a table that is somehow not a tree cannot
    /// hold a caller forever.
    public static let maximumDepth = 64

    public func isAlive(_ pid: pid_t) -> Bool { entries[pid] != nil }

    public func parent(of pid: pid_t) -> pid_t? { entries[pid]?.parent }

    public func startTime(of pid: pid_t) -> Date? { entries[pid]?.startedAt }

    /// `pid` and each of its ancestors, nearest first, up to but not including
    /// launchd. Empty when `pid` is not in the table.
    ///
    /// Stops at a pid the table does not hold, at a repeat (a table read
    /// across a fork can briefly disagree with itself), and at
    /// `maximumDepth`. A chain cut short is the conservative answer: an
    /// ancestor this walk does not reach is one nothing can be joined to.
    public func ancestry(of pid: pid_t) -> [pid_t] {
        var chain: [pid_t] = []
        var seen: Set<pid_t> = []
        var current = pid
        while current > 1, chain.count < Self.maximumDepth,
              let entry = entries[current], seen.insert(current).inserted {
            chain.append(current)
            current = entry.parent
        }
        return chain
    }

    /// The whole table, read with one `sysctl(KERN_PROC_ALL)`.
    ///
    /// Nil when the kernel refused, never a partial table: a table missing
    /// pids would make a live ancestor read as gone, and the caller could not
    /// tell that from the truth.
    public static func read() -> ProcessTableSnapshot? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        // The table can grow between the sizing call and the read, so size
        // with slack and retry a few times on ENOMEM rather than once.
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
                return nil
            }
            let stride = MemoryLayout<kinfo_proc>.stride
            var capacity = size / stride + 64
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            size = capacity * stride
            let status = procs.withUnsafeMutableBytes { buffer in
                sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0)
            }
            if status != 0 {
                if errno == ENOMEM { continue }
                return nil
            }
            capacity = size / stride
            var entries: [pid_t: Entry] = [:]
            entries.reserveCapacity(capacity)
            for info in procs.prefix(capacity) {
                let pid = info.kp_proc.p_pid
                guard pid > 0 else { continue }
                // A zombie has exited and only awaits its parent's `wait`: it
                // is not a live holder or job, and must not anchor anything.
                guard Int32(info.kp_proc.p_stat) != SZOMB else { continue }
                entries[pid] = Entry(
                    parent: info.kp_eproc.e_ppid,
                    startedAt: ProcessStartTime.startTime(of: info))
            }
            return ProcessTableSnapshot(entries: entries)
        }
        return nil
    }
}
