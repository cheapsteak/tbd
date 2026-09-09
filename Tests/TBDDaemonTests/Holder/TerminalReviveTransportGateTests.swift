import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// The transport gate as `terminalHistory.revive` asks it — the branches that
/// need no `TBDHolder` binary. The branch that does, a real holder behind a
/// revived tab, is `HolderSpawnGateTests` in the live target.
///
/// A revive used to be pinned to tmux whatever the flag said. What is pinned
/// here instead is that it decides like every other spawn, and that the
/// decision reaches the *tmux* half of the spawn too: the flag-on failure case
/// asserts no `new-session` was issued, because `prepareTmuxServer` is a no-op
/// for a holder decision and a revive that started a server before failing
/// would leave the very resource the transport exists to remove.
///
/// The failing spawner is a `HolderSpawner` whose executable does not exist:
/// `canSpawn` is decided from the spawner's presence alone, so the gate takes
/// the holder path, and `posix_spawn` then fails before any holder exists.
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
        let environment: [String: String]
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
        holderFlag: Bool,
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
        try await db.config.setPtyHolderEnabled(holderFlag)

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
            db: db, router: router, recorder: recorder, environment: environment,
            worktree: worktree, closedTerminalID: closed.id, home: home,
            worktreePath: worktreePath)
    }

    private func expectTmuxRow(_ terminal: Terminal, in fixture: Fixture) async throws {
        let row = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(row.transport == .tmux)
        #expect(!row.tmuxWindowID.isEmpty)
        #expect(row.holderPID == nil)
        #expect(row.childPID == nil)
        #expect(fixture.recorder.count("new-window") == 1)
        let socketPath = try HolderRendezvous.socketPath(
            sessionID: terminal.id, environment: fixture.environment)
        #expect(
            !FileManager.default.fileExists(atPath: socketPath),
            "a holder rendezvous was created for a tmux-transport revive")
    }

    // MARK: - Flag off

    /// Today's behaviour, exactly: a tmux server, one tmux window, a tmux row.
    @Test("flag off: a revived terminal spawns onto tmux")
    func flagOffSpawnsOntoTmux() async throws {
        let fixture = try await Self.makeFixture(
            holderFlag: false, spawner: Self.unspawnableSpawner())
        defer { fixture.tearDown() }

        let response = try await fixture.revive()
        #expect(response.success, "\(response.error ?? "")")
        let terminal = try response.decodeResult(Terminal.self)
        try await expectTmuxRow(terminal, in: fixture)
        #expect(terminal.kind == .shell)
    }

    // MARK: - Flag on, nothing to spawn with

    /// A registry with no spawner — a daemon whose `TBDHolder` binary an
    /// upgrade moved away. The flag is on and the answer is still tmux, the
    /// same fallback every other spawn path takes.
    @Test("flag on with a registry that cannot spawn falls back to tmux")
    func flagOnWithoutASpawnerFallsBackToTmux() async throws {
        let fixture = try await Self.makeFixture(holderFlag: true, spawner: nil)
        defer { fixture.tearDown() }

        let response = try await fixture.revive()
        #expect(response.success, "\(response.error ?? "")")
        let terminal = try response.decodeResult(Terminal.self)
        try await expectTmuxRow(terminal, in: fixture)
    }

    // MARK: - Flag on, the holder spawn fails

    /// The request fails the way a tmux spawn failure fails today — an error
    /// response and no row — and, because the decision reached
    /// `prepareTmuxServer` too, no tmux server was started on the way there.
    @Test("a holder revive spawn failure fails the request and starts no tmux server")
    func holderSpawnFailureFailsTheRevive() async throws {
        let fixture = try await Self.makeFixture(
            holderFlag: true, spawner: Self.unspawnableSpawner())
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

    /// The history row survives a refused revive, so the tab can still be
    /// brought back once the flag is off or the binary is back.
    @Test("a failed holder revive keeps the history entry")
    func failedHolderReviveKeepsHistory() async throws {
        let fixture = try await Self.makeFixture(
            holderFlag: true, spawner: Self.unspawnableSpawner())
        defer { fixture.tearDown() }

        _ = try await fixture.revive()

        let entries = try await fixture.db.terminalHistory.list(
            worktreeID: fixture.worktree.id)
        #expect(entries.contains { $0.id == fixture.closedTerminalID })
    }
}
