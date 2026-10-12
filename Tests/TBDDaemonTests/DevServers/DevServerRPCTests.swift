import Clocks
import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("server.* RPC handlers")
struct DevServerRPCTests {
    private final class ArgvRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var argvs: [[String]] = []
        func record(_ argv: [String]) { lock.lock(); defer { lock.unlock() }; argvs.append(argv) }
        var all: [[String]] { lock.lock(); defer { lock.unlock() }; return argvs }
        func containing(_ word: String) -> [[String]] { all.filter { $0.contains(word) } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private struct Fixture {
        let db: TBDDatabase
        let router: RPCRouter
        let recorder: ArgvRecorder
        let inspector: FakeDevServerTabInspector
        let signalling: FakeDevServerSignalling
        let runner: FakeDevServerCommandRunner
        let processes: [Int32: DevServerProcessInfo]
        let worktree: Worktree
        let worktreePath: String
        let runningFilesDir: URL
        let home: String
        let changes: Counter

        func tearDown() {
            for path in [worktreePath, runningFilesDir.path, home] {
                try? FileManager.default.removeItem(atPath: path)
            }
        }

        func call<P: Encodable>(_ method: String, _ params: P) async throws -> RPCResponse {
            await router.handle(try RPCRequest(method: method, params: params))
        }
    }

    private static let start = Date(timeIntervalSince1970: 1_760_190_000)

    private static func makeFixture(
        toml: String,
        runner: FakeDevServerCommandRunner = FakeDevServerCommandRunner(),
        processes: [Int32: DevServerProcessInfo] = [:],
        signalling: FakeDevServerSignalling = FakeDevServerSignalling()
    ) async throws -> Fixture {
        let home = fencedScratchRoot(prefix: "tbdsrv")
        let recorder = ArgvRecorder()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { recorder.record($0) })
        // An explicit history dir: stop closes tabs, and a tab close writes
        // Closed Terminals history, which must never resolve to the real store.
        let db = try TBDDatabase(inMemory: true, terminalHistoryDir: home + "/terminal-history")
        let configDirManager = makeIsolatedConfigDirManager(tag: "dev-server-rpc")
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(), configDirManager: configDirManager)
        let router = RPCRouter(
            db: db, lifecycle: lifecycle, tmux: tmux, startTime: Date(),
            configDirManager: configDirManager, actuationLog: makeTestActuationLog())
        let worktreePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-srv-wt-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(
            atPath: worktreePath + "/apps/web", withIntermediateDirectories: true)
        try Data(toml.utf8).write(to: URL(fileURLWithPath: worktreePath + "/tbd.toml"))
        let repo = try await db.repos.create(
            path: "/tmp/tbd-srv-repo-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "fix-login", branch: "tbd/fix-login",
            path: worktreePath, tmuxServer: "tbd-srv-test")
        let runningFilesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-srv-files-\(UUID().uuidString)", isDirectory: true)
        let inspector = FakeDevServerTabInspector()
        let changes = Counter()
        router.devServerTabInspector = inspector
        router.devServerCommandRunner = runner
        router.devServerRunningFiles = DevServerRunningFileStore(directory: runningFilesDir)
        router.devServerProcessProbe = DevServerProcessProbe(info: { processes[$0] })
        router.devServerEnvironment = ["TBD_HOME": home]
        router.devServerStopper = DevServerStopper(
            killer: DevServerGroupKiller(signalling: signalling, grace: .seconds(5),
                                         pollInterval: .seconds(5), postKillWait: .zero, clock: TestClock()),
            commandRunner: runner)
        router.onDevServersChanged = { changes.bump() }
        return Fixture(db: db, router: router, recorder: recorder, inspector: inspector,
                       signalling: signalling, runner: runner, processes: processes,
                       worktree: worktree, worktreePath: worktreePath,
                       runningFilesDir: runningFilesDir, home: home, changes: changes)
    }

    private static let webTOML = """
        [servers.web]
        command = "pnpm dev"
        cwd = "apps/web"
        label = "Web app"
        """

    @Test func listReportsDeclaredServersAndParseErrors() async throws {
        let f = try await Self.makeFixture(toml: Self.webTOML)
        defer { f.tearDown() }
        try FileManager.default.createDirectory(atPath: f.worktreePath + "/.claude", withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: f.worktreePath + "/.claude/launch.json"))
        let response = try await f.call(RPCMethod.serverList,
                                        DevServerListParams(worktreeID: f.worktree.id, runStatusCommands: false))
        #expect(response.success, "\(response.error ?? "")")
        let list = try response.decodeResult(DevServerListResult.self)
        #expect(list.servers.map(\.name) == ["web"])
        #expect(list.servers.first?.state == .stopped)
        #expect(list.parseErrors.map { ($0.path as NSString).lastPathComponent } == ["launch.json"])
    }

    @Test func startSpawnsAServerTabWithItsNameLabelCwdAndEnvironment() async throws {
        let f = try await Self.makeFixture(toml: Self.webTOML)
        defer { f.tearDown() }
        let response = try await f.call(RPCMethod.serverStart,
                                        DevServerActionParams(worktreeID: f.worktree.id, names: ["web"]))
        let result = try response.decodeResult(DevServerActionResult.self)
        let outcome = try #require(result.outcomes.first)
        #expect(outcome.status == .started)
        let row = try #require(try await f.db.terminals.get(id: try #require(outcome.terminalID)))
        #expect(row.serverName == "web")
        #expect(row.label == "Web app")
        #expect(row.kind == .shell)
        let newWindow = try #require(f.recorder.containing("new-window").first)
        let shellCommand = try #require(newWindow.last)
        #expect(shellCommand.contains("exec /bin/sh -c 'pnpm dev'"))
        #expect(shellCommand.contains("export DEV_SERVER_NAME='web'"))
        #expect(shellCommand.contains("export DEV_SERVERS_DIR='\(f.runningFilesDir.path)'"))
        #expect(shellCommand.contains("export TBD_WORKTREE_PATH='\(f.worktreePath)'"))
        #expect(newWindow.contains(f.worktreePath + "/apps/web"))
        #expect(f.changes.value == 1)
    }

    /// Review Focus 3: a server that dies at once keeps its screen.
    @Test func startRequestsRemainOnExitForTmuxTabs() async throws {
        let f = try await Self.makeFixture(toml: Self.webTOML)
        defer { f.tearDown() }
        let result = try await f.call(RPCMethod.serverStart,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: []))
            .decodeResult(DevServerActionResult.self)
        let row = try #require(try await f.db.terminals.get(id: try #require(result.outcomes.first?.terminalID)))
        #expect(f.recorder.all.contains(
            ["-L", "tbd-srv-test", "set-option", "-wt", row.tmuxWindowID, "remain-on-exit", "on"]))
    }

    @Test func startingARunningServerDoesNothingAndSaysSo() async throws {
        let f = try await Self.makeFixture(toml: Self.webTOML)
        defer { f.tearDown() }
        let existing = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@5", tmuxPaneID: "%5", label: "Web app",
            kind: .shell, serverName: "web")
        f.inspector.set(.running(pid: 500, expectedStart: nil), for: existing.id)
        let result = try await f.call(RPCMethod.serverStart,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: ["web"]))
            .decodeResult(DevServerActionResult.self)
        #expect(result.outcomes == [.init(name: "web", status: .alreadyRunning,
                                          terminalID: existing.id, message: "already running")])
        #expect(f.recorder.containing("new-window").isEmpty)
    }

    @Test func anExitedTmuxTabIsRespawnedInPlace() async throws {
        let f = try await Self.makeFixture(toml: Self.webTOML)
        defer { f.tearDown() }
        let existing = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@5", tmuxPaneID: "%5", label: "Web app",
            kind: .shell, serverName: "web")
        f.inspector.set(.exited(code: 1), for: existing.id)
        let result = try await f.call(RPCMethod.serverStart,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: ["web"]))
            .decodeResult(DevServerActionResult.self)
        #expect(result.outcomes.first?.status == .started)
        #expect(result.outcomes.first?.terminalID == existing.id)
        #expect(f.recorder.containing("new-window").isEmpty)
        let respawn = try #require(f.recorder.containing("respawn-window").first)
        #expect(respawn.contains("@5"))
        #expect(try await f.db.terminals.list(worktreeID: f.worktree.id).count == 1)
    }

    @Test func startingAnUndeclaredNameFails() async throws {
        let f = try await Self.makeFixture(toml: Self.webTOML)
        defer { f.tearDown() }
        let result = try await f.call(RPCMethod.serverStart,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: ["api"]))
            .decodeResult(DevServerActionResult.self)
        #expect(result.outcomes.first?.status == .failed)
        #expect(try await f.db.terminals.list(worktreeID: f.worktree.id).isEmpty)
    }

    @Test func aStartWhoseCwdIsMissingFailsAndRecordsNothing() async throws {
        let f = try await Self.makeFixture(toml: "[servers.web]\ncommand = \"x\"\ncwd = \"apps/missing\"\n")
        defer { f.tearDown() }
        let result = try await f.call(RPCMethod.serverStart,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: ["web"]))
            .decodeResult(DevServerActionResult.self)
        #expect(result.outcomes.first?.status == .failed)
        #expect(result.outcomes.first?.message?.contains("apps/missing") == true)
        #expect(try await f.db.terminals.list(worktreeID: f.worktree.id).isEmpty)
        #expect(f.recorder.containing("new-window").isEmpty)
    }

    @Test func stopKillsTheTabsGroupAndClosesTheTab() async throws {
        let signalling = FakeDevServerSignalling()
        signalling.add(pid: 500, pgid: 500, start: Self.start)
        let f = try await Self.makeFixture(toml: Self.webTOML, signalling: signalling)
        defer { f.tearDown() }
        let existing = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@5", tmuxPaneID: "%5", label: "Web app",
            kind: .shell, serverName: "web")
        f.inspector.set(.running(pid: 500, expectedStart: nil), for: existing.id)
        let result = try await f.call(RPCMethod.serverStop,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: ["web"]))
            .decodeResult(DevServerActionResult.self)
        #expect(result.outcomes.first?.status == .stopped)
        #expect(signalling.sentSignals == [.init(pgid: 500, signal: SIGTERM)])
        #expect(try await f.db.terminals.get(id: existing.id) == nil)
    }

    @Test func aFailingDeclaredStopIsReportedAndTheTabStays() async throws {
        let runner = FakeDevServerCommandRunner(outcomes: ["make stop": .exited(2)])
        let f = try await Self.makeFixture(
            toml: "[servers.web]\ncommand = \"pnpm dev\"\nstop = \"make stop\"\n", runner: runner)
        defer { f.tearDown() }
        let existing = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@5", tmuxPaneID: "%5", kind: .shell, serverName: "web")
        f.inspector.set(.running(pid: 500, expectedStart: nil), for: existing.id)
        let result = try await f.call(RPCMethod.serverStop,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: ["web"]))
            .decodeResult(DevServerActionResult.self)
        #expect(result.outcomes.first?.status == .failed)
        #expect(f.signalling.sentSignals.isEmpty)
        #expect(try await f.db.terminals.get(id: existing.id) != nil)
    }

    /// Review Focus 5: two worktrees, same server name, separate files.
    @Test func stoppingOneWorktreeLeavesTheOtherWorktreesFile() async throws {
        let signalling = FakeDevServerSignalling()
        signalling.add(pid: 500, pgid: 500, start: Self.start)
        signalling.add(pid: 600, pgid: 600, start: Self.start)
        let processes: [Int32: DevServerProcessInfo] = [
            500: .init(startTime: Self.start, isZombie: false),
            600: .init(startTime: Self.start, isZombie: false),
        ]
        let f = try await Self.makeFixture(toml: Self.webTOML, processes: processes, signalling: signalling)
        defer { f.tearDown() }
        let otherRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-srv-other-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: otherRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: otherRoot) }
        let store = DevServerRunningFileStore(directory: f.runningFilesDir)
        let endpoints = [DevServerEndpoint(name: "app", url: "http://localhost:3000")]
        let mine = try store.write(DevServerRunningFile(root: f.worktreePath, server: "web",
            endpoints: endpoints, pid: 500, startTime: Self.start.timeIntervalSince1970))
        let theirs = try store.write(DevServerRunningFile(root: otherRoot, server: "web",
            endpoints: endpoints, pid: 600, startTime: Self.start.timeIntervalSince1970))

        let result = try await f.call(RPCMethod.serverStop,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: ["web"]))
            .decodeResult(DevServerActionResult.self)

        #expect(result.outcomes.first?.status == .stopped)
        #expect(signalling.sentSignals == [.init(pgid: 500, signal: SIGTERM)])
        #expect(!FileManager.default.fileExists(atPath: mine))
        #expect(FileManager.default.fileExists(atPath: theirs))
    }

    /// D2: an ended holder server's tab is gone (reconcile), and its saved
    /// last output still makes it read *Exited* with its code.
    private func savedExit(_ f: Fixture, code: Int32) async throws -> Terminal {
        let tab = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "", tmuxPaneID: "", label: "Web app",
            kind: .shell, transport: .holder, serverName: "web")
        await f.db.terminalHistory.recordServerExit(
            terminal: tab, serverName: "web", capture: "BOOM\n", exitCode: code)
        try await f.db.terminals.delete(id: tab.id)
        return tab
    }

    @Test func aSavedLastOutputReadsExitedAfterItsTabIsGone() async throws {
        let f = try await Self.makeFixture(toml: Self.webTOML)
        defer { f.tearDown() }
        let tab = try await savedExit(f, code: 3)
        let server = try #require(try await f.call(RPCMethod.serverList,
                                                   DevServerListParams(worktreeID: f.worktree.id, runStatusCommands: false))
            .decodeResult(DevServerListResult.self).servers.first)
        #expect(server.state == .exited)
        #expect(server.exitCode == 3)
        #expect(server.lastOutputID == tab.id)
        #expect(server.terminalID == nil)
    }

    /// Review Focus 6.
    @Test func stopDetachesTheSavedLastOutput() async throws {
        let f = try await Self.makeFixture(toml: Self.webTOML)
        defer { f.tearDown() }
        let tab = try await savedExit(f, code: 3)
        let result = try await f.call(RPCMethod.serverStop,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: ["web"]))
            .decodeResult(DevServerActionResult.self)
        #expect(result.outcomes.first?.status == .stopped)
        let server = try #require(try await f.call(RPCMethod.serverList,
                                                   DevServerListParams(worktreeID: f.worktree.id, runStatusCommands: false))
            .decodeResult(DevServerListResult.self).servers.first)
        #expect(server.state == .stopped)
        #expect(server.lastOutputID == nil)
        let kept = try await f.db.terminalHistory.list(worktreeID: f.worktree.id)
        #expect(kept.map(\.id) == [tab.id], "the output stays in Closed Terminals")
        #expect(kept.first?.serverName == nil)
        #expect(f.signalling.sentSignals.isEmpty)
    }

    @Test func startDetachesTheSavedLastOutput() async throws {
        let f = try await Self.makeFixture(toml: Self.webTOML)
        defer { f.tearDown() }
        _ = try await savedExit(f, code: 3)
        let result = try await f.call(RPCMethod.serverStart,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: ["web"]))
            .decodeResult(DevServerActionResult.self)
        #expect(result.outcomes.first?.status == .started)
        #expect(try await f.db.terminalHistory.latestServerOutputs(worktreeID: f.worktree.id).isEmpty)
    }

    @Test func summaryReturnsTheProvidersIDs() async throws {
        let f = try await Self.makeFixture(toml: Self.webTOML)
        defer { f.tearDown() }
        let id = UUID()
        f.router.devServerSummaryProvider = { [id] }
        let result = try await f.router.handle(RPCRequest(method: RPCMethod.serverSummary))
            .decodeResult(DevServerSummaryResult.self)
        #expect(result.runningWorktreeIDs == [id])
    }

    @Test func statusCommandsRunOnlyWhenAsked() async throws {
        let runner = FakeDevServerCommandRunner(outcomes: ["probe": .exited(0)])
        let f = try await Self.makeFixture(
            toml: "[servers.db]\ncommand = \"x\"\nstatus = \"probe\"\n", runner: runner)
        defer { f.tearDown() }
        let quiet = try await f.call(RPCMethod.serverList,
                                     DevServerListParams(worktreeID: f.worktree.id, runStatusCommands: false))
            .decodeResult(DevServerListResult.self)
        #expect(runner.runs.isEmpty)
        #expect(quiet.servers.first?.state == .stopped)
        let probed = try await f.call(RPCMethod.serverList,
                                      DevServerListParams(worktreeID: f.worktree.id, runStatusCommands: true))
            .decodeResult(DevServerListResult.self)
        #expect(runner.runs.map(\.timeout) == [.seconds(5)])
        #expect(probed.servers.first?.state == .running)
    }
}
