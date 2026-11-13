import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TBDKernel
import DaemonTestSupport
import TestSupport

/// The holder spawn double (`FakeHolderLaunch`) driven through the one spawn
/// every path shares, `WorktreeLifecycle.spawnTerminal`, with the transport
/// chosen by the production gate.
///
/// What is pinned is the contract the double's doc comment states: a spawn
/// writes an ordinary holder row carrying the double's pids and starts no
/// process; a row that cannot be written hands the spawn back through
/// `abandon`; a failed launch writes nothing; and a teardown that starts from
/// the row reaches the double rather than the kernel.
@Suite("holder spawn double")
struct HolderSpawnDoubleTests {

    // MARK: - Fixture

    private final class TmuxArgvRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var argvs: [[String]] = []
        func record(_ argv: [String]) { lock.withLock { argvs.append(argv) } }
        var all: [[String]] { lock.withLock { argvs } }
    }

    private struct Fixture {
        let db: TBDDatabase
        let lifecycle: WorktreeLifecycle
        let launch: FakeHolderLaunch
        let registry: HolderRegistry
        let tmux: TmuxArgvRecorder
        let worktree: Worktree
        let spawnedAt: Date
    }

    private static func makeFixture() async throws -> Fixture {
        let tmuxRecorder = TmuxArgvRecorder()
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPtyHolderEnabled(true)
        // Whole seconds, so the stamp survives the database round trip exactly.
        let spawnedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let launch = FakeHolderLaunch()
        let registry = makeHolderRegistryDouble(launch: launch)
        var lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(),
            tmux: TmuxManager(dryRun: true, dryRunRecorder: { tmuxRecorder.record($0) }),
            hooks: HookResolver(),
            configDirManager: makeIsolatedConfigDirManager(tag: "holder-spawn-double"),
            now: { spawnedAt })
        lifecycle.holderRegistry = registry
        let repo = try await db.repos.create(
            path: "/tmp/tbd-hsd-repo-\(UUID().uuidString)",
            displayName: "acme", defaultBranch: "main")
        // `spawnTerminal` never touches the directory: no process runs in it.
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "tbd/wt",
            path: "/tmp/tbd-hsd-wt-\(UUID().uuidString)", tmuxServer: "tbd-hsd-test")
        return Fixture(
            db: db, lifecycle: lifecycle, launch: launch, registry: registry,
            tmux: tmuxRecorder, worktree: worktree, spawnedAt: spawnedAt)
    }

    /// A shell spawn whose transport the production gate decides.
    private static func spawn(
        in fixture: Fixture, id: UUID = UUID(), command: String = "htop"
    ) async throws -> TBDShared.Terminal {
        let config = try await fixture.db.config.get()
        return try await fixture.lifecycle.spawnTerminal(
            id: id,
            worktreeID: fixture.worktree.id,
            tmuxServer: fixture.worktree.tmuxServer,
            workingDirectory: fixture.worktree.localPath,
            command: command,
            env: ["TBD_TERMINAL_ID": id.uuidString],
            sensitiveEnv: ["ACME_TOKEN": "acme-secret"],
            cols: 132,
            rows: 43,
            label: command,
            claudeSessionID: nil,
            profileID: nil,
            kind: .shell,
            transport: TerminalSpawnTransport.decide(config: config, registry: fixture.registry))
    }

    // MARK: - The gate

    /// The double's registry reports that it can spawn, so the gate picks it
    /// with the flag on and still falls back to tmux with the flag off.
    @Test("the gate picks the double's registry only with the flag on")
    func gatePicksTheDoubleOnlyWithTheFlagOn() async throws {
        let fixture = try await Self.makeFixture()
        #expect(fixture.registry.canSpawn)

        let on = try await fixture.db.config.get()
        #expect(TerminalSpawnTransport.decide(config: on, registry: fixture.registry).isHolder)

        try await fixture.db.config.setPtyHolderEnabled(false)
        let off = try await fixture.db.config.get()
        #expect(!TerminalSpawnTransport.decide(config: off, registry: fixture.registry).isHolder)
    }

    // MARK: - A spawn

    @Test("a spawn writes a holder row with the double's pids and starts nothing")
    func spawnWritesAHolderRow() async throws {
        let fixture = try await Self.makeFixture()
        let id = UUID()

        let returned = try await Self.spawn(in: fixture, id: id)

        let launch = try #require(fixture.launch.launches.only)
        #expect(launch.terminalID == id)
        #expect(returned.id == id)
        let row = try #require(try await fixture.db.terminals.get(id: id))
        #expect(row.transport == .holder)
        #expect(row.tmuxWindowID.isEmpty)
        #expect(row.tmuxPaneID.isEmpty)
        #expect(row.holderPID == launch.handle.holderPID)
        #expect(row.childPID == launch.handle.childPID)
        #expect(row.holderChildStartedAt == fixture.spawnedAt)

        // What a real holder would have been asked to run.
        #expect(launch.request.workingDirectory == fixture.worktree.localPath)
        #expect(launch.request.columns == 132)
        #expect(launch.request.rows == 43)
        #expect(launch.request.environment["ACME_TOKEN"] == "acme-secret")
        #expect(launch.argv.first == "/bin/sh")
        let commandLine = try #require(launch.commandLine)
        #expect(commandLine.contains("htop"))
        #expect(commandLine.contains("export TBD_TERMINAL_ID="))
        #expect(commandLine.contains(id.uuidString))

        // No tmux, no rendezvous, no reader.
        #expect(fixture.tmux.all.isEmpty, "a holder spawn reached tmux: \(fixture.tmux.all)")
        #expect(!FileManager.default.fileExists(atPath: launch.handle.socketPath))
        #expect(await fixture.registry.reader(for: id) == nil)
        #expect(await fixture.registry.adoptedProcess(for: id) == nil)
        #expect(await fixture.registry.lastKnownStatus(for: id) == nil)
        #expect(fixture.launch.abandonments.isEmpty)
    }

    @Test("each spawn gets pids no real process can hold")
    func eachSpawnGetsDistinctUnissuablePIDs() async throws {
        let fixture = try await Self.makeFixture()

        _ = try await Self.spawn(in: fixture)
        _ = try await Self.spawn(in: fixture)

        let pids = fixture.launch.launches.flatMap { [$0.handle.holderPID, $0.handle.childPID] }
        #expect(pids.count == 4)
        #expect(Set(pids).count == 4)
        #expect(pids.allSatisfy { $0 > FakeHolderLaunch.pidFloor })
    }

    // MARK: - Failures

    /// The row is refused after the double answered: `spawnTerminal`'s
    /// create-time cleanup must hand that very spawn back.
    ///
    /// A row already holding the planned id is what refuses it — the insert's
    /// primary key — because the registry knows nothing of that row and so
    /// lets the spawn through first.
    @Test("a row that cannot be written abandons the spawn")
    func rowWriteFailureAbandonsTheSpawn() async throws {
        let fixture = try await Self.makeFixture()
        let id = UUID()
        _ = try await fixture.db.terminals.create(
            id: id, worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1")

        await #expect(throws: (any Error).self) {
            _ = try await Self.spawn(in: fixture, id: id)
        }

        let launch = try #require(fixture.launch.launches.only)
        #expect(launch.terminalID == id)
        #expect(fixture.launch.abandonments == [
            FakeHolderLaunch.Abandonment(terminalID: id, handle: launch.handle),
        ])
        #expect(await fixture.registry.letGo(for: id)?.reason == .teardown)
        // The row in the way is untouched, and no holder row was written.
        let row = try #require(try await fixture.db.terminals.get(id: id))
        #expect(row.transport == .tmux)
        #expect(row.holderPID == nil)
        #expect(fixture.tmux.all.isEmpty, "the cleanup fell through to tmux: \(fixture.tmux.all)")
    }

    @Test("a failed launch writes no row and abandons nothing")
    func failedLaunchWritesNoRow() async throws {
        let fixture = try await Self.makeFixture()
        let id = UUID()
        fixture.launch.failNextSpawn()

        await #expect(throws: FakeHolderLaunch.SpawnFailure(terminalID: id)) {
            _ = try await Self.spawn(in: fixture, id: id)
        }

        #expect(fixture.launch.failedSpawns == [id])
        #expect(fixture.launch.launches.isEmpty)
        #expect(fixture.launch.abandonments.isEmpty)
        #expect(try await fixture.db.terminals.get(id: id) == nil)
        #expect(fixture.tmux.all.isEmpty, "a failed holder spawn fell through to tmux")

        // One scripted failure fails one spawn.
        _ = try await Self.spawn(in: fixture)
        #expect(fixture.launch.launches.count == 1)
    }

    // MARK: - Teardown

    /// The teardown every row-deleting path runs rebuilds the handle from the
    /// row, and that handle — the one the spawn gave out — reaches the double.
    @Test("disposing a double's row reaches the double, not the kernel")
    func disposingTheRowReachesTheDouble() async throws {
        let fixture = try await Self.makeFixture()
        let row = try await Self.spawn(in: fixture)
        let launch = try #require(fixture.launch.launch(for: row.id))

        let left = await fixture.lifecycle.disposeHolder(for: row)

        #expect(left == nil, "\(left ?? "")")
        #expect(fixture.launch.abandonments == [
            FakeHolderLaunch.Abandonment(terminalID: row.id, handle: launch.handle),
        ])
        #expect(await fixture.registry.letGo(for: row.id)?.reason == .teardown)
    }

    /// A fresh spawn for a terminal id clears the let-go it was under, as a
    /// real spawn's publish does.
    @Test("a fresh spawn clears the terminal's let-go")
    func freshSpawnClearsLetGo() async throws {
        let fixture = try await Self.makeFixture()
        let row = try await Self.spawn(in: fixture)
        _ = await fixture.lifecycle.disposeHolder(for: row)
        #expect(await fixture.registry.letGo(for: row.id) != nil)
        try await fixture.db.terminals.delete(id: row.id)

        _ = try await Self.spawn(in: fixture, id: row.id)

        #expect(await fixture.registry.letGo(for: row.id) == nil)
    }
}

private extension Array {
    /// The single element, or nil when there are none or several.
    var only: Element? { count == 1 ? first : nil }
}
