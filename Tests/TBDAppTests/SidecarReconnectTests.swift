import Darwin
import Foundation
import TBDShared
import Testing

@testable import TBDApp
import TestSupport

/// A FD sidecar that drops while the RPC socket stays up is reconnected, and
/// paced so two app instances cannot take it from each other in a loop.
///
/// `DaemonClient.connect()` reconnects the sidecar only after an RPC fails, so
/// before this a sidecar lost on its own — handed to a second app instance, or
/// dropped by a daemon restart no poll noticed — stayed down, and every new
/// holder tab failed to attach. The pacing is plain data and is tested as such;
/// the reconnect itself runs against a real listening socket standing in for
/// the daemon's vend socket.
@Suite("A sidecar that drops while the daemon stays up is reconnected, with backoff")
struct SidecarReconnectTests {

    private typealias Backoff = SidecarReconnectBackoff
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)
    private static let first = FDSidecarClient.ConnectionID(rawValue: 1)
    private static let second = FDSidecarClient.ConnectionID(rawValue: 2)

    // MARK: - The pacing

    @Test("a first reconnect is immediate, and each one after it waits twice as long, up to a cap")
    func theBackoffDoublesToACap() {
        var backoff = Backoff()
        #expect(backoff.allowsReconnect(at: Self.start), "a sidecar that drops once reconnects at once")

        backoff.noteReconnect(Self.first, at: Self.start)
        #expect(!backoff.allowsReconnect(at: Self.start.addingTimeInterval(Backoff.initialDelay - 0.1)))
        #expect(backoff.allowsReconnect(at: Self.start.addingTimeInterval(Backoff.initialDelay)))

        #expect(Backoff.delay(afterReconnect: 1) == Backoff.initialDelay)
        #expect(Backoff.delay(afterReconnect: 2) == Backoff.initialDelay * 2)
        #expect(Backoff.delay(afterReconnect: 3) == Backoff.initialDelay * 4)
        #expect(Backoff.delay(afterReconnect: 100) == Backoff.maximumDelay,
                "the wait must stop growing rather than overflow")
        #expect(Backoff.stableAfter > Backoff.maximumDelay, """
            a run must not reset on a connection that merely outlasted the longest wait, or two \
            instances fighting at the cap would reset each other back to two seconds
            """)
    }

    @Test("two instances taking the sidecar from each other are pushed ever further apart")
    func aFightBacksOff() {
        var backoff = Backoff()
        var now = Self.start
        var waits: [TimeInterval] = []
        // Each reconnect is taken away again by the other instance as soon as
        // it can; this instance reconnects as soon as it is allowed to.
        for round in 0..<12 {
            #expect(backoff.allowsReconnect(at: now))
            backoff.noteReconnect(FDSidecarClient.ConnectionID(rawValue: UInt64(round + 1)), at: now)
            var next = now
            while !backoff.allowsReconnect(at: next) { next = next.addingTimeInterval(1) }
            waits.append(next.timeIntervalSince(now))
            now = next
        }
        #expect(waits == waits.sorted(), "the waits must never shrink during a fight: \(waits)")
        #expect(waits.last == Backoff.maximumDelay, "a fight must settle at the cap: \(waits)")
    }

    @Test("a reconnect that holds for long enough ends the run; a shorter one or another connection does not")
    func aStableReconnectEndsTheRun() {
        var backoff = Backoff()
        backoff.noteReconnect(Self.first, at: Self.start)
        backoff.noteReconnect(Self.first, at: Self.start.addingTimeInterval(Backoff.initialDelay))
        #expect(backoff.reconnects == 2)

        backoff.noteConnected(Self.first, at: Self.start.addingTimeInterval(Backoff.stableAfter - 1))
        #expect(backoff.reconnects == 2, "a connection that has not held long enough ends nothing")
        backoff.noteConnected(Self.second, at: Self.start.addingTimeInterval(Backoff.stableAfter * 2))
        #expect(backoff.reconnects == 2, "a connection this path did not make says nothing about its run")

        let held = Self.start.addingTimeInterval(Backoff.initialDelay + Backoff.stableAfter)
        backoff.noteConnected(Self.first, at: held)
        #expect(backoff.reconnects == 0)
        #expect(backoff.allowsReconnect(at: held), "after a stable stretch the next drop reconnects at once")
    }

    // MARK: - The reconnect

    /// A listening socket standing in for the daemon's vend socket.
    private final class VendListener {
        let path: String
        private let root: String
        private let fd: Int32

        init() throws {
            root = fencedScratchRoot(prefix: "vnd")
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            path = "\(root)/v.sock"
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
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
        }

        /// Takes the pending connection and hangs it up, the way the daemon
        /// drops a sidecar it has handed to another app instance.
        func dropPendingConnection() {
            let accepted = accept(fd, nil, nil)
            #expect(accepted >= 0, "no sidecar connection was pending: errno \(errno)")
            if accepted >= 0 { Darwin.close(accepted) }
        }

        func stop() {
            Darwin.close(fd)
            try? FileManager.default.removeItem(atPath: root)
        }
    }

    @Test("a sidecar found down while the daemon is up is reconnected, and the next drop waits its turn")
    func aDownSidecarIsReconnected() async throws {
        let listener = try VendListener()
        defer { listener.stop() }
        let client = DaemonClient(
            socketPath: "/nonexistent/tbd-test.sock", vendSocketPath: listener.path)
        let sidecar = client.fdSidecar
        #expect(!sidecar.isConnected)

        #expect(await client.reconnectSidecarIfDown(at: Self.start))
        #expect(sidecar.isConnected, "a sidecar that is down must be reconnected")

        listener.dropPendingConnection()
        _ = try await waitFor(
            "the dropped sidecar to be seen as down",
            observed: { "isConnected=\(sidecar.isConnected)" }
        ) { !sidecar.isConnected }

        let tooSoon = Self.start.addingTimeInterval(Backoff.initialDelay / 2)
        #expect(await client.reconnectSidecarIfDown(at: tooSoon) == false)
        #expect(!sidecar.isConnected, "a second drop inside the wait must not reconnect yet")

        let afterTheWait = Self.start.addingTimeInterval(Backoff.initialDelay)
        #expect(await client.reconnectSidecarIfDown(at: afterTheWait))
        #expect(sidecar.isConnected, "once the wait is over the sidecar must be reconnected")
    }

    @Test("a connected sidecar is left as it is")
    func aConnectedSidecarIsLeftAlone() async throws {
        let listener = try VendListener()
        defer { listener.stop() }
        let client = DaemonClient(
            socketPath: "/nonexistent/tbd-test.sock", vendSocketPath: listener.path)
        #expect(await client.reconnectSidecarIfDown(at: Self.start))
        let connection = try #require(client.fdSidecar.currentConnection)

        #expect(await client.reconnectSidecarIfDown(at: Self.start.addingTimeInterval(60)))
        #expect(client.fdSidecar.currentConnection == connection,
                "a sidecar that is up must not be replaced")
    }

    @Test("a holder attach reconnects a sidecar that is down before it asks")
    func anAttachReconnectsTheSidecarFirst() async throws {
        let listener = try VendListener()
        defer { listener.stop() }
        // No RPC listener: the request itself fails, which is beside the point.
        let rpc = DaemonClient(
            socketPath: "/nonexistent/tbd-test.sock", vendSocketPath: listener.path)
        let holderClient = HolderAttachClient(daemonClient: rpc)
        #expect(!rpc.fdSidecar.isConnected)

        _ = try? await holderClient.attach(worktreeID: UUID(), paneID: "", terminalID: UUID())

        #expect(rpc.fdSidecar.isConnected, """
            an attach sent with the sidecar down is refused, because the daemon has nowhere \
            to vend the descriptor — it must reconnect the sidecar before it asks
            """)
    }
}
