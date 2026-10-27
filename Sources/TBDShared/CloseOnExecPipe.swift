import Darwin
import Foundation

/// Setting `FD_CLOEXEC` on one end of a fresh pipe failed.
public struct CloseOnExecPipeError: LocalizedError, CustomStringConvertible, Equatable, Sendable {
    /// The descriptor `fcntl` refused.
    public let fileDescriptor: Int32
    public let errno: Int32

    public var description: String {
        "could not mark pipe descriptor \(fileDescriptor) close-on-exec: \(String(cString: strerror(errno)))"
    }

    public var errorDescription: String? { description }
}

extension Pipe {
    /// A `Pipe` whose two ends are both close-on-exec.
    ///
    /// `Pipe()` creates both descriptors inheritable, so any child another
    /// thread starts through a path that closes nothing — a `forkpty`, such as
    /// SwiftTerm's, or a `posix_spawn` without `POSIX_SPAWN_CLOEXEC_DEFAULT` —
    /// while the pipe is open takes a copy of both ends. That is the same hazard
    /// `HolderSpawner.makeLaunchSocketPair` documents for the launch channel.
    /// For a pipe that feeds a child's stdin, the stray copy of the write end is
    /// the dangerous one: end of file arrives only once every copy is closed, so
    /// a child whose exit is keyed to stdin EOF outlives its parent's close —
    /// and, when the parent is SIGKILLed, outlives the parent itself — for as
    /// long as the unrelated child happens to live. Measured with
    /// `PeerHelperLifecycleTests.anUnrelatedChildDoesNotHoldTheHelpersStdinOpen`:
    /// a raw-spawned `/bin/sleep` held a plain-`Pipe()` helper alive past a
    /// 30 s deadline, and a `Foundation.Process` child in the same place did not.
    ///
    /// The intended child still gets its end: the spawn places it on fd 0 or 1
    /// with a dup2 (a `posix_spawn` file action, in `Process`), and dup2 clears
    /// `FD_CLOEXEC` on the descriptor it places, whatever the source carries.
    ///
    /// Darwin has no `pipe2`, so the flag is set straight after `pipe` returns;
    /// a child another thread starts in the instant between the two calls can
    /// still inherit an end. That window is a few instructions wide, where a
    /// plain `Pipe()` leaves both ends exposed for the whole life of the child.
    ///
    /// Throws rather than returning a pipe with an end left inheritable, since a
    /// caller handed one could not tell.
    public static func closeOnExec() throws -> Pipe {
        let pipe = Pipe()
        for fd in [pipe.fileHandleForReading.fileDescriptor,
                   pipe.fileHandleForWriting.fileDescriptor] {
            let flags = fcntl(fd, F_GETFD)
            guard flags >= 0, fcntl(fd, F_SETFD, flags | FD_CLOEXEC) >= 0 else {
                throw CloseOnExecPipeError(fileDescriptor: fd, errno: Darwin.errno)
            }
        }
        return pipe
    }
}
