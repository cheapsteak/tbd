import Foundation
import DaemonTestSupport
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The resume gate keyed by session id (`TmuxResumeGate`), through the RPCs
/// that start an existing session: each answers a refusal with
/// `terminalOnTmux` and the command that ends the server, records a
/// not-eligible outcome, starts nothing, and leaves the mark; each goes ahead
/// once the server is gone; and none asks the probe about a session nothing
/// marked.
///
/// The mark comes from `terminal.delete` of a live tmux row, the close the
/// History pane's Resume and Closed Terminals then reach by session id. The
/// probe is injected and switchable, so no test asks a real socket.
@Suite("Resume gate RPCs")
struct TmuxResumeGateRPCTests {
    /// What the injected probe answers, switchable mid-test.
    final class ServerState: @unchecked Sendable {
        private let lock = NSLock()
        private var value: LeftoverTmuxServerState = .running
        var state: LeftoverTmuxServerState {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    struct Fixture {
        let root: URL
        let db: TBDDatabase
        let router: RPCRouter
        let worktree: Worktree
        let holder: FakeHolderLaunch
        let server: ServerState
        let probe: RecordingLeftoverTmuxProbe
        let actuationPath: String

        func tearDown() { try? FileManager.default.removeItem(at: root) }

        /// The outcome row of the last act the router recorded.
        func lastOutcome() throws -> ActuationRow {
            try #require(ActuationRecordReader(activePath: actuationPath).readRows()
                .last { $0.kind == .outcome })
        }

        func send<P: Encodable>(_ method: String, _ params: P) async throws -> RPCResponse {
            await router.handle(try RPCRequest(method: method, params: params))
        }
    }

