import Darwin
import Foundation
import TBDKernel

/// A child process a test spawned that writes its own pid to a file before it
/// `exec`s, so cleanup can find it on every exit path without having recorded
/// anything earlier.
public enum RecordedChild {
    /// SIGKILLs the process at the pid written in `pidFile` only if it started
    /// no later than the file was written; with no file, no pid, no live
    /// process or a later start it does nothing. The child started before it
    /// wrote the file, and a process that reuses the pid after the child is
    /// gone started after the write, so the comparison tells the child from
    /// somebody else's process.
    public static func killIfStartedBeforeWriting(pidFile: String) {
        guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: pidFile),
              let written = attributes[.modificationDate] as? Date,
              let started = ProcessStartTime.startTime(pid: pid),
              // The kernel's start time and the file system's modification
              // date have different precision; 1 ms absorbs the difference.
              started <= written.addingTimeInterval(0.001)
        else { return }
        kill(pid, SIGKILL)
    }
}
