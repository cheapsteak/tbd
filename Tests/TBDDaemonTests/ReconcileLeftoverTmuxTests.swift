import Foundation
import DaemonTestSupport
import GRDB
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// A leftover-tmux probe that answers from a closure and records every server
/// it was asked about, so a test can say which servers a pass probed and how
/// often.
final class RecordingLeftoverTmuxProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    private let answer: @Sendable (String) -> LeftoverTmuxServerState

    init(answer: @escaping @Sendable (String) -> LeftoverTmuxServerState) {
        self.answer = answer
    }

    /// The probe to install as `WorktreeLifecycle.leftoverTmuxProbe`.
    var probe: LeftoverTmuxServerProbe {
        LeftoverTmuxServerProbe { [self] server in
            self.record(server)
            return self.answer(server)
        }
    }

    /// Every server asked about, in the order asked.
    var servers: [String] {
        lock.lock(); defer { lock.unlock() }
        return asked
    }

    private func record(_ server: String) {
        lock.lock(); defer { lock.unlock() }
        asked.append(server)
    }
}

/// What reconcile does with a live tmux row, now that TBD no longer drives
/// tmux: the only fact it acts on is the row's tmux server being positively
/// gone, read off the server's socket (`LeftoverTmuxServerProbe`). Gone, the
/// row takes the established park-or-delete fork; anything else leaves it
/// live, because its session may still be running where TBD cannot reach it.
///
/// Each fixture injects the probe, so no socket is asked.
@Suite("Reconcile and leftover tmux sessions")
struct ReconcileLeftoverTmuxTests {

