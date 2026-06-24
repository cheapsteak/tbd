import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

// BUG 2: SocketServer must increment its connected-client count when a client
// connects and decrement it when the client disconnects. The daemon.status
// RPC reads this via connectedClientsProvider; if the atomic never moves, the
// "Connected clients" counter is permanently 0.
@Suite("SocketServer connected-client count")
struct SocketServerConnectedClientsTests {

    /// Build a throwaway RPCRouter the same way RPCRouterTestHelpers does:
    /// in-memory DB + dryRun tmux so no real tmux server is contacted.
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
            startTime: Date()
        )
    }

    /// Open a raw AF_UNIX/SOCK_STREAM client and connect() to `path`.
    /// Returns the connected fd (caller closes it).
    private func connectRawClient(to path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let rawPathPtr = UnsafeMutableRawPointer(pathPtr)
                rawPathPtr.copyMemory(from: ptr, byteCount: strlen(ptr) + 1)
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

    /// Poll `condition` up to ~2s in small steps; return true once it holds.
    private func poll(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        return condition()
    }

    @Test("connectedClients tracks connect and disconnect")
    func tracksConnectAndDisconnect() async throws {
        // Short /tmp path well under the ~104-char sun_path limit. NOT ~/tbd/sock.
        let socketPath = "/tmp/tbd-test-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(socketPath) }

        let router = try makeRouter()
        let server = SocketServer(router: router, socketPath: socketPath)
        try await server.start()

        #expect(server.connectedClients == 0)

        let clientFd = connectRawClient(to: socketPath)
        #expect(clientFd >= 0)

        let reachedOne = await poll { server.connectedClients == 1 }
        #expect(reachedOne)
        #expect(server.connectedClients == 1)

        close(clientFd)

        let backToZero = await poll { server.connectedClients == 0 }
        #expect(backToZero)
        #expect(server.connectedClients == 0)

        await server.stop()
    }
}
