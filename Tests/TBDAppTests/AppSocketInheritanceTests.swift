import Darwin
import Foundation
import Testing

@testable import TBDApp

/// **The app's two daemon-facing sockets must not survive an `exec`.**
///
/// This is the app-side twin of `HolderDescriptorInheritanceTests` in the
/// daemon target, and it exists because the app is the process that forks
/// hardest. SwiftTerm's `Pty.fork(andExec:)` is a `forkpty` whose child path is
/// an optional `chdir` and then `execve` — no close sweep, no `FD_CLOEXEC`
/// applied to anything — and one is started for every tmux-backed panel, on top
/// of the git and PR-status tools the app shells out to through
/// `Foundation.Process`. So every descriptor the app leaves inheritable is a
/// descriptor some panel's shell is holding a copy of.
///
/// What that costs is specific to these two sockets. The daemon's only trigger
/// for "the app died" is EOF on the sidecar connection it accepted; there is no
/// periodic liveness sweep. A viewer process holding an inherited copy keeps
/// that connection open after the app is gone, so seizing the crashed app's
/// sessions waits until the last inheritor exits. Bounded rather than
/// permanent — those children die when their own masters close — but it is a
/// delay measured in whatever the longest-lived child happens to be.
@Suite("AppSocketInheritance")
struct AppSocketInheritanceTests {

    private static func isCloseOnExec(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFD)
        return flags >= 0 && (flags & FD_CLOEXEC) != 0
    }

    private static func noSIGPIPE(on fd: Int32) -> Bool {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, &length) == 0 else { return false }
        return value != 0
    }

    /// The non-vacuity premise for every row below, asserted rather than
    /// assumed: `socket(2)` hands back an **inheritable** descriptor. There is
    /// no `SOCK_CLOEXEC` on darwin to ask for anything else, so a passing row
    /// below can only mean the production code set the flag itself.
    @Test("a freshly created AF_UNIX socket is inheritable")
    func freshSocketsAreInheritable() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { Darwin.close(fd) }
        #expect(
            !Self.isCloseOnExec(fd),
            """
            socket(2) now returns close-on-exec descriptors on this platform, so every \
            assertion in this suite is vacuous and must be rewritten
            """)
    }

    // MARK: - The RPC socket

    /// A listening `AF_UNIX` socket at a path of this test's own, so
    /// `makeConnectedSocket` has a real peer to connect to. Returned close-on-exec
    /// itself: this suite runs beside others that keep `/bin/sleep 120` children
    /// alive for the rest of the run, and a test's own scaffolding has no
    /// business being inherited either.
    private func makeListener() throws -> (fd: Int32, path: String, directory: URL) {
        // Directly under `/tmp` and short: `sun_path` is 104 bytes on darwin and
        // the harness's scratch root is already deep.
        let directory = URL(fileURLWithPath: "/tmp/tbd-appsock-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("d.sock").path

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        try #require(path.utf8.count < sunPathSize)
        path.withCString { source in
            withUnsafeMutablePointer(to: &addr.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { chars in
                    _ = strlcpy(chars, source, sunPathSize)
                }
            }
        }
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0, "bind failed: errno \(errno)")
        try #require(Darwin.listen(fd, 4) == 0, "listen failed: errno \(errno)")
        return (fd, path, directory)
    }

    /// Every RPC call mints one of these — roughly two hundred call sites plus
    /// a two-second poll — so an inheritable one is not a rare event but the
    /// steady state of the app's descriptor table.
    @Test("the RPC socket the app connects with is close-on-exec")
    func connectedSocketIsCloseOnExec() throws {
        let listener = try makeListener()
        defer {
            Darwin.close(listener.fd)
            try? FileManager.default.removeItem(at: listener.directory)
        }

        let client = DaemonClient(socketPath: listener.path)
        let fd = try client.makeConnectedSocket()
        defer { Darwin.close(fd) }

        #expect(Self.isCloseOnExec(fd), """
            a panel's forkpty child would inherit this RPC socket; SwiftTerm's fork path \
            execs without closing anything
            """)
    }

    /// The other flag this same function sets, now that a test can reach the
    /// descriptor. Losing it is what makes a daemon restart kill TBDApp outright.
    @Test("the RPC socket the app connects with suppresses SIGPIPE")
    func connectedSocketSuppressesSIGPIPE() throws {
        let listener = try makeListener()
        defer {
            Darwin.close(listener.fd)
            try? FileManager.default.removeItem(at: listener.directory)
        }

        let client = DaemonClient(socketPath: listener.path)
        let fd = try client.makeConnectedSocket()
        defer { Darwin.close(fd) }

        #expect(Self.noSIGPIPE(on: fd))
    }

    // MARK: - The FD-vending sidecar

    /// `adopt(fd:)` is the one funnel every sidecar socket passes through —
    /// `connect(path:)` calls it, and so do the tests' `socketpair` ends — so
    /// asserting on it covers the production connection too.
    ///
    /// This is the socket whose EOF is the daemon's only notice that the app
    /// died, which is why an inherited copy costs more here than anywhere else
    /// in the app.
    @Test("FDSidecarClient makes the socket it adopts close-on-exec")
    func adoptedSidecarSocketIsCloseOnExec() throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let daemonSide = pair[0]
        let appSide = pair[1]
        defer { Darwin.close(daemonSide) }
        _ = fcntl(daemonSide, F_SETFD, FD_CLOEXEC)
        try #require(!Self.isCloseOnExec(appSide))

        let client = FDSidecarClient()
        client.adopt(fd: appSide)   // ownership transfers; the receive loop closes it on EOF

        #expect(Self.isCloseOnExec(appSide), """
            every tmux-backed panel starts a forkpty child, and a child holding a copy of \
            this socket keeps the daemon from ever seeing the app's death
            """)
    }
}
