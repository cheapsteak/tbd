import Darwin
import os

/// Per-descriptor suppression of SIGPIPE for the pipes the daemon writes into a
/// child's stdin, and for the pane fanout's pipes to the app.
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
/// it runs in: the test host catches SIGPIPE with a handler instead of ignoring
/// it (`Tests/TestProcessDefaults/SIGPIPEHandler.c` says why).
///
/// **Only on an end this process writes to.** The flag belongs to the open file
/// description, not to the descriptor number, so a `dup` carries it, and so
/// does a child that is handed the descriptor. A child handed the write end of
/// its stdout or stderr pipe would therefore lose the SIGPIPE it may rely on to
/// stop writing once its reader has gone (`yes | head`). That is why the flag
/// is set at each call site, on the write end the daemon keeps for itself, and
/// not inside a pipe factory such as `Pipe.closeOnExec()`, which also makes the
/// stdout and stderr pipes whose write ends a child is handed.
///
/// Call it on a `Pipe`'s write end only once `isUsablePipe` has accepted that
/// pipe. A `Pipe()` whose `pipe(2)` failed reports descriptor 0, this process's
/// own stdin, which is not this code's to mark.
///
/// This is the pipe sibling of `SocketSIGPIPE`
/// (`Sources/TBDApp/SocketSIGPIPE.swift`), which sets `SO_NOSIGPIPE` on the
/// app's sockets; the two share a call shape and the handling of a refusal.
/// Every caller is in the daemon, so it lives in `Base`, below all of them, and
/// a change to it recompiles nothing outside the daemon.
enum PipeSIGPIPE {
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
    /// pipe unprotected, so the first one is logged here, once, rather than at
    /// each call site.
    @discardableResult
    static func suppress(on fd: Int32) -> Bool {
        suppress(on: fd, reportRefusal: true)
    }

    /// `suppress(on:)` with the refusal report made optional, for the test that
    /// checks a refusal. With `reportRefusal: false` a refusal returns `false`
    /// without logging and without spending the process's one fault log, so
    /// that test neither hides a later real refusal nor writes a fault on every
    /// run. Production code calls `suppress(on:)`.
    static func suppress(on fd: Int32, reportRefusal: Bool) -> Bool {
        guard fcntl(fd, F_SETNOSIGPIPE, 1) != -1 else {
            let failureCode = errno
            if reportRefusal { reportFirstRefusal(fd: fd, code: failureCode) }
            return false
        }
        return true
    }

    private static func reportFirstRefusal(fd: Int32, code failureCode: Int32) {
        let isFirst = refusalLogged.withLock { logged in
            defer { logged = true }
            return !logged
        }
        guard isFirst else { return }
        // `.fault`: per docs/diagnostics-strategy.md that is "invariants
        // violated, programmer errors, this should never happen", and a freshly
        // created pipe refusing F_SETNOSIGPIPE is exactly that. Logged once;
        // later refusals are silent.
        logger.fault(
            """
            F_SETNOSIGPIPE refused on fd \(fd, privacy: .public) (errno \
            \(failureCode, privacy: .public)): a write to this pipe after its \
            reader has gone raises SIGPIPE, which ends any process that neither \
            ignores nor catches it
            """)
    }
}
