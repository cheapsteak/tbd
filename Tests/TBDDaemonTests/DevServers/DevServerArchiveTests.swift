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
        let runner: FakeDevServerCommandRunner
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
                       runner: runner, filesDir: filesDir, pathA: pathA, pathB: pathB, worktreeA: a, worktreeB: b)
    }

    private func report(_ f: Fixture, root: String, pid: Int32) throws -> String {
        try DevServerRunningFileStore(directory: f.filesDir).write(DevServerRunningFile(
            root: root, server: "web", endpoints: [DevServerEndpoint(name: "app", url: "http://localhost:3000")],
            pid: pid, startTime: Self.start.timeIntervalSince1970))
    }

    /// Review Focus 5: archiving one worktree stops its own tab server and
    /// leaves the other worktree's server and running file alone.
    @Test func archiveLeavesOtherWorktreesServersAlone() async throws {
        let f = try await Self.makeFixture(); defer { f.tearDown() }
        let tab = try await f.db.terminals.create(
            worktreeID: f.worktreeA.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .shell, serverName: "web")
        f.inspector.set(.running(pid: 700, expectedStart: nil), for: tab.id)
        let theirs = try report(f, root: f.pathB, pid: 600)
        _ = try await f.lifecycle.beginArchiveWorktree(worktreeID: f.worktreeA.id)
        #expect(f.signalling.sentSignals == [.init(pgid: 700, signal: SIGTERM)])
        #expect(FileManager.default.fileExists(atPath: theirs))
    }

    /// Any same-user process can write a running file naming any pid, and
    /// archive can run unattended: a server known only through a running
    /// file is left running. Nothing is signalled, its declared `stop` does
    /// not run, and its file stays for OrphanGC once the process ends.
    @Test func archiveNeverSignalsARunningFileOnlyServer() async throws {
        let f = try await Self.makeFixture(); defer { f.tearDown() }
        try Data("""
            [servers.web]
            command = "pnpm dev"
            stop = "make stop-web"
            """.utf8).write(to: URL(fileURLWithPath: f.pathA + "/tbd.toml"))
        let file = try report(f, root: f.pathA, pid: 500)
        let local = try #require(try await f.db.worktrees.getLocal(id: f.worktreeA.id))
        let operations = try #require(f.lifecycle.devServerOperations)
        let reports = await operations.stopAllForArchive(worktree: local)
        #expect(reports.map(\.name) == ["web"])
        #expect(reports.first?.succeeded == false)
        #expect(reports.first?.message?.hasPrefix("left running:") == true)
        _ = try await f.lifecycle.beginArchiveWorktree(worktreeID: f.worktreeA.id)
        #expect(f.runner.runs.isEmpty)
        #expect(f.signalling.sentSignals.isEmpty)
        #expect(f.signalling.sentToProcesses.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    /// A server with both a TBD tab and a running file is stopped through
    /// the tab only: the pid the file names is never signalled, even when it
    /// is not the tab's job. The file is kept while that pid lives.
    @Test func archiveStopsATabServerThroughItsTabOnlyNotItsRunningFilesPid() async throws {
        let f = try await Self.makeFixture(); defer { f.tearDown() }
        let tab = try await f.db.terminals.create(
            worktreeID: f.worktreeA.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .shell, serverName: "web")
        f.inspector.set(.running(pid: 700, expectedStart: nil), for: tab.id)
        let file = try report(f, root: f.pathA, pid: 500)
        _ = try await f.lifecycle.beginArchiveWorktree(worktreeID: f.worktreeA.id)
        #expect(f.signalling.sentSignals == [.init(pgid: 700, signal: SIGTERM)])
        #expect(f.signalling.sentToProcesses.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    /// A holder tab whose job has no recorded start time cannot be told
    /// apart from a reused pid: archive does not signal it and leaves it to
    /// the tab teardown.
    @Test func archiveDoesNotSignalAHolderJobWithNoRecordedStartTime() async throws {
        let f = try await Self.makeFixture(); defer { f.tearDown() }
        let tab = try await f.db.terminals.create(
            worktreeID: f.worktreeA.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .shell, serverName: "web")
        f.inspector.set(.runningUnverifiable(pid: 700), for: tab.id)
        _ = try await f.lifecycle.beginArchiveWorktree(worktreeID: f.worktreeA.id)
        #expect(f.signalling.sentSignals.isEmpty)
        #expect(f.signalling.sentToProcesses.isEmpty)
        #expect(try await f.db.terminals.get(id: tab.id) == nil, "archive's teardown still removes the tab")
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

    /// A holder server's exit is stamped as its last output while its row
    /// exists — which includes the exit archive's own SIGTERM causes. After
    /// archive no server may read Exited from such an entry.
    @Test func archiveDetachesServerOutputsStampedDuringIt() async throws {
        let f = try await Self.makeFixture(); defer { f.tearDown() }
        let tab = try await f.db.terminals.create(
            worktreeID: f.worktreeA.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .shell, serverName: "web")
        f.inspector.set(.exited(code: 143), for: tab.id)
        await f.db.terminalHistory.recordServerExit(terminal: tab, serverName: "web", capture: nil, exitCode: 143)
        #expect(try await f.db.terminalHistory.latestServerOutputs(worktreeID: f.worktreeA.id)["web"] != nil)
        _ = try await f.lifecycle.beginArchiveWorktree(worktreeID: f.worktreeA.id)
        #expect(try await f.db.terminalHistory.latestServerOutputs(worktreeID: f.worktreeA.id).isEmpty)
        #expect(try await f.db.terminalHistory.list(worktreeID: f.worktreeA.id).map(\.id) == [tab.id],
                "the output stays in Closed Terminals")
    }

    /// Archive can fire with no user gesture (auto-archive on merge), so it
    /// never runs a repo's `status` command. A server that reads running
    /// only through one is left running: its `stop` does not run either.
    @Test func archiveNeverRunsStatusCommandsAndLeavesAStatusOnlyServerRunning() async throws {
        let f = try await Self.makeFixture(); defer { f.tearDown() }
        try Data("""
            [servers.db]
            command = "docker compose up -d db"
            status = "docker compose ps db"
            stop = "docker compose stop db"
            """.utf8).write(to: URL(fileURLWithPath: f.pathA + "/tbd.toml"))
        _ = try await f.lifecycle.beginArchiveWorktree(worktreeID: f.worktreeA.id)
        #expect(f.runner.runs.isEmpty)
        #expect(f.signalling.sentSignals.isEmpty)
    }

    /// Only the running TBD tab is stopped, through its process group. No
    /// `status` or `stop` command runs, the running-file server's pid is not
    /// signalled, and a status-only server is left alone.
    @Test func archiveStopsVisibleServersWithoutRunningRepoCommands() async throws {
        let f = try await Self.makeFixture(); defer { f.tearDown() }
        try Data("""
            [servers.web]
            command = "pnpm dev"
            status = "probe web"
            [servers.api]
            command = "pnpm api"
            status = "probe api"
            stop = "make stop-api"
            [servers.db]
            command = "docker compose up -d db"
            status = "probe db"
            stop = "make stop-db"
            """.utf8).write(to: URL(fileURLWithPath: f.pathA + "/tbd.toml"))
        let file = try report(f, root: f.pathA, pid: 500)
        let tab = try await f.db.terminals.create(
            worktreeID: f.worktreeA.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .shell, serverName: "api")
        f.inspector.set(.running(pid: 700, expectedStart: nil), for: tab.id)
        _ = try await f.lifecycle.beginArchiveWorktree(worktreeID: f.worktreeA.id)
        #expect(f.runner.runs.isEmpty)
        #expect(f.signalling.sentSignals == [.init(pgid: 700, signal: SIGTERM)])
        #expect(f.signalling.sentToProcesses.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    /// Repo code runs only on a user gesture, and archive can fire without
    /// one: a TBD tab server's process group is killed and its declared
    /// `stop` never runs.
    @Test func archiveKillsATabServersGroupInsteadOfRunningItsDeclaredStop() async throws {
        let f = try await Self.makeFixture(); defer { f.tearDown() }
        try Data("""
            [servers.web]
            command = "pnpm dev"
            stop = "make stop-web"
            """.utf8).write(to: URL(fileURLWithPath: f.pathA + "/tbd.toml"))
        let tab = try await f.db.terminals.create(
            worktreeID: f.worktreeA.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .shell, serverName: "web")
        f.inspector.set(.running(pid: 700, expectedStart: nil), for: tab.id)
        _ = try await f.lifecycle.beginArchiveWorktree(worktreeID: f.worktreeA.id)
        #expect(f.runner.runs.isEmpty)
        #expect(f.signalling.sentSignals == [.init(pgid: 700, signal: SIGTERM)])
        #expect(try await f.db.terminals.get(id: tab.id) == nil)
    }

    /// Reconcile archives a worktree whose checkout has vanished and runs
    /// archive's dev-server steps: a server running in a TBD tab has its
    /// group killed, a server known only through a running file (its `root`
    /// still names the vanished path; its own tab has exited) is left
    /// running with its file kept, no repo command runs, and the worktree's
    /// saved server output is detached.
    @Test func reconcileArchiveOfAVanishedWorktreeStopsTabServersAndDetachesOutputs() async throws {
        let f = try await Self.makeFixture(); defer { f.tearDown() }
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let repo = try await f.db.repos.create(path: repoDir.path, displayName: "acme", defaultBranch: "main")
        // Never created on disk: no tbd.toml, no directory, not a git worktree.
        let vanished = tempDir.appendingPathComponent("vanished").path
        let wt = try await f.db.worktrees.create(
            repoID: repo.id, name: "gone", branch: "tbd/gone", path: vanished, tmuxServer: "tbd-srvarc")
        let file = try report(f, root: vanished, pid: 500)
        let tab = try await f.db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .shell, serverName: "web")
        f.inspector.set(.exited(code: 143), for: tab.id)
        await f.db.terminalHistory.recordServerExit(terminal: tab, serverName: "web", capture: nil, exitCode: 143)
        #expect(try await f.db.terminalHistory.latestServerOutputs(worktreeID: wt.id)["web"] != nil)
        let apiTab = try await f.db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2", kind: .shell, serverName: "api")
        f.inspector.set(.running(pid: 700, expectedStart: nil), for: apiTab.id)

        try await f.lifecycle.reconcile(
            repoID: repo.id, actuationLog: makeTestActuationLog(), reapSharedScratchTmuxResources: true)

        #expect(try await f.db.worktrees.get(id: wt.id)?.status == .archived)
        #expect(f.runner.runs.isEmpty)
        #expect(f.signalling.sentSignals == [.init(pgid: 700, signal: SIGTERM)])
        #expect(f.signalling.sentToProcesses.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(try await f.db.terminalHistory.latestServerOutputs(worktreeID: wt.id).isEmpty)
    }

    @Test func withoutOperationsWiredArchiveSignalsNothing() async throws {
        var f = try await Self.makeFixture(); defer { f.tearDown() }
        f.lifecycle.devServerOperations = nil
        let tab = try await f.db.terminals.create(
            worktreeID: f.worktreeA.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .shell, serverName: "web")
        f.inspector.set(.running(pid: 700, expectedStart: nil), for: tab.id)
        _ = try await f.lifecycle.beginArchiveWorktree(worktreeID: f.worktreeA.id)
        #expect(f.signalling.sentSignals.isEmpty)
    }
}
