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
    /// What the injected probe answers, switchable mid-test: `state` for
    /// every server, unless a server has an answer of its own, and after any
    /// queued answers, which are given first, one per probe, in order.
    final class ServerState: @unchecked Sendable {
        private let lock = NSLock()
        private var value: LeftoverTmuxServerState = .running
        private var perServer: [String: LeftoverTmuxServerState] = [:]
        private var queued: [LeftoverTmuxServerState] = []
        var state: LeftoverTmuxServerState {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }

        /// `server` answers `answer`, whatever `state` says.
        func set(_ answer: LeftoverTmuxServerState, for server: String) {
            lock.withLock { perServer[server] = answer }
        }

        /// The next probes answer `answers`, in order, whichever server they
        /// ask about.
        func queue(_ answers: [LeftoverTmuxServerState]) {
            lock.withLock { queued += answers }
        }

        func answer(for server: String) -> LeftoverTmuxServerState {
            lock.withLock {
                if !queued.isEmpty { return queued.removeFirst() }
                return perServer[server] ?? value
            }
        }
    }

    /// Counts the router's Codex home preparations.
    final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        func record() { lock.withLock { calls += 1 } }
        var count: Int { lock.withLock { calls } }
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
        /// Start admission, which records every request it is asked.
        let admission: StubAdmission
        /// Every preparation of the shared Codex home, which a Codex start
        /// writes before it spawns.
        let codexHomes: CallCounter

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
        let holder = FakeHolderLaunch()
        let registry = makeHolderRegistryDouble(launch: holder)
        let server = ServerState()
        let probe = RecordingLeftoverTmuxProbe { name in server.answer(for: name) }
        let codexHomes = CallCounter()
        let manager = ClaudeProfileConfigDirManager(
            baseDirectory: root.appendingPathComponent("profiles"),
            hostBaseDirectory: root.appendingPathComponent("claude"))
        var lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), hooks: HookResolver(),
            configDirManager: manager,
            codexExecutableResolver: CodexLaunchTestStub.executableResolver,
            codexHomeEnsurer: CodexLaunchTestStub.homeEnsurer,
            leftoverTmuxProbe: probe.probe)
        lifecycle.holderRegistry = registry
        let actuationPath = root.appendingPathComponent("actuations.jsonl").path
        let router = RPCRouter(
            db: db, lifecycle: lifecycle, configDirManager: manager,
            codexExecutableResolver: { "/usr/bin/true" },
            codexHomeEnsurer: {
                codexHomes.record()
                return root.appendingPathComponent("codex")
            },
            actuationLog: ActuationLog(path: actuationPath))
        router.holderRegistry = registry
        await router.hibernationCoordinator.setHolderRegistry(registry)
        await router.hibernationCoordinator.setLeftoverTmuxProbe(probe.probe)
        let admission = StubAdmission(.admit)
        router.startAdmission = admission
        try await db.config.setStartAdmissionEnabled(true)
        let repo = try await db.repos.create(
            path: root.path, displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "acme", branch: "main", path: root.path,
            tmuxServer: "tbd-acme")
        return Fixture(
            root: root, db: db, router: router, worktree: worktree, holder: holder,
            server: server, probe: probe, actuationPath: actuationPath,
            admission: admission, codexHomes: codexHomes)
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
    /// were, and the probe asked about `probed`, by default `server` alone.
    /// With `probed` empty, only that `server` was the last asked.
    private func expectRefused(
        _ response: RPCResponse, _ f: Fixture, terminalsBefore: [Terminal],
        server: String = "tbd-acme", marks: [String] = ["tbd-acme"],
        probed: [String]? = nil,
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
        if probed?.isEmpty == true {
            #expect(f.probe.servers.last == server, sourceLocation: sourceLocation)
        } else {
            #expect(f.probe.servers == (probed ?? [server]), sourceLocation: sourceLocation)
        }
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

    /// A tmux row of `kind`, by default Claude, on `sessionID` in `worktree`,
    /// left open in `state`. With `nullTransport` its transport is NULL, as
    /// most rows written before the transport column read.
    private func openATmuxRow(
        _ f: Fixture, in worktree: Worktree, state: TmuxRowState = .unparked,
        nullTransport: Bool = false, kind: TerminalKind = .claude
    ) async throws -> Terminal {
        let row = try await f.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: kind == .claude ? TerminalLabel.claudeCode : nil,
            claudeSessionID: Self.sessionID, kind: kind, transport: .tmux)
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
    /// parked, so it is no reason to ask. The same row, unparked, is refused
    /// first, so the row and the session are ones the gate does read; once it
    /// is parked, both starts go ahead with no further probe, though the probe
    /// still answers `.running`.
    @Test func aParkedTmuxRowOnTheSessionIsNotProbed() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let row = try await openATmuxRow(f, in: f.worktree)
        let params = SessionResumeParams(worktreeID: f.worktree.id, identity: identity)

        let refused = try await f.send(RPCMethod.sessionResume, params)
        try await expectRefused(refused, f, terminalsBefore: [row], marks: [])

        try await f.db.terminals.setHibernated(id: row.id, sessionID: Self.sessionID, reason: .auto)
        let parked = try #require(try await f.db.terminals.get(id: row.id))
        #expect(parked.isParked)
        #expect(parked.pendingSessionIncarnationID == nil)

        let resumed = try await f.send(RPCMethod.sessionResume, params)
        #expect(resumed.success, "error: \(resumed.error ?? "nil")")
        let created = try await f.send(RPCMethod.terminalCreate, TerminalCreateParams(
            worktreeID: f.worktree.id, type: .claude, resumeSessionID: Self.sessionID))
        #expect(created.success, "error: \(created.error ?? "nil")")

        #expect(f.probe.servers == ["tbd-acme"],
                "a parked tmux row's server was probed again: \(f.probe.servers)")
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

    /// Closing a tmux row whose park is in flight closes it as a live row:
    /// its agent may still be running, so its Closed Terminals entry is marked
    /// with the server rather than written from the park, and a resume of its
    /// session afterwards waits for the server although no row names it.
    @Test func closingATmuxRowWhoseParkIsInFlightMarksItsEntry() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let row = try await openATmuxRow(f, in: f.worktree, state: .parkInFlight)

        let deleted = try await f.send(
            RPCMethod.terminalDelete, TerminalDeleteParams(terminalID: row.id))
        #expect(deleted.success, "error: \(deleted.error ?? "nil")")
        let entry = try #require(try await f.db.terminalHistory.list(worktreeID: f.worktree.id)
            .first { $0.id == row.id })
        #expect(entry.liveOnTmuxServer == "tbd-acme")
        #expect(try await f.db.terminals.list(worktreeID: f.worktree.id).isEmpty)

        let refused = try await f.send(
            RPCMethod.sessionResume,
            SessionResumeParams(worktreeID: f.worktree.id, identity: identity))
        try await expectRefused(refused, f, terminalsBefore: [])
    }

    /// A close whose mark cannot be written keeps the row: the delete fails,
    /// says why and records the failure, nothing is written, and the open row
    /// keeps naming its session, so a resume of it is still refused while the
    /// server may run.
    @Test func aCloseWhoseMarkCannotBeWrittenKeepsTheRowAndTheResumeStaysRefused() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let row = try await openATmuxRow(f, in: f.worktree)
        try await f.db.failTerminalHistoryWritesForTests()

        let deleted = try await f.send(
            RPCMethod.terminalDelete, TerminalDeleteParams(terminalID: row.id))

        #expect(!deleted.success)
        #expect(deleted.error?.contains("Terminal \(row.id) was not closed") == true,
                "error: \(deleted.error ?? "nil")")
        #expect(try f.lastOutcome().result == .synchronous(.transportFailed))
        #expect(try await f.db.terminals.list(worktreeID: f.worktree.id) == [row])
        #expect(try await f.db.terminalHistory.list(worktreeID: f.worktree.id).isEmpty)

        let refused = try await f.send(
            RPCMethod.sessionResume,
            SessionResumeParams(worktreeID: f.worktree.id, identity: identity))
        try await expectRefused(refused, f, terminalsBefore: [row], marks: [])
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
        // The handler asks the gate ahead of start admission, so a refused
        // revive is never admitted, held or recorded as a start.
        #expect(f.admission.requests.isEmpty, "admission was asked: \(f.admission.requests)")
    }

    /// The gate the lifecycle asks again, after the handler's let the revive
    /// through and admission admitted it: the server came back between the
    /// two. The lifecycle asks its gate before it writes anything, so the
    /// person is told the same thing, with the same code, and the act is
    /// recorded as declined, as the handler's own refusal is.
    @Test func aRefusalTheLifecycleGateRaisesAfterAdmissionIsRecordedAsDeclined() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        try await archiveNamingTheMarkedSession(f)
        f.server.queue([.absent])

        let refused = try await f.send(
            RPCMethod.worktreeRevive, WorktreeReviveParams(worktreeID: f.worktree.id))

        #expect(!refused.success)
        #expect(refused.errorCode == RPCErrorCode.terminalOnTmux.rawValue)
        #expect(refused.error == LeftoverTmuxSession.resumeRefusal(server: "tbd-acme"))
        let outcome = try f.lastOutcome()
        #expect(outcome.result == .synchronous(.refused))
        #expect(outcome.reason == .notEligible)
        #expect(f.probe.servers == ["tbd-acme", "tbd-acme"])
        #expect(f.admission.requests.count == 1)
        #expect(f.holder.launches.isEmpty)
        #expect(try await f.db.worktrees.get(id: f.worktree.id)?.status == .archived)
    }

    /// A revive of a session that only a tmux row in another worktree carries:
    /// the revive asks about its own worktree's server, which is gone, and
    /// about that row's worktree's, which may run, and is refused naming the
    /// second.
    @Test func worktreeReviveWaitsWhileATmuxRowInAnotherWorktreeCarriesTheSession() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let other = try await otherWorktree(f)
        let row = try await openATmuxRow(f, in: other)
        try await f.db.worktrees.archive(id: f.worktree.id)
        try await f.db.worktrees.setArchivedAgentTabs(
            id: f.worktree.id,
            tabs: [ArchivedAgentTab(identity: identity, ordinal: 0, isPrimary: true)])
        f.server.set(.absent, for: "tbd-acme")

        let refused = try await f.send(
            RPCMethod.worktreeRevive, WorktreeReviveParams(worktreeID: f.worktree.id))

        try await expectRefused(
            refused, f, terminalsBefore: [], server: "tbd-acme-other", marks: [],
            probed: ["tbd-acme", "tbd-acme-other"])
        #expect(try await f.db.worktrees.get(id: f.worktree.id)?.status == .archived)
        #expect(try await f.db.terminals.list(worktreeID: other.id) == [row])
        #expect(f.admission.requests.isEmpty)
    }

    /// A fresh-branch revive of a Codex thread resumes the thread itself, so
    /// it asks the gate. A Claude conversation is carried over with
    /// `--fork-session` and asks nothing (`WorktreeReviveFreshTests`).
    @Test func reviveConversationFreshOfACodexThreadAnswersTheRefusalWithTheTmuxCode() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        try await archiveNamingTheMarkedSession(f)
        let codex = AgentSessionIdentity(agentKind: .codex, sessionID: Self.sessionID)
        try await f.db.localAgentSessions.upsert(LocalAgentSession(
            worktreeID: f.worktree.id, identity: codex,
            firstObservedAt: .distantPast, lastObservedAt: .distantPast))
        let repoID = try #require(f.worktree.repoID)
        let worktreesBefore = try await f.db.worktrees.list(repoID: repoID).map(\.id)

        let refused = try await f.send(
            RPCMethod.worktreeReviveConversationFresh,
            WorktreeReviveConversationFreshParams(
                archivedWorktreeID: f.worktree.id, sessionID: Self.sessionID, identity: codex))

        try await expectRefused(refused, f, terminalsBefore: [])
        #expect(try await f.db.worktrees.list(repoID: repoID).map(\.id) == worktreesBefore)
        #expect(f.admission.requests.isEmpty, "admission was asked: \(f.admission.requests)")
    }

    /// The same, with a Codex tmux row in another worktree carrying the thread
    /// and nothing marked: the archived worktree's own server is gone, the
    /// row's worktree's may run.
    @Test func reviveConversationFreshOfACodexThreadWaitsWhileATmuxRowInAnotherWorktreeCarriesIt() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let other = try await otherWorktree(f)
        let row = try await openATmuxRow(f, in: other, kind: .codex)
        let codex = AgentSessionIdentity(agentKind: .codex, sessionID: Self.sessionID)
        try await f.db.worktrees.archive(id: f.worktree.id)
        try await f.db.worktrees.setArchivedAgentTabs(
            id: f.worktree.id,
            tabs: [ArchivedAgentTab(identity: codex, ordinal: 0, isPrimary: true)])
        try await f.db.localAgentSessions.upsert(LocalAgentSession(
            worktreeID: f.worktree.id, identity: codex,
            firstObservedAt: .distantPast, lastObservedAt: .distantPast))
        f.server.set(.absent, for: "tbd-acme")
        let repoID = try #require(f.worktree.repoID)
        let worktreesBefore = try await f.db.worktrees.list(repoID: repoID).map(\.id)

        let refused = try await f.send(
            RPCMethod.worktreeReviveConversationFresh,
            WorktreeReviveConversationFreshParams(
                archivedWorktreeID: f.worktree.id, sessionID: Self.sessionID, identity: codex))

        try await expectRefused(
            refused, f, terminalsBefore: [], server: "tbd-acme-other", marks: [],
            probed: ["tbd-acme", "tbd-acme-other"])
        #expect(try await f.db.worktrees.list(repoID: repoID).map(\.id) == worktreesBefore)
        #expect(try await f.db.terminals.list(worktreeID: other.id) == [row])
        #expect(f.admission.requests.isEmpty)
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

    /// A wake of a parked holder row whose session a tmux row in another
    /// worktree still carries, with nothing marked: refused naming that row's
    /// worktree's server, and the row stays parked. The wake's own
    /// worktree's server is gone, and whether the wake also asks about it is
    /// not what this pins.
    @Test func aWakeWaitsWhileATmuxRowInAnotherWorktreeCarriesTheSession() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        f.server.set(.absent, for: "tbd-acme")
        let other = try await otherWorktree(f)
        let row = try await openATmuxRow(f, in: other)
        let created = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, claudeSessionID: Self.sessionID, kind: .claude,
            transport: .holder)
        try await f.db.terminals.setHibernated(id: created.id, sessionID: Self.sessionID, reason: .auto)
        let parked = try #require(try await f.db.terminals.get(id: created.id))

        let refused = try await f.send(
            RPCMethod.terminalResume, TerminalResumeParams(terminalID: parked.id))

        try await expectRefused(
            refused, f, terminalsBefore: [parked], server: "tbd-acme-other", marks: [],
            probed: [])
        #expect(try await f.db.terminals.get(id: parked.id)?.isParked == true)
        #expect(try await f.db.terminals.list(worktreeID: other.id) == [row])
    }

    // MARK: - Closed Terminals reopen

    /// A Closed Terminals entry a holder row's close wrote, unmarked, for
    /// `sessionID`: the row is gone, the entry stays.
    private func closedHolderEntry(_ f: Fixture) async throws -> TerminalHistoryEntry {
        let row = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, claudeSessionID: Self.sessionID, kind: .claude,
            transport: .holder)
        await f.db.terminalHistory.recordOnClose(terminal: row, capture: nil)
        try await f.db.terminals.delete(id: row.id)
        let entry = try #require(try await f.db.terminalHistory.list(worktreeID: f.worktree.id)
            .first { $0.id == row.id })
        #expect(entry.liveOnTmuxServer == nil)
        return entry
    }

    /// Closed Terminals' reopen of an unmarked entry whose session a tmux row
    /// in another worktree still carries: the gate's open-row lookup refuses
    /// it, naming that row's worktree's server.
    @Test func closedTerminalsReopenWaitsWhileATmuxRowInAnotherWorktreeCarriesTheSession() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let entry = try await closedHolderEntry(f)
        let other = try await otherWorktree(f)
        let row = try await openATmuxRow(f, in: other)
        let params = TerminalHistoryReviveParams(worktreeID: f.worktree.id, id: entry.id)

        let refused = try await f.send(RPCMethod.terminalHistoryRevive, params)
        try await expectRefused(
            refused, f, terminalsBefore: [], server: "tbd-acme-other", marks: [])
        #expect(try await f.db.terminals.list(worktreeID: other.id) == [row])

        f.server.state = .absent
        let reopened = try await f.send(RPCMethod.terminalHistoryRevive, params)
        #expect(reopened.success, "error: \(reopened.error ?? "nil")")
    }

    /// The entry of a parked tmux tab that is still open, as an archive
    /// refused after it closed that row leaves it, is not reopened: waking the
    /// tab afterwards would start the session a second time. The entry is
    /// unmarked and the gate does not read a parked row, so the gate alone
    /// would let the reopen through, though the probe answers `.running`. The
    /// refusal writes nothing. Once the tab is closed, the same reopen goes
    /// ahead.
    @Test func closedTerminalsReopenOfAnEntryWhoseParkedTmuxTabIsStillOpenIsRefused() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let row = try await openATmuxRow(f, in: f.worktree, state: .parked)
        await f.db.terminalHistory.recordOnClose(terminal: row, capture: row.suspendedSnapshot)
        let entry = try #require(try await f.db.terminalHistory.list(worktreeID: f.worktree.id)
            .first { $0.id == row.id })
        #expect(entry.liveOnTmuxServer == nil)
        let params = TerminalHistoryReviveParams(worktreeID: f.worktree.id, id: row.id)

        let refused = try await f.send(RPCMethod.terminalHistoryRevive, params)

        #expect(!refused.success)
        #expect(refused.error == "Terminal \(row.id) is still open, parked on tmux, and its "
            + "session comes back there when it is woken. Close that tab before "
            + "reopening it from Closed Terminals.")
        let outcome = try f.lastOutcome()
        #expect(outcome.result == .synchronous(.refused))
        #expect(outcome.reason == .notEligible)
        #expect(f.holder.launches.isEmpty)
        #expect(f.probe.servers.isEmpty)
        #expect(try await f.db.terminals.list(worktreeID: f.worktree.id) == [row])
        #expect(try await f.db.terminalHistory.list(worktreeID: f.worktree.id).map(\.id) == [row.id])
        #expect(f.admission.requests.isEmpty)

        try await f.db.terminals.delete(id: row.id)
        let reopened = try await f.send(RPCMethod.terminalHistoryRevive, params)
        #expect(reopened.success, "error: \(reopened.error ?? "nil")")
        #expect(f.holder.launches.count == 1)
        #expect(f.probe.servers.isEmpty)
    }

    /// A tab on the pty holder that still carries the entry's session —
    /// running it, or parked and resuming it when woken — is not joined by a
    /// second one: the reopen mints a new terminal, so nothing else would stop
    /// it starting beside that tab, and the gate reads only tmux rows and
    /// marks. The refusal writes nothing and asks no probe. Once that tab is
    /// closed, the same reopen goes ahead.
    @Test("Closed Terminals' reopen is refused while a holder tab carries the session",
          arguments: [false, true])
    func closedTerminalsReopenBesideAHolderTabCarryingTheSessionIsRefused(parked: Bool) async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let entry = try await closedHolderEntry(f)
        let created = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, claudeSessionID: Self.sessionID, kind: .claude,
            transport: .holder)
        if parked {
            try await f.db.terminals.setHibernated(id: created.id, sessionID: Self.sessionID, reason: .auto)
        }
        let carrier = try #require(try await f.db.terminals.get(id: created.id))
        let params = TerminalHistoryReviveParams(worktreeID: f.worktree.id, id: entry.id)

        let refused = try await f.send(RPCMethod.terminalHistoryRevive, params)

        #expect(!refused.success)
        #expect(refused.error == "Terminal \(carrier.id) is still open and carries this session, so "
            + "reopening it would run the session a second time. Use that tab, or close "
            + "it before reopening this entry from Closed Terminals.")
        let outcome = try f.lastOutcome()
        #expect(outcome.result == .synchronous(.refused))
        #expect(outcome.reason == .notEligible)
        #expect(f.holder.launches.isEmpty)
        #expect(f.probe.servers.isEmpty)
        #expect(f.admission.requests.isEmpty)
        #expect(try await f.db.terminals.list(worktreeID: f.worktree.id) == [carrier])

        try await f.db.terminals.delete(id: carrier.id)
        let reopened = try await f.send(RPCMethod.terminalHistoryRevive, params)
        #expect(reopened.success, "error: \(reopened.error ?? "nil")")
        #expect(f.holder.launches.count == 1)
    }

    /// A shell tab on the pty holder carries the session of a Claude started
    /// by hand in it, so the reopen is refused with that tab named as a shell.
    /// A `SessionEnd` naming another session leaves it carrying the session;
    /// once that Claude's own `SessionEnd` says it left, the tab forgets the
    /// id, stays open, and the same reopen goes ahead beside it.
    @Test func closedTerminalsReopenBesideAHolderShellGoesAheadOnceItsHandStartedSessionEnds() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let entry = try await closedHolderEntry(f)
        let created = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            claudeSessionID: Self.sessionID, kind: .shell, transport: .holder)
        // The row as stored, not as `create` returned it: the store keeps
        // `createdAt` to the millisecond, so the returned value can differ.
        let shell = try #require(try await f.db.terminals.get(id: created.id))
        let params = TerminalHistoryReviveParams(worktreeID: f.worktree.id, id: entry.id)

        let refused = try await f.send(RPCMethod.terminalHistoryRevive, params)
        #expect(!refused.success)
        #expect(refused.error == RPCRouter.handStartedCarrierRefusal(terminalID: shell.id))
        #expect(refused.error?.hasPrefix("A Claude started by hand in shell tab") == true)
        let outcome = try f.lastOutcome()
        #expect(outcome.result == .synchronous(.refused))
        #expect(outcome.reason == .notEligible)
        #expect(f.holder.launches.isEmpty)

        let earlier = try await f.send(
            RPCMethod.terminalSessionEnded,
            TerminalSessionEndedParams(terminalID: shell.id, reason: "exit", sessionID: "sess-acme-earlier"))
        #expect(earlier.success, "error: \(earlier.error ?? "nil")")
        let afterEarlier = try #require(try await f.db.terminals.get(id: shell.id))
        #expect(afterEarlier.claudeSessionID == Self.sessionID,
                "a report naming another session forgot the shell's session id")
        #expect(afterEarlier == shell, "a report naming another session changed the shell")
        let stillRefused = try await f.send(RPCMethod.terminalHistoryRevive, params)
        #expect(stillRefused.error == RPCRouter.handStartedCarrierRefusal(terminalID: shell.id))

        let ended = try await f.send(
            RPCMethod.terminalSessionEnded,
            TerminalSessionEndedParams(terminalID: shell.id, reason: "exit", sessionID: Self.sessionID))
        #expect(ended.success, "error: \(ended.error ?? "nil")")
        let after = try #require(try await f.db.terminals.get(id: shell.id))
        #expect(after.claudeSessionID == nil)
        #expect(!after.isParked)

        let reopened = try await f.send(RPCMethod.terminalHistoryRevive, params)
        #expect(reopened.success, "error: \(reopened.error ?? "nil")")
        #expect(f.holder.launches.count == 1)
        #expect(try await f.db.terminals.get(id: shell.id) != nil)
    }

    // MARK: - A session the worktree's archived record names

    /// An active worktree that still carries its archived record, as adopting
    /// an archived row's folder or a revive that has not finished leaves it,
    /// naming `sessionID`.
    private func keepAnArchivedRecordNamingTheSession(_ f: Fixture) async throws {
        try await f.db.worktrees.setArchivedAgentTabs(
            id: f.worktree.id,
            tabs: [ArchivedAgentTab(identity: identity, ordinal: 0, isPrimary: true)])
        #expect(try await f.db.worktrees.get(id: f.worktree.id)?.status != .archived)
    }

    /// `terminal.create` resuming a session the worktree's archived record
    /// names asks about the worktree's own server, though no row or mark
    /// names the session: an earlier build's archive could leave its agent
    /// running there. A session the record does not name asks nothing.
    @Test func terminalCreateResumingASessionTheArchivedRecordNamesAsksTheWorktreesServer() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        try await keepAnArchivedRecordNamingTheSession(f)

        let unnamed = try await f.send(RPCMethod.terminalCreate, TerminalCreateParams(
            worktreeID: f.worktree.id, type: .claude, resumeSessionID: "sess-acme-plain"))
        #expect(unnamed.success, "error: \(unnamed.error ?? "nil")")
        #expect(f.probe.servers.isEmpty, "an unnamed session's resume probed: \(f.probe.servers)")
        let launchesBefore = f.holder.launches.count
        let terminalsBefore = try await f.db.terminals.list(worktreeID: f.worktree.id)

        let params = TerminalCreateParams(
            worktreeID: f.worktree.id, type: .claude, resumeSessionID: Self.sessionID)
        let refused = try await f.send(RPCMethod.terminalCreate, params)
        #expect(!refused.success)
        #expect(refused.errorCode == RPCErrorCode.terminalOnTmux.rawValue)
        #expect(refused.error == LeftoverTmuxSession.resumeRefusal(server: "tbd-acme"))
        #expect(try f.lastOutcome().result == .synchronous(.refused))
        #expect(f.probe.servers == ["tbd-acme"])
        #expect(f.holder.launches.count == launchesBefore)
        #expect(try await f.db.terminals.list(worktreeID: f.worktree.id) == terminalsBefore)

        f.server.state = .absent
        let created = try await f.send(RPCMethod.terminalCreate, params)
        #expect(created.success, "error: \(created.error ?? "nil")")
    }

    /// Closed Terminals' reopen of an unmarked entry whose session the
    /// worktree's archived record names asks about the worktree's own server.
    @Test func closedTerminalsReopenOfASessionTheArchivedRecordNamesAsksTheWorktreesServer() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let entry = try await closedHolderEntry(f)
        try await keepAnArchivedRecordNamingTheSession(f)
        let params = TerminalHistoryReviveParams(worktreeID: f.worktree.id, id: entry.id)

        let refused = try await f.send(RPCMethod.terminalHistoryRevive, params)
        try await expectRefused(refused, f, terminalsBefore: [], marks: [])

        f.server.state = .absent
        let reopened = try await f.send(RPCMethod.terminalHistoryRevive, params)
        #expect(reopened.success, "error: \(reopened.error ?? "nil")")
    }

    // MARK: - A Codex resume

    /// A refused resume of a Codex thread writes nothing for it: the shared
    /// Codex home is prepared only once the gate has let the start through.
    @Test func aRefusedCodexResumePreparesNoCodexHome() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        _ = try await closeALiveTmuxRow(f)
        let codex = AgentSessionIdentity(agentKind: .codex, sessionID: Self.sessionID)
        try await f.db.localAgentSessions.upsert(LocalAgentSession(
            worktreeID: f.worktree.id, identity: codex,
            firstObservedAt: .distantPast, lastObservedAt: .distantPast))
        let params = SessionResumeParams(worktreeID: f.worktree.id, identity: codex)

        let refused = try await f.send(RPCMethod.sessionResume, params)
        try await expectRefused(refused, f, terminalsBefore: [])
        #expect(f.codexHomes.count == 0, "a refused resume prepared the Codex home")

        f.server.state = .absent
        let resumed = try await f.send(RPCMethod.sessionResume, params)
        #expect(resumed.success, "error: \(resumed.error ?? "nil")")
        #expect(f.codexHomes.count == 1)
    }

    // MARK: - A Claude started by hand in a tmux tab

    /// A shell tab on tmux whose hand-started Claude reported its session id
    /// carries that id, so the gate refuses a resume of it while the
    /// worktree's server may run. Once that Claude's `SessionEnd` says it
    /// left, the tab forgets the id, and the resume goes ahead without asking
    /// the probe again.
    @Test func aHandStartedSessionThatEndedInATmuxShellTabNoLongerHoldsTheGate() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let row = try await openATmuxRow(f, in: f.worktree, kind: .shell)
        let params = SessionResumeParams(worktreeID: f.worktree.id, identity: identity)

        let refused = try await f.send(RPCMethod.sessionResume, params)
        try await expectRefused(refused, f, terminalsBefore: [row], marks: [])

        let ended = try await f.send(
            RPCMethod.terminalSessionEnded,
            TerminalSessionEndedParams(terminalID: row.id, reason: "exit", sessionID: Self.sessionID))
        #expect(ended.success, "error: \(ended.error ?? "nil")")
        let after = try #require(try await f.db.terminals.get(id: row.id))
        #expect(after.claudeSessionID == nil)
        #expect(!after.isParked)

        let resumed = try await f.send(RPCMethod.sessionResume, params)
        #expect(resumed.success, "error: \(resumed.error ?? "nil")")
        #expect(f.probe.servers == ["tbd-acme"])
    }

    /// A shell can run one hand-started Claude after another under the same
    /// incarnation. A `SessionEnd` from an earlier one that arrives after a
    /// newer one recorded its id names the earlier session, so the tab keeps
    /// the newer id and the gate keeps refusing a second start of it.
    @Test func aLateSessionEndFromAnEarlierSessionKeepsHoldingTheGate() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let row = try await openATmuxRow(f, in: f.worktree, kind: .shell)

        let ended = try await f.send(
            RPCMethod.terminalSessionEnded,
            TerminalSessionEndedParams(terminalID: row.id, reason: "exit", sessionID: "sess-acme-earlier"))
        #expect(ended.success, "error: \(ended.error ?? "nil")")
        #expect(try await f.db.terminals.get(id: row.id) == row,
                "a report naming another session changed the tab")

        let refused = try await f.send(
            RPCMethod.sessionResume,
            SessionResumeParams(worktreeID: f.worktree.id, identity: identity))
        try await expectRefused(refused, f, terminalsBefore: [row], marks: [])
    }

    /// A `SessionEnd` that names no session, as an older `tbd` sends it, is
    /// judged by its incarnation alone: the tab forgets the id it carries,
    /// and the resume goes ahead without asking the probe again.
    @Test func aSessionEndNamingNoSessionForgetsTheTabsSessionByItsIncarnation() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let row = try await openATmuxRow(f, in: f.worktree, kind: .shell)
        let params = SessionResumeParams(worktreeID: f.worktree.id, identity: identity)

        let refused = try await f.send(RPCMethod.sessionResume, params)
        try await expectRefused(refused, f, terminalsBefore: [row], marks: [])

        let ended = try await f.send(
            RPCMethod.terminalSessionEnded,
            TerminalSessionEndedParams(terminalID: row.id, reason: "exit"))
        #expect(ended.success, "error: \(ended.error ?? "nil")")
        #expect(try await f.db.terminals.get(id: row.id)?.claudeSessionID == nil)

        let resumed = try await f.send(RPCMethod.sessionResume, params)
        #expect(resumed.success, "error: \(resumed.error ?? "nil")")
        #expect(f.probe.servers == ["tbd-acme"])
    }

    /// A `SessionEnd` whose reason is not a process exit (`clear`) leaves the
    /// hand-started Claude running, so the tab keeps its id and the gate keeps
    /// refusing.
    @Test func aHandStartedSessionThatClearedKeepsHoldingTheGate() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let row = try await openATmuxRow(f, in: f.worktree, kind: .shell)

        let ended = try await f.send(
            RPCMethod.terminalSessionEnded,
            TerminalSessionEndedParams(terminalID: row.id, reason: "clear"))
        #expect(ended.success, "error: \(ended.error ?? "nil")")
        #expect(try await f.db.terminals.get(id: row.id) == row)

        let refused = try await f.send(
            RPCMethod.sessionResume,
            SessionResumeParams(worktreeID: f.worktree.id, identity: identity))
        try await expectRefused(refused, f, terminalsBefore: [row], marks: [])
    }

    /// The store's guards: a tab that is not an agent's, on either transport,
    /// with the report's incarnation, forgets its id when the report names
    /// that session or names none. An agent tab, a stale incarnation and a
    /// report naming another session forget nothing.
    @Test func forgettingAnEndedHandStartedSessionSparesAgentTabsAndStaleReports() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let claudeTab = try await openATmuxRow(f, in: f.worktree)
        let codexTab = try await openATmuxRow(f, in: f.worktree, kind: .codex)
        let incarnation = UUID()

        for spared in [claudeTab, codexTab] {
            for named in [Self.sessionID, nil] as [String?] {
                let cleared = try await f.db.terminals.clearEndedHandStartedSession(
                    id: spared.id, reportedIncarnationID: nil, endedSessionID: named)
                #expect(!cleared, "agent tab \(spared.id) forgot its session id")
                #expect(try await f.db.terminals.get(id: spared.id)?.claudeSessionID == Self.sessionID)
            }
        }

        for transport in [TerminalTransport.tmux, .holder] {
            let named = try await handStartedShell(f, on: transport, incarnation: incarnation)
            for stale in [Self.sessionID, nil] as [String?] {
                let cleared = try await f.db.terminals.clearEndedHandStartedSession(
                    id: named.id, reportedIncarnationID: UUID(), endedSessionID: stale)
                #expect(!cleared, "a stale \(transport.rawValue) report forgot the tab's session id")
            }
            let other = try await f.db.terminals.clearEndedHandStartedSession(
                id: named.id, reportedIncarnationID: incarnation, endedSessionID: "sess-acme-earlier")
            #expect(!other, "a report naming another session forgot the \(transport.rawValue) tab's id")
            #expect(try await f.db.terminals.get(id: named.id)?.claudeSessionID == Self.sessionID)
            let current = try await f.db.terminals.clearEndedHandStartedSession(
                id: named.id, reportedIncarnationID: incarnation, endedSessionID: Self.sessionID)
            #expect(current, "the \(transport.rawValue) tab kept the session that ended")
            #expect(try await f.db.terminals.get(id: named.id)?.claudeSessionID == nil)
            let again = try await f.db.terminals.clearEndedHandStartedSession(
                id: named.id, reportedIncarnationID: incarnation, endedSessionID: nil)
            #expect(!again, "a tab carrying no session reported a change")

            for unnamed in ["", nil] as [String?] {
                let fallback = try await handStartedShell(f, on: transport, incarnation: incarnation)
                let cleared = try await f.db.terminals.clearEndedHandStartedSession(
                    id: fallback.id, reportedIncarnationID: incarnation, endedSessionID: unnamed)
                #expect(cleared, "a \(transport.rawValue) report naming no session kept the tab's id")
                #expect(try await f.db.terminals.get(id: fallback.id)?.claudeSessionID == nil)
            }
        }
    }

    /// A shell tab on `transport` carrying `sessionID` under `incarnation`,
    /// as a Claude started by hand in it leaves it.
    private func handStartedShell(
        _ f: Fixture, on transport: TerminalTransport, incarnation: UUID
    ) async throws -> Terminal {
        try await f.db.terminals.create(
            worktreeID: f.worktree.id,
            tmuxWindowID: transport == .tmux ? "@3" : "",
            tmuxPaneID: transport == .tmux ? "%3" : "",
            claudeSessionID: Self.sessionID, kind: .shell, transport: transport,
            sessionIncarnationID: incarnation)
    }

    // MARK: - Switching the account of a parked tmux row

    /// A cold account switch of a tmux row whose park is in flight is refused
    /// while its server may run, as moving it to the holder is: its agent may
    /// still be writing the transcript the switch would carry. Once the
    /// server is gone, the row is re-homed as any parked row.
    @Test func aColdSwitchOfATmuxRowWhoseParkIsInFlightWaitsForItsServer() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let row = try await openATmuxRow(f, in: f.worktree, state: .parkInFlight)
        let params = TerminalSwapProfileParams(terminalID: row.id, newProfileID: nil, mode: .inPlace)

        let refused = try await f.send(RPCMethod.terminalSwapProfile, params)

        #expect(!refused.success)
        #expect(refused.errorCode == RPCErrorCode.terminalOnTmux.rawValue)
        #expect(refused.error == LeftoverTmuxSession.stillRunningRefusal(
            terminalID: row.id, server: "tbd-acme"))
        #expect(f.probe.servers == ["tbd-acme"])
        #expect(try await f.db.terminals.get(id: row.id) == row)

        f.server.state = .absent
        let rehomed = try await f.send(RPCMethod.terminalSwapProfile, params)
        #expect(rehomed.success, "error: \(rehomed.error ?? "nil")")
        #expect(f.holder.launches.isEmpty)
    }

    /// A tmux row parked with no park in flight ended its session, so its
    /// cold switch asks no probe and goes ahead while the server may run.
    @Test func aColdSwitchOfAParkedTmuxRowAsksNoProbe() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let row = try await openATmuxRow(f, in: f.worktree, state: .parked)

        let rehomed = try await f.send(
            RPCMethod.terminalSwapProfile,
            TerminalSwapProfileParams(terminalID: row.id, newProfileID: nil, mode: .inPlace))

        #expect(rehomed.success, "error: \(rehomed.error ?? "nil")")
        #expect(f.probe.servers.isEmpty)
        #expect(f.holder.launches.isEmpty)
    }

    // MARK: - A pending auto-resume on a close that fails

    /// A tmux row's close that cannot write its mark keeps the row, and the
    /// row keeps its pending auto-resume; the close that succeeds cancels it.
    @Test func aCloseWhoseMarkCannotBeWrittenKeepsThePendingAutoResume() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let row = try await openATmuxRow(f, in: f.worktree)
        _ = try await f.db.scheduledResumes.insertPending(ScheduledResume(
            terminalID: row.id, worktreeID: f.worktree.id,
            resetsAt: Date(), fireAt: Date().addingTimeInterval(3600),
            limitType: "session", rawMessage: "m"))
        try await f.db.failTerminalHistoryWritesForTests()

        let failed = try await f.send(
            RPCMethod.terminalDelete, TerminalDeleteParams(terminalID: row.id))

        #expect(!failed.success)
        #expect(try await f.db.terminals.get(id: row.id) != nil)
        #expect(try await f.db.scheduledResumes.pending(terminalID: row.id) != nil,
                "a close that kept its row cancelled the row's auto-resume")

        try await f.db.restoreTerminalHistoryWritesForTests()
        let deleted = try await f.send(
            RPCMethod.terminalDelete, TerminalDeleteParams(terminalID: row.id))
        #expect(deleted.success, "error: \(deleted.error ?? "nil")")
        #expect(try await f.db.scheduledResumes.pending(terminalID: row.id) == nil)
    }

    /// A tmux row's close whose mark is written but whose delete fails keeps
    /// the row, and the row keeps its pending auto-resume: the close cancels
    /// it only once the delete has committed.
    @Test func aCloseWhoseDeleteFailsKeepsThePendingAutoResume() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let row = try await openATmuxRow(f, in: f.worktree)
        _ = try await f.db.scheduledResumes.insertPending(ScheduledResume(
            terminalID: row.id, worktreeID: f.worktree.id,
            resetsAt: Date(), fireAt: Date().addingTimeInterval(3600),
            limitType: "session", rawMessage: "m"))
        try await f.db.writerForTests.write { db in
            try db.execute(sql: """
                CREATE TRIGGER acme_reject_terminal_delete BEFORE DELETE ON terminal
                BEGIN SELECT RAISE(ABORT, 'acme terminal delete failed'); END
                """)
        }

        let failed = try await f.send(
            RPCMethod.terminalDelete, TerminalDeleteParams(terminalID: row.id))

        #expect(!failed.success)
        #expect(try await f.db.terminals.get(id: row.id) != nil)
        #expect(try await f.db.scheduledResumes.pending(terminalID: row.id) != nil,
                "a close whose delete failed cancelled the row's auto-resume")
        #expect(try f.lastOutcome().result == .synchronous(.transportFailed))

        try await f.db.writerForTests.write { db in
            try db.execute(sql: "DROP TRIGGER acme_reject_terminal_delete")
        }
        let deleted = try await f.send(
            RPCMethod.terminalDelete, TerminalDeleteParams(terminalID: row.id))
        #expect(deleted.success, "error: \(deleted.error ?? "nil")")
        #expect(try await f.db.terminals.get(id: row.id) == nil)
        #expect(try await f.db.scheduledResumes.pending(terminalID: row.id) == nil,
                "a close that deleted the row kept its auto-resume")
    }
}
