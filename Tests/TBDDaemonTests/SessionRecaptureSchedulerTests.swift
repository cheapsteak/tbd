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
            server: "tbd-recapture",
            expectedIncarnationID: fixture.terminal.sessionIncarnationID
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
            server: "tbd-recapture",
            expectedIncarnationID: fixture.terminal.sessionIncarnationID
        )

        await clock.advanceWhenSuspended(by: .seconds(5))
        await Task.megaYield()
        let unchanged = try #require(try await fixture.db.terminals.get(id: fixture.terminal.id))
        #expect(unchanged.claudeSessionID == fixture.sourceSessionID)
    }

    @Test func ignoresCaptureFromAProcessReplacedBeforePersistence() async throws {
        let fixture = try await makeFixture()
        let clock = TestClock<Duration>()
        let capture = BlockingSessionCapture(result: "stale-captured-session")
        let scheduler = SessionRecaptureScheduler(
            db: fixture.db,
            tmux: TmuxManager(dryRun: true),
            captureSessionID: { _, _ in capture.capture() },
            clock: clock)

        scheduler.schedule(
            terminalID: fixture.terminal.id,
            paneID: "%7",
            server: "tbd-recapture",
            expectedIncarnationID: fixture.terminal.sessionIncarnationID)

        await clock.advanceWhenSuspended(by: .seconds(5))
        guard await waitUntil({ capture.isBlocked }) else {
            capture.release()
            Issue.record("recapture did not reach the detector")
            return
        }
        let replacementToken = try #require(try await fixture.db.terminals.prepareProfileAgentRespawn(
            id: fixture.terminal.id,
            expectedState: TerminalReplacementSnapshot(terminal: fixture.terminal),
            sessionID: "replacement-session",
            transcriptPath: "/tmp/replacement-session.jsonl",
            profileID: nil,
            at: Date(timeIntervalSinceReferenceDate: 20)))
        capture.release()
        await Task.megaYield()

        let stored = try #require(try await fixture.db.terminals.get(id: fixture.terminal.id))
        #expect(stored.sessionIncarnationID == replacementToken)
        #expect(stored.claudeSessionID == "replacement-session")
        #expect(stored.transcriptPath == "/tmp/replacement-session.jsonl")
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

private final class BlockingSessionCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseGate = DispatchSemaphore(value: 0)
    private let result: String
    private var blocked = false

    init(result: String) {
        self.result = result
    }

    var isBlocked: Bool {
        lock.withLock { blocked }
    }

    func capture() -> String {
        lock.withLock { blocked = true }
        releaseGate.waitForGate("session recapture")
        return result
    }

    func release() {
        releaseGate.signal()
    }
}
