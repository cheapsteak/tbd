import Clocks
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// The transport gate as a `.fork` profile swap asks it, and the recapture
/// target that follows from it — the branches that need no `TBDHolder` binary.
/// The branch that does, a fork landing on a real holder, is
/// `HolderSpawnGateTests` in the live target.
///
/// The recapture half is the reason this suite exists rather than a row
/// assertion alone. A real scheduler's only trace is a database write five wall
/// seconds later, made only if a live Claude process answers, so "scheduled
/// against the pane" and "scheduled against the holder's child" are
/// indistinguishable from the row. `router.sessionRecaptureFactory` makes the
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

    private static func unspawnableSpawner() -> HolderSpawner {
        HolderSpawner(executableURL: URL(fileURLWithPath: "/nonexistent/TBDHolder"))
    }

    private static func makeFixture(
        holderFlag: Bool,
        spawner: HolderSpawner?
    ) async throws -> Fixture {
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
        try await db.config.setPtyHolderEnabled(holderFlag)

        let configDirManager = makeIsolatedConfigDirManager(tag: "fork-swap-gate")
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
            db: db, router: router, recorder: recorder, probe: probe,
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

    // MARK: - Flag off

    /// Today's behaviour, exactly: a tmux window, a tmux row, and a recapture
    /// scheduled against that row's own pane.
    @Test("flag off: a fork tab spawns onto tmux and recaptures through its pane")
    func flagOffForksOntoTmux() async throws {
        let fixture = try await Self.makeFixture(
            holderFlag: false, spawner: Self.unspawnableSpawner())
        defer { fixture.tearDown() }

        let response = try await fixture.fork()
        #expect(response.success, "\(response.error ?? "")")

        let forked = try await forkedRow(in: fixture)
        #expect(forked.transport == .tmux)
        #expect(!forked.tmuxPaneID.isEmpty)
        #expect(forked.holderPID == nil)
        #expect(forked.childPID == nil)
        #expect(fixture.recorder.count("new-window") == 1)

        let landed = await waitUntil { !fixture.probe.targets.isEmpty }
        #expect(landed, "the fork scheduled no session recapture")
        #expect(fixture.probe.targets == [
            .tmuxPane(server: fixture.worktree.tmuxServer, paneID: forked.tmuxPaneID)
        ])

        // The source tab is untouched — a fork copies, it does not move.
        #expect(try await fixture.db.terminals.get(id: fixture.source.id) != nil)
    }

    // MARK: - Flag on, nothing to spawn with

    /// A registry with no spawner falls back to tmux whole: a tmux row AND a
    /// pane-addressed recapture, not a half-taken holder path.
    @Test("flag on with a registry that cannot spawn falls back to tmux")
    func flagOnWithoutASpawnerFallsBackToTmux() async throws {
        let fixture = try await Self.makeFixture(holderFlag: true, spawner: nil)
        defer { fixture.tearDown() }

        let response = try await fixture.fork()
        #expect(response.success, "\(response.error ?? "")")

        let forked = try await forkedRow(in: fixture)
        #expect(forked.transport == .tmux)
        #expect(fixture.recorder.count("new-window") == 1)

        let landed = await waitUntil { !fixture.probe.targets.isEmpty }
        #expect(landed, "the fork scheduled no session recapture")
        #expect(fixture.probe.targets == [
            .tmuxPane(server: fixture.worktree.tmuxServer, paneID: forked.tmuxPaneID)
        ])
    }

    // MARK: - Flag on, the holder spawn fails

    /// The fork takes the holder path and fails there, leaving no new row, no
    /// tmux window and no tmux server — `prepareTmuxServer` is a no-op for a
    /// holder decision, and the fork must not have started one anyway.
    @Test("a holder fork spawn failure fails the swap and starts no tmux server")
    func holderSpawnFailureFailsTheFork() async throws {
        let fixture = try await Self.makeFixture(
            holderFlag: true, spawner: Self.unspawnableSpawner())
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

    // MARK: - The in-place refusal is untouched

    /// The holder refusal for `.inPlace` is scoped to that mode and stays put:
    /// a holder source row cannot be respawned in place, whatever the flag
    /// says about new spawns.
    @Test("an in-place swap on a holder row is still refused")
    func inPlaceOnAHolderRowIsStillRefused() async throws {
        let fixture = try await Self.makeFixture(holderFlag: true, spawner: nil)
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
        // The refusal itself, not merely a failure: `.inPlace` on a holder row
        // has several other ways to fail (an unresolvable profile, a missing
        // source session), and only this text says the transport was what
        // stopped it.
        #expect(
            response.error?.contains(
                RPCRouter.holderInPlaceSwapRefusal(terminalID: holderSource.id)) == true,
            "the swap failed for some other reason: \(response.error ?? "success")")
        #expect(fixture.recorder.count("new-window") == 0)
    }
}
