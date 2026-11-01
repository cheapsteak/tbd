import Darwin
import Foundation
import TBDKernel

/// A child process a test spawned, remembered by its pid and by the kernel
/// start time it had while the test knew it was alive.
///
/// The start time is the identity check (Tests/CLAUDE.md, "kill by captured
/// PID"): a pid is free for reuse the moment its process is reaped, and on a
/// shared machine its next owner is somebody else's process, so a remembered
/// pid is signalled only while it still names the process that was recorded.
public struct RecordedChild: Sendable, Equatable {
    public let pid: pid_t
    public let startTime: Date

    /// Remembers `pid` with its current start time, or returns nil when no
    /// live process has that pid. Call it only while the test knows the child
    /// is alive.
    public static func record(pid: pid_t) -> RecordedChild? {
        guard let started = ProcessStartTime.startTime(pid: pid) else { return nil }
        return RecordedChild(pid: pid, startTime: started)
    }

    /// SIGKILLs the child if `pid` still names the process that was recorded,
    /// and does nothing otherwise.
    public func killIfStillTheSame() {
        guard ProcessStartTime.startTime(pid: pid) == startTime else { return }
        kill(pid, SIGKILL)
    }
}
