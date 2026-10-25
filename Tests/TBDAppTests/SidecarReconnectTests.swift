import Darwin
import Foundation
import TBDShared
import Testing

@testable import TBDApp
import TestSupport

/// A FD sidecar that drops while the app stays connected is reconnected: by
/// the poll tick on an escalating backoff, and by a holder attach on a fixed
/// minimum interval that leaves the poll's backoff alone.
///
/// `DaemonClient.connect()` runs only while the app believes itself
/// disconnected, so before this a sidecar lost on its own — handed to a second
/// app instance, or dropped by a daemon restart no poll noticed — stayed down,
/// and every new holder tab failed to attach. The pacing is plain data over
/// clock offsets and is tested as such; the reconnect itself runs against a
/// real listening socket standing in for the daemon's vend socket, on an
/// injected clock.
@Suite("A sidecar that drops while the app stays connected is reconnected, with pacing")
struct SidecarReconnectTests {

    private typealias Backoff = SidecarReconnectBackoff

    // MARK: - The pacing

    @Test("a first poll reconnect is immediate, and each one after it waits twice as long, up to a cap")
    func theBackoffDoublesToACap() {
        var backoff = Backoff()
        #expect(backoff.allowsReconnect(.poll, at: .zero), "a sidecar that drops once reconnects at once")

        backoff.noteReconnect(.poll, at: .zero)
        #expect(!backoff.allowsReconnect(.poll, at: Backoff.initialDelay - .milliseconds(100)))
        #expect(backoff.allowsReconnect(.poll, at: Backoff.initialDelay))

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
        var now = Duration.zero
        var waits: [Duration] = []
        // Each reconnect is taken away again by the other instance as soon as
        // it can; this instance reconnects as soon as it is allowed to.
        for _ in 0..<12 {
            #expect(backoff.allowsReconnect(.poll, at: now))
            backoff.noteReconnect(.poll, at: now)
            var next = now
            while !backoff.allowsReconnect(.poll, at: next) { next += .seconds(1) }
            waits.append(next - now)
            now = next
        }
        #expect(waits == waits.sorted(), "the waits must never shrink during a fight: \(waits)")
        #expect(waits.last == Backoff.maximumDelay, "a fight must settle at the cap: \(waits)")
    }

    @Test("a reconnect that holds for long enough ends the run; a shorter one does not")
    func aStableReconnectEndsTheRun() {
        var backoff = Backoff()
        backoff.noteConnected(at: .zero)
        #expect(backoff.reconnects == 0, "a sidecar up with no reconnect behind it is no run")
        backoff.noteReconnect(.poll, at: .zero)
        let last = Backoff.initialDelay
        backoff.noteReconnect(.poll, at: last)
        #expect(backoff.reconnects == 2)

        backoff.noteConnected(at: last + Backoff.stableAfter - .seconds(1))
        #expect(backoff.reconnects == 2, "a connection that has not held long enough ends nothing")

        let held = last + Backoff.stableAfter
        backoff.noteConnected(at: held)
        #expect(backoff.reconnects == 0)
        #expect(backoff.allowsReconnect(.poll, at: held), "after a stable stretch the next drop reconnects at once")
    }

