import Clocks
import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Dev server operations")
struct DevServerOperationsTests {
    @Test func stopAllForArchiveStopsRunningServersAndSkipsStoppedOnes() async throws {
        let db = try TBDDatabase(inMemory: true)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-srvops-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data("[servers.web]\ncommand = \"a\"\n[servers.api]\ncommand = \"b\"\n".utf8)
            .write(to: URL(fileURLWithPath: path + "/tbd.toml"))
        let worktree = try await db.worktrees.createScratch(name: "s", displayName: "s", path: path, tmuxServer: "tbd-srvops")
        let local = try #require(try await db.worktrees.getLocal(id: worktree.id))
        let webTab = try await db.terminals.create(worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
                                                   kind: .shell, serverName: "web")
        let inspector = FakeDevServerTabInspector()
        inspector.set(.running(pid: 500, expectedStart: nil), for: webTab.id)
        let signalling = FakeDevServerSignalling()
        signalling.add(pid: 500, pgid: 500, start: Date())
        let runner = FakeDevServerCommandRunner()
        let operations = DevServerOperations(
            db: db, tabInspector: inspector, commandRunner: runner,
            stopper: DevServerStopper(
                killer: DevServerGroupKiller(signalling: signalling, grace: .seconds(5),
                                             // swiftlint:disable:next no_polling_test_clock - legacy, #1171
                                             pollInterval: .seconds(5), postKillWait: .zero, clock: TestClock()),
                commandRunner: runner),
            runningFiles: DevServerRunningFileStore(directory: URL(fileURLWithPath: path + "/files")),
            probe: DevServerProcessProbe(info: { _ in nil }), environment: [:])
        let reports = await operations.stopAllForArchive(worktree: local)
        #expect(reports.map(\.name) == ["web"])
        #expect(reports.allSatisfy { $0.succeeded })
        #expect(signalling.sentSignals == [.init(pgid: 500, signal: SIGTERM)])
        // The tab is archive's to close.
        #expect(try await db.terminals.get(id: webTab.id) != nil)
    }

    /// A server TBD started whose declaration has since been removed still
    /// runs in its tab: archive stops it with a group kill like any other.
    @Test func stopAllForArchiveStopsAServerTabWhoseDeclarationIsGone() async throws {
        let db = try TBDDatabase(inMemory: true)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-srvops-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data("[servers.web]\ncommand = \"a\"\n".utf8).write(to: URL(fileURLWithPath: path + "/tbd.toml"))
        let worktree = try await db.worktrees.createScratch(name: "s", displayName: "s", path: path, tmuxServer: "tbd-srvops")
        let local = try #require(try await db.worktrees.getLocal(id: worktree.id))
        let oldTab = try await db.terminals.create(worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
                                                   kind: .shell, serverName: "old")
        let inspector = FakeDevServerTabInspector()
        inspector.set(.running(pid: 600, expectedStart: nil), for: oldTab.id)
        let signalling = FakeDevServerSignalling()
        signalling.add(pid: 600, pgid: 600, start: Date())
        let runner = FakeDevServerCommandRunner()
        let operations = DevServerOperations(
            db: db, tabInspector: inspector, commandRunner: runner,
            stopper: DevServerStopper(
                killer: DevServerGroupKiller(signalling: signalling, grace: .seconds(5),
                                             // swiftlint:disable:next no_polling_test_clock - legacy, #1171
                                             pollInterval: .seconds(5), postKillWait: .zero, clock: TestClock()),
                commandRunner: runner),
            runningFiles: DevServerRunningFileStore(directory: URL(fileURLWithPath: path + "/files")),
            probe: DevServerProcessProbe(info: { _ in nil }), environment: [:])
        let reports = await operations.stopAllForArchive(worktree: local)
        let names: [String] = reports.map { $0.name }
        #expect(names == ["old"])
        #expect(reports.first?.succeeded == true)
        #expect(signalling.sentSignals == [.init(pgid: 600, signal: SIGTERM)])
    }

    /// A gesture stop signals the pid a running file names; archive's
    /// request for the same server never does, and archive leaves the
    /// running-file-only server running without signalling anything.
    @Test func onlyAGestureStopSignalsARunningFilesPid() async throws {
        let db = try TBDDatabase(inMemory: true)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-srvops-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data("[servers.web]\ncommand = \"a\"\n".utf8).write(to: URL(fileURLWithPath: path + "/tbd.toml"))
        let worktree = try await db.worktrees.createScratch(name: "s", displayName: "s", path: path, tmuxServer: "tbd-srvops")
        let local = try #require(try await db.worktrees.getLocal(id: worktree.id))
        let start = Date(timeIntervalSince1970: 1_760_190_000)
        let filesDir = URL(fileURLWithPath: path + "/files")
        _ = try DevServerRunningFileStore(directory: filesDir).write(DevServerRunningFile(
            root: path, server: "web", endpoints: [DevServerEndpoint(name: "app", url: "http://localhost:3000")],
            pid: 500, startTime: start.timeIntervalSince1970))
        let signalling = FakeDevServerSignalling()
        signalling.add(pid: 500, pgid: 500, start: start)
        let runner = FakeDevServerCommandRunner()
        let operations = DevServerOperations(
            db: db, tabInspector: FakeDevServerTabInspector(), commandRunner: runner,
            stopper: DevServerStopper(
                killer: DevServerGroupKiller(signalling: signalling, grace: .seconds(5),
                                             // swiftlint:disable:next no_polling_test_clock - legacy, #1171
                                             pollInterval: .seconds(5), postKillWait: .zero, clock: TestClock()),
                commandRunner: runner),
            runningFiles: DevServerRunningFileStore(directory: filesDir),
            probe: DevServerProcessProbe(info: { $0 == 500 ? DevServerProcessInfo(startTime: start, isZombie: false) : nil }),
            environment: [:])
        let snapshot = await operations.snapshot(worktree: local, runStatusCommands: false)
        #expect(snapshot.info("web")?.state == .running)

        let gesture = await operations.stopRequest(for: "web", in: snapshot, repoPath: nil)
        #expect(gesture.killTargets.map(\.pid) == [500])
        let archive = await operations.stopRequest(for: "web", in: snapshot, repoPath: nil, signalRunningFiles: false)
        #expect(archive.killTargets.isEmpty)

        let reports = await operations.stopAllForArchive(worktree: local)
        #expect(reports.map(\.name) == ["web"])
        #expect(reports.first?.succeeded == false)
        #expect(signalling.sentSignals.isEmpty)
        #expect(runner.runs.isEmpty)

        let stopped = await operations.stopper.stop(gesture)
        #expect(stopped.succeeded)
        #expect(signalling.sentSignals == [.init(pgid: 500, signal: SIGTERM)])
    }
}
