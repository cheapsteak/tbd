import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// `terminal.recreateWindow` and the window probe it decides on.
///
/// The Claude-resumable arm of this handler parks the row and then `killWindow`s
/// it the moment it believes the window is gone. Believing that on a `false`
/// meant believing it on a timeout, so a recreate arriving while the machine was
/// busy parked and killed a session that was alive and working — on a user's own
/// gesture, which makes it worse than the startup sweep's version of the same
/// bug. Ignorance is now reported back to the caller and nothing is touched.
///
/// Every test fingerprints the row rather than only reading the response: a
/// refusal that still parked or re-identified the row is precisely the failure
/// under test, and the return value cannot see it.
@Suite("recreateWindow and the window probe")
struct RecreateWindowProbeTests {

    private func isolatedConfigDirManager() -> ClaudeProfileConfigDirManager {
        makeIsolatedConfigDirManager(tag: "recreate-probe")
    }

    private func seedWorktree(_ db: TBDDatabase) async throws -> (Worktree, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-recreate-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repo = try await db.repos.create(
            path: dir.path, displayName: "acme", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main", path: dir.path,
            tmuxServer: "tbd-recreate")
        return (wt, dir)
    }

    private func seedClaudeTerminal(
        _ db: TBDDatabase, worktreeID: UUID
    ) async throws -> Terminal {
        let terminal = try await db.terminals.create(
            worktreeID: worktreeID, tmuxWindowID: "@7", tmuxPaneID: "%7",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-recreate", kind: .claude)
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .idle, source: .derived)
        return try #require(try await db.terminals.get(id: terminal.id))
    }

    private func router(_ db: TBDDatabase, tmux: TmuxManager) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())
    }

    /// Every column the park arm would touch.
    private struct RowFingerprint: Equatable {
        let tmuxWindowID: String
        let tmuxPaneID: String
        let claudeSessionID: String?
        let hibernatedAt: Date?
        let suspendedAt: Date?
        let hibernateReason: HibernateReason?
        let sessionIncarnationID: UUID?

        init(_ t: Terminal) {
            tmuxWindowID = t.tmuxWindowID
            tmuxPaneID = t.tmuxPaneID
            claudeSessionID = t.claudeSessionID
            hibernatedAt = t.hibernatedAt
            suspendedAt = t.suspendedAt
            hibernateReason = t.hibernateReason
            sessionIncarnationID = t.sessionIncarnationID
        }
    }

    private func run(
        windowPresence: TmuxPresence
    ) async throws -> (response: RPCResponse, before: RowFingerprint,
                       after: RowFingerprint, tmuxCalls: [[String]], terminalID: UUID) {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorded.append($0) },
            dryRunWindowPresence: { _, _ in windowPresence })
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(db, worktreeID: wt.id)
        let before = RowFingerprint(terminal)

        let response = await router(db, tmux: tmux).handle(try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: terminal.id)))

        let after = try #require(try await db.terminals.get(id: terminal.id))
        return (response, before, RowFingerprint(after), recorded.snapshot(), terminal.id)
    }

    /// The regression. A probe that never answered must not become a park and a
    /// kill; the caller is told to retry instead.
    @Test("an unanswered probe parks nothing, kills nothing, and says so")
    func unknownProbeRefusesAndLeavesTheRowAlone() async throws {
        let run = try await run(windowPresence: .unknown)

        #expect(!run.response.success)
        #expect(run.response.error == RPCRouter.unansweredWindowProbeRefusal(
            terminalID: run.terminalID))
        #expect(run.after == run.before,
                "an unanswered probe mutated the row it was supposed to leave alone")
        #expect(!run.tmuxCalls.contains { $0.contains("kill-window") },
                "an unanswered probe killed a window: \(run.tmuxCalls)")
    }

    /// Positive evidence still parks, exactly as before. Without this the
    /// tri-state could be satisfied by a handler that never acts.
    @Test("a window tmux says is gone is still parked")
    func absentProbeStillParks() async throws {
        let run = try await run(windowPresence: .absent)

        #expect(run.response.success)
        #expect(run.after.hibernatedAt != nil,
                "the tri-state probe stopped recreateWindow acting on positive evidence")
        #expect(run.after.claudeSessionID == run.before.claudeSessionID,
                "the park discarded the session identity it exists to preserve")
        #expect(run.tmuxCalls.contains { $0.contains("kill-window") },
                "the park did not eliminate the dead pane: \(run.tmuxCalls)")
    }

    /// A live window means the request was stale. Unchanged behaviour: succeed,
    /// touch nothing.
    @Test("a live window is a stale request and is ignored")
    func aliveProbeIgnoresTheRequest() async throws {
        let run = try await run(windowPresence: .alive)

        #expect(run.response.success)
        #expect(run.after == run.before,
                "a stale recreate request mutated a row whose window is alive")
        #expect(!run.tmuxCalls.contains { $0.contains("kill-window") },
                "a stale recreate request killed a live window: \(run.tmuxCalls)")
    }
}
