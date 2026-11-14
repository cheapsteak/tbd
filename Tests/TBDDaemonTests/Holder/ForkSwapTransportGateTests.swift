import Clocks
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TBDKernel
import DaemonTestSupport
import TestSupport

/// The transport gate as a `.fork` profile swap asks it, and the recapture
/// target that follows from it — the branches that need no `TBDHolder` binary.
/// A fork that lands is driven through the holder spawn double
/// (`FakeHolderLaunch`); a fork landing on a real holder is
/// `HolderSpawnGateTests` in the live target.
///
/// The recapture half is the reason this suite exists rather than a row
/// assertion alone. A real scheduler's only trace is a database write five wall
/// seconds later, made only if a live Claude process answers, so which process
/// a recapture was scheduled against is invisible in the row. `router.sessionRecaptureFactory` makes the
/// decision itself the observable, on virtual time.
@Suite("terminal.swapProfile fork transport gate")
struct ForkSwapTransportGateTests {

    // MARK: - Probe

    /// The scheduler the swap path is given in place of the real one, and the
    /// record of every target it was asked about. `ImmediateClock` so the
    /// branch is asserted without waiting out the production five seconds; it
    /// never reaches `ClaudeStateDetector`, which would read a session file at
    /// a process-wide path.
    private final class RecaptureProbe: @unchecked Sendable {
        static let detectedSessionID = "FORK-RECAPTURED-BY-THE-PROBE"

        private let lock = NSLock()
        private var recorded: [SessionRecaptureTarget] = []

        var targets: [SessionRecaptureTarget] {
            lock.withLock { recorded }
        }

        func scheduler(db: TBDDatabase, tmux: TmuxManager) -> SessionRecaptureScheduler {
            SessionRecaptureScheduler(
                db: db,
                tmux: tmux,
                // `withLock` rather than `lock()`/`unlock()`: this closure is
                // `async`, where the unscoped pair is unavailable.
                captureSessionID: { [self] target in
                    lock.withLock { recorded.append(target) }
                    return Self.detectedSessionID
                },
                clock: ImmediateClock())
        }
    }

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
        let launch: FakeHolderLaunch
        let probe: RecaptureProbe
        let environment: [String: String]
        let worktree: Worktree
        let source: Terminal
        let home: String
        let worktreePath: String

        func tearDown() {
            try? FileManager.default.removeItem(atPath: home)
            try? FileManager.default.removeItem(atPath: worktreePath)
        }

