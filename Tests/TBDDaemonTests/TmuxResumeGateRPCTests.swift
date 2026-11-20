import Foundation
import GRDB
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
/// History pane's Resume and Closed Terminals then reach by session id. A tmux
/// row left open names its session the same way, in its worktree's server,
/// while it is unparked or its park is in flight; a parked one with no park in
/// flight names none. The probe is injected and switchable, so no test asks a
/// real socket.
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

    /// Everything a refusal must say and leave: the code, the advice naming
    /// `server`, a not-eligible outcome, no spawn, no row, the marks as they
    /// were, and the probe asked about `server` alone.
    private func expectRefused(
        _ response: RPCResponse, _ f: Fixture, terminalsBefore: [Terminal],
        server: String = "tbd-acme", marks: [String] = ["tbd-acme"],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        #expect(!response.success, sourceLocation: sourceLocation)
        #expect(response.errorCode == RPCErrorCode.terminalOnTmux.rawValue,
                sourceLocation: sourceLocation)
        #expect(response.error == LeftoverTmuxSession.resumeRefusal(server: server),
                sourceLocation: sourceLocation)
        let outcome = try f.lastOutcome()
        #expect(outcome.result == .synchronous(.refused), sourceLocation: sourceLocation)
        #expect(outcome.reason == .notEligible, sourceLocation: sourceLocation)
        #expect(f.holder.launches.isEmpty, sourceLocation: sourceLocation)
        #expect(try await f.db.terminals.list(worktreeID: f.worktree.id) == terminalsBefore,
                sourceLocation: sourceLocation)
        #expect(try await f.db.terminalHistory.liveOnTmuxServers(sessionIDs: [Self.sessionID])
            == marks, sourceLocation: sourceLocation)
        #expect(f.probe.servers == [server], sourceLocation: sourceLocation)
    }

    /// How a seeded tmux row stands.
    enum TmuxRowState {
        /// Unparked, its tab showing that the session is still on tmux.
        case unparked
        /// Parked, with no park in flight: its session ended.
        case parked
        /// Parked with the park still in flight (`pendingSessionIncarnationID`
        /// set), the way an earlier build's tmux hibernate left a row whose
        /// respawn failed after it had signalled the agent.
        case parkInFlight
    }

    /// A tmux Claude row on `sessionID` in `worktree`, left open in `state`.
    /// With `nullTransport` its transport is NULL, as most rows written before
    /// the transport column read.
    private func openATmuxRow(
        _ f: Fixture, in worktree: Worktree, state: TmuxRowState = .unparked,
        nullTransport: Bool = false
    ) async throws -> Terminal {
        let row = try await f.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: TerminalLabel.claudeCode, claudeSessionID: Self.sessionID, kind: .claude,
            transport: .tmux)
        switch state {
        case .unparked:
            break
        case .parked:
            try await f.db.terminals.setHibernated(id: row.id, sessionID: Self.sessionID, reason: .auto)
        case .parkInFlight:
            let live = try #require(try await f.db.terminals.get(id: row.id))
            _ = try #require(try await f.db.terminals.beginHibernatedShellRespawn(
                id: row.id, expectedState: TerminalHibernationSnapshot(terminal: live),
                reason: .auto))
        }
        if nullTransport {
            try await f.db.writerForTests.write { db in
                try db.execute(
                    sql: "UPDATE terminal SET transport = NULL WHERE id = ?",
                    arguments: [row.id.uuidString])
            }
        }
        return try #require(try await f.db.terminals.get(id: row.id))
    }

    /// A second worktree of the fixture's repo, on a tmux server of its own.
    private func otherWorktree(_ f: Fixture) async throws -> Worktree {
        let repoID = try #require(f.worktree.repoID)
        let path = f.root.appendingPathComponent("other").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return try await f.db.worktrees.create(
            repoID: repoID, name: "acme-other", branch: "other", path: path,
            tmuxServer: "tbd-acme-other")
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

    // MARK: - An unparked tmux row on the session

    /// The History pane's Resume of the session a tmux tab in the same
    /// worktree still shows: the gate reads the open row as it reads a mark,
    /// probing the worktree's server, and leaves the row alone.
    @Test func sessionResumeWaitsWhileAnOpenTmuxRowCarriesTheSession() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let row = try await openATmuxRow(f, in: f.worktree)
        let params = SessionResumeParams(worktreeID: f.worktree.id, identity: identity)

        let refused = try await f.send(RPCMethod.sessionResume, params)
        try await expectRefused(refused, f, terminalsBefore: [row], marks: [])

        f.server.state = .absent
        let resumed = try await f.send(RPCMethod.sessionResume, params)
        #expect(resumed.success, "error: \(resumed.error ?? "nil")")
        let terminal = try resumed.decodeResult(Terminal.self)
        #expect(terminal.transport == .holder)
        let command = try #require(f.holder.launch(for: terminal.id)?.commandLine)
        #expect(command.contains("--resume \(Self.sessionID)"))
        #expect(try await f.db.terminals.get(id: row.id) == row)
    }

    /// `terminal.create` resuming the session, while a tmux row in another
    /// worktree carries it: the gate looks in every worktree, and the server
    /// it asks about is that row's worktree's.
    @Test func terminalCreateResumingWaitsWhileATmuxRowInAnotherWorktreeCarriesTheSession() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let other = try await otherWorktree(f)
        let row = try await openATmuxRow(f, in: other)
        let params = TerminalCreateParams(
            worktreeID: f.worktree.id, type: .claude, resumeSessionID: Self.sessionID)

        let refused = try await f.send(RPCMethod.terminalCreate, params)
        try await expectRefused(
            refused, f, terminalsBefore: [], server: "tbd-acme-other", marks: [])
        #expect(try await f.db.terminals.list(worktreeID: other.id) == [row])

        f.server.state = .absent
        let created = try await f.send(RPCMethod.terminalCreate, params)
        #expect(created.success, "error: \(created.error ?? "nil")")
        let terminal = try created.decodeResult(Terminal.self)
        #expect(terminal.transport == .holder)
        #expect(terminal.claudeSessionID == Self.sessionID)
        let command = try #require(f.holder.launch(for: terminal.id)?.commandLine)
        #expect(command.contains("--resume \(Self.sessionID)"))
        #expect(try await f.db.terminals.get(id: row.id) == row)
    }

    /// A parked tmux row with no park in flight ended its session when it was
    /// parked, so it is no reason to ask. The probe answers `.running`: a start
    /// that asked it would be refused.
    @Test func aParkedTmuxRowOnTheSessionIsNotProbed() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        _ = try await openATmuxRow(f, in: f.worktree, state: .parked)

        let resumed = try await f.send(
            RPCMethod.sessionResume,
            SessionResumeParams(worktreeID: f.worktree.id, identity: identity))
        #expect(resumed.success, "error: \(resumed.error ?? "nil")")
        let created = try await f.send(RPCMethod.terminalCreate, TerminalCreateParams(
            worktreeID: f.worktree.id, type: .claude, resumeSessionID: Self.sessionID))
        #expect(created.success, "error: \(created.error ?? "nil")")

        #expect(f.probe.servers.isEmpty, "a parked tmux row's server was probed: \(f.probe.servers)")
        #expect(f.holder.launches.count == 2)
    }

    /// A tmux row parked with its park still in flight may still be running
    /// its agent, so the gate reads it as it reads an unparked row: probed,
    /// and refused while the server may run.
    @Test func sessionResumeWaitsWhileATmuxRowsParkIsInFlight() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let row = try await openATmuxRow(f, in: f.worktree, state: .parkInFlight)
        #expect(row.isParked)
        #expect(row.pendingSessionIncarnationID != nil)
        let params = SessionResumeParams(worktreeID: f.worktree.id, identity: identity)

        let refused = try await f.send(RPCMethod.sessionResume, params)
        try await expectRefused(refused, f, terminalsBefore: [row], marks: [])

        f.server.state = .absent
        let resumed = try await f.send(RPCMethod.sessionResume, params)
        #expect(resumed.success, "error: \(resumed.error ?? "nil")")
    }

    /// A row whose transport is NULL, as most rows written before the
    /// transport column read, is on tmux to the gate just as `'tmux'` is.
    @Test func terminalCreateResumingWaitsWhileATmuxRowWithANullTransportCarriesTheSession() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let row = try await openATmuxRow(f, in: f.worktree, nullTransport: true)
        let transportIsNull = try await f.db.writerForTests.read { db in
            try Bool.fetchOne(
                db, sql: "SELECT transport IS NULL FROM terminal WHERE id = ?",
                arguments: [row.id.uuidString])
        }
        #expect(transportIsNull == true)

        let refused = try await f.send(RPCMethod.terminalCreate, TerminalCreateParams(
            worktreeID: f.worktree.id, type: .claude, resumeSessionID: Self.sessionID))
        try await expectRefused(refused, f, terminalsBefore: [row], marks: [])
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
