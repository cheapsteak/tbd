import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

// A dying daemon must not unlink a live successor's socket.
//
// The socket path is a rendezvous every daemon generation binds in turn: a new
// daemon's `start()` removes whatever file is there and binds its own. If the
// outgoing daemon's `stop()` then unlinks on existence alone, it deletes the
// successor's socket. The successor never finds out — it keeps accepting on a
// listener no client can reach, and every client fails against a path that is
// simply gone. Only the file's identity, not its name, tells the two apart.
@Suite("SocketServer socket-file ownership")
struct SocketServerSocketOwnershipTests {

    /// Throwaway RPCRouter: in-memory DB + dryRun tmux, so no real tmux server
    /// is contacted and nothing under ~/tbd is touched.
    private func makeRouter() throws -> RPCRouter {
        let db = try TBDDatabase(inMemory: true)
        return RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog()
        )
    }

    /// `st_ino` of whatever is at `path`, or nil if nothing is. This is the
    /// identity the fix turns on — a path check alone cannot tell one server's
    /// socket from another's.
    private func inode(of path: String) -> ino_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_ino
    }

    /// Open an AF_UNIX/SOCK_STREAM client and connect() to `path`. Returns the
    /// connected fd, or -1. This is the client's-eye view: it is what actually
    /// breaks when the socket file is unlinked out from under a live listener.
    private func connectRawClient(to path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                UnsafeMutableRawPointer(pathPtr).copyMemory(from: ptr, byteCount: strlen(ptr) + 1)
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    /// Short /tmp path, well under the ~104-byte `sun_path` limit. NOT ~/tbd/sock.
    private func scratchSocketPath() -> String {
        "/tmp/tbd-sockown-\(UUID().uuidString.prefix(8)).sock"
    }

    @Test("a stopping server leaves a successor's socket at the same path alone")
    func successorSocketSurvivesPredecessorStop() async throws {
        let socketPath = scratchSocketPath()
        defer { unlink(socketPath) }

        // Daemon A binds the rendezvous path.
        let serverA = SocketServer(router: try makeRouter(), socketPath: socketPath)
        try await serverA.start()
        let inodeA = try #require(inode(of: socketPath))

        // Daemon B takes the path over: its start() unlinks A's file and binds
        // its own, so the path now names a different inode.
        let serverB = SocketServer(router: try makeRouter(), socketPath: socketPath)
        try await serverB.start()
        let inodeB = try #require(inode(of: socketPath))
        #expect(inodeB != inodeA, "B's bind must produce a new inode, or this test proves nothing")

        // A shuts down afterwards — the orphaned-daemon case.
        await serverA.stop()

        // B's socket must still be there, and must still be B's.
        #expect(inode(of: socketPath) == inodeB, "A's stop() deleted the live successor's socket")

        // And a client must still be able to reach B through the path.
        let clientFd = connectRawClient(to: socketPath)
        #expect(clientFd >= 0, "clients can no longer reach the live daemon at \(socketPath)")
        if clientFd >= 0 { close(clientFd) }

        await serverB.stop()
    }

    @Test("a stopping server still reclaims the socket it bound itself")
    func serverReclaimsItsOwnSocket() async throws {
        let socketPath = scratchSocketPath()
        defer { unlink(socketPath) }

        let server = SocketServer(router: try makeRouter(), socketPath: socketPath)
        try await server.start()
        #expect(inode(of: socketPath) != nil)

        await server.stop()

        // Nobody else took the path over, so the file is this server's to clean
        // up. The ownership check must not turn into "never unlink".
        #expect(inode(of: socketPath) == nil, "a server must still reclaim its own socket file")
    }

    @Test("a server that never bound unlinks nothing")
    func neverStartedServerUnlinksNothing() async throws {
        let socketPath = scratchSocketPath()
        defer { unlink(socketPath) }

        // Somebody else's socket sits at the path.
        let incumbent = SocketServer(router: try makeRouter(), socketPath: socketPath)
        try await incumbent.start()
        let incumbentInode = try #require(inode(of: socketPath))

        // A second server is constructed but never starts — a daemon that lost
        // the race to bind and is now being torn down.
        let neverStarted = SocketServer(router: try makeRouter(), socketPath: socketPath)
        await neverStarted.stop()

        #expect(
            inode(of: socketPath) == incumbentInode,
            "stop() on a server that never bound deleted a live socket"
        )

        await incumbent.stop()
    }
}
