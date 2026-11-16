import Foundation
import DaemonTestSupport
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// `terminal.recreateWindow` — the app's Check Again — and the leftover-tmux
/// server probe it decides on.
///
/// TBD no longer drives tmux, so for a live tmux agent row — Claude, or Codex
/// with a recorded thread — the handler asks only whether the row's tmux server
/// is still listening. While it is, the session may still be running there and
/// the row is left alone, with the advice that ends it. Once the server is
/// positively gone the row is parked, keeping the identity a wake resumes from
/// once the row has been migrated to the pty holder. Nothing reaches tmux
/// either way.
///
/// Every test fingerprints the row rather than only reading the response: a
/// refusal that still parked or re-identified the row is precisely the failure
/// under test, and the return value cannot see it.
@Suite("recreateWindow and the leftover-tmux probe")
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

    /// The two agent rows the handler parks: a Claude tab with a session, and
    /// a Codex tab with a recorded thread and launch options.
    enum Agent: String, CaseIterable, Sendable {
        case claude, codex
    }

    static let codexOptions = CodexLaunchOptions(
        model: "acme-model", disabledFeatures: ["acme-feature"])

    private func seedTerminal(
        _ db: TBDDatabase, worktreeID: UUID, agent: Agent
    ) async throws -> Terminal {
        let terminal: Terminal
        switch agent {
        case .claude:
            terminal = try await db.terminals.create(
                worktreeID: worktreeID, tmuxWindowID: "@7", tmuxPaneID: "%7",
                label: TerminalLabel.claudeCode, claudeSessionID: "sess-recreate",
                kind: .claude, transport: .tmux)
        case .codex:
            terminal = try await db.terminals.create(
                worktreeID: worktreeID, tmuxWindowID: "@7", tmuxPaneID: "%7",
                label: TerminalLabel.codex, claudeSessionID: "acme-thread",
                kind: .codex, transport: .tmux, codexLaunchOptions: Self.codexOptions)
        }
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .idle, source: .derived)
        return try #require(try await db.terminals.get(id: terminal.id))
    }

    private func router(
        _ db: TBDDatabase, tmux: TmuxManager, server: LeftoverTmuxServerState
    ) -> RPCRouter {
        var lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver())
        lifecycle.leftoverTmuxProbe = LeftoverTmuxServerProbe { _ in server }
        return RPCRouter(
            db: db,
            lifecycle: lifecycle,
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())
    }

    /// Every column the park arm would touch.
    private struct RowFingerprint: Equatable {
        let tmuxWindowID: String
        let tmuxPaneID: String
        let claudeSessionID: String?
        let transport: TerminalTransport
        let kind: TerminalKind?
        let codexLaunchOptions: CodexLaunchOptions?
        let hibernatedAt: Date?
        let suspendedAt: Date?
        let hibernateReason: HibernateReason?
        let sessionIncarnationID: UUID?

        init(_ t: Terminal) {
            tmuxWindowID = t.tmuxWindowID
            tmuxPaneID = t.tmuxPaneID
            claudeSessionID = t.claudeSessionID
            transport = t.transport
            kind = t.kind
            codexLaunchOptions = t.codexLaunchOptions
            hibernatedAt = t.hibernatedAt
            suspendedAt = t.suspendedAt
            hibernateReason = t.hibernateReason
            sessionIncarnationID = t.sessionIncarnationID
        }
    }

    private func run(
        server: LeftoverTmuxServerState, agent: Agent = .claude
    ) async throws -> (response: RPCResponse, before: RowFingerprint,
                       after: RowFingerprint, tmuxCalls: [[String]], terminalID: UUID) {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { recorded.append($0) })
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedTerminal(db, worktreeID: wt.id, agent: agent)
        let before = RowFingerprint(terminal)

        let response = await router(db, tmux: tmux, server: server).handle(try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: terminal.id)))

        let after = try #require(try await db.terminals.get(id: terminal.id))
        return (response, before, RowFingerprint(after), recorded.snapshot(), terminal.id)
    }

    /// A server still listening means the session may still be running in
    /// tmux. The row is left as it is, and the person is told how to end the
    /// session and then move it; the code tells the app to keep its notice.
    @Test("a tmux server still running refuses, and leaves the row live", arguments: Agent.allCases)
    func runningServerRefusesAndLeavesTheRowAlone(agent: Agent) async throws {
        let run = try await run(server: .running, agent: agent)

        #expect(!run.response.success)
        #expect(run.response.knownErrorCode == .terminalOnTmux)
        #expect(run.response.error == LeftoverTmuxSession.stillRunningRefusal(
            terminalID: run.terminalID, server: "tbd-recreate"))
        #expect(run.after == run.before,
                "a refused recreate mutated the row it was supposed to leave alone")
        #expect(run.after.hibernatedAt == nil, "a row still running in tmux was parked")
        #expect(run.tmuxCalls.isEmpty, "recreateWindow reached tmux: \(run.tmuxCalls)")
    }

    /// A server positively gone parks. The row stays on tmux and keeps
    /// everything a wake resumes from — the Claude session id, or the Codex
    /// thread id and launch options — so a migration followed by a wake brings
    /// the session back on the holder. Nothing reaches tmux.
    @Test("a tmux server that is gone parks the row with its identity kept", arguments: Agent.allCases)
    func absentServerParks(agent: Agent) async throws {
        let run = try await run(server: .absent, agent: agent)

        #expect(run.response.success, "the park was refused: \(run.response.error ?? "")")
        let returned = try run.response.decodeResult(TBDShared.Terminal.self)
        #expect(returned.isParked, "the response did not carry the parked row")
        #expect(returned.id == run.terminalID)
        #expect(run.after.hibernatedAt != nil, "the row was not parked")
        #expect(run.after.hibernateReason == .recovery)
        #expect(run.after.claudeSessionID == run.before.claudeSessionID,
                "the park discarded the session identity it exists to preserve")
        #expect(run.after.kind == run.before.kind, "the park changed the tab's kind")
        #expect(run.after.codexLaunchOptions == run.before.codexLaunchOptions,
                "the park discarded the recorded Codex launch options")
        #expect(run.after.transport == .tmux,
                "the park moved the row off tmux without a migration")
        #expect(run.tmuxCalls.isEmpty, "recreateWindow reached tmux: \(run.tmuxCalls)")
    }

    /// A row already parked has nothing running to look for: the request is
    /// answered with the row as it is, and the probe is not asked.
    @Test("a parked tmux row is returned unchanged without asking the probe")
    func parkedRowIsReturnedUnchanged() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { recorded.append($0) })
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let seeded = try await seedTerminal(db, worktreeID: wt.id, agent: .claude)
        try await db.terminals.setHibernated(id: seeded.id, sessionID: "sess-recreate")
        let terminal = try #require(try await db.terminals.get(id: seeded.id))
        let before = RowFingerprint(terminal)

        var lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver())
        lifecycle.leftoverTmuxProbe = LeftoverTmuxServerProbe { _ in
            Issue.record("a parked row must not be probed")
            return .running
        }
        let router = RPCRouter(
            db: db, lifecycle: lifecycle, tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: terminal.id)))

        #expect(response.success, "error: \(response.error ?? "")")
        #expect(try response.decodeResult(TBDShared.Terminal.self).id == terminal.id)
        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(RowFingerprint(after) == before)
        #expect(recorded.snapshot().isEmpty)
    }
}
