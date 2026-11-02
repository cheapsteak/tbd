import Darwin
import os

/// Per-descriptor suppression of SIGPIPE for the pipes TBD writes to.
///
/// A write to a pipe whose reading end has closed fails with `EPIPE` and also
/// raises `SIGPIPE`. XNU raises that signal at the process, not at the writing
/// thread, so it lands on whichever thread does not block it: left at its
/// default disposition it ends the process, and caught by a handler it can
/// interrupt another thread's blocked call with `EINTR`. `F_SETNOSIGPIPE` stops
/// the kernel raising it for writes to that pipe, so the writer sees only the
/// `EPIPE` its error path is written to handle, and no other thread sees
/// anything.
///
/// The daemon ignores SIGPIPE process-wide (`Sources/TBDDaemon/main.swift`), so
/// there this narrows what that line already does. It is set per descriptor
/// anyway so that the code writing to the pipe does not depend on the process
/// it runs in. The test host catches SIGPIPE with a handler instead of ignoring
/// it (`Tests/TestProcessDefaults/SIGPIPEHandler.c` says why), and the app
/// leaves it at its default.
///
/// The flag belongs to the open file rather than to the descriptor number, so a
/// `dup` of the descriptor carries it. Set it on the end this process writes
/// to, never on an end a child is handed to write to: that child would lose
/// the signal it may rely on to stop writing.
///
/// This is the pipe sibling of `SocketSIGPIPE`
/// (`Sources/TBDApp/SocketSIGPIPE.swift`), which sets `SO_NOSIGPIPE` on the
/// app's sockets, and shares its call shape and its handling of a refusal. It
/// lives in `TBDShared` rather than beside that type so that the daemon and the
/// app can both call it.
public enum PipeSIGPIPE {
    /// The daemon's subsystem, because the daemon is the only caller.
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "pipeSIGPIPE")

    /// Latched the first time `fcntl` refuses, so a systematically failing
    /// environment reports the reason once instead of once per pipe: the
    /// bounded runner creates a pipe for every subprocess it feeds stdin to.
    private static let refusalLogged = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Set `F_SETNOSIGPIPE` on `fd`, the write end of a pipe. Call immediately
    /// after the pipe is created, before any write can reach it. Returns
    /// whether the flag was accepted; tests read it back with
    /// `fcntl(fd, F_GETNOSIGPIPE)`.
    ///
    /// The production call sites discard the result, because there is nothing
    /// useful for them to do about a refusal: the pipe is still the only one
    /// they have. A refusal must not be silent, though, since it leaves the
    /// pipe unprotected, so the diagnostic lives here, once, rather than at
    /// each call site.
    @discardableResult
    public static func suppress(on fd: Int32) -> Bool {
        guard fcntl(fd, F_SETNOSIGPIPE, 1) != -1 else {
            let failureCode = errno
            let isFirst = refusalLogged.withLock { logged in
                defer { logged = true }
                return !logged
            }
            if isFirst {
                // `.fault`: per docs/diagnostics-strategy.md that is "invariants
                // violated, programmer errors, this should never happen", and a
                // freshly created pipe refusing F_SETNOSIGPIPE is exactly that.
                // Logged once; later refusals are silent.
                logger.fault(
                    """
                    F_SETNOSIGPIPE refused on fd \(fd, privacy: .public) (errno \
                    \(failureCode, privacy: .public)): a write to this pipe after its \
                    reader has gone raises SIGPIPE, which ends any process that neither \
                    ignores nor catches it
                    """)
            }
            return false
        }
        return true
    }
}
