import Darwin
import os

/// Per-socket suppression of SIGPIPE for the sockets the app writes to.
///
/// Writing to a socket whose peer has closed raises `SIGPIPE`, and its default
/// disposition **terminates the process**. The app writes to two kinds of
/// socket whose peer can vanish under it — the daemon's RPC socket
/// (`DaemonClient.makeConnectedSocket`) and the FD-vending sidecar
/// (`FDSidecarClient`) — so without this a daemon that dies or hangs up
/// mid-write kills TBDApp outright, losing every terminal panel, instead of
/// handing the writer the `EPIPE` its `catch`/error path is written to handle.
///
/// **This is deliberately per-socket, and must NOT be "simplified" into the
/// process-wide `signal(SIGPIPE, SIG_IGN)` one-liner that
/// `Sources/TBDDaemon/main.swift`, `TBDHolder` and `TBDPeerHelper` use.** A
/// disposition set to `SIG_IGN` is inherited across `fork` **and** `exec`, and
/// unlike those executables the app forks children constantly: every local-PTY
/// terminal panel spawns a shell or an agent through SwiftTerm's
/// `LocalProcess`/`forkpty`. Those jobs would then start life with SIGPIPE
/// ignored — `yes | head` spins instead of dying, and nothing hangs up on a
/// lost terminal. `Sources/TBDHolder/Holder.swift` resets `SIGPIPE` to
/// `SIG_DFL` in its child for exactly that reason; SwiftTerm's fork path is
/// third-party and does no such reset, so the app cannot rely on one. A socket
/// option is not inherited by anything, which is why the fix lives here.
///
/// Precedent and identical call shape: `HolderClient.connect`
/// (`Sources/TBDDaemon/Holder/HolderClient.swift`), which protects the daemon's
/// holder socket the same way.
enum SocketSIGPIPE {
    private static let logger = Logger(subsystem: "com.tbd.app", category: "socketSIGPIPE")

    /// Latched the first time `setsockopt` refuses, so a systematically
    /// failing environment reports the reason once instead of storming the
    /// log: `DaemonClient.makeConnectedSocket` mints a socket per RPC — ~200
    /// call sites plus a 2-second poll — and every one of them would log.
    /// One named `.fault` is all a reader needs; the second is noise.
    private static let refusalLogged = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Set `SO_NOSIGPIPE` on `fd`. Call immediately after the socket is created
    /// or adopted, before any write can reach it. Returns whether the option
    /// was accepted; tests read the option back with `getsockopt`.
    ///
    /// Both production call sites discard the result, because there is nothing
    /// useful for them to do about a refusal — the socket is still the only one
    /// they have. But a refusal must not be *silent*: it leaves the socket
    /// unprotected, and the next write to a vanished peer kills the process,
    /// which is the exact failure this type exists to remove. So the diagnostic
    /// lives in here, once, rather than at each call site.
    @discardableResult
    static func suppress(on fd: Int32) -> Bool {
        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let failureCode = errno
            let isFirst = refusalLogged.withLock { logged in
                defer { logged = true }
                return !logged
            }
            if isFirst {
                // `.fault`: per docs/diagnostics-strategy.md that is "invariants
                // violated, programmer errors, this should never happen", and a
                // freshly created or adopted socket refusing SO_NOSIGPIPE is
                // exactly that. Logged once — later refusals are silent.
                logger.fault(
                    """
                    SO_NOSIGPIPE refused on fd \(fd, privacy: .public) (errno \
                    \(failureCode, privacy: .public)) — this socket is unprotected, \
                    and a write to a closed peer will kill the app
                    """)
            }
            return false
        }
        return true
    }
}
