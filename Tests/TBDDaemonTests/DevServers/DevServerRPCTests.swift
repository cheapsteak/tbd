import Clocks
import Foundation
import GRDB
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("server.* RPC handlers")
struct DevServerRPCTests {
    private final class ArgvRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var argvs: [[String]] = []
        private var hook: (@Sendable ([String]) -> Void)?
        /// Runs synchronously inside the tmux call that records `argv`.
        func onRecord(_ body: @escaping @Sendable ([String]) -> Void) {
            lock.lock(); defer { lock.unlock() }; hook = body
        }
        func record(_ argv: [String]) {
            lock.lock()
            argvs.append(argv)
            let body = hook
            lock.unlock()
            body?(argv)
        }
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
        signalling: FakeDevServerSignalling = FakeDevServerSignalling(),
        paneSendTarget: (@Sendable (String, String) throws -> PaneSendTarget)? = nil
    ) async throws -> Fixture {
        let home = fencedScratchRoot(prefix: "tbdsrv")
        let recorder = ArgvRecorder()
        let tmux = TmuxManager(
            dryRun: true, dryRunRecorder: { recorder.record($0) }, dryRunPaneSendTarget: paneSendTarget)
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
                                         // swiftlint:disable:next no_polling_test_clock - legacy, #1171
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
        let terminalID = try #require(outcome.terminalID)
        let row = try #require(try await f.db.terminals.get(id: terminalID))
        #expect(row.serverName == "web")
        #expect(row.label == "Web app")
        #expect(row.kind == .shell)
        let newWindow = try #require(f.recorder.containing("new-window").first)
        let shellCommand = try #require(newWindow.first { $0.contains("exec /bin/sh") })
        #expect(shellCommand.contains("exec /bin/sh -c 'pnpm dev'"))
        #expect(shellCommand.contains("export DEV_SERVER_NAME='web'"))
        #expect(shellCommand.contains("export DEV_SERVERS_DIR='\(f.runningFilesDir.path)'"))
        #expect(shellCommand.contains("export TBD_WORKTREE_PATH='\(f.worktreePath)'"))
        #expect(newWindow.contains(f.worktreePath + "/apps/web"))
        #expect(f.changes.value == 1)
    }

    /// Review Focus 3: a server that dies at once keeps its screen. The
    /// option rides the `new-window` invocation itself, so a command that
    /// exits before a second tmux call could land still leaves its window.
    @Test func startCreatesTmuxTabsWithRemainOnExitInTheSameInvocation() async throws {
        let f = try await Self.makeFixture(toml: Self.webTOML)
        defer { f.tearDown() }
        let result = try await f.call(RPCMethod.serverStart,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: []))
            .decodeResult(DevServerActionResult.self)
        #expect(result.outcomes.first?.status == .started)
        let newWindow = try #require(f.recorder.containing("new-window").first)
        let chain: [String] = [";", "set-option", "-w", "remain-on-exit", "on"]
        #expect(Array(newWindow.suffix(chain.count)) == chain)
        let remainCalls = f.recorder.containing("remain-on-exit")
        #expect(remainCalls.count == 1, "no separate remain-on-exit call races the command")
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

    /// A tab whose state could not be read may still run the server: a
    /// start opens no second tab and says to retry.
    @Test func startRefusesWhenTheServersTabCannotBeRead() async throws {
        let f = try await Self.makeFixture(toml: Self.webTOML)
        defer { f.tearDown() }
        let existing = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@5", tmuxPaneID: "%5", label: "Web app",
            kind: .shell, serverName: "web")
        f.inspector.set(.unknown(reason: "tmux timed out"), for: existing.id)
        let result = try await f.call(RPCMethod.serverStart,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: ["web"]))
            .decodeResult(DevServerActionResult.self)
        #expect(result.outcomes.first?.status == .failed)
        #expect(result.outcomes.first?.message?.contains("try again") == true)
        #expect(f.recorder.containing("new-window").isEmpty)
        #expect(f.recorder.containing("respawn-window").isEmpty)
        #expect(try await f.db.terminals.list(worktreeID: f.worktree.id).count == 1)
    }

    /// A `status` command that timed out leaves the server Unknown: it may
    /// be running, so a start refuses rather than risk a duplicate.
    @Test func startRefusesWhenTheStatusCommandTimesOut() async throws {
        let runner = FakeDevServerCommandRunner(outcomes: ["probe": .timedOut])
        let f = try await Self.makeFixture(
            toml: "[servers.web]\ncommand = \"pnpm dev\"\nstatus = \"probe\"\n", runner: runner)
        defer { f.tearDown() }
        let result = try await f.call(RPCMethod.serverStart,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: ["web"]))
            .decodeResult(DevServerActionResult.self)
        #expect(result.outcomes == [.init(name: "web", status: .failed,
                                          message: RPCRouter.statusTimedOutMessage)])
        #expect(f.recorder.containing("new-window").isEmpty)
        #expect(try await f.db.terminals.list(worktreeID: f.worktree.id).isEmpty)
    }

    /// Start runs only the named servers' `status` commands.
    @Test func startRunsOnlyTheNamedServersStatusCommands() async throws {
        let runner = FakeDevServerCommandRunner(outcomes: ["probe-web": .exited(1), "probe-api": .exited(1)])
        let f = try await Self.makeFixture(toml: """
            [servers.web]
            command = "pnpm dev"
            status = "probe-web"
            [servers.api]
            command = "pnpm api"
            status = "probe-api"
            """, runner: runner)
        defer { f.tearDown() }
        _ = try await f.call(RPCMethod.serverStart,
                             DevServerActionParams(worktreeID: f.worktree.id, names: ["web"]))
        #expect(runner.runs.map(\.command) == ["probe-web"])
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

    /// The previous run's saved output is detached before the new run is
    /// spawned: an exit the new run records while it starts — a command that
    /// dies at once — is its own, and survives the start.
    @Test func anExitRecordedDuringTheSpawnSurvivesTheStart() async throws {
        let f = try await Self.makeFixture(toml: Self.webTOML)
        defer { f.tearDown() }
        let existing = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@5", tmuxPaneID: "%5", label: "Web app",
            kind: .shell, serverName: "web")
        f.inspector.set(.exited(code: 1), for: existing.id)
        // An entry for the tab, not yet attached to the server.
        await f.db.terminalHistory.recordOnClose(terminal: existing, capture: "BOOM\n")
        let writer = f.db.writerForTests
        let entryID = existing.id.uuidString
        f.recorder.onRecord { argv in
            guard argv.contains("respawn-window") else { return }
            // The new run's exit, stamped while the spawn is in flight.
            try? writer.write { conn in
                try conn.execute(
                    sql: "UPDATE terminal_history SET serverName = 'web', exitCode = 7 WHERE id = ?",
                    arguments: [entryID])
            }
        }
        let result = try await f.call(RPCMethod.serverStart,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: ["web"]))
            .decodeResult(DevServerActionResult.self)
        #expect(result.outcomes.first?.status == .started)
        let saved = try await f.db.terminalHistory.latestServerOutputs(worktreeID: f.worktree.id)
        #expect(saved["web"]?.id == existing.id)
        #expect(saved["web"]?.exitCode == 7)
        #expect(f.recorder.containing("remain-on-exit").isEmpty, "the respawned window keeps its option")
    }

    /// `respawn-window -k` kills whatever the pane runs, so a reused exited
    /// tab must prove its pane is still this terminal's first.
    @Test func anExitedTabWhosePaneBelongsToAnotherTerminalIsNotRespawned() async throws {
        let stranger = UUID().uuidString
        let f = try await Self.makeFixture(
            toml: Self.webTOML, paneSendTarget: { _, _ in .dead(terminalID: stranger) })
        defer { f.tearDown() }
        let existing = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@5", tmuxPaneID: "%5", label: "Web app",
            kind: .shell, serverName: "web")
        f.inspector.set(.exited(code: 1), for: existing.id)
        let result = try await f.call(RPCMethod.serverStart,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: ["web"]))
            .decodeResult(DevServerActionResult.self)
        #expect(result.outcomes.first?.status == .failed)
        #expect(f.recorder.containing("respawn-window").isEmpty)
        #expect(f.recorder.containing("new-window").isEmpty)
    }

    /// Answers from a script, one status per call, repeating the last.
    private final class ScriptedTabInspector: DevServerTabInspecting, @unchecked Sendable {
        private let lock = NSLock()
        private var script: [DevServerTabStatus]
        init(_ script: [DevServerTabStatus]) { self.script = script }
        func status(of terminal: Terminal, tmuxServer: String) async -> DevServerTabStatus { next() }
        private func next() -> DevServerTabStatus {
            lock.lock(); defer { lock.unlock() }
            return script.count > 1 ? script.removeFirst() : script[0]
        }
    }

    /// The snapshot that chose to reuse an exited tab can be a `status`
    /// timeout old. Under the lock the pane is read again; one that is no
    /// longer dead is not respawned over.
    @Test func anExitedTabThatCameBackIsNotRespawnedOver() async throws {
        let f = try await Self.makeFixture(toml: Self.webTOML)
        defer { f.tearDown() }
        _ = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@5", tmuxPaneID: "%5", label: "Web app",
            kind: .shell, serverName: "web")
        f.router.devServerTabInspector = ScriptedTabInspector([
            .exited(code: 1), .running(pid: 700, expectedStart: nil),
        ])
        let result = try await f.call(RPCMethod.serverStart,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: ["web"]))
            .decodeResult(DevServerActionResult.self)
        #expect(result.outcomes.first?.status == .failed)
        #expect(f.recorder.containing("respawn-window").isEmpty)
    }

    /// A second start for a server whose start is still in flight does not
    /// spawn a second tab, and fails: the first start may still fail, so
    /// the caller must not read success (the CLI exits non-zero).
    @Test func aStartWhileAnotherStartIsInFlightFailsAsAlreadyStarting() async throws {
        let f = try await Self.makeFixture(toml: Self.webTOML)
        defer { f.tearDown() }
        _ = await f.router.devServerClaims.claim(["web"], in: f.worktree.id, for: .start)
        let result = try await f.call(RPCMethod.serverStart,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: ["web"]))
            .decodeResult(DevServerActionResult.self)
        #expect(result.outcomes == [.init(name: "web", status: .failed, message: "already starting; try again")])
        #expect(!result.allSucceeded)
        #expect(f.recorder.containing("new-window").isEmpty)
        #expect(try await f.db.terminals.list(worktreeID: f.worktree.id).isEmpty)
    }

    @Test func aStopWhileAStartIsInFlightFailsAndSignalsNothing() async throws {
        let signalling = FakeDevServerSignalling()
        signalling.add(pid: 500, pgid: 500, start: Self.start)
        let f = try await Self.makeFixture(toml: Self.webTOML, signalling: signalling)
        defer { f.tearDown() }
        let existing = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@5", tmuxPaneID: "%5", kind: .shell, serverName: "web")
        f.inspector.set(.running(pid: 500, expectedStart: nil), for: existing.id)
        _ = await f.router.devServerClaims.claim(["web"], in: f.worktree.id, for: .start)
        let result = try await f.call(RPCMethod.serverStop,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: ["web"]))
            .decodeResult(DevServerActionResult.self)
        #expect(result.outcomes.first?.status == .failed)
        #expect(signalling.sentSignals.isEmpty)
        #expect(try await f.db.terminals.get(id: existing.id) != nil)
    }

    /// A request releases its claims: the next start acts.
    @Test func aFinishedStartReleasesItsClaim() async throws {
        let f = try await Self.makeFixture(toml: Self.webTOML)
        defer { f.tearDown() }
        _ = try await f.call(RPCMethod.serverStart, DevServerActionParams(worktreeID: f.worktree.id, names: ["web"]))
        let claim = await f.router.devServerClaims.claim(["web"], in: f.worktree.id, for: .start)
        #expect(claim.claimed == ["web"])
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

    /// `server.stop` is a user gesture, so a declared `stop` runs there —
    /// unlike archive, which only signals — and nothing is signalled.
    @Test func aGestureStopRunsTheDeclaredStopCommand() async throws {
        let signalling = FakeDevServerSignalling()
        signalling.add(pid: 500, pgid: 500, start: Self.start)
        let f = try await Self.makeFixture(
            toml: "[servers.web]\ncommand = \"pnpm dev\"\nstop = \"make stop\"\n", signalling: signalling)
        defer { f.tearDown() }
        let existing = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@5", tmuxPaneID: "%5", kind: .shell, serverName: "web")
        f.inspector.set(.running(pid: 500, expectedStart: nil), for: existing.id)
        let result = try await f.call(RPCMethod.serverStop,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: ["web"]))
            .decodeResult(DevServerActionResult.self)
        #expect(result.outcomes.first?.status == .stopped)
        #expect(f.runner.runs.map(\.command) == ["make stop"])
        #expect(signalling.sentSignals.isEmpty)
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

    /// Stop on an exited server closes its tab and clears its Exited state;
    /// its declared `stop` is not run, since nothing is running to stop.
    @Test func stoppingAnExitedServerClosesItsTabWithoutRunningItsStopCommand() async throws {
        let runner = FakeDevServerCommandRunner(outcomes: ["make stop": .exited(2)])
        let f = try await Self.makeFixture(
            toml: "[servers.web]\ncommand = \"pnpm dev\"\nstop = \"make stop\"\n", runner: runner)
        defer { f.tearDown() }
        let existing = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@5", tmuxPaneID: "%5", kind: .shell, serverName: "web")
        f.inspector.set(.exited(code: 1), for: existing.id)
        let result = try await f.call(RPCMethod.serverStop,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: ["web"]))
            .decodeResult(DevServerActionResult.self)
        #expect(result.outcomes.first?.status == .stopped)
        #expect(runner.runs.isEmpty)
        #expect(try await f.db.terminals.get(id: existing.id) == nil)
    }

    /// A tab whose state could not be read may still run the server: a stop
    /// neither runs anything nor reports success.
    @Test func stopRefusesWhenTheServersTabCannotBeRead() async throws {
        let runner = FakeDevServerCommandRunner()
        let signalling = FakeDevServerSignalling()
        signalling.add(pid: 500, pgid: 500, start: Self.start)
        let f = try await Self.makeFixture(
            toml: "[servers.web]\ncommand = \"pnpm dev\"\nstop = \"make stop\"\n",
            runner: runner, signalling: signalling)
        defer { f.tearDown() }
        let existing = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@5", tmuxPaneID: "%5", kind: .shell, serverName: "web")
        f.inspector.set(.unknown(reason: "tmux timed out"), for: existing.id)
        let result = try await f.call(RPCMethod.serverStop,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: ["web"]))
            .decodeResult(DevServerActionResult.self)
        #expect(result.outcomes.first?.status == .failed)
        #expect(runner.runs.isEmpty)
        #expect(signalling.sentSignals.isEmpty)
        #expect(try await f.db.terminals.get(id: existing.id) != nil)
    }

    /// A status-only server (`docker compose up -d`) with no `stop` has no
    /// process TBD may signal: the stop fails rather than claiming success.
    @Test func stoppingAStatusOnlyServerWithoutAStopCommandFails() async throws {
        let runner = FakeDevServerCommandRunner(outcomes: ["probe": .exited(0)])
        let f = try await Self.makeFixture(
            toml: "[servers.db]\ncommand = \"docker compose up -d\"\nstatus = \"probe\"\n", runner: runner)
        defer { f.tearDown() }
        let result = try await f.call(RPCMethod.serverStop,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: ["db"]))
            .decodeResult(DevServerActionResult.self)
        #expect(result.outcomes.first?.status == .failed)
        #expect(result.outcomes.first?.message?.contains("declare a `stop` command") == true)
    }

    /// The stop re-reads the tab rather than trusting the snapshot's pid.
    @Test func stopSignalsThePidTheTabHasAtStopTime() async throws {
        let signalling = FakeDevServerSignalling()
        signalling.add(pid: 500, pgid: 500, start: Self.start)
        let f = try await Self.makeFixture(toml: Self.webTOML, signalling: signalling)
        defer { f.tearDown() }
        let existing = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@5", tmuxPaneID: "%5", kind: .shell, serverName: "web")
        f.inspector.set(.running(pid: 500, expectedStart: nil), for: existing.id)
        let operations = f.router.devServerOperations()
        let local = try #require(try await f.db.worktrees.getLocal(id: f.worktree.id))
        let snapshot = await operations.snapshot(worktree: local, runStatusCommands: false)
        f.inspector.set(.running(pid: 501, expectedStart: nil), for: existing.id)
        let request = await operations.stopRequest(for: "web", in: snapshot, repoPath: nil)
        #expect(request.killTargets == [.firstHand(pid: 501)])
        f.inspector.set(.runningUnverifiable(pid: 502), for: existing.id)
        let unverifiable = await operations.stopRequest(for: "web", in: snapshot, repoPath: nil)
        #expect(unverifiable.killTargets.isEmpty)
        #expect(unverifiable.unverifiable.count == 1)
        #expect(!unverifiable.runningOnlyByStatus)
        f.inspector.set(.unknown(reason: "tmux timed out"), for: existing.id)
        let unreadable = await operations.stopRequest(for: "web", in: snapshot, repoPath: nil)
        #expect(unreadable.killTargets.isEmpty)
        #expect(unreadable.unverifiable.count == 1)
        #expect(!unreadable.runningOnlyByStatus)
    }

    /// TBD started `old`, then its declaration was removed. Its tab still
    /// runs the command: listed as undeclared, stoppable by name (a group
    /// kill of its tab — there is no declared `stop`), and part of Stop all.
    @Test func aServerTabWhoseDeclarationIsGoneIsListedAndStoppable() async throws {
        let signalling = FakeDevServerSignalling()
        signalling.add(pid: 500, pgid: 500, start: Self.start)
        let f = try await Self.makeFixture(toml: Self.webTOML, signalling: signalling)
        defer { f.tearDown() }
        let orphan = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@5", tmuxPaneID: "%5", label: "Old",
            kind: .shell, serverName: "old")
        f.inspector.set(.running(pid: 500, expectedStart: nil), for: orphan.id)

        let list = try await f.call(RPCMethod.serverList,
                                    DevServerListParams(worktreeID: f.worktree.id, runStatusCommands: false))
            .decodeResult(DevServerListResult.self)
        let names: [String] = list.servers.map { $0.name }
        #expect(names == ["web", "old"])
        let old = try #require(list.servers.last)
        #expect(old.source == nil)
        #expect(old.state == .running)
        #expect(old.terminalID == orphan.id)

        let result = try await f.call(RPCMethod.serverStop,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: []))
            .decodeResult(DevServerActionResult.self)
        let stoppedNames: [String] = result.outcomes.map { $0.name }
        #expect(stoppedNames == ["old"])
        #expect(result.outcomes.first?.status == .stopped)
        #expect(signalling.sentSignals == [.init(pgid: 500, signal: SIGTERM)])
        #expect(try await f.db.terminals.get(id: orphan.id) == nil)
    }

    @Test func aServerTabWhoseDeclarationIsGoneStopsByName() async throws {
        let signalling = FakeDevServerSignalling()
        signalling.add(pid: 500, pgid: 500, start: Self.start)
        let f = try await Self.makeFixture(toml: Self.webTOML, signalling: signalling)
        defer { f.tearDown() }
        let orphan = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@5", tmuxPaneID: "%5", kind: .shell, serverName: "old")
        f.inspector.set(.running(pid: 500, expectedStart: nil), for: orphan.id)
        let result = try await f.call(RPCMethod.serverStop,
                                      DevServerActionParams(worktreeID: f.worktree.id, names: ["old"]))
            .decodeResult(DevServerActionResult.self)
        #expect(result.outcomes.first?.status == .stopped)
        #expect(signalling.sentSignals == [.init(pgid: 500, signal: SIGTERM)])
        #expect(f.runner.runs.isEmpty)
        #expect(try await f.db.terminals.get(id: orphan.id) == nil)
    }

    /// Review Focus 5: two worktrees, same server name, separate files. Also
    /// pins that a gesture stop still signals the pid a running file names,
    /// which archive never does.
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
