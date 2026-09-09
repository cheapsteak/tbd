import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// The transport gate as `terminal.create` asks it — the branches that need
/// no `TBDHolder` binary. The branch that does, a real holder behind an extra
/// terminal, is `HolderSpawnGateTests` in the live target.
///
/// Three things are pinned here that the happy path cannot show:
///
///   - **A tmux extra terminal is never routed.** With the proxy on and the
///     holder flag off, the fake supervisor must be asked for nothing — a
///     route minted for a tmux spawn would be a stream file nothing writes.
///   - **A registry that cannot spawn falls back to tmux**, exactly as the
///     primary path does, rather than failing the request or routing a
///     session that then never starts.
///   - **A holder spawn that fails retires the route it minted**, from the
///     failing call itself and by the token it minted, so a refused extra
///     terminal leaves no route file for the sweep.
///
/// The failing spawner is a `HolderSpawner` whose executable does not exist:
/// `canSpawn` is decided from the spawner's presence alone, so the gate takes
/// the holder path, and `posix_spawn` then fails before any holder exists.
@Suite("terminal.create transport gate")
struct TerminalCreateTransportGateTests {

    // MARK: - Fixture

    private final class TmuxArgvRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var argvs: [[String]] = []
        func record(_ argv: [String]) {
            lock.lock(); defer { lock.unlock() }
            argvs.append(argv)
        }
        var newWindowCount: Int {
            lock.lock(); defer { lock.unlock() }
            return argvs.filter { $0.contains("new-window") }.count
        }
    }

    private struct Fixture {
        let db: TBDDatabase
        let router: RPCRouter
        let recorder: TmuxArgvRecorder
        let supervisor: FakeModelProxySupervisor
        let environment: [String: String]
        let worktree: Worktree
        let home: String
        let worktreePath: String

        func tearDown() {
            try? FileManager.default.removeItem(atPath: home)
            try? FileManager.default.removeItem(atPath: worktreePath)
        }

        func create(_ params: TerminalCreateParams) async throws -> RPCResponse {
            await router.handle(try RPCRequest(method: RPCMethod.terminalCreate, params: params))
        }
    }

    /// A spawner whose executable is not there. The registry built on it
    /// reports `canSpawn`, so the gate takes the holder path; the spawn then
    /// fails at `posix_spawn`, before any holder, socket or lock outlives it.
    private static func unspawnableSpawner() -> HolderSpawner {
        HolderSpawner(executableURL: URL(fileURLWithPath: "/nonexistent/TBDHolder"))
    }

    private static func makeFixture(
        holderFlag: Bool,
        proxyFlag: Bool,
        spawner: HolderSpawner?
    ) async throws -> Fixture {
        // Short and under the run's scratch root: the rendezvous socket the
        // failing spawn would bind lives under it, against `sun_path`'s cap.
        let home = fencedScratchRoot(prefix: "tbdtcg")
        let environment = [
            "TBD_HOME": home,
            "PATH": "/usr/bin:/bin",
            "SHELL": "/bin/sh",
        ]
        let recorder = TmuxArgvRecorder()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { recorder.record($0) })
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPtyHolderEnabled(holderFlag)
        // Streaming turns the proxy on in the same transaction; the routed
        // branch asserts the stream path, which is what streaming reads.
        try await db.config.setTranscriptStreamingEnabled(proxyFlag)

        let configDirManager = makeIsolatedConfigDirManager(tag: "terminal-create-gate")
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
            configDirManager: configDirManager)
        let router = RPCRouter(
            db: db, lifecycle: lifecycle, tmux: tmux, startTime: Date(),
            configDirManager: configDirManager,
            // The login-session case below arms the auto-`/login` pump against
            // the dry-run tmux; on the router's default delays it would poll
            // an empty pane for the rest of the run.
            loginSessions: LoginSessionCoordinator(delays: .init(
                pumpInitialDelay: .zero,
                pumpPollInterval: .milliseconds(5),
                pumpPostSendDelay: .milliseconds(5),
                pumpTimeout: .milliseconds(50),
                identityPollInterval: .milliseconds(5),
                identityPollTimeout: .milliseconds(50))),
            actuationLog: makeTestActuationLog())
        router.holderRegistry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: environment,
            listTerminals: { [] },
            spawner: spawner)
        let supervisor = FakeModelProxySupervisor()
        router.modelProxySupervisor = supervisor
        router.codexExecutableResolver = { "/opt/test/bin/codex" }
        router.codexHomeEnsurer = {
            URL(fileURLWithPath: home).appendingPathComponent("codex-home", isDirectory: true)
        }

        let repo = try await db.repos.create(
            path: "/tmp/tbd-tcg-repo-\(UUID().uuidString)",
            displayName: "acme", defaultBranch: "main")
        // `terminal.create` refuses to spawn into a missing directory.
        let worktreePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-tcg-wt-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(
            atPath: worktreePath, withIntermediateDirectories: true)
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "tbd/wt",
            path: worktreePath, tmuxServer: "tbd-tcg-test")
        return Fixture(
            db: db, router: router, recorder: recorder, supervisor: supervisor,
            environment: environment, worktree: worktree, home: home,
            worktreePath: worktreePath)
    }

    private func expectTmuxRow(_ terminal: Terminal, in fixture: Fixture) async throws {
        let row = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(row.transport == .tmux)
        #expect(!row.tmuxWindowID.isEmpty)
        #expect(row.holderPID == nil)
        #expect(row.childPID == nil)
        #expect(row.holderChildStartedAt == nil)
        #expect(row.transcriptStreamPath == nil)
        #expect(fixture.recorder.newWindowCount == 1)
        let socketPath = try HolderRendezvous.socketPath(
            sessionID: terminal.id, environment: fixture.environment)
        #expect(
            !FileManager.default.fileExists(atPath: socketPath),
            "a holder rendezvous was created for a tmux-transport extra terminal")
    }

    // MARK: - Flag off

    /// Today's behavior, exactly: a tmux window, a tmux row, and — with the
    /// proxy on — no route, because only a holder spawn is ever routed.
    @Test("flag off: an extra Claude terminal spawns onto tmux and is not routed")
    func flagOffSpawnsOntoTmux() async throws {
        let fixture = try await Self.makeFixture(
            holderFlag: false, proxyFlag: true, spawner: Self.unspawnableSpawner())
        defer { fixture.tearDown() }

        let response = try await fixture.create(
            TerminalCreateParams(worktreeID: fixture.worktree.id, type: .claude))
        #expect(response.success, "\(response.error ?? "")")
        let terminal = try response.decodeResult(Terminal.self)
        try await expectTmuxRow(terminal, in: fixture)
        #expect(fixture.supervisor.made.isEmpty, "a tmux spawn was routed")
        #expect(fixture.supervisor.retired.isEmpty)
    }

    // MARK: - Flag on, nothing to spawn with

    /// A registry with no spawner — a daemon whose `TBDHolder` binary an
    /// upgrade moved away. The flag is on and the answer is still tmux, the
    /// same fallback the primary path takes, and the proxy is asked nothing:
    /// the gate refused before the routing decision was reached.
    @Test("flag on with a registry that cannot spawn falls back to tmux")
    func flagOnWithoutASpawnerFallsBackToTmux() async throws {
        let fixture = try await Self.makeFixture(
            holderFlag: true, proxyFlag: true, spawner: nil)
        defer { fixture.tearDown() }

        let response = try await fixture.create(
            TerminalCreateParams(worktreeID: fixture.worktree.id, type: .claude))
        #expect(response.success, "\(response.error ?? "")")
        let terminal = try response.decodeResult(Terminal.self)
        try await expectTmuxRow(terminal, in: fixture)
        #expect(fixture.supervisor.made.isEmpty, "a tmux fallback was routed")
    }

    // MARK: - Flag on, the holder spawn fails

    /// The request fails the way a tmux spawn failure fails today — an error
    /// response, no row — and the route minted before the command was
    /// composed is retired by its own token.
    @Test("a holder spawn failure fails the request and retires the minted route")
    func holderSpawnFailureRetiresTheRoute() async throws {
        let fixture = try await Self.makeFixture(
            holderFlag: true, proxyFlag: true, spawner: Self.unspawnableSpawner())
        defer { fixture.tearDown() }

        let response = try await fixture.create(
            TerminalCreateParams(worktreeID: fixture.worktree.id, type: .claude))
        #expect(!response.success)
        #expect(
            response.error?.contains("/nonexistent/TBDHolder") == true,
            "the request failed before the holder spawn: \(response.error ?? "")")
        #expect(fixture.supervisor.made.count == 1, "the routing decision was not made before the spawn")
        #expect(fixture.supervisor.retired == [fixture.supervisor.token])
        #expect(try await fixture.db.terminals.list(worktreeID: fixture.worktree.id).isEmpty)
        #expect(fixture.recorder.newWindowCount == 0, "a failed holder spawn fell through to tmux")
    }

    /// A shell never asks the proxy: the holder path is taken (the spawn
    /// fails, which is the proof) and no route is minted or retired, because
    /// the shell branch has no attachment at all rather than an unproxied one.
    @Test("a shell extra terminal takes the holder path and is never routed")
    func shellTakesTheHolderPathUnrouted() async throws {
        let fixture = try await Self.makeFixture(
            holderFlag: true, proxyFlag: true, spawner: Self.unspawnableSpawner())
        defer { fixture.tearDown() }

        let response = try await fixture.create(
            TerminalCreateParams(worktreeID: fixture.worktree.id, cmd: "htop"))
        #expect(
            response.error?.contains("/nonexistent/TBDHolder") == true,
            "a shell extra terminal did not take the holder path: \(response.error ?? "success")")
        #expect(fixture.supervisor.made.isEmpty)
        #expect(fixture.supervisor.retired.isEmpty)
        #expect(fixture.recorder.newWindowCount == 0)
    }

    /// The holder runs any command, so a Codex extra terminal takes the
    /// transport the flag chose, exactly as the primary path's Codex branch
    /// does — and, like the shell, is never routed.
    @Test("a Codex extra terminal takes the holder path and is never routed")
    func codexTakesTheHolderPathUnrouted() async throws {
        let fixture = try await Self.makeFixture(
            holderFlag: true, proxyFlag: true, spawner: Self.unspawnableSpawner())
        defer { fixture.tearDown() }

        let response = try await fixture.create(
            TerminalCreateParams(worktreeID: fixture.worktree.id, type: .codex))
        #expect(
            response.error?.contains("/nonexistent/TBDHolder") == true,
            "a Codex extra terminal did not take the holder path: \(response.error ?? "success")")
        #expect(fixture.supervisor.made.isEmpty)
        #expect(fixture.recorder.newWindowCount == 0)
    }

    // MARK: - The login tab stays on tmux

    /// A profile login tab is the one extra terminal that stays on tmux with
    /// the flag on: its auto-`/login` pump reads and types through a tmux
    /// pane. With a spawner that would fail, success here is the proof that
    /// the holder path was not taken.
    @Test("a login session stays on tmux with the flag on")
    func loginSessionStaysOnTmux() async throws {
        let fixture = try await Self.makeFixture(
            holderFlag: true, proxyFlag: false, spawner: Self.unspawnableSpawner())
        defer { fixture.tearDown() }
        let profile = try await fixture.db.modelProfiles.create(name: "Login", kind: .oauth)

        let response = try await fixture.create(
            TerminalCreateParams(
                worktreeID: fixture.worktree.id, type: .claude,
                overrideProfileID: profile.id, loginSession: true))
        #expect(response.success, "\(response.error ?? "")")
        let terminal = try response.decodeResult(Terminal.self)
        #expect(terminal.label == TerminalLabel.login)
        try await expectTmuxRow(terminal, in: fixture)
    }
}