    /// A second app instance that takes the sidecar back on every attach must
    /// be slowed down, not fought tab by tab: attach-time reconnects escalate
    /// too, on a run of their own. And panels retrying through a daemon
    /// restart must not spend the poll's run against a vend socket that is
    /// not up yet, or no reconnect would be allowed when it came back.
    @Test("attach-time reconnects back off on a run of their own, apart from the poll's")
    func attachReconnectsBackOffOnTheirOwn() {
        var backoff = Backoff()
        var now = Duration.zero
        var waits: [Duration] = []
        for _ in 0..<8 {
            #expect(backoff.allowsReconnect(.attach, at: now))
            backoff.noteReconnect(.attach, at: now)
            var next = now
            while !backoff.allowsReconnect(.attach, at: next) { next += .milliseconds(500) }
            waits.append(next - now)
            now = next
        }
        #expect(waits == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16),
                          .seconds(30), .seconds(30), .seconds(30)], "\(waits)")
        #expect(backoff.reconnects == 0, "an attach-time try is not a step in the poll's run")
        #expect(backoff.allowsReconnect(.poll, at: now),
                "the poll must still be free to reconnect the moment the socket is back")
    }

    @Test("a delivered attach ends the attach run, and only that run")
    func aDeliveredAttachEndsTheAttachRun() {
        var backoff = Backoff()
        backoff.noteReconnect(.attach, at: .zero)
        backoff.noteReconnect(.attach, at: .seconds(1))
        backoff.noteReconnect(.poll, at: .seconds(1))
        #expect(!backoff.allowsReconnect(.attach, at: .seconds(2)))

        backoff.noteAttachDelivered()

        #expect(backoff.attachReconnects == 0)
        #expect(backoff.allowsReconnect(.attach, at: .seconds(2)),
                "a reconnect that led to a delivered attach was not fighting anybody")
        #expect(backoff.reconnects == 1, "the poll's run is not the attach's to end")
        #expect(!backoff.allowsReconnect(.poll, at: .seconds(2)))
    }

    // MARK: - The reconnect

    /// A listening socket standing in for the daemon's vend socket.
    private final class VendListener {
        let path: String
        private let root: String
        private let fd: Int32

        /// Binds `<root>/v.sock`; mints a root when none is given.
        init(root givenRoot: String? = nil) throws {
            root = givenRoot ?? fencedScratchRoot(prefix: "vnd")
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            path = Self.socketPath(in: root)
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

        static func socketPath(in root: String) -> String { "\(root)/v.sock" }

        /// Takes the pending connection and hangs it up, the way the daemon
        /// drops a sidecar it has handed to another app instance.
        func dropPendingConnection() {
            let accepted = accept(fd, nil, nil)
            #expect(accepted >= 0, "no sidecar connection was pending: errno \(errno)")
            if accepted >= 0 { Darwin.close(accepted) }
        }

        /// Takes every connection waiting to be accepted, hangs each up, and
        /// says how many there were.
        func pendingConnections() -> Int {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
            var count = 0
            while true {
                let accepted = accept(fd, nil, nil)
                guard accepted >= 0 else { break }
                Darwin.close(accepted)
                count += 1
            }
            return count
        }

        func stop() {
            Darwin.close(fd)
            try? FileManager.default.removeItem(atPath: root)
        }
    }

    @Test("a sidecar found down is reconnected by the poll, and the next drop waits its turn")
    func aDownSidecarIsReconnected() async throws {
        let listener = try VendListener()
        defer { listener.stop() }
        let clock = EventDrivenTestClock()
        let client = DaemonClient(
            socketPath: "/nonexistent/tbd-test.sock", vendSocketPath: listener.path, clock: clock)
        let sidecar = await client.fdSidecar
        #expect(!sidecar.isConnected)

        #expect(await client.reconnectSidecarIfDown(.poll))
        #expect(sidecar.isConnected, "a sidecar that is down must be reconnected")

        listener.dropPendingConnection()
        _ = try await waitFor(
            "the dropped sidecar to be seen as down",
            observed: { "isConnected=\(sidecar.isConnected)" }
        ) { !sidecar.isConnected }

        await clock.advance(by: Backoff.initialDelay / 2)
        #expect(await client.reconnectSidecarIfDown(.poll) == false)
        #expect(!sidecar.isConnected, "a second drop inside the wait must not reconnect yet")

        await clock.advance(by: Backoff.initialDelay / 2)
        #expect(await client.reconnectSidecarIfDown(.poll))
        #expect(sidecar.isConnected, "once the wait is over the sidecar must be reconnected")
    }

    /// The daemon restarted and its vend socket is not back yet: a burst of
    /// panels tries to reconnect and fails, again and again. When the socket
    /// comes back, the very next poll tick must reconnect.
    @Test("a burst of attach-time reconnects against a missing socket leaves the poll free")
    func anAttachBurstLeavesThePollFree() async throws {
        let root = fencedScratchRoot(prefix: "vnd")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let clock = EventDrivenTestClock()
        let client = DaemonClient(
            socketPath: "/nonexistent/tbd-test.sock",
            vendSocketPath: VendListener.socketPath(in: root), clock: clock)
        let sidecar = await client.fdSidecar

        #expect(await client.reconnectSidecarIfDown(.attach) == false, "nothing is listening yet")
        #expect(await client.reconnectSidecarIfDown(.attach) == false)
        for _ in 0..<5 {
            await clock.advance(by: Backoff.attachInitialDelay)
            #expect(await client.reconnectSidecarIfDown(.attach) == false)
        }

        let listener = try VendListener(root: root)
        defer { listener.stop() }
        #expect(await client.reconnectSidecarIfDown(.poll), """
            the attach-time tries spent the poll's backoff, so the socket came back and no \
            reconnect was allowed
            """)
        #expect(sidecar.isConnected)
    }

    /// A second app instance takes the sidecar back every time this one
    /// reconnects it for an attach. Each takeover must push the next
    /// attach-time reconnect further out, until a delivered attach shows the
    /// fight is over.
    @Test("attach-time reconnects slow down under repeated takeover, and a delivered attach resets them")
    func repeatedTakeoverSlowsAttachReconnects() async throws {
        let listener = try VendListener()
        defer { listener.stop() }
        let clock = EventDrivenTestClock()
        let client = DaemonClient(
            socketPath: "/nonexistent/tbd-test.sock", vendSocketPath: listener.path, clock: clock)
        let sidecar = await client.fdSidecar
        func takeOver() async throws {
            listener.dropPendingConnection()
            _ = try await waitFor(
                "the sidecar to be taken over",
                observed: { "isConnected=\(sidecar.isConnected)" }
            ) { !sidecar.isConnected }
        }

        #expect(await client.reconnectSidecarIfDown(.attach), "the first reconnect is immediate")
        var wait = Backoff.attachInitialDelay
        for _ in 0..<3 {
            try await takeOver()
            await clock.advance(by: wait / 2)
            #expect(await client.reconnectSidecarIfDown(.attach) == false,
                    "a reconnect inside the wait of \(wait) went through")
            await clock.advance(by: wait / 2)
            #expect(await client.reconnectSidecarIfDown(.attach), "the wait of \(wait) is over")
            wait *= 2
        }

        await client.noteHolderAttachDelivered()
        try await takeOver()
        #expect(await client.reconnectSidecarIfDown(.attach),
                "after a delivered attach the next takeover is answered at once")
        #expect(sidecar.isConnected)
    }

    @Test("a connected sidecar is left as it is")
    func aConnectedSidecarIsLeftAlone() async throws {
        let listener = try VendListener()
        defer { listener.stop() }
        let clock = EventDrivenTestClock()
        let client = DaemonClient(
            socketPath: "/nonexistent/tbd-test.sock", vendSocketPath: listener.path, clock: clock)
        let sidecar = await client.fdSidecar
        #expect(await client.reconnectSidecarIfDown(.poll))
        #expect(sidecar.isConnected)

        await clock.advance(by: .seconds(60))
        #expect(await client.reconnectSidecarIfDown(.poll))
        #expect(await client.reconnectSidecarIfDown(.attach))
        #expect(sidecar.isConnected)
        #expect(listener.pendingConnections() == 1,
                "a sidecar that is up must not be replaced by a second connection")
    }

    @Test("a holder attach reconnects a sidecar that is down before it asks")
    func anAttachReconnectsTheSidecarFirst() async throws {
        let listener = try VendListener()
        defer { listener.stop() }
        // No RPC listener: the request itself fails, which is beside the point.
        let rpc = DaemonClient(
            socketPath: "/nonexistent/tbd-test.sock", vendSocketPath: listener.path)
        let holderClient = HolderAttachClient(daemonClient: rpc)
        let sidecar = await rpc.fdSidecar
        #expect(!sidecar.isConnected)

        _ = try? await holderClient.attach(worktreeID: UUID(), paneID: "", terminalID: UUID())

        #expect(sidecar.isConnected, """
            an attach sent with the sidecar down is refused, because the daemon has nowhere \
            to vend the descriptor — it must reconnect the sidecar before it asks
            """)
    }
}