    private static let sessionID = "sess-acme-tmux"

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmux-resume-gate-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try TBDDatabase(inMemory: true)
        let tmux = TmuxManager(dryRun: true)
        let holder = FakeHolderLaunch()
        let registry = makeHolderRegistryDouble(launch: holder)
        let server = ServerState()
        let probe = RecordingLeftoverTmuxProbe { _ in server.state }
        let manager = ClaudeProfileConfigDirManager(
            baseDirectory: root.appendingPathComponent("profiles"),
            hostBaseDirectory: root.appendingPathComponent("claude"))
        var lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
            configDirManager: manager)
        lifecycle.holderRegistry = registry
        lifecycle.leftoverTmuxProbe = probe.probe
        let actuationPath = root.appendingPathComponent("actuations.jsonl").path
        let router = RPCRouter(
            db: db, lifecycle: lifecycle, tmux: tmux, configDirManager: manager,
            codexExecutableResolver: { "/usr/bin/true" },
            codexHomeEnsurer: { root.appendingPathComponent("codex") },
            actuationLog: ActuationLog(path: actuationPath))
        router.holderRegistry = registry
        await router.hibernationCoordinator.setHolderRegistry(registry)
        await router.hibernationCoordinator.setLeftoverTmuxProbe(probe.probe)
        router.startAdmission = StubAdmission(.admit)
        try await db.config.setStartAdmissionEnabled(true)
        let repo = try await db.repos.create(
            path: root.path, displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "acme", branch: "main", path: root.path,
            tmuxServer: "tbd-acme")
        return Fixture(
            root: root, db: db, router: router, worktree: worktree, holder: holder,
            server: server, probe: probe, actuationPath: actuationPath)
    }

    /// A live tmux Claude row on `sessionID`, closed through `terminal.delete`,
    /// which runs no tmux command and marks its Closed Terminals entry.
    private func closeALiveTmuxRow(_ f: Fixture) async throws -> TerminalHistoryEntry {
        let row = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, claudeSessionID: Self.sessionID, kind: .claude,
            transport: .tmux)
        let deleted = try await f.send(
            RPCMethod.terminalDelete, TerminalDeleteParams(terminalID: row.id))
        #expect(deleted.success, "error: \(deleted.error ?? "nil")")
        let entry = try #require(try await f.db.terminalHistory.list(worktreeID: f.worktree.id)
            .first { $0.id == row.id })
        #expect(entry.liveOnTmuxServer == "tbd-acme")
        return entry
    }

    /// Everything a refusal must say and leave: the code, the advice, a
    /// not-eligible outcome, no spawn, no row, and the mark still in place.
    private func expectRefused(
        _ response: RPCResponse, _ f: Fixture, terminalsBefore: [Terminal],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        #expect(!response.success, sourceLocation: sourceLocation)
        #expect(response.errorCode == RPCErrorCode.terminalOnTmux.rawValue,
                sourceLocation: sourceLocation)
        #expect(response.error == LeftoverTmuxSession.resumeRefusal(server: "tbd-acme"),
                sourceLocation: sourceLocation)
        let outcome = try f.lastOutcome()
        #expect(outcome.result == .synchronous(.refused), sourceLocation: sourceLocation)
        #expect(outcome.reason == .notEligible, sourceLocation: sourceLocation)
        #expect(f.holder.launches.isEmpty, sourceLocation: sourceLocation)
        #expect(try await f.db.terminals.list(worktreeID: f.worktree.id) == terminalsBefore,
                sourceLocation: sourceLocation)
        #expect(try await f.db.terminalHistory.liveOnTmuxServers(sessionIDs: [Self.sessionID])
            == ["tbd-acme"], sourceLocation: sourceLocation)
        #expect(f.probe.servers == ["tbd-acme"], sourceLocation: sourceLocation)
    }

    private var identity: AgentSessionIdentity {
        AgentSessionIdentity(agentKind: .claude, sessionID: Self.sessionID)
    }

    // MARK: - session.resume

    /// The History pane's Resume on an active worktree, after `terminal.delete`
    /// closed the live tmux tab that carried the session.
    @Test func sessionResumeOfADeletedLiveTmuxRowsSessionWaitsForItsServer() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        _ = try await closeALiveTmuxRow(f)
        let params = SessionResumeParams(worktreeID: f.worktree.id, identity: identity)

        let refused = try await f.send(RPCMethod.sessionResume, params)
        try await expectRefused(refused, f, terminalsBefore: [])

        f.server.state = .absent
        let resumed = try await f.send(RPCMethod.sessionResume, params)
        #expect(resumed.success, "error: \(resumed.error ?? "nil")")
        let terminal = try resumed.decodeResult(Terminal.self)
        #expect(terminal.transport == .holder)
        #expect(terminal.claudeSessionID == Self.sessionID)
        let command = try #require(f.holder.launch(for: terminal.id)?.commandLine)
        #expect(command.contains("--resume \(Self.sessionID)"))
    }

    @Test func sessionResumeOfAnUnmarkedSessionAsksNoProbe() async throws {
        let f = try await fixture()
        defer { f.tearDown() }

        let resumed = try await f.send(RPCMethod.sessionResume, SessionResumeParams(
            worktreeID: f.worktree.id,
            identity: AgentSessionIdentity(agentKind: .claude, sessionID: "sess-acme-plain")))

        #expect(resumed.success, "error: \(resumed.error ?? "nil")")
        #expect(f.probe.servers.isEmpty)
        #expect(f.holder.launches.count == 1)
    }

    // MARK: - terminalHistory.revive

    /// Closed Terminals' reopen of the entry the delete wrote.
    @Test func closedTerminalsReopenOfAMarkedEntryWaitsForItsServer() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let entry = try await closeALiveTmuxRow(f)
        let params = TerminalHistoryReviveParams(worktreeID: f.worktree.id, id: entry.id)

        let refused = try await f.send(RPCMethod.terminalHistoryRevive, params)
        try await expectRefused(refused, f, terminalsBefore: [])

        f.server.state = .absent
        let reopened = try await f.send(RPCMethod.terminalHistoryRevive, params)
        #expect(reopened.success, "error: \(reopened.error ?? "nil")")
        let terminal = try reopened.decodeResult(Terminal.self)
        #expect(terminal.transport == .holder)
        #expect(terminal.claudeSessionID == Self.sessionID)
    }

    // MARK: - worktree.revive and worktree.reviveConversationFresh

    /// An archived worktree whose record names the marked session.
    private func archiveNamingTheMarkedSession(_ f: Fixture) async throws {
        _ = try await closeALiveTmuxRow(f)
        try await f.db.worktrees.archive(id: f.worktree.id)
        try await f.db.worktrees.setArchivedAgentTabs(
            id: f.worktree.id,
            tabs: [ArchivedAgentTab(identity: identity, ordinal: 0, isPrimary: true)])
    }

    @Test func worktreeReviveAnswersTheRefusalWithTheTmuxCode() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        try await archiveNamingTheMarkedSession(f)

        let refused = try await f.send(
            RPCMethod.worktreeRevive, WorktreeReviveParams(worktreeID: f.worktree.id))

        try await expectRefused(refused, f, terminalsBefore: [])
        #expect(try await f.db.worktrees.get(id: f.worktree.id)?.status == .archived)
    }

    @Test func reviveConversationFreshAnswersTheRefusalWithTheTmuxCode() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        try await archiveNamingTheMarkedSession(f)
        let repoID = try #require(f.worktree.repoID)
        let worktreesBefore = try await f.db.worktrees.list(repoID: repoID).map(\.id)

        let refused = try await f.send(
            RPCMethod.worktreeReviveConversationFresh,
            WorktreeReviveConversationFreshParams(
                archivedWorktreeID: f.worktree.id, sessionID: Self.sessionID))

        try await expectRefused(refused, f, terminalsBefore: [])
        #expect(try await f.db.worktrees.list(repoID: repoID).map(\.id) == worktreesBefore)
    }

    // MARK: - terminal.resume (a wake)

    /// A parked holder row on the marked session: a deleted live tmux row
    /// carried the same session, so waking this row waits for the server, and
    /// the row stays parked.
    @Test func aWakeOfAParkedRowOnAMarkedSessionWaitsForTheServer() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        _ = try await closeALiveTmuxRow(f)
        let created = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, claudeSessionID: Self.sessionID, kind: .claude,
            transport: .holder)
        try await f.db.terminals.setHibernated(id: created.id, sessionID: Self.sessionID, reason: .auto)
        let parked = try #require(try await f.db.terminals.get(id: created.id))

        let refused = try await f.send(
            RPCMethod.terminalResume, TerminalResumeParams(terminalID: parked.id))

        try await expectRefused(refused, f, terminalsBefore: [parked])
        #expect(try await f.db.terminals.get(id: parked.id)?.isParked == true)

        f.server.state = .absent
        let woken = try await f.send(
            RPCMethod.terminalResume, TerminalResumeParams(terminalID: parked.id))
        #expect(woken.success, "error: \(woken.error ?? "nil")")
        #expect(try await f.db.terminals.get(id: parked.id)?.isParked == false)
        #expect(f.holder.launch(for: parked.id) != nil)
    }

    /// The cheap path: a wake of a session nothing marked reads the marks and
    /// asks no probe.
    @Test func aWakeOfAnUnmarkedSessionAsksNoProbe() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let created = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-acme-plain", kind: .claude,
            transport: .holder)
        try await f.db.terminals.setHibernated(id: created.id, sessionID: "sess-acme-plain", reason: .auto)

        let woken = try await f.send(
            RPCMethod.terminalResume, TerminalResumeParams(terminalID: created.id))

        #expect(woken.success, "error: \(woken.error ?? "nil")")
        #expect(f.probe.servers.isEmpty)
    }
}