    private func makeLifecycle(
        db: TBDDatabase, probe: RecordingLeftoverTmuxProbe
    ) -> WorktreeLifecycle {
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver(),
            leftoverTmuxProbe: probe.probe)
        return lifecycle
    }

    private func seedRepo(db: TBDDatabase, at repoPath: String) async throws -> (Repo, Worktree) {
        let repo = try await db.repos.create(
            path: repoPath, displayName: "acme", defaultBranch: "main")
        let main = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main", path: repoPath,
            tmuxServer: TmuxServerName.forRepoPath(repoPath))
        return (repo, main)
    }

    private func seedTerminals(
        db: TBDDatabase, worktree: Worktree
    ) async throws -> (claude: Terminal, shell: Terminal) {
        let claude = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-tmux", kind: .claude)
        let shell = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@2", tmuxPaneID: "%2", kind: .shell)
        return (claude, shell)
    }

    // MARK: - The terminal sweep

    @Test("a gone server parks the resumable row, keeping its session, and deletes the shell")
    func goneServerParksAndDeletes() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let probe = RecordingLeftoverTmuxProbe(answer: { _ in .absent })
        let lifecycle = makeLifecycle(db: db, probe: probe)
        let (repo, main) = try await seedRepo(db: db, at: repoDir.path)
        let rows = try await seedTerminals(db: db, worktree: main)

        try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog())

        let claude = try #require(try await db.terminals.get(id: rows.claude.id),
                                  "a resumable row must be parked, not deleted")
        #expect(claude.isParked)
        #expect(claude.hibernateReason == .recovery)
        #expect(claude.claudeSessionID == "sess-tmux")
        #expect(claude.transport == .tmux, "reconcile parks; the migration moves the row")
        #expect(try await db.terminals.get(id: rows.shell.id) == nil,
                "a shell with nothing to resume must be deleted")
        #expect(probe.servers == [main.tmuxServer])
    }

    @Test("a server that may still be running leaves every row on it untouched")
    func runningServerLeavesRowsAlone() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let probe = RecordingLeftoverTmuxProbe(answer: { _ in .running })
        let lifecycle = makeLifecycle(db: db, probe: probe)
        let (repo, main) = try await seedRepo(db: db, at: repoDir.path)
        let rows = try await seedTerminals(db: db, worktree: main)
        let claudeBefore = try #require(try await db.terminals.get(id: rows.claude.id))
        let shellBefore = try #require(try await db.terminals.get(id: rows.shell.id))

        try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog())

        #expect(try await db.terminals.get(id: rows.claude.id) == claudeBefore)
        #expect(try await db.terminals.get(id: rows.shell.id) == shellBefore)
        #expect(probe.servers == [main.tmuxServer])
    }

    /// Rows overwhelmingly share one server, so the pass asks each server name
    /// once, however many rows and worktrees name it.
    @Test("the probe is asked once per server name")
    func probeIsAskedOncePerServer() async throws {
        let db = try TBDDatabase(inMemory: true)
        let probe = RecordingLeftoverTmuxProbe(answer: { _ in .running })
        let lifecycle = makeLifecycle(db: db, probe: probe)
        let first = try await db.worktrees.createScratch(
            name: "acme-one", displayName: "Acme One",
            path: "/tmp/acme-one", tmuxServer: "tbd-acme-shared")
        let second = try await db.worktrees.createScratch(
            name: "acme-two", displayName: "Acme Two",
            path: "/tmp/acme-two", tmuxServer: "tbd-acme-shared")
        let third = try await db.worktrees.createScratch(
            name: "acme-three", displayName: "Acme Three",
            path: "/tmp/acme-three", tmuxServer: "tbd-acme-other")
        for (index, worktree) in [first, first, second, third].enumerated() {
            _ = try await db.terminals.create(
                worktreeID: worktree.id, tmuxWindowID: "@\(index)", tmuxPaneID: "%\(index)",
                kind: .shell)
        }

        try await lifecycle.reconcileScratchTerminals(actuationLog: makeTestActuationLog())

        #expect(probe.servers.sorted() == ["tbd-acme-other", "tbd-acme-shared"])
    }

    /// A parked row has no process to reach, and is already what the pass
    /// would produce, so its server is never asked about.
    @Test("a parked tmux row is never probed")
    func parkedRowIsNeverProbed() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let probe = RecordingLeftoverTmuxProbe(answer: { _ in .absent })
        let lifecycle = makeLifecycle(db: db, probe: probe)
        let (repo, main) = try await seedRepo(db: db, at: repoDir.path)
        let parked = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-parked", kind: .claude)
        try await db.terminals.setHibernated(id: parked.id, sessionID: "sess-parked")
        let before = try #require(try await db.terminals.get(id: parked.id))

        try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog())

        #expect(probe.servers.isEmpty, "a parked row was probed: \(probe.servers)")
        #expect(try await db.terminals.get(id: parked.id) == before)
    }

    /// A shell tab an earlier build exit-stamped, whose server is gone, leaves
    /// in one startup.
    ///
    /// Step 8d lifts the stamp (`HibernationCoordinator.reconcileOnStartup`,
    /// `liftEarlierBuildsExitStamp`), and `performStartupReconciliation`, which
    /// skips every parked row, then sees an unparked shell row on a gone server
    /// and deletes it — there is no session it may preserve, whatever id the
    /// row carries. Run in the other order, or without the lift, the row stays
    /// parked behind a snapshot no wake will resume.
    @Test("a shell tab an earlier build exit-stamped on a gone server is removed in one startup")
    func liftedShellStampOnAGoneServerIsRemovedInOneStartup() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let tmux = TmuxManager(dryRun: true)
        let probe = RecordingLeftoverTmuxProbe(answer: { _ in .absent })
        let lifecycle = makeLifecycle(db: db, probe: probe)
        let (repo, main) = try await seedRepo(db: db, at: repoDir.path)
        let shell = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            claudeSessionID: "sess-hand-started", kind: .shell)
        // This build's `stampSessionExited` refuses a shell tab, so the earlier
        // build's stamp is written the way any park is.
        try await db.terminals.setHibernated(
            id: shell.id, sessionID: "sess-hand-started", reason: .exited)

        let coordinator = HibernationCoordinator(
            db: db, tmux: tmux,
            configDirManager: makeIsolatedConfigDirManager(tag: "reconcile-lift"),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)
        await coordinator.reconcileOnStartup()
        try await lifecycle.reconcile(
            repoID: repo.id,
            actuationLog: makeTestActuationLog())

        #expect(try await db.terminals.get(id: shell.id) == nil,
                "a lifted shell tab on a gone server survived the startup that lifted it")
    }

    // MARK: - The shared park

    @Test("parkLeftoverTmuxRow parks a live resumable tmux row and reports it parked")
    func parkLeftoverParksALiveResumableRow() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(
            db: db, probe: RecordingLeftoverTmuxProbe(answer: { _ in .absent }))
        let (_, main) = try await seedRepo(db: db, at: repoDir.path)
        let rows = try await seedTerminals(db: db, worktree: main)
        let claudeBefore = try #require(try await db.terminals.get(id: rows.claude.id))

        guard case .parked(let row) = try await lifecycle.parkLeftoverTmuxRow(claudeBefore) else {
            Issue.record("the row was not parked")
            return
        }
        let parked = try #require(row)

        #expect(parked.id == rows.claude.id)
        #expect(parked.isParked)
        #expect(parked.hibernateReason == .recovery)
        #expect(parked.claudeSessionID == "sess-tmux")
        #expect(parked.pendingSessionIncarnationID == nil, "the park must finish, not stay in flight")
        #expect(parked.transport == .tmux)
        #expect(try await db.terminals.get(id: rows.claude.id) == parked)
    }

    /// Left alone, and the row untouched, for every row the park must not
    /// take: a holder row, a row already parked, and a row with nothing to
    /// resume.
    @Test("parkLeftoverTmuxRow refuses a holder row, a parked row and a row with nothing to resume")
    func parkLeftoverRefusesOtherRows() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(
            db: db, probe: RecordingLeftoverTmuxProbe(answer: { _ in .absent }))
        let (_, main) = try await seedRepo(db: db, at: repoDir.path)
        let rows = try await seedTerminals(db: db, worktree: main)
        let holder = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-holder", kind: .claude,
            transport: .holder)
        let alreadyParked = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "@3", tmuxPaneID: "%3",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-parked", kind: .claude)
        try await db.terminals.setHibernated(id: alreadyParked.id, sessionID: "sess-parked")
        let holderBefore = try #require(try await db.terminals.get(id: holder.id))
        let parkedBefore = try #require(try await db.terminals.get(id: alreadyParked.id))
        let shellBefore = try #require(try await db.terminals.get(id: rows.shell.id))

        #expect(try await lifecycle.parkLeftoverTmuxRow(holderBefore) == .leftAlone)
        #expect(try await db.terminals.get(id: holder.id) == holderBefore)
        #expect(try await lifecycle.parkLeftoverTmuxRow(parkedBefore) == .leftAlone)
        #expect(try await db.terminals.get(id: alreadyParked.id) == parkedBefore)
        #expect(try await lifecycle.parkLeftoverTmuxRow(shellBefore) == .leftAlone)
        #expect(try await db.terminals.get(id: rows.shell.id) == shellBefore)
    }

    /// A row that changed after the caller read it is left as it is: the park
    /// is a compare-and-set against the row as read.
    @Test("parkLeftoverTmuxRow leaves a row that changed since it was read")
    func parkLeftoverLosesTheRaceToAChangedRow() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(
            db: db, probe: RecordingLeftoverTmuxProbe(answer: { _ in .absent }))
        let (_, main) = try await seedRepo(db: db, at: repoDir.path)
        let rows = try await seedTerminals(db: db, worktree: main)
        let asRead = try #require(try await db.terminals.get(id: rows.claude.id))
        // Parked under the caller after it read the row.
        try await db.terminals.setHibernated(id: rows.claude.id, sessionID: "sess-tmux")
        let changed = try #require(try await db.terminals.get(id: rows.claude.id))

        #expect(try await lifecycle.parkLeftoverTmuxRow(asRead) == .leftAlone)
        #expect(try await db.terminals.get(id: rows.claude.id) == changed)
    }

    /// A tab closed after the caller read it is an ordinary race, not a
    /// failure: the park reports it closed and throws nothing.
    @Test("parkLeftoverTmuxRow reports a row closed since it was read as closed, without throwing")
    func parkLeftoverReportsAClosedRow() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(
            db: db, probe: RecordingLeftoverTmuxProbe(answer: { _ in .absent }))
        let (_, main) = try await seedRepo(db: db, at: repoDir.path)
        let rows = try await seedTerminals(db: db, worktree: main)
        let asRead = try #require(try await db.terminals.get(id: rows.claude.id))
        try await db.terminals.delete(id: rows.claude.id)

        #expect(try await lifecycle.parkLeftoverTmuxRow(asRead) == .closed)
        #expect(try await db.terminals.get(id: rows.claude.id) == nil)
    }

    /// A park whose two halves straddle `between`, run on the row's id once
    /// the park is written and before its fence. Returns the outcome and the
    /// row as it reads afterwards.
    private func parkAcrossAnInterlude(
        _ between: @escaping @Sendable (TBDDatabase, UUID) async -> Void
    ) async throws -> (LeftoverTmuxParkOutcome, Terminal?) {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        var lifecycle = makeLifecycle(
            db: db, probe: RecordingLeftoverTmuxProbe(answer: { _ in .absent }))
        lifecycle.leftoverParkBetweenHalvesForTesting = { id in await between(db, id) }
        let (_, main) = try await seedRepo(db: db, at: repoDir.path)
        let rows = try await seedTerminals(db: db, worktree: main)
        let asRead = try #require(try await db.terminals.get(id: rows.claude.id))

        let outcome = try await lifecycle.parkLeftoverTmuxRow(asRead)
        return (outcome, try await db.terminals.get(id: rows.claude.id))
    }

    /// A wake between the halves clears the pending incarnation the fence
    /// expects, so the fence finds nothing to finish: the park was written,
    /// and the wake decides what the row is now.
    @Test("a park whose row is woken between its halves is superseded, and the wake stands")
    func parkLeftoverWokenBetweenTheHalvesIsSuperseded() async throws {
        let (outcome, after) = try await parkAcrossAnInterlude { db, id in
            do {
                try await db.terminals.clearHibernated(id: id)
            } catch {
                Issue.record("the interlude's wake failed: \(error)")
            }
        }

        #expect(outcome == .superseded)
        let row = try #require(after)
        #expect(!row.isParked, "the park's fence overrode the wake")
    }

    /// A row unparked between the halves with its incarnation untouched makes
    /// the fence itself refuse ("not parked"); that is the same supersession,
    /// not a failure.
    @Test("a park whose row is unparked between its halves, incarnation kept, is superseded")
    func parkLeftoverUnparkedBetweenTheHalvesIsSuperseded() async throws {
        let (outcome, after) = try await parkAcrossAnInterlude { db, id in
            do {
                try await db.writerForTests.write { connection in
                    try connection.execute(
                        sql: "UPDATE terminal SET hibernatedAt = NULL, suspendedAt = NULL WHERE id = ?",
                        arguments: [id.uuidString])
                }
            } catch {
                Issue.record("the interlude's unpark failed: \(error)")
            }
        }

        #expect(outcome == .superseded)
        let row = try #require(after)
        #expect(!row.isParked)
    }

    @Test("a park whose row is closed between its halves is closed, without throwing")
    func parkLeftoverClosedBetweenTheHalvesIsClosed() async throws {
        let (outcome, after) = try await parkAcrossAnInterlude { db, id in
            do {
                try await db.terminals.delete(id: id)
            } catch {
                Issue.record("the interlude's close failed: \(error)")
            }
        }

        #expect(outcome == .closed)
        #expect(after == nil)
    }

    @Test("parkLeftoverTmuxRow reports a park it made as parked, with the row")
    func parkLeftoverReportsTheParkedRow() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(
            db: db, probe: RecordingLeftoverTmuxProbe(answer: { _ in .absent }))
        let (_, main) = try await seedRepo(db: db, at: repoDir.path)
        let rows = try await seedTerminals(db: db, worktree: main)
        let asRead = try #require(try await db.terminals.get(id: rows.claude.id))

        let outcome = try await lifecycle.parkLeftoverTmuxRow(asRead)

        let parked = try #require(try await db.terminals.get(id: rows.claude.id))
        #expect(parked.isParked)
        #expect(outcome == .parked(parked))
    }

    /// The pass reads a worktree's rows before it probes their server, so a
    /// `terminal.migrate` that lands while the probe runs leaves the pass
    /// holding a stale read of both rows. This probe makes that migrate land
    /// exactly there, then answers gone. An unconditional write would stamp a
    /// park on the agent now running on the holder, or delete the shell's row.
    @Test("a row that moved to the holder between the pass's read and its write is left alone")
    func aRowMovedToTheHolderMidPassIsLeftAlone() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let (repo, main) = try await seedRepo(db: db, at: repoDir.path)
        let rows = try await seedTerminals(db: db, worktree: main)
        let claudeID = rows.claude.id
        let shellID = rows.shell.id
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver(),
            leftoverTmuxProbe: LeftoverTmuxServerProbe { _ in
                await Self.migrateToHolder(db: db, claudeID: claudeID, shellID: shellID)
                return .absent
            })

        try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog())

        let claude = try #require(try await db.terminals.get(id: claudeID))
        #expect(claude.transport == .holder)
        #expect(!claude.isParked,
                "reconcile parked a session that was already running on the holder")
        let shell = try #require(try await db.terminals.get(id: shellID),
                                 "reconcile deleted a shell that was already running on the holder")
        #expect(shell.transport == .holder)
    }

    /// Move both seeded rows to the holder as `terminal.migrate` does once
    /// their tmux server is gone: the resumable row is parked, moved and
    /// woken; the shell is started again on the holder in one write. A row
    /// already on the holder is left alone, so a second call changes nothing.
    private static func migrateToHolder(db: TBDDatabase, claudeID: UUID, shellID: UUID) async {
        do {
            if let claude = try await db.terminals.get(id: claudeID), claude.transport == .tmux {
                try await db.terminals.setHibernated(
                    id: claudeID, sessionID: "sess-tmux", reason: .recovery)
                if let parked = try await db.terminals.get(id: claudeID) {
                    _ = try await db.terminals.setParkedTransport(
                        id: claudeID,
                        expectedState: TerminalReplacementSnapshot(terminal: parked),
                        transport: .holder)
                }
                try await db.terminals.clearHibernated(id: claudeID)
            }
            if let shell = try await db.terminals.get(id: shellID), shell.transport == .tmux {
                _ = try await db.terminals.moveRunningShellToHolder(
                    id: shellID,
                    expectedState: TerminalReplacementSnapshot(terminal: shell),
                    incarnationID: UUID(), holderPID: 4242, childPID: 4243, startedAt: Date())
            }
        } catch {
            Issue.record("the simulated migrate failed: \(error)")
        }
    }

    // MARK: - The sighting

    @Test("the sighting names the server the row's worktree stores and the probe's answer")
    func sightingNamesTheStoredServer() async throws {
        let db = try TBDDatabase(inMemory: true)
        let probe = RecordingLeftoverTmuxProbe(answer: { server in
            server == "tbd-acme-inherited" ? .running : .absent
        })
        let lifecycle = makeLifecycle(db: db, probe: probe)
        let scratch = try await db.worktrees.createScratch(
            name: "acme", displayName: "Acme",
            path: "/tmp/acme-sighting", tmuxServer: "tbd-acme-inherited")
        let terminal = try await db.terminals.create(
            worktreeID: scratch.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .shell)

        let sighting = await lifecycle.leftoverTmuxServerSighting(for: terminal)

        #expect(sighting == LeftoverTmuxServerSighting(
            server: "tbd-acme-inherited", state: .running))
        #expect(probe.servers == ["tbd-acme-inherited"])
    }
}
