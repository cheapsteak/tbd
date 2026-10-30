import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// CLOCK: `EventDrivenTestClock` with its strict waits, because the recheck is
/// a re-arming loop: the re-arm after a tick is the proof that the tick's
/// refresh finished (`Tests/CLAUDE.md`, "The event-driven clock").
@Suite("Dev server running-file monitor", .clockDriven)
struct DevServerRunningFileMonitorTests {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [Int32: DevServerProcessInfo] = [:]
        private var deltas = 0
        func set(_ p: [Int32: DevServerProcessInfo]) { lock.lock(); processes = p; lock.unlock() }
        func info(_ pid: Int32) -> DevServerProcessInfo? { lock.lock(); defer { lock.unlock() }; return processes[pid] }
        func bump() { lock.lock(); deltas += 1; lock.unlock() }
        var deltaCount: Int { lock.lock(); defer { lock.unlock() }; return deltas }
    }

    private struct Fixture {
        let db: TBDDatabase
        let box: Box
        let inspector: FakeDevServerTabInspector
        let dir: URL
        let worktree: Worktree
        let worktreePath: String
        let clock: EventDrivenTestClock
        let monitor: DevServerRunningFileMonitor
        func tearDown() {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(atPath: worktreePath)
        }
    }

    private static let start = Date(timeIntervalSince1970: 1_760_190_000)

    private static func makeFixture() async throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-srvmon-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let worktree = try await db.worktrees.createScratch(
            name: "s", displayName: "s", path: path, tmuxServer: "tbd-srvmon")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-srvmon-files-\(UUID().uuidString)", isDirectory: true)
        let box = Box()
        let inspector = FakeDevServerTabInspector()
        let clock = EventDrivenTestClock()
        let monitor = DevServerRunningFileMonitor(
            db: db, runningFiles: DevServerRunningFileStore(directory: dir),
            probe: DevServerProcessProbe(info: { box.info($0) }), tabInspector: inspector,
            broadcast: { delta in if case .devServersChanged = delta { box.bump() } },
            recheckInterval: .seconds(10), clock: clock)
        return Fixture(db: db, box: box, inspector: inspector, dir: dir, worktree: worktree,
                       worktreePath: path, clock: clock, monitor: monitor)
    }

    private func writeFile(
        _ f: Fixture, pid: Int32,
        endpoints: [DevServerEndpoint] = [DevServerEndpoint(name: "app", url: "http://localhost:3000")]
    ) throws {
        try DevServerRunningFileStore(directory: f.dir).write(DevServerRunningFile(
            root: f.worktreePath, server: "web", endpoints: endpoints,
            pid: pid, startTime: Self.start.timeIntervalSince1970))
    }

    /// The running set does not move, but the server list's Open buttons do:
    /// a re-report that adds an endpoint must reach the app.
    @Test func newEndpointsForAnAlreadyRunningWorktreeBroadcast() async throws {
        let f = try await Self.makeFixture(); defer { f.tearDown() }
        f.box.set([500: .init(startTime: Self.start, isZombie: false)])
        try writeFile(f, pid: 500)
        await f.monitor.refresh()
        #expect(f.box.deltaCount == 1)
        try writeFile(f, pid: 500, endpoints: [
            DevServerEndpoint(name: "app", url: "http://localhost:3000"),
            DevServerEndpoint(name: "storybook", url: "http://localhost:6006"),
        ])
        await f.monitor.refresh()
        #expect(await f.monitor.runningWorktreeIDs() == [f.worktree.id])
        #expect(f.box.deltaCount == 2, "an endpoint change must broadcast")
        await f.monitor.refresh()
        #expect(f.box.deltaCount == 2, "an unchanged fingerprint must not broadcast")
    }

    /// A worktree a running file already marks keeps its dot when its server
    /// tab exits, but the tab's server now reads Exited.
    @Test func aServerTabExitingBesideALiveFileBroadcasts() async throws {
        let f = try await Self.makeFixture(); defer { f.tearDown() }
        f.box.set([500: .init(startTime: Self.start, isZombie: false)])
        try writeFile(f, pid: 500)
        let tab = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .shell, serverName: "api")
        f.inspector.set(.running(pid: 600, expectedStart: nil), for: tab.id)
        await f.monitor.refresh()
        #expect(f.box.deltaCount == 1)
        f.inspector.set(.exited(code: 1), for: tab.id)
        await f.monitor.refresh()
        #expect(await f.monitor.runningWorktreeIDs() == [f.worktree.id])
        #expect(f.box.deltaCount == 2)
    }

    @Test func aLiveFileMarksItsWorktreeAndBroadcastsOnce() async throws {
        let f = try await Self.makeFixture(); defer { f.tearDown() }
        f.box.set([500: .init(startTime: Self.start, isZombie: false)])
        try writeFile(f, pid: 500)
        await f.monitor.refresh()
        #expect(await f.monitor.runningWorktreeIDs() == [f.worktree.id])
        #expect(f.box.deltaCount == 1)
        await f.monitor.refresh()
        #expect(f.box.deltaCount == 1, "an unchanged summary must not broadcast")
    }

    @Test func aStaleFileDoesNotMarkItsWorktree() async throws {
        let f = try await Self.makeFixture(); defer { f.tearDown() }
        try writeFile(f, pid: 500)
        await f.monitor.refresh()
        #expect(await f.monitor.runningWorktreeIDs().isEmpty)
        #expect(f.box.deltaCount == 0)
    }

    /// A file whose root is no known worktree marks nothing, however live.
    @Test func aLiveFileForAnUnknownRootMarksNothing() async throws {
        let f = try await Self.makeFixture(); defer { f.tearDown() }
        f.box.set([500: .init(startTime: Self.start, isZombie: false)])
        try DevServerRunningFileStore(directory: f.dir).write(DevServerRunningFile(
            root: "/tmp/acme/not-a-worktree", server: "web", endpoints: [],
            pid: 500, startTime: Self.start.timeIntervalSince1970))
        await f.monitor.refresh()
        #expect(await f.monitor.runningWorktreeIDs().isEmpty)
        #expect(f.box.deltaCount == 0)
    }

    @Test func aRunningServerTabMarksItsWorktreeAndAnExitedOneDoesNot() async throws {
        let f = try await Self.makeFixture(); defer { f.tearDown() }
        let tab = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .shell, serverName: "web")
        f.inspector.set(.running(pid: 1, expectedStart: nil), for: tab.id)
        await f.monitor.refresh()
        #expect(await f.monitor.runningWorktreeIDs() == [f.worktree.id])
        f.inspector.set(.exited(code: 1), for: tab.id)
        await f.monitor.refresh()
        #expect(await f.monitor.runningWorktreeIDs().isEmpty)
        #expect(f.box.deltaCount == 2)
    }

    /// Only tabs carrying a server name count: an ordinary running shell does
    /// not light the dot.
    @Test func aRunningPlainTabDoesNotMarkItsWorktree() async throws {
        let f = try await Self.makeFixture(); defer { f.tearDown() }
        let tab = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .shell)
        f.inspector.set(.running(pid: 1, expectedStart: nil), for: tab.id)
        await f.monitor.refresh()
        #expect(await f.monitor.runningWorktreeIDs().isEmpty)
    }

    /// The spec's 10-second recheck, on the injected clock: a server that
    /// died without cleaning up drops out with no file event at all.
    @Test func aServerThatDiesDropsOutOnTheRecheck() async throws {
        let f = try await Self.makeFixture(); defer { f.tearDown() }
        f.box.set([500: .init(startTime: Self.start, isZombie: false)])
        try writeFile(f, pid: 500)
        await f.monitor.start()
        #expect(await f.monitor.runningWorktreeIDs() == [f.worktree.id])
        f.box.set([:])
        do {
            try await f.clock.requireAdvanceWhenArmed(by: .seconds(10))
            // The loop re-arms only after the tick's refresh has returned.
            try await f.clock.requireSleeperArmed()
        } catch {
            await f.monitor.stop()
            throw error
        }
        await f.monitor.stop()
        #expect(await f.monitor.runningWorktreeIDs().isEmpty)
        #expect(f.box.deltaCount == 2)
    }

    /// The watcher sees a new file without waiting for the recheck (the
    /// clock is never advanced here).
    @Test func aNewFileIsSeenWithoutTheRecheck() async throws {
        let f = try await Self.makeFixture(); defer { f.tearDown() }
        f.box.set([500: .init(startTime: Self.start, isZombie: false)])
        await f.monitor.start()
        #expect(await f.monitor.runningWorktreeIDs().isEmpty)
        try writeFile(f, pid: 500)
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await f.monitor.runningWorktreeIDs() == [f.worktree.id]
        }
        await f.monitor.stop()
        if outcome == .timedOut {
            Issue.record(BoundedWaitTimeout(
                what: "the directory watcher to report a new running file",
                observed: "\(await f.monitor.runningWorktreeIDs())",
                deadline: TestDeadlines.saturatedPass))
        }
    }
}
