import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TBDKernel
import DaemonTestSupport
import TestSupport

/// The holder spawn double (`FakeHolderLaunch`) driven through the one spawn
/// every path shares, `WorktreeLifecycle.spawnTerminal`, with the transport
/// granted by the production gate.
///
/// What is pinned is the contract the double's doc comment states: a spawn
/// writes an ordinary holder row carrying the double's pids and starts no
/// process; a row that cannot be written hands the spawn back through
/// `abandon`; a failed launch writes nothing; a live session refuses a second
/// spawn until a teardown; and every teardown — the row's, a park's, the hook
/// tab's — reaches the double rather than the kernel.
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

    /// A shell spawn whose transport the production gate grants.
    private static func spawn(
        in fixture: Fixture, id: UUID = UUID(), command: String = "htop"
    ) async throws -> TBDShared.Terminal {
        try await fixture.lifecycle.spawnTerminal(
            id: id,
            worktreeID: fixture.worktree.id,
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
            transport: try TerminalSpawnTransport.decide(registry: fixture.registry).get())
    }

    // MARK: - The gate

    /// The double's registry reports that it can spawn, so the gate grants it,
    /// carrying that very registry into the spawn.
    @Test("the gate grants the double's registry")
    func gateGrantsTheDoublesRegistry() async throws {
        let fixture = try await Self.makeFixture()
        #expect(fixture.registry.canSpawn)

        let granted = try TerminalSpawnTransport.decide(registry: fixture.registry).get()
        #expect(granted.registry === fixture.registry)
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

        // No tmux and no reader. What keeps a process from starting is not
        // observable here, so it is stated instead: the double's registry has
        // no `HolderSpawner` (`spawner: nil`), so `spawn` has nothing to
        // `posix_spawn` with and runs the fabricator in its place.
        #expect(fixture.tmux.all.isEmpty, "a holder spawn reached tmux: \(fixture.tmux.all)")
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

        // One scripted failure fails one spawn, and the failed spawn did not
        // leave its terminal id claimed: the retry goes through.
        _ = try await Self.spawn(in: fixture, id: id)
        #expect(fixture.launch.launches.map(\.terminalID) == [id])
    }

    /// A queued failure is the one that fires even when the spawn would have
    /// failed on something else — here a rendezvous path too long for
    /// `sun_path`, which the double derives as a real spawn does.
    @Test("a queued failure fires before anything else the spawn could fail on")
    func queuedFailureFiresFirst() async throws {
        let launch = FakeHolderLaunch()
        var environment = FakeHolderLaunch.scratchEnvironment()
        environment["TBD_HOME"] = "/tmp/" + String(repeating: "x", count: 200)
        let registry = makeHolderRegistryDouble(launch: launch, environment: environment)
        let id = UUID()

        // The path really is unrepresentable, so the check below discriminates.
        await #expect(throws: (any Error).self) {
            _ = try await registry.spawn(terminalID: id, launch: Self.launchRequest())
        }
        #expect(launch.failedSpawns.isEmpty)

        launch.failNextSpawn()
        await #expect(throws: FakeHolderLaunch.SpawnFailure(terminalID: id)) {
            _ = try await registry.spawn(terminalID: id, launch: Self.launchRequest())
        }
        #expect(launch.failedSpawns == [id])
        #expect(launch.launches.isEmpty)
    }

    // MARK: - A live session refuses a second spawn

    /// A real registry refuses a spawn for a session it already holds, and the
    /// wake path depends on that refusal; a fabricated session must refuse it
    /// too, without the second spawn ever reaching the double.
    @Test("a second spawn of a live terminal id is refused")
    func secondSpawnOfALiveIDIsRefused() async throws {
        let fixture = try await Self.makeFixture()
        let id = UUID()
        _ = try await fixture.registry.spawn(terminalID: id, launch: Self.launchRequest())

        await #expect(throws: HolderRegistry.Error.sessionAlreadyRegistered(terminalID: id)) {
            _ = try await fixture.registry.spawn(terminalID: id, launch: Self.launchRequest())
        }

        #expect(fixture.launch.launches.map(\.terminalID) == [id])
    }

    @Test("after a teardown, the terminal id can be spawned again")
    func respawnAfterAbandonSucceeds() async throws {
        let fixture = try await Self.makeFixture()
        let id = UUID()
        let first = try await fixture.registry.spawn(
            terminalID: id, launch: Self.launchRequest())

        await fixture.registry.abandon(terminalID: id, handle: first)
        let second = try await fixture.registry.spawn(
            terminalID: id, launch: Self.launchRequest())

        #expect(fixture.launch.launches.map(\.terminalID) == [id, id])
        #expect(second != first, "the respawn reused the first spawn's pids")
        #expect(await fixture.registry.letGo(for: id) == nil)
    }

    /// A park's let-go is the one a wake may undo, and the wake then spawns
    /// the same terminal id again.
    @Test("a park's abandon records a park let-go and frees the id for the wake")
    func parkAbandonFreesTheIDForAWake() async throws {
        let fixture = try await Self.makeFixture()
        let id = UUID()
        let handle = try await fixture.registry.spawn(
            terminalID: id, launch: Self.launchRequest())

        await fixture.registry.abandon(terminalID: id, handle: handle, reason: .park)

        #expect(fixture.launch.abandonments == [
            FakeHolderLaunch.Abandonment(terminalID: id, handle: handle),
        ])
        #expect(await fixture.registry.letGo(for: id)?.reason == .park)
        _ = try await fixture.registry.spawn(terminalID: id, launch: Self.launchRequest())
        #expect(await fixture.registry.letGo(for: id) == nil)
    }

    /// A real spawn's publish replaces whatever status was remembered with the
    /// holder's own report; the double has none to give, so the remembered
    /// one is cleared rather than left to describe the session it replaced.
    @Test("a respawn through the double clears a remembered status")
    func respawnClearsARememberedStatus() async throws {
        let fixture = try await Self.makeFixture()
        let id = UUID()
        let handle = try await fixture.registry.spawn(
            terminalID: id, launch: Self.launchRequest())
        await fixture.registry.abandon(terminalID: id, handle: handle, reason: .park)
        await fixture.registry.recordStatusForTesting(
            .exitedStatusUnknown, for: id, fromAbsentRendezvous: true)
        #expect(await fixture.registry.lastKnownStatus(for: id) == .exitedStatusUnknown)

        _ = try await fixture.registry.spawn(terminalID: id, launch: Self.launchRequest())

        #expect(await fixture.registry.lastKnownStatus(for: id) == nil)
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

    // MARK: - The hook tab's teardown

    /// The hook tab's teardown hands the double the handle rebuilt from the
    /// row's pids, reports nothing for a row that recorded its job fully, and
    /// frees the id.
    @Test("a hook tab's verified teardown reaches the double")
    func verifiedTeardownReachesTheDouble() async throws {
        let fixture = try await Self.makeFixture()
        let id = UUID()
        let handle = try await fixture.registry.spawn(
            terminalID: id, launch: Self.launchRequest())

        let left = await fixture.registry.abandonVerifiedJob(
            terminalID: id, holderPID: handle.holderPID, childPID: handle.childPID,
            childStartedAt: fixture.spawnedAt)

        #expect(left == nil, "\(left ?? "")")
        #expect(fixture.launch.abandonments == [
            FakeHolderLaunch.Abandonment(terminalID: id, handle: handle),
        ])
        #expect(await fixture.registry.letGo(for: id)?.reason == .teardown)
        _ = try await fixture.registry.spawn(terminalID: id, launch: Self.launchRequest())
    }

    @Test("a hook tab's verified teardown reports a missing child pid as production does")
    func verifiedTeardownReportsAMissingChildPID() async throws {
        let report = try await Self.expectVerifiedTeardownReportMatchesProduction(
            childPID: nil, childStartedAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(report.contains("recorded no child pid"), "\(report)")
    }

    @Test("a hook tab's verified teardown reports a missing start time as production does")
    func verifiedTeardownReportsAMissingStartTime() async throws {
        let report = try await Self.expectVerifiedTeardownReportMatchesProduction(
            childPID: FakeHolderLaunch.pidFloor + 99, childStartedAt: nil)
        #expect(report.contains("recorded no child start time"), "\(report)")
    }

    /// Runs the hook tab's teardown for one row through the double's registry
    /// and through a registry with no fabricator, and expects the same report
    /// from both and the rebuilt handle at the double. Returns the report.
    ///
    /// Neither case signals anything on the real registry: both are refused
    /// before the kernel is asked, and with no holder pid there is nothing to
    /// reap.
    private static func expectVerifiedTeardownReportMatchesProduction(
        childPID: Int32?, childStartedAt: Date?
    ) async throws -> String {
        let fixture = try await makeFixture()
        let production = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: FakeHolderLaunch.scratchEnvironment(),
            listTerminals: { [] })
        let id = UUID()
        let socketPath = try HolderRendezvous.socketPath(
            sessionID: id, environment: fixture.registry.environment)

        let fabricated = await fixture.registry.abandonVerifiedJob(
            terminalID: id, holderPID: nil, childPID: childPID, childStartedAt: childStartedAt)
        let real = await production.abandonVerifiedJob(
            terminalID: id, holderPID: nil, childPID: childPID, childStartedAt: childStartedAt)

        let report = try #require(fabricated)
        #expect(report == real)
        let expected = FakeHolderLaunch.Abandonment(
            terminalID: id,
            handle: HolderHandle(holderPID: 0, childPID: childPID ?? 0, socketPath: socketPath))
        #expect(fixture.launch.abandonments == [expected])
        return report
    }

    // MARK: - Helpers

    /// A launch for the tests that call the registry directly, where what is
    /// launched does not matter.
    private static func launchRequest() -> HolderLaunchRequest {
        HolderLaunchRequest(
            executable: "/bin/sh", arguments: ["-c", "true"], workingDirectory: "/tmp",
            environment: [:], columns: 80, rows: 24)
    }
}

private extension Array {
    /// The single element, or nil when there are none or several.
    var only: Element? { count == 1 ? first : nil }
}
