import Darwin

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
    /// Set `SO_NOSIGPIPE` on `fd`. Call immediately after the socket is created
    /// or adopted, before any write can reach it. Returns whether the option
    /// was accepted; callers ignore it (it cannot fail for a live socket) and
    /// tests read the option back with `getsockopt`.
    @discardableResult
    static func suppress(on fd: Int32) -> Bool {
        var on: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
    }
}
