import Foundation
import Testing
import DaemonTestSupport
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// A parked tmux row cannot wake when the tmux leg cannot serve. The refusal
/// names the migration gesture, leaves the row parked with its session id, and
/// never touches a holder row or a tmux row that tmux can serve.
@Suite("Tmux wake backstop")
struct TmuxWakeBackstopTests {
    private static let sessionID = "sess-backstop"

    private struct Fixture {
        let db: TBDDatabase
        let coordinator: HibernationCoordinator
        let worktree: Worktree
        let scratch: String
        func tearDown() { try? FileManager.default.removeItem(atPath: scratch) }
    }

    /// `tmuxResolvable: false` builds a real-mode manager whose PATH is an empty
    /// directory, so the binary genuinely cannot resolve. `true` is dry-run,
    /// which can always serve.
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
        let tmux = tmuxResolvable
            ? TmuxManager(dryRun: true)
            : TmuxManager(dryRun: false, tmuxPathOverride: emptyBin)
        let coordinator = HibernationCoordinator(
            db: db, tmux: tmux,
            configDirManager: makeIsolatedConfigDirManager(tag: "tmux-backstop"),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog(tag: "tmux-backstop"))
        return Fixture(db: db, coordinator: coordinator, worktree: worktree, scratch: scratch)
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

    @Test func aTmuxRowRefusesItsWakeWithTheMigrationNamed() async throws {
        let f = try await Self.makeFixture(tmuxResolvable: false)
        defer { f.tearDown() }
        let row = try await Self.parkedRow(f, transport: .tmux)

        let result = await f.coordinator.wake(terminalID: row.id)

        guard case .respawnFailed(let reason) = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        // The command is the whole product of this refusal, so it has to be
        // runnable as printed: a literal `<id>` would send a stranded person
        // looking for which session it meant.
        #expect(reason.contains("tbd terminal migrate \(row.id.uuidString)"),
                "the refusal does not name the session to migrate: \(reason)")
        let after = try #require(try await f.db.terminals.get(id: row.id))
        #expect(after.isParked, "the refusal must leave the row parked")
        #expect(after.claudeSessionID == Self.sessionID)
        #expect(after.transport == .tmux)
    }

    @Test func aHolderRowIsUnaffectedWhenTmuxIsMissing() async throws {
        let f = try await Self.makeFixture(tmuxResolvable: false)
        defer { f.tearDown() }
        let row = try await Self.parkedRow(f, transport: .holder)

        // No holder registry here, so the holder wake fails for its own reason;
        // the point is that it is not the tmux refusal.
        let result = await f.coordinator.wake(terminalID: row.id)

        if case .respawnFailed(let reason) = result {
            #expect(!reason.contains("tbd terminal migrate"),
                    "a holder row was refused for want of tmux: \(reason)")
        }
    }

    @Test func aTmuxRowStillWakesWhenTmuxCanServe() async throws {
        let f = try await Self.makeFixture(tmuxResolvable: true)
        defer { f.tearDown() }
        let row = try await Self.parkedRow(f, transport: .tmux)

        let result = await f.coordinator.wake(terminalID: row.id)

        #expect(result.isOk, "the refusal swallowed the working path: \(result)")
        let after = try #require(try await f.db.terminals.get(id: row.id))
        #expect(!after.isParked)
    }
}
