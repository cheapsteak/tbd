import Clocks
import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Archive stops dev servers")
struct DevServerArchiveTests {
    private static let start = Date(timeIntervalSince1970: 1_760_190_000)

    private struct Fixture {
        let db: TBDDatabase
        var lifecycle: WorktreeLifecycle
        let signalling: FakeDevServerSignalling
        let inspector: FakeDevServerTabInspector
        let filesDir: URL
        let pathA: String
        let pathB: String
        let worktreeA: Worktree
        let worktreeB: Worktree
        func tearDown() {
            for p in [filesDir.path, pathA, pathB] { try? FileManager.default.removeItem(atPath: p) }
        }
    }

    private static func makeFixture() async throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        let tmux = TmuxManager(dryRun: true)
        var lifecycle = WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver())
        let tmp = FileManager.default.temporaryDirectory
        let pathA = tmp.appendingPathComponent("tbd-srvarc-a-\(UUID().uuidString)").path
        let pathB = tmp.appendingPathComponent("tbd-srvarc-b-\(UUID().uuidString)").path
        for p in [pathA, pathB] {
            try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
            try Data("[servers.web]\ncommand = \"pnpm dev\"\n".utf8).write(to: URL(fileURLWithPath: p + "/tbd.toml"))
        }
        let repo = try await db.repos.create(path: "/tmp/tbd-srvarc-repo-\(UUID().uuidString)",
                                             displayName: "acme", defaultBranch: "main")
        let a = try await db.worktrees.create(repoID: repo.id, name: "a", branch: "tbd/a", path: pathA, tmuxServer: "tbd-srvarc")
        let b = try await db.worktrees.create(repoID: repo.id, name: "b", branch: "tbd/b", path: pathB, tmuxServer: "tbd-srvarc")
        let filesDir = tmp.appendingPathComponent("tbd-srvarc-files-\(UUID().uuidString)", isDirectory: true)
        let signalling = FakeDevServerSignalling()
        signalling.add(pid: 500, pgid: 500, start: start)
        signalling.add(pid: 600, pgid: 600, start: start)
        signalling.add(pid: 700, pgid: 700, start: start)
        let processes: [Int32: DevServerProcessInfo] = [
            500: .init(startTime: start, isZombie: false), 600: .init(startTime: start, isZombie: false),
        ]
        let inspector = FakeDevServerTabInspector()
        let runner = FakeDevServerCommandRunner()
        lifecycle.devServerOperations = DevServerOperations(
            db: db, tabInspector: inspector, commandRunner: runner,
            stopper: DevServerStopper(
                killer: DevServerGroupKiller(signalling: signalling, grace: .seconds(5),
                                             pollInterval: .seconds(5), postKillWait: .zero, clock: TestClock()),
                commandRunner: runner),
            runningFiles: DevServerRunningFileStore(directory: filesDir),
            probe: DevServerProcessProbe(info: { processes[$0] }), environment: [:])
        return Fixture(db: db, lifecycle: lifecycle, signalling: signalling, inspector: inspector,
                       filesDir: filesDir, pathA: pathA, pathB: pathB, worktreeA: a, worktreeB: b)
    }

    private func report(_ f: Fixture, root: String, pid: Int32) throws -> String {
        try DevServerRunningFileStore(directory: f.filesDir).write(DevServerRunningFile(
            root: root, server: "web", endpoints: [DevServerEndpoint(name: "app", url: "http://localhost:3000")],
            pid: pid, startTime: Self.start.timeIntervalSince1970))
    }

    /// Review Focus 5.
    @Test func archiveLeavesOtherWorktreesServersAlone() async throws {
        let f = try await Self.makeFixture(); defer { f.tearDown() }
        let mine = try report(f, root: f.pathA, pid: 500)
        let theirs = try report(f, root: f.pathB, pid: 600)
        _ = try await f.lifecycle.beginArchiveWorktree(worktreeID: f.worktreeA.id)
        #expect(f.signalling.sentSignals == [.init(pgid: 500, signal: SIGTERM)])
        #expect(!FileManager.default.fileExists(atPath: mine))
        #expect(FileManager.default.fileExists(atPath: theirs))
    }

    @Test func archiveStopsAServerTBDStarted() async throws {
        let f = try await Self.makeFixture(); defer { f.tearDown() }
        let tab = try await f.db.terminals.create(
            worktreeID: f.worktreeA.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .shell, serverName: "web")
        f.inspector.set(.running(pid: 700, expectedStart: nil), for: tab.id)
        _ = try await f.lifecycle.beginArchiveWorktree(worktreeID: f.worktreeA.id)
        #expect(f.signalling.sentSignals == [.init(pgid: 700, signal: SIGTERM)])
        #expect(try await f.db.terminals.get(id: tab.id) == nil, "archive's teardown still removes the tab")
    }

    @Test func withoutOperationsWiredArchiveSignalsNothing() async throws {
        var f = try await Self.makeFixture(); defer { f.tearDown() }
        f.lifecycle.devServerOperations = nil
        _ = try report(f, root: f.pathA, pid: 500)
        _ = try await f.lifecycle.beginArchiveWorktree(worktreeID: f.worktreeA.id)
        #expect(f.signalling.sentSignals.isEmpty)
    }
}
