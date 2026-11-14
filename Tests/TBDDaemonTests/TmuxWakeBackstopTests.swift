import Foundation
import Testing
import DaemonTestSupport
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// A parked tmux row never wakes: TBD starts sessions only on the pty holder.
/// The refusal names the migration gesture, leaves the row parked with its
/// session id, and touches nothing — whether or not tmux is installed. A
/// parked holder row wakes as before.
@Suite("Tmux wake backstop")
struct TmuxWakeBackstopTests {
    private static let sessionID = "sess-backstop"

    private struct Fixture {
        let db: TBDDatabase
        let coordinator: HibernationCoordinator
        let worktree: Worktree
        let holder: FakeHolderLaunch
        let tmuxCommands: TmuxCommandLog
        let scratch: String
        func tearDown() { try? FileManager.default.removeItem(atPath: scratch) }
    }

    /// Every tmux command a dry-run manager was asked to run.
    final class TmuxCommandLog: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [[String]] = []
        func append(_ args: [String]) { lock.withLock { commands.append(args) } }
        var snapshot: [[String]] { lock.withLock { commands } }
    }

    /// `tmuxResolvable: false` builds a real-mode manager whose PATH is an empty
    /// directory, so the binary genuinely cannot resolve. `true` is dry-run,
    /// which can always serve and records every command it is asked to run.
    /// Either way the coordinator holds a holder registry that can spawn,
    /// through the spawn double, so a refusal is never for want of one.
    private static func makeFixture(tmuxResolvable: Bool) async throws -> Fixture {
        let scratch = fencedScratchRoot(prefix: "tbdbackstop")
        let emptyBin = "\(scratch)/empty-bin"
        let wtPath = "\(scratch)/wt"
        for dir in [emptyBin, wtPath, "\(scratch)/repo"] {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
        }
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "\(scratch)/repo", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "tbd/wt",
            path: wtPath, tmuxServer: "tbd-backstop-test")
        let log = TmuxCommandLog()
        let tmux = tmuxResolvable
            ? TmuxManager(dryRun: true, dryRunRecorder: { args in log.append(args) })
            : TmuxManager(dryRun: false, tmuxPathOverride: emptyBin)
        let coordinator = HibernationCoordinator(
            db: db, tmux: tmux,
            configDirManager: makeIsolatedConfigDirManager(tag: "tmux-backstop"),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog(tag: "tmux-backstop"))
        let holder = FakeHolderLaunch()
        await coordinator.setHolderRegistry(makeHolderRegistryDouble(launch: holder))
        return Fixture(
            db: db, coordinator: coordinator, worktree: worktree, holder: holder,
            tmuxCommands: log, scratch: scratch)
    }

    private static func parkedRow(
        _ f: Fixture, transport: TerminalTransport
    ) async throws -> Terminal {
        let created = try await f.db.terminals.create(
            worktreeID: f.worktree.id,
            tmuxWindowID: transport == .holder ? "" : "@3",
            tmuxPaneID: transport == .holder ? "" : "%3",
            label: TerminalLabel.claudeCode,
            claudeSessionID: sessionID,
            kind: .claude,
            transport: transport)
        try await f.db.terminals.setHibernated(
            id: created.id, sessionID: sessionID, reason: .auto)
        return try #require(try await f.db.terminals.get(id: created.id))
    }

    /// The refusal, and that it changed nothing: the row is still parked on
    /// tmux with its session id, and no holder was started for it.
    private static func expectRefused(
        _ result: WakeResult, row: Terminal, _ f: Fixture
    ) async throws {
        guard case .respawnFailed(let reason) = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(reason == HibernationCoordinator.tmuxWakeUnavailableReason(terminalID: row.id))
        // The command is the whole product of this refusal, so it has to be
        // runnable as printed: a literal `<id>` would send a stranded person
        // looking for which session it meant.
        #expect(reason.contains("tbd terminal migrate \(row.id.uuidString)"),
                "the refusal does not name the session to migrate: \(reason)")
        let after = try #require(try await f.db.terminals.get(id: row.id))
        #expect(after.isParked, "the refusal must leave the row parked")
        #expect(after.claudeSessionID == Self.sessionID)
        #expect(after.transport == .tmux)
        #expect(after.tmuxWindowID == "@3")
        #expect(f.holder.launches.isEmpty, "a tmux row's wake started a holder")
    }

    @Test func aTmuxRowRefusesItsWakeWhenTmuxIsMissing() async throws {
        let f = try await Self.makeFixture(tmuxResolvable: false)
        defer { f.tearDown() }
        let row = try await Self.parkedRow(f, transport: .tmux)

        let result = await f.coordinator.wake(terminalID: row.id)

        try await Self.expectRefused(result, row: row, f)
    }

    /// The case the backstop exists for now: tmux is there and could serve,
    /// and the row still refuses, without a single tmux command.
    @Test func aTmuxRowRefusesItsWakeEvenWhenTmuxCanServe() async throws {
        let f = try await Self.makeFixture(tmuxResolvable: true)
        defer { f.tearDown() }
        let row = try await Self.parkedRow(f, transport: .tmux)

        let result = await f.coordinator.wake(terminalID: row.id)

        try await Self.expectRefused(result, row: row, f)
        #expect(f.tmuxCommands.snapshot.isEmpty,
                "a refused wake ran tmux: \(f.tmuxCommands.snapshot)")
    }

    /// The other branch of the backstop: a parked holder row wakes on the
    /// holder, with tmux missing, and resumes its own session.
    @Test func aParkedHolderRowStillWakes() async throws {
        let f = try await Self.makeFixture(tmuxResolvable: false)
        defer { f.tearDown() }
        let row = try await Self.parkedRow(f, transport: .holder)

        let result = await f.coordinator.wake(terminalID: row.id)

        #expect(result.isOk, "a parked holder row did not wake: \(result)")
        let after = try #require(try await f.db.terminals.get(id: row.id))
        #expect(!after.isParked)
        #expect(after.transport == .holder)
        let launch = try #require(f.holder.launch(for: row.id))
        #expect(launch.commandLine?.contains(Self.sessionID) == true,
                "the wake did not resume the row's session: \(launch.commandLine ?? "nil")")
    }
}