        func fork() async throws -> RPCResponse {
            await router.handle(try RPCRequest(
                method: RPCMethod.terminalSwapProfile,
                params: TerminalSwapProfileParams(
                    terminalID: source.id, newProfileID: nil, mode: .fork)))
        }
    }

    /// The registry a fixture's router and coordinator share.
    private enum Registry {
        /// Spawns through the holder spawn double, so a fork lands.
        case spawnDouble
        /// Has no spawner: a daemon whose `TBDHolder` binary has gone.
        case cannotSpawn
        /// A spawner whose executable does not exist. The registry reports
        /// `canSpawn`, so the gate grants it, and the spawn then fails at
        /// `posix_spawn`, before any holder exists.
        case unspawnable
    }

    private static func makeFixture(_ registry: Registry) async throws -> Fixture {
        let home = fencedScratchRoot(prefix: "tbdfsg")
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
        let db = try TBDDatabase(inMemory: true)

        let configDirManager = makeIsolatedConfigDirManager(tag: "fork-swap-gate")
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
            configDirManager: configDirManager)
        let router = RPCRouter(
            db: db, lifecycle: lifecycle, tmux: tmux, startTime: Date(),
            configDirManager: configDirManager,
            actuationLog: makeTestActuationLog())
        let launch = FakeHolderLaunch()
        switch registry {
        case .spawnDouble:
            router.holderRegistry = makeHolderRegistryDouble(
                launch: launch, environment: environment)
        case .cannotSpawn, .unspawnable:
            router.holderRegistry = HolderRegistry(
                owner: HolderOwnerToken(rawValue: "acme-installation"),
                environment: environment,
                listTerminals: { [] },
                spawner: registry == .unspawnable
                    ? HolderSpawner(executableURL: URL(fileURLWithPath: "/nonexistent/TBDHolder"))
                    : nil)
        }
        // The coordinator's registry as well as the router's: the in-place
        // holder arm parks through the coordinator, and a coordinator with no
        // registry refuses for a reason that is not the one under test.
        await router.hibernationCoordinator.setHolderRegistry(router.holderRegistry)
        // A live holder, so the no-reader rail is what these rows reach;
        // the ended-session path has tests of its own.
        await router.hibernationCoordinator.setHolderProcessIsLive { _ in true }
        let probe = RecaptureProbe()
        router.sessionRecaptureFactory = { db, tmux in
            probe.scheduler(db: db, tmux: tmux)
        }

        let repo = try await db.repos.create(
            path: "/tmp/tbd-fsg-repo-\(UUID().uuidString)",
            displayName: "acme", defaultBranch: "main")
        let worktreePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-fsg-wt-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(
            atPath: worktreePath, withIntermediateDirectories: true)
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "tbd/wt",
            path: worktreePath, tmuxServer: "tbd-fsg-test")

        // A live tmux Claude tab with a NON-blank transcript: a blank session
        // plans `.fresh`, which schedules no recapture at all, and the target
        // is what this suite is about.
        // `fencedScratchRoot` mints a path and creates nothing; the atomic
        // write below needs the directory to exist.
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true)
        let transcript = (home as NSString).appendingPathComponent("source.jsonl")
        try #"{"type":"user","message":{"content":"fork this"}}"#
            .write(toFile: transcript, atomically: true, encoding: .utf8)
        let created = try await db.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: "@source",
            tmuxPaneID: "%source",
            label: TerminalLabel.claudeCode,
            claudeSessionID: "fork-source-session",
            kind: .claude)
        try await db.terminals.updateSession(
            id: created.id, sessionID: "fork-source-session", transcriptPath: transcript)
        let source = try #require(try await db.terminals.get(id: created.id))

        return Fixture(
            db: db, router: router, recorder: recorder, launch: launch, probe: probe,
            environment: environment, worktree: worktree, source: source,
            home: home, worktreePath: worktreePath)
    }

    /// The forked row, which is the one row in the worktree that is not the
    /// source.
    private func forkedRow(in fixture: Fixture) async throws -> Terminal {
        let rows = try await fixture.db.terminals.list(worktreeID: fixture.worktree.id)
        return try #require(
            rows.first { $0.id != fixture.source.id },
            "the fork created no new terminal row")
    }

    // MARK: - The fork lands

    /// A holder row with the double's pids, no tmux at all, and a recapture
    /// scheduled against the job the holder forked — the only process that can
    /// name the session a `--fork-session` resume mints.
    @Test("a fork tab spawns onto the holder and recaptures through its child")
    func aForkLandsOnTheHolder() async throws {
        let fixture = try await Self.makeFixture(.spawnDouble)
        defer { fixture.tearDown() }

        let response = try await fixture.fork()
        #expect(response.success, "\(response.error ?? "")")

        let forked = try await forkedRow(in: fixture)
        let launch = try #require(fixture.launch.launch(for: forked.id))
        #expect(forked.transport == .holder)
        #expect(forked.tmuxWindowID.isEmpty)
        #expect(forked.tmuxPaneID.isEmpty)
        #expect(forked.holderPID == launch.handle.holderPID)
        #expect(forked.childPID == launch.handle.childPID)
        #expect(
            fixture.recorder.count("new-window") == 0 && fixture.recorder.count("new-session") == 0,
            "a holder fork opened tmux: \(fixture.recorder.all)")

        let landed = await waitUntil { !fixture.probe.targets.isEmpty }
        #expect(landed, "the fork scheduled no session recapture")
        #expect(fixture.probe.targets == [.holderChild(pid: launch.handle.childPID)])

        // The source tab is untouched — a fork copies, it does not move.
        #expect(try await fixture.db.terminals.get(id: fixture.source.id) != nil)
    }

    // MARK: - Nothing to spawn with

    /// A registry with no spawner refuses the fork with the gate's reason:
    /// no new row, no tmux, no recapture.
    @Test("a registry that cannot spawn refuses the fork")
    func aRegistryThatCannotSpawnRefusesTheFork() async throws {
        let fixture = try await Self.makeFixture(.cannotSpawn)
        defer { fixture.tearDown() }

        let response = try await fixture.fork()
        #expect(!response.success)
        #expect(response.error == TerminalSpawnRefusal.holderUnavailable.message)
        let rows = try await fixture.db.terminals.list(worktreeID: fixture.worktree.id)
        #expect(rows.map(\.id) == [fixture.source.id], "a refused fork left a row behind")
        #expect(
            fixture.recorder.count("new-window") == 0 && fixture.recorder.count("new-session") == 0,
            "a refused fork opened tmux: \(fixture.recorder.all)")
        #expect(fixture.probe.targets.isEmpty, "a refused fork scheduled a recapture")
    }

    // MARK: - The holder spawn fails

    /// The fork takes the holder path and fails there, leaving no new row, no
    /// tmux window and no tmux server.
    @Test("a holder fork spawn failure fails the swap and starts no tmux server")
    func holderSpawnFailureFailsTheFork() async throws {
        let fixture = try await Self.makeFixture(.unspawnable)
        defer { fixture.tearDown() }

        let response = try await fixture.fork()
        #expect(!response.success)
        #expect(
            response.error?.contains("/nonexistent/TBDHolder") == true,
            "the fork did not take the holder path: \(response.error ?? "success")")
        let rows = try await fixture.db.terminals.list(worktreeID: fixture.worktree.id)
        #expect(rows.map(\.id) == [fixture.source.id], "a failed fork left a row behind")
        #expect(
            fixture.recorder.count("new-window") == 0,
            "a failed holder fork fell through to tmux: \(fixture.recorder.all)")
        #expect(
            fixture.recorder.count("new-session") == 0,
            "a holder fork started a tmux server: \(fixture.recorder.all)")
        #expect(fixture.probe.targets.isEmpty, "a fork that never spawned scheduled a recapture")
    }

    // MARK: - The in-place holder arm is not this suite's

    /// `.inPlace` on a holder row takes the holder arm, which parks the
    /// session first. This fixture's registry adopted nothing, so the park
    /// stops at its reader lookup — enough to say the transport is not what
    /// stopped it, and that only the fork path spawns. The arm itself is
    /// `HolderInPlaceSwapTests` and the live suite.
    @Test("an in-place swap on a holder row takes the holder arm rather than refusing")
    func inPlaceOnAHolderRowTakesTheHolderArm() async throws {
        let fixture = try await Self.makeFixture(.spawnDouble)
        defer { fixture.tearDown() }
        let holderSource = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id,
            tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode,
            claudeSessionID: "holder-source-session",
            kind: .claude,
            transport: .holder,
            holderPID: 4242,
            childPID: 4243)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: holderSource.id, newProfileID: nil, mode: .inPlace)))

        #expect(!response.success)
        #expect(
            response.error == HibernationCoordinator.holderNoReaderRefusal,
            "the swap failed for some other reason: \(response.error ?? "success")")
        #expect(fixture.recorder.count("new-window") == 0)
        #expect(fixture.recorder.count("respawn-window") == 0)
        #expect(fixture.launch.launches.isEmpty, "the in-place arm spawned before parking")
    }
}
