import Clocks
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 1: in-memory database and virtual time only.
@Suite("Session recapture scheduler", .clockDriven)
struct SessionRecaptureSchedulerTests {
    @Test func persistsDetectedSessionIDAfterFiveSeconds() async throws {
        let fixture = try await makeFixture()
        let clock = TestClock<Duration>()
        let detectedSessionID = UUID().uuidString
        let scheduler = SessionRecaptureScheduler(
            db: fixture.db,
            tmux: TmuxManager(dryRun: true),
            captureSessionID: { server, paneID in
                guard server == "tbd-recapture", paneID == "%7" else { return nil }
                return detectedSessionID
            },
            clock: clock
        )

        scheduler.schedule(
            terminalID: fixture.terminal.id,
            paneID: "%7",
            server: "tbd-recapture"
        )

        await clock.advanceWhenSuspended(by: .seconds(5))
        await Task.megaYield()
        let updated = try #require(try await fixture.db.terminals.get(id: fixture.terminal.id))
        #expect(updated.claudeSessionID == detectedSessionID)
    }

    @Test func keepsSourceSessionIDWhenDetectionReturnsNil() async throws {
        let fixture = try await makeFixture()
        let clock = TestClock<Duration>()
        let scheduler = SessionRecaptureScheduler(
            db: fixture.db,
            tmux: TmuxManager(dryRun: true),
            captureSessionID: { _, _ in nil },
            clock: clock
        )

        scheduler.schedule(
            terminalID: fixture.terminal.id,
            paneID: "%7",
            server: "tbd-recapture"
        )

        await clock.advanceWhenSuspended(by: .seconds(5))
        await Task.megaYield()
        let unchanged = try #require(try await fixture.db.terminals.get(id: fixture.terminal.id))
        #expect(unchanged.claudeSessionID == fixture.sourceSessionID)
    }

    private func makeFixture() async throws -> (
        db: TBDDatabase,
        terminal: Terminal,
        sourceSessionID: String
    ) {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/session-recapture-repo",
            displayName: "recapture",
            defaultBranch: "main"
        )
        let worktree = try await db.worktrees.create(
            repoID: repo.id,
            name: "recapture",
            branch: "tbd/recapture",
            path: "/tmp/session-recapture-worktree",
            tmuxServer: "tbd-recapture"
        )
        let sourceSessionID = UUID().uuidString
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: "@7",
            tmuxPaneID: "%7",
            label: TerminalLabel.claudeCode,
            claudeSessionID: sourceSessionID,
            kind: .claude
        )
        return (db, terminal, sourceSessionID)
    }
}
