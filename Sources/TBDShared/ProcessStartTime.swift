import Darwin
import Foundation

/// The kernel's record of when a process started, and the exact string shape
/// Claude Code writes into a peer registry record's `procStart`.
///
/// A shadow peer's record must describe a process that genuinely exists and
/// genuinely owns the socket
/// (`docs/specs/2026-08-29-remote-peer-messaging-design.md`, "Shadow peer
/// lifecycle"), which means `procStart` is read from the kernel rather than
/// composed from "now". The two differ by however long the helper took to get
/// from `exec` to publishing, and the difference is exactly what a recycled-pid
/// check would look at.
///
/// Sits in `TBDShared` because both halves need it: the helper writes the value
/// into its own record, and `ShadowPeerReconciler` compares a record's value
/// against the pid it is filed under to recognise the **recycled-pid ghost** —
/// the record Claude Code's reaper provably will not collect, because the
/// reaper checks pid liveness and nothing else (measured).
public enum ProcessStartTime {
    /// When `pid` started, or nil when the pid is dead or the kernel refuses
    /// (another user's process). Callers must treat nil as "not a process we
    /// can describe" rather than substituting the current time — a fabricated
    /// `procStart` is precisely the value the ghost check is trying to catch.
    public static func startTime(pid: pid_t) -> Date? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        // `p_starttime` is a `#define` onto an anonymous union member, so the C
        // spelling does not survive into Swift; `p_un.__p_starttime` is the
        // imported name of the same `struct timeval` (sys/proc.h,
        // `struct extern_proc`).
        let started = info.kp_proc.p_un.__p_starttime
        guard started.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970:
            TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
    }

    /// `procStart`'s exact shape: `ctime(3)`'s local-time rendering —
    /// `"Sat Aug 29 22:07:57 2026"`, with the day of month space-padded to two
    /// columns. Every record on a live registry carries this format, and it is
    /// the same rendering `ps -o lstart=` produces, so the value TBD writes is
    /// byte-identical to the one any other reader of that pid would compute.
    ///
    /// `ctime_r` is used rather than a `DateFormatter`: ICU has no space-padded
    /// day-of-month specifier, so a formatter would silently drift from the
    /// observed shape on days 1-9.
    public static func format(_ date: Date) -> String {
        var seconds = time_t(date.timeIntervalSince1970)
        // ctime_r requires a buffer of at least 26 bytes.
        var buffer = [CChar](repeating: 0, count: 32)
        guard ctime_r(&seconds, &buffer) != nil else { return "" }
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The `procStart` value for a live pid, or nil when there is no such
    /// process to describe.
    public static func procStart(pid: pid_t) -> String? {
        guard let date = startTime(pid: pid) else { return nil }
        return format(date)
    }
}
