import Foundation
import TBDShared

public struct PIDFile: Sendable {
    let path: String

    public init(path: String? = nil) {
        // See HookResolver — keep cross-module `TBDConstants` access inside
        // this module to avoid Xcode 26.3 unsafeMutableAddressor link failures.
        self.path = path ?? TBDConstants.pidFilePath
    }

    /// Claim the pid file for `pid`, this process by default.
    ///
    /// The parameter exists for one caller: a successor whose handover failed
    /// has to put the predecessor's pid back, returning the world to the state
    /// it found. See `Daemon.start()`.
    public func write(pid: pid_t = ProcessInfo.processInfo.processIdentifier) throws {
        try "\(pid)".write(toFile: path, atomically: true, encoding: .utf8)
    }

    public func read() -> pid_t? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = pid_t(content.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return pid
    }

    /// Stale when the recorded pid is not a *live TBDDaemon*. A bare
    /// `kill(pid, 0)` is insufficient: after a reboot the recorded pid can be
    /// recycled by an unrelated process, which would read as "daemon alive" and
    /// leave the dead socket in place — so a freshly-spawned daemon aborts (see
    /// Daemon.start's existing-pid gate). Verify the executable name too.
    public func isStale(
        isLiveDaemon: (pid_t) -> Bool = { ProcessLiveness.isLiveNamedProcess(pid: $0, name: ProcessLiveness.daemonExecutableName) }
    ) -> Bool {
        guard let pid = read() else { return false }
        return !isLiveDaemon(pid)
    }

    public func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Remove the pid file only if it still names *this* process.
    ///
    /// A handover puts two daemons on one pid file for a moment: the successor
    /// writes its own pid over the file first, so that every spurious spawn in
    /// the gap — the app's two-second poller, a stray `restart.sh` — meets a
    /// file naming a live daemon and exits at the gate. The predecessor then
    /// shuts down. An unconditional `remove()` there deletes the *successor's*
    /// claim, reopening exactly the race the successor-first write closes.
    ///
    /// Returns whether the file was ours, so callers can chain other
    /// process-owned artifacts off the same answer.
    @discardableResult
    public func removeIfOwned(pid: pid_t = ProcessInfo.processInfo.processIdentifier) -> Bool {
        guard let recorded = read() else { return false }
        guard recorded == pid else { return false }
        try? FileManager.default.removeItem(atPath: path)
        return true
    }

    /// Remove a stale pid file. **The socket file is deliberately left alone.**
    ///
    /// What removing it here can cost is a live daemon's rendezvous. A pid file
    /// reads as stale whenever the pid it names is not a live `TBDDaemon`, and
    /// a successor daemon writes its pid file (step 4 of `Daemon.start()`) well
    /// before it binds the socket, so "stale pid, live socket" is a state the
    /// path really passes through. Deleting the socket there leaves the
    /// successor accepting on a listener no client can reach.
    ///
    /// What it buys, against that, is bounded. The only thing that needs the
    /// rendezvous path free is `bind(2)`, and `SocketServer.start()` clears the
    /// path itself immediately before binding — but this runs at step 2 of
    /// `Daemon.start()` and that bind is hundreds of lines later, with plenty
    /// of `throw`s in between, so it is not true that the bind always
    /// eventually runs. A startup that fails first can leave a stale socket
    /// file behind.
    ///
    /// It is left anyway, because an unbound socket file behaves to a client
    /// exactly like a missing one — `connect(2)` fails either way — while an
    /// unlinked live one silently strands a working daemon. Clearing the
    /// rendezvous path is the act of whoever is about to bind it, and of
    /// nobody else. See `SocketServer.unlinkSocketFile(ifStillIdentity:)`.
    public func cleanupIfStale() {
        if isStale() {
            remove()
        }
    }
}
