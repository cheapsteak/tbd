import Foundation
import GRDB
import DaemonTestSupport
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The resume gate keyed by session id (`TmuxResumeGate`), through the
/// lifecycle: every live tmux row TBD deletes leaves a Closed Terminals entry
/// marked with its tmux server, and every start of that session on the pty
/// holder asks the probe about the server first — a revive, a revive with the
/// History pane's preferred session, a fresh-branch revive of a Codex thread,
/// and `spawnTerminal` itself. A spawn that forks the session asks nothing.
///
/// Each archived fixture is a real git worktree with a holder Claude tab,
/// spawned through the holder double, beside a seeded live tmux Claude row.
/// The probe is injected and records what it was asked, so no test runs tmux
/// or asks a real socket. The RPC answers are `TmuxResumeGateRPCTests`.
@Suite("Resume gate for sessions a closed tmux row carried")
struct TmuxResumeGateTests {
    struct Fixture {
        let tempDir: URL
        let db: TBDDatabase
        let repo: Repo
        let worktree: Worktree
        let holder: FakeHolderLaunch
        let probe: RecordingLeftoverTmuxProbe
        let lifecycle: WorktreeLifecycle
        /// The session id of the seeded tmux row.
        let tmuxSessionID: String

        func tearDown() {
            try? FileManager.default.removeItem(at: tempDir)
        }

        func archivedRow() async throws -> Worktree {
            try #require(try await db.worktrees.get(id: worktree.id))
        }

