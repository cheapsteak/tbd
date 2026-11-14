import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TBDKernel
import DaemonTestSupport
import TestSupport

/// The transport gate as `terminalHistory.revive` asks it — the branches that
/// need no `TBDHolder` binary. The branch that does, a real holder behind a
/// revived tab, is `HolderSpawnGateTests` in the live target.
///
/// What is pinned here is that a revive asks the gate like every other spawn,
/// and that neither of its failures touches tmux: no `new-session` and no
/// `new-window` is issued, because a revive that started a server before
/// failing would leave the very resource the holder transport exists to
/// remove.
///
/// The failing spawner is a `HolderSpawner` whose executable does not exist:
/// `canSpawn` is decided from the spawner's presence alone, so the gate grants
/// the holder, and `posix_spawn` then fails before any holder exists.
@Suite("terminalHistory.revive transport gate")
struct TerminalReviveTransportGateTests {

    // MARK: - Fixture

    private final class TmuxArgvRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var argvs: [[String]] = []
        func record(_ argv: [String]) {
            lock.lock(); defer { lock.unlock() }
            argvs.append(argv)
        }
        var all: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return argvs
        }
        func count(_ subcommand: String) -> Int {
            all.filter { $0.contains(subcommand) }.count
        }
    }

    private struct Fixture {
        let db: TBDDatabase
        let router: RPCRouter
        let recorder: TmuxArgvRecorder
        let worktree: Worktree
        let closedTerminalID: UUID
        let home: String
        let worktreePath: String

        func tearDown() {
            try? FileManager.default.removeItem(atPath: home)
            try? FileManager.default.removeItem(atPath: worktreePath)
        }

        func revive() async throws -> RPCResponse {
            await router.handle(try RPCRequest(
                method: RPCMethod.terminalHistoryRevive,
                params: TerminalHistoryReviveParams(
                    worktreeID: worktree.id, id: closedTerminalID)))
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
        let home = fencedScratchRoot(prefix: "tbdtrg")
        let environment = [
            "TBD_HOME": home,
            "PATH": "/usr/bin:/bin",
            "SHELL": "/bin/sh",
        ]
        let recorder = TmuxArgvRecorder()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.record($0) },
            dryRunCapturePane: { _, _ in "" })
        let db = try TBDDatabase(
            inMemory: true,
            terminalHistoryDir: (home as NSString).appendingPathComponent("history"))

        let configDirManager = makeIsolatedConfigDirManager(tag: "terminal-revive-gate")
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
            configDirManager: configDirManager)
        let router = RPCRouter(
            db: db, lifecycle: lifecycle, tmux: tmux, startTime: Date(),
            configDirManager: configDirManager,
            actuationLog: makeTestActuationLog())
        router.holderRegistry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: environment,
            listTerminals: { [] },
            spawner: spawner)

        let repo = try await db.repos.create(
            path: "/tmp/tbd-trg-repo-\(UUID().uuidString)",
            displayName: "acme", defaultBranch: "main")
        // A revive refuses to spawn into a missing directory.
        let worktreePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-trg-wt-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(
            atPath: worktreePath, withIntermediateDirectories: true)
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "tbd/wt",
            path: worktreePath, tmuxServer: "tbd-trg-test")

        // A closed SHELL terminal with captured scrollback: the branch that
        // reopens a fresh shell, chosen because it resolves no profile and
        // reads no transcript — the transport decision is what is under test.
        let closed = Terminal(
            worktreeID: worktree.id, tmuxWindowID: "@9", tmuxPaneID: "%9",
            label: nil, kind: .shell)
        await db.terminalHistory.store(
            terminal: closed, text: "prior shell output\n", closedAt: Date())

        return Fixture(
            db: db, router: router, recorder: recorder,
            worktree: worktree, closedTerminalID: closed.id, home: home,
            worktreePath: worktreePath)
    }

    // MARK: - Nothing to spawn with

    /// A registry with no spawner — a daemon whose `TBDHolder` binary an
    /// upgrade moved away. The revive is refused with the gate's reason, and
    /// nothing is written or started.
    @Test("a registry that cannot spawn refuses the revive")
    func aRegistryThatCannotSpawnRefusesTheRevive() async throws {
        let fixture = try await Self.makeFixture(spawner: nil)
        defer { fixture.tearDown() }

        let response = try await fixture.revive()
        #expect(!response.success)
        #expect(response.error == TerminalSpawnRefusal.holderUnavailable.message)
        #expect(try await fixture.db.terminals.list(worktreeID: fixture.worktree.id).isEmpty)
        #expect(
            fixture.recorder.count("new-window") == 0 && fixture.recorder.count("new-session") == 0,
            "a refused revive reached tmux: \(fixture.recorder.all)")
    }

    // MARK: - The holder spawn fails

    /// The request fails with an error response and no row, and no tmux
    /// server was started on the way there.
    @Test("a holder revive spawn failure fails the request and starts no tmux server")
    func holderSpawnFailureFailsTheRevive() async throws {
        let fixture = try await Self.makeFixture(spawner: Self.unspawnableSpawner())
        defer { fixture.tearDown() }

        let response = try await fixture.revive()
        #expect(!response.success)
        #expect(
            response.error?.contains("/nonexistent/TBDHolder") == true,
            "the revive did not take the holder path: \(response.error ?? "success")")
        #expect(try await fixture.db.terminals.list(worktreeID: fixture.worktree.id).isEmpty)
        #expect(
            fixture.recorder.count("new-window") == 0,
            "a failed holder revive fell through to tmux: \(fixture.recorder.all)")
        #expect(
            fixture.recorder.count("new-session") == 0,
            "a holder revive started a tmux server: \(fixture.recorder.all)")
    }
}
