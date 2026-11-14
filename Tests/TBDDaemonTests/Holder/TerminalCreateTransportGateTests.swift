import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TBDKernel
import DaemonTestSupport
import TestSupport

/// The transport gate as `terminal.create` asks it — the branches that need
/// no `TBDHolder` binary. The branch that does, a real holder behind an extra
/// terminal, is `HolderSpawnGateTests` in the live target.
///
/// Two things are pinned here that the happy path cannot show:
///
///   - **A registry that cannot spawn refuses the request** with the gate's
///     reason, and leaves no row and no tmux behind.
///   - **A holder spawn that fails fails the request** and leaves no row.
///
/// The failing spawner is a `HolderSpawner` whose executable does not exist:
/// `canSpawn` is decided from the spawner's presence alone, so the gate grants
/// the holder, and `posix_spawn` then fails before any holder exists.
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
        /// Whether a tmux *server* was started. A spawn must not start one at
        /// all, and a window count alone cannot say so: a server is ensured
        /// before its first window.
        var newSessionCount: Int {
            lock.lock(); defer { lock.unlock() }
            return argvs.filter { $0.contains("new-session") }.count
        }
    }

    private struct Fixture {
        let db: TBDDatabase
        let router: RPCRouter
        let recorder: TmuxArgvRecorder
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

        let configDirManager = makeIsolatedConfigDirManager(tag: "terminal-create-gate")
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
            configDirManager: configDirManager)
        let router = RPCRouter(
            db: db, lifecycle: lifecycle, tmux: tmux, startTime: Date(),
            configDirManager: configDirManager,
            // The login-session case below arms the identity watcher; on the
            // router's default delays it would poll for half an hour.
            loginSessions: LoginSessionCoordinator(delays: .init(
                identityPollInterval: .milliseconds(5),
                identityPollTimeout: .milliseconds(50))),
            actuationLog: makeTestActuationLog())
        router.holderRegistry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: environment,
            listTerminals: { [] },
            spawner: spawner)
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
            db: db, router: router, recorder: recorder,
            environment: environment, worktree: worktree, home: home,
            worktreePath: worktreePath)
    }

    // MARK: - Nothing to spawn with

    /// A registry with no spawner — a daemon whose `TBDHolder` binary an
    /// upgrade moved away. The request is refused with the gate's reason,
    /// before any row or tmux server exists.
    @Test("a registry that cannot spawn refuses the request")
    func aRegistryThatCannotSpawnRefuses() async throws {
        let fixture = try await Self.makeFixture(spawner: nil)
        defer { fixture.tearDown() }

        let response = try await fixture.create(
            TerminalCreateParams(worktreeID: fixture.worktree.id, type: .claude))
        #expect(!response.success)
        #expect(response.error == TerminalSpawnRefusal.holderUnavailable.message)
        #expect(try await fixture.db.terminals.list(worktreeID: fixture.worktree.id).isEmpty)
        #expect(fixture.recorder.newWindowCount == 0)
        #expect(fixture.recorder.newSessionCount == 0)
    }

    // MARK: - The holder spawn fails

    /// The request fails the way a tmux spawn failure fails today — an error
    /// response, no row.
    @Test("a holder spawn failure fails the request")
    func holderSpawnFailureFailsTheRequest() async throws {
        let fixture = try await Self.makeFixture(
            spawner: Self.unspawnableSpawner())
        defer { fixture.tearDown() }

        let response = try await fixture.create(
            TerminalCreateParams(worktreeID: fixture.worktree.id, type: .claude))
        #expect(!response.success)
        #expect(
            response.error?.contains("/nonexistent/TBDHolder") == true,
            "the request failed before the holder spawn: \(response.error ?? "")")
        #expect(try await fixture.db.terminals.list(worktreeID: fixture.worktree.id).isEmpty)
        #expect(fixture.recorder.newWindowCount == 0, "a failed holder spawn fell through to tmux")
    }

    /// A shell takes the holder path too (the spawn fails, which is the
    /// proof).
    @Test("a shell extra terminal takes the holder path")
    func shellTakesTheHolderPath() async throws {
        let fixture = try await Self.makeFixture(
            spawner: Self.unspawnableSpawner())
        defer { fixture.tearDown() }

        let response = try await fixture.create(
            TerminalCreateParams(worktreeID: fixture.worktree.id, cmd: "htop"))
        #expect(
            response.error?.contains("/nonexistent/TBDHolder") == true,
            "a shell extra terminal did not take the holder path: \(response.error ?? "success")")
        #expect(fixture.recorder.newWindowCount == 0)
    }

    /// The holder runs any command, so a Codex extra terminal takes it too,
    /// exactly as the primary path's Codex branch does.
    @Test("a Codex extra terminal takes the holder path")
    func codexTakesTheHolderPath() async throws {
        let fixture = try await Self.makeFixture(
            spawner: Self.unspawnableSpawner())
        defer { fixture.tearDown() }

        let response = try await fixture.create(
            TerminalCreateParams(worktreeID: fixture.worktree.id, type: .codex))
        #expect(
            response.error?.contains("/nonexistent/TBDHolder") == true,
            "a Codex extra terminal did not take the holder path: \(response.error ?? "success")")
        #expect(fixture.recorder.newWindowCount == 0)
    }

    // MARK: - The login tab takes the decided transport

    /// The profile login tab is not pinned: it takes the holder path like
    /// every other spawn.
    ///
    /// With a spawner that cannot start anything, the failure IS the proof:
    /// a login tab that had stayed on tmux would have succeeded here.
    @Test("a login session takes the holder path")
    func loginSessionTakesTheHolderPath() async throws {
        let fixture = try await Self.makeFixture(
            spawner: Self.unspawnableSpawner())
        defer { fixture.tearDown() }
        let profile = try await fixture.db.modelProfiles.create(name: "Login", kind: .oauth)

        let response = try await fixture.create(
            TerminalCreateParams(
                worktreeID: fixture.worktree.id, type: .claude,
                overrideProfileID: profile.id, loginSession: true))
        #expect(!response.success)
        #expect(
            response.error?.contains("/nonexistent/TBDHolder") == true,
            "a login session did not take the holder path: \(response.error ?? "success")")
        #expect(fixture.recorder.newWindowCount == 0, "a failed holder login tab fell through to tmux")
        #expect(
            fixture.recorder.newSessionCount == 0,
            "a tmux server was started for a holder-transport login tab")
        #expect(try await fixture.db.terminals.list(worktreeID: fixture.worktree.id).isEmpty)
    }
}