        /// The Closed Terminals entry of the seeded tmux row's session.
        func tmuxEntry() async throws -> TerminalHistoryEntry {
            try #require(try await db.terminalHistory.list(worktreeID: worktree.id)
                .first { $0.claudeSessionID == tmuxSessionID })
        }
    }

    /// An archived worktree whose tmux row was live, or parked when
    /// `tmuxRowParked`, at archive, with a probe that answers `serverState`.
    /// With `closedBeforeArchive` the tmux row's tab is closed first, the way
    /// `terminal.delete` closes it, so the archive's record has no tab for its
    /// session and only the Closed Terminals entry names it.
    func archivedFixture(
        serverState: LeftoverTmuxServerState, tmuxRowParked: Bool = false,
        closedBeforeArchive: Bool = false
    ) async throws -> Fixture {
        let (tempDir, repoDir) = try await createTestRepo()
        let db = try TBDDatabase(inMemory: true)
        let holder = FakeHolderLaunch()
        let probe = RecordingLeftoverTmuxProbe { _ in serverState }
        var lifecycle = makeLifecycle(db: db, holder: holder)
        lifecycle.leftoverTmuxProbe = probe.probe
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        let worktree = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)
        let tmuxSessionID = UUID().uuidString.lowercased()
        var tmuxRow = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@7", tmuxPaneID: "%7",
            label: "Claude Code", claudeSessionID: tmuxSessionID, kind: .claude,
            transport: .tmux)
        if tmuxRowParked {
            try await db.terminals.setSuspended(id: tmuxRow.id, sessionID: tmuxSessionID)
            tmuxRow = try #require(try await db.terminals.get(id: tmuxRow.id))
        }
        if closedBeforeArchive {
            try await WorktreeLifecycle.closeLeftoverTmuxRow(
                tmuxRow, server: worktree.tmuxServer, history: db.terminalHistory)
            try await db.terminals.delete(id: tmuxRow.id)
        }
        try await lifecycle.archiveWorktree(worktreeID: worktree.id, force: true)

        return Fixture(
            tempDir: tempDir, db: db, repo: repo, worktree: worktree, holder: holder,
            probe: probe, lifecycle: lifecycle, tmuxSessionID: tmuxSessionID)
    }

    // MARK: - The mark

    /// Archive keeps the tmux row's tab, so a revive brings it back on the
    /// holder, and marks its Closed Terminals entry with the worktree's
    /// server. Nothing else is marked, and nothing is probed.
    @Test func archiveMarksALiveTmuxRowsEntryAndKeepsItsTab() async throws {
        let fixture = try await archivedFixture(serverState: .running)
        defer { fixture.tearDown() }

        let tabs = try #require(try await fixture.archivedRow().archivedAgentTabs)
        #expect(tabs.contains { $0.identity.sessionID == fixture.tmuxSessionID })
        #expect(try await fixture.tmuxEntry().liveOnTmuxServer == fixture.worktree.tmuxServer)
        let others = try await fixture.db.terminalHistory.list(worktreeID: fixture.worktree.id)
            .filter { $0.claudeSessionID != fixture.tmuxSessionID }
        #expect(!others.isEmpty)
        #expect(others.allSatisfy { $0.liveOnTmuxServer == nil })
        #expect(fixture.probe.servers.isEmpty)
    }

    // MARK: - worktree.revive

    @Test func reviveRefusesWhileTheServerMayRunAndLeavesTheRecord() async throws {
        let fixture = try await archivedFixture(serverState: .running)
        defer { fixture.tearDown() }
        let before = try await fixture.archivedRow()
        let entriesBefore = try await fixture.db.terminalHistory.list(worktreeID: fixture.worktree.id)
        let launchesBefore = fixture.holder.launches.count

        await #expect(throws: TmuxResumeRefusal(server: fixture.worktree.tmuxServer)) {
            _ = try await fixture.lifecycle.reviveWorktree(
                worktreeID: fixture.worktree.id, skipClaude: false)
        }

        let after = try await fixture.archivedRow()
        #expect(after.status == .archived)
        #expect(after.archivedAgentTabs == before.archivedAgentTabs)
        #expect(after.archivedClaudeSessions == before.archivedClaudeSessions)
        #expect(try await fixture.db.terminalHistory.list(worktreeID: fixture.worktree.id)
            == entriesBefore)
        #expect(try await fixture.db.terminals.list(worktreeID: fixture.worktree.id).isEmpty)
        #expect(fixture.holder.launches.count == launchesBefore)
        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.localPath))
        #expect(fixture.probe.servers == [fixture.worktree.tmuxServer])
    }

    /// Once the server is gone every tab comes back on the holder. The probe
    /// is asked about the marked server only: before anything is written,
    /// and again by `spawnTerminal` for the tab that resumes the session.
    @Test func reviveRelaunchesOnTheHolderOnceTheServerIsGone() async throws {
        let fixture = try await archivedFixture(serverState: .absent)
        defer { fixture.tearDown() }

        let revived = try await fixture.lifecycle.reviveWorktree(
            worktreeID: fixture.worktree.id, skipClaude: false)

        let terminals = try await fixture.db.terminals.list(worktreeID: revived.id)
        let relaunched = try #require(terminals.first { $0.claudeSessionID == fixture.tmuxSessionID })
        #expect(relaunched.transport == .holder)
        #expect(fixture.holder.launches.contains { $0.terminalID == relaunched.id })
        #expect(terminals.allSatisfy { $0.transport == .holder })
        #expect(!fixture.probe.servers.isEmpty)
        #expect(fixture.probe.servers.allSatisfy { $0 == fixture.worktree.tmuxServer })
    }

    /// The probe answers `.running`, so a revive that asked it would refuse:
    /// the success proves it was not asked.
    @Test func aParkedTmuxRowsEntryIsUnmarkedAndRevivesWithoutTheProbe() async throws {
        let fixture = try await archivedFixture(serverState: .running, tmuxRowParked: true)
        defer { fixture.tearDown() }

        #expect(try await fixture.tmuxEntry().liveOnTmuxServer == nil)

        let revived = try await fixture.lifecycle.reviveWorktree(
            worktreeID: fixture.worktree.id, skipClaude: false)

        let terminals = try await fixture.db.terminals.list(worktreeID: revived.id)
        let relaunched = try #require(terminals.first { $0.claudeSessionID == fixture.tmuxSessionID })
        #expect(relaunched.transport == .holder)
        #expect(fixture.holder.launches.contains { $0.terminalID == relaunched.id })
        #expect(fixture.probe.servers.isEmpty)
    }

    /// A revive that skips the agent tabs relaunches none of them, so a marked
    /// session is no reason to ask, and the record stays for a later revive.
    @Test func aReviveThatSkipsTheAgentTabsAsksNothing() async throws {
        let fixture = try await archivedFixture(serverState: .running)
        defer { fixture.tearDown() }

        let revived = try await fixture.lifecycle.reviveWorktree(
            worktreeID: fixture.worktree.id, skipClaude: true)

        #expect(revived.status == .active)
        let terminals = try await fixture.db.terminals.list(worktreeID: revived.id)
        #expect(!terminals.contains { $0.claudeSessionID == fixture.tmuxSessionID })
        #expect(fixture.probe.servers.isEmpty)
    }

    /// The History pane's Resume on an archived worktree: a revive with a
    /// preferred session the archived tabs do not name, because its tab was
    /// closed before the archive. The gate asks by session id, so the closed
    /// tab's mark still refuses it.
    @Test func aReviveWithAPreferredSessionAClosedTmuxTabCarriedRefuses() async throws {
        let fixture = try await archivedFixture(serverState: .running, closedBeforeArchive: true)
        defer { fixture.tearDown() }
        let identity = AgentSessionIdentity(agentKind: .claude, sessionID: fixture.tmuxSessionID)
        let tabs = try await fixture.archivedRow().archivedAgentTabs ?? []
        #expect(!tabs.contains { $0.identity == identity })
        try await fixture.db.localAgentSessions.upsert(LocalAgentSession(
            worktreeID: fixture.worktree.id, identity: identity,
            firstObservedAt: .distantPast, lastObservedAt: .distantPast))
        let launchesBefore = fixture.holder.launches.count

        await #expect(throws: TmuxResumeRefusal(server: fixture.worktree.tmuxServer)) {
            _ = try await fixture.lifecycle.reviveWorktree(
                worktreeID: fixture.worktree.id, skipClaude: false, preferredSession: identity)
        }

        #expect(try await fixture.archivedRow().status == .archived)
        #expect(try await fixture.archivedRow().archivedAgentTabs ?? [] == tabs)
        #expect(fixture.holder.launches.count == launchesBefore)
        #expect(fixture.probe.servers == [fixture.worktree.tmuxServer])
    }

    // MARK: - Reconcile's archive

    /// Reconcile archives a worktree whose checkout is gone without recording
    /// archived tabs, but its live tmux row's entry is marked like any other
    /// close, so the History pane's Resume of that session afterwards — a
    /// revive with it as the preferred session — is refused.
    @Test func reconcilesArchiveOfAVanishedCheckoutMarksItsLiveTmuxRowAndAHistoryResumeRefuses() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let holder = FakeHolderLaunch()
        let probe = RecordingLeftoverTmuxProbe { _ in .running }
        var lifecycle = makeLifecycle(db: db, holder: holder)
        lifecycle.leftoverTmuxProbe = probe.probe
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "gone", branch: "gone-branch",
            path: tempDir.appendingPathComponent("vanished").path, tmuxServer: "tbd-acme-gone")
        let sessionID = UUID().uuidString.lowercased()
        _ = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Claude Code", claudeSessionID: sessionID, kind: .claude, transport: .tmux)

        try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog())

        let archived = try #require(try await db.worktrees.get(id: worktree.id))
        #expect(archived.status == .archived)
        let entry = try #require(try await db.terminalHistory.list(worktreeID: worktree.id).first)
        #expect(entry.claudeSessionID == sessionID)
        #expect(entry.liveOnTmuxServer == "tbd-acme-gone")

        let identity = AgentSessionIdentity(agentKind: .claude, sessionID: sessionID)
        try await db.localAgentSessions.upsert(LocalAgentSession(
            worktreeID: worktree.id, identity: identity,
            firstObservedAt: .distantPast, lastObservedAt: .distantPast))
        await #expect(throws: TmuxResumeRefusal(server: "tbd-acme-gone")) {
            _ = try await lifecycle.reviveWorktree(
                worktreeID: worktree.id, skipClaude: false, preferredSession: identity)
        }
        #expect(try await db.worktrees.get(id: worktree.id)?.status == .archived)
        #expect(holder.launches.isEmpty)
    }

    // MARK: - A mark that cannot be written

    /// An archive whose live tmux row's mark cannot be written is refused
    /// before it changes anything: the worktree stays active with its
    /// checkout and every row, nothing is recorded, and the open tmux row
    /// still names its session to the gate.
    @Test func anArchiveWhoseMarkCannotBeWrittenIsRefusedAndKeepsEveryRow() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let holder = FakeHolderLaunch()
        let probe = RecordingLeftoverTmuxProbe { _ in .running }
        var lifecycle = makeLifecycle(db: db, holder: holder)
        lifecycle.leftoverTmuxProbe = probe.probe
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let worktree = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)
        let sessionID = UUID().uuidString.lowercased()
        let created = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@7", tmuxPaneID: "%7",
            label: "Claude Code", claudeSessionID: sessionID, kind: .claude,
            transport: .tmux)
        let tmuxRow = try #require(try await db.terminals.get(id: created.id))
        let rowsBefore = Set(try await db.terminals.list(worktreeID: worktree.id).map(\.id))
        #expect(rowsBefore.count > 1, "the fixture has no holder tab beside the tmux row")
        try await db.failTerminalHistoryWritesForTests()

        await #expect(throws: LeftoverTmuxMarkUnwritable.self) {
            try await lifecycle.archiveWorktree(worktreeID: worktree.id, force: true)
        }

        #expect(try await db.worktrees.get(id: worktree.id)?.status != .archived)
        #expect(FileManager.default.fileExists(atPath: worktree.localPath))
        #expect(Set(try await db.terminals.list(worktreeID: worktree.id).map(\.id)) == rowsBefore)
        #expect(try await db.terminals.get(id: tmuxRow.id) == tmuxRow)
        #expect(try await db.terminalHistory.list(worktreeID: worktree.id).isEmpty)
        #expect(try await lifecycle.tmuxResumeRefusal(resuming: [sessionID])
            == TmuxResumeRefusal(server: worktree.tmuxServer))
    }

    /// Reconcile's archive leaves a worktree whose live tmux row's mark cannot
    /// be written for its next sweep, rows and all, and records the failure.
    /// The next sweep that can write the mark archives the worktree.
    @Test func reconcilesArchiveLeavesAWorktreeWhoseMarkCannotBeWrittenForTheNextSweep() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let probe = RecordingLeftoverTmuxProbe { _ in .running }
        var lifecycle = makeLifecycle(db: db, holder: FakeHolderLaunch())
        lifecycle.leftoverTmuxProbe = probe.probe
        let actuationPath = tempDir.appendingPathComponent("actuation/actuations.jsonl").path
        let actuationLog = ActuationLog(path: actuationPath)
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "gone", branch: "gone-branch",
            path: tempDir.appendingPathComponent("vanished").path, tmuxServer: "tbd-acme-gone")
        let sessionID = UUID().uuidString.lowercased()
        let tmuxRow = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Claude Code", claudeSessionID: sessionID, kind: .claude, transport: .tmux)
        try await db.failTerminalHistoryWritesForTests()

        try await lifecycle.reconcile(repoID: repo.id, actuationLog: actuationLog)

        #expect(try await db.worktrees.get(id: worktree.id)?.status != .archived)
        #expect(try await db.terminals.list(worktreeID: worktree.id).map(\.id) == [tmuxRow.id])
        #expect(try await db.terminalHistory.list(worktreeID: worktree.id).isEmpty)
        let outcomes = try ActuationRecordReader(activePath: actuationPath).readRows()
            .filter { $0.kind == .outcome }
        #expect(outcomes.contains { $0.result == .synchronous(.transportFailed) })
        #expect(try await lifecycle.tmuxResumeRefusal(resuming: [sessionID])
            == TmuxResumeRefusal(server: "tbd-acme-gone"))

        try await db.restoreTerminalHistoryWritesForTests()
        try await lifecycle.reconcile(repoID: repo.id, actuationLog: actuationLog)

        #expect(try await db.worktrees.get(id: worktree.id)?.status == .archived)
        #expect(try await db.terminals.list(worktreeID: worktree.id).isEmpty)
        let entry = try #require(try await db.terminalHistory.list(worktreeID: worktree.id).first)
        #expect(entry.liveOnTmuxServer == "tbd-acme-gone")
    }

    // MARK: - worktree.reviveConversationFresh

    /// A fresh-branch revive of a Codex thread resumes the thread itself, so
    /// it asks the same question, keyed by the thread id, before any new
    /// worktree exists. No archived tab names the thread: its tab was closed
    /// before the archive, and only its Closed Terminals entry carries the
    /// mark. A Claude conversation is carried over with `--fork-session` and
    /// asks nothing (`WorktreeReviveFreshTests`).
    @Test func aFreshBranchReviveOfACodexThreadAsksBySessionID() async throws {
        let fixture = try await archivedFixture(serverState: .running, closedBeforeArchive: true)
        defer { fixture.tearDown() }
        let identity = AgentSessionIdentity(agentKind: .codex, sessionID: fixture.tmuxSessionID)
        try await fixture.db.localAgentSessions.upsert(LocalAgentSession(
            worktreeID: fixture.worktree.id, identity: identity,
            firstObservedAt: .distantPast, lastObservedAt: .distantPast))
        let worktreesBefore = try await fixture.db.worktrees.list(repoID: fixture.repo.id).count

        await #expect(throws: TmuxResumeRefusal(server: fixture.worktree.tmuxServer)) {
            _ = try await fixture.lifecycle.reviveConversationOnFreshBranch(
                archivedWorktreeID: fixture.worktree.id, sessionID: fixture.tmuxSessionID,
                identity: identity)
        }

        #expect(try await fixture.db.worktrees.list(repoID: fixture.repo.id).count == worktreesBefore)
        #expect(fixture.probe.servers == [fixture.worktree.tmuxServer])
    }

    // MARK: - spawnTerminal

    /// The choke point every new row passes: a spawn naming a marked session
    /// starts nothing and writes no row while the server may run, and starts
    /// on the holder once it is gone. A fresh session id has no mark, so its
    /// spawn asks no probe, and a spawn that forks the marked session
    /// (`forksSession`) asks none either: it lands while the server may run.
    @Test func spawnTerminalAsksAboutTheSessionItNames() async throws {
        let (tempDir, _) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let holder = FakeHolderLaunch()
        final class StateBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: LeftoverTmuxServerState = .running
            var state: LeftoverTmuxServerState {
                get { lock.withLock { value } }
                set { lock.withLock { value = newValue } }
            }
        }
        let server = StateBox()
        let probe = RecordingLeftoverTmuxProbe { _ in server.state }
        var configured = makeLifecycle(db: db, holder: holder)
        configured.leftoverTmuxProbe = probe.probe
        let lifecycle = configured
        let repo = try await db.repos.create(
            path: tempDir.path, displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "tbd/wt", path: tempDir.path,
            tmuxServer: "tbd-acme")
        let marked = Terminal(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            claudeSessionID: "sess-marked", kind: .claude)
        try await db.terminalHistory.recordLiveTmuxClose(terminal: marked, server: "tbd-acme")
        let transport = try TerminalSpawnTransport.decide(registry: lifecycle.holderRegistry).get()
        func spawn(_ id: UUID, session: String, forks: Bool = false) async throws -> Terminal {
            try await lifecycle.spawnTerminal(
                id: id, worktreeID: worktree.id, workingDirectory: tempDir.path,
                command: "claude --resume \(session)\(forks ? " --fork-session" : "")",
                env: [:], sensitiveEnv: [:],
                cols: 80, rows: 24, label: TerminalLabel.claudeCode,
                claudeSessionID: session, profileID: nil, kind: .claude,
                transport: transport, forksSession: forks)
        }

        let fresh = try await spawn(UUID(), session: UUID().uuidString.lowercased())
        #expect(probe.servers.isEmpty, "a fresh session id has no mark to ask about")
        #expect(holder.launches.map(\.terminalID) == [fresh.id])

        let refusedID = UUID()
        await #expect(throws: TmuxResumeRefusal(server: "tbd-acme")) {
            _ = try await spawn(refusedID, session: "sess-marked")
        }
        #expect(holder.launch(for: refusedID) == nil)
        #expect(try await db.terminals.get(id: refusedID) == nil)
        #expect(probe.servers == ["tbd-acme"])

        let forked = try await spawn(UUID(), session: "sess-marked", forks: true)
        #expect(forked.transport == .holder)
        #expect(holder.launch(for: forked.id) != nil)
        #expect(probe.servers == ["tbd-acme"], "a spawn that forks asked the gate")

        server.state = .absent
        let resumed = try await spawn(UUID(), session: "sess-marked")
        #expect(resumed.transport == .holder)
        #expect(holder.launch(for: resumed.id) != nil)
    }

    // MARK: - The refusal

    @Test func theRefusalCarriesTheTmuxCodeAndTheCommandThatEndsTheServer() {
        let refusal = TmuxResumeRefusal(server: "tbd-acme")
        #expect(refusal.coded.code == .terminalOnTmux)
        #expect(refusal.coded.text == refusal.message)
        #expect(refusal.message == LeftoverTmuxSession.resumeRefusal(server: "tbd-acme"))
        #expect(refusal.message.contains("tmux -L tbd-acme kill-server"))
        #expect(refusal.message.contains("restart the Mac"))
        #expect(refusal.message.hasSuffix("Then try again."))
    }
}

extension TBDDatabase {
    /// Makes every write to `terminal_history` fail, as a write to a full disk
    /// or a locked database does, so a test can show what a close does when
    /// the mark that guards a session cannot be written. SQLite aborts the
    /// statement from a trigger, so nothing in the daemon is substituted.
    func failTerminalHistoryWritesForTests() async throws {
        try await writerForTests.write { db in
            try db.execute(sql: """
                CREATE TRIGGER acme_history_insert_fails BEFORE INSERT ON terminal_history
                BEGIN SELECT RAISE(ABORT, 'acme history write failed'); END;
                CREATE TRIGGER acme_history_update_fails BEFORE UPDATE ON terminal_history
                BEGIN SELECT RAISE(ABORT, 'acme history write failed'); END;
                """)
        }
    }

    /// Undoes `failTerminalHistoryWritesForTests`.
    func restoreTerminalHistoryWritesForTests() async throws {
        try await writerForTests.write { db in
            try db.execute(sql: """
                DROP TRIGGER acme_history_insert_fails;
                DROP TRIGGER acme_history_update_fails;
                """)
        }
    }
}
