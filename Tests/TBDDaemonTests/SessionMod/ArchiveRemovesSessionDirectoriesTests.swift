import Foundation
import DaemonTestSupport
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TBDKernel

/// Every path that archives a worktree removes the session-mod directory of
/// each Claude session in it, draft included, once that session's process has
/// exited: the explicit archive, reconcile's archive of a vanished checkout,
/// and the scratch archive. The mod writes the box one last time on
/// `session.end`, so a removal ahead of the exit would be undone by that
/// write. A parked session has no process, so its directory goes at once. A
/// session the teardown left running keeps its directory for `OrphanGC`, and
/// a live row an earlier build left on tmux is one: closing it runs no tmux
/// command, so its session may still be running there.
///
/// Every directory lives under an injected scratch `sessionsDir`.
@Suite("Session mod: archive removes session directories")
struct ArchiveRemovesSessionDirectoriesTests {

    // MARK: - Fixture


    private struct Fixture {
        let home: URL
        let sessionsDir: URL
        let db: TBDDatabase
        let repo: Repo
        let worktree: Worktree

        func tearDown() {
            try? FileManager.default.removeItem(at: home)
        }

        func lifecycle(
            registry: HolderRegistry? = nil
        ) -> WorktreeLifecycle {
            var lifecycle = WorktreeLifecycle(
                db: db, git: GitManager(), hooks: HookResolver(),
                configDirManager: makeIsolatedConfigDirManager(tag: "archmod"),
                sessionsDir: sessionsDir,
                leftoverTmuxProbe: .absent)
            lifecycle.holderRegistry = registry
            return lifecycle
        }

        func tmuxClaude(
            _ sessionID: String, in worktreeID: UUID? = nil, pane: String = "%1"
        ) async throws -> Terminal {
            try await db.terminals.create(
                worktreeID: worktreeID ?? worktree.id,
                tmuxWindowID: "@\(pane.dropFirst())", tmuxPaneID: pane,
                label: TerminalLabel.claudeCode, claudeSessionID: sessionID, kind: .claude)
        }

        /// A tmux row an earlier build parked: its session ended at the park.
        func parkedTmuxClaude(
            _ sessionID: String, in worktreeID: UUID? = nil, pane: String = "%1"
        ) async throws -> Terminal {
            let terminal = try await tmuxClaude(sessionID, in: worktreeID, pane: pane)
            try await db.terminals.setHibernated(id: terminal.id, sessionID: sessionID)
            return try #require(try await db.terminals.get(id: terminal.id))
        }

        /// A holder row as a live session's looks. `childPID: 0` is the one
        /// value the registry's disposal refuses to signal; any other value a
        /// fixture could name is a pid this shared box may really be running.
        func liveHolderClaude(_ sessionID: String) async throws -> Terminal {
            try await db.terminals.create(
                worktreeID: worktree.id, tmuxWindowID: "", tmuxPaneID: "",
                label: TerminalLabel.claudeCode, claudeSessionID: sessionID, kind: .claude,
                transport: .holder, holderPID: 9101, childPID: 0)
        }

        /// A holder row as a park leaves it: parked, and naming no process.
        func parkedHolderClaude(_ sessionID: String) async throws -> Terminal {
            let terminal = try await db.terminals.create(
                worktreeID: worktree.id, tmuxWindowID: "", tmuxPaneID: "",
                label: TerminalLabel.claudeCode, claudeSessionID: sessionID, kind: .claude,
                transport: .holder)
            try await db.terminals.setHibernated(id: terminal.id, sessionID: sessionID)
            return try #require(try await db.terminals.get(id: terminal.id))
        }

        @discardableResult
        func seed(_ sessionID: String) throws -> URL {
            try ArchiveRemovesSessionDirectoriesTests.seedSessionDirectory(
                sessionsDir, sessionID: sessionID)
        }

        func hasDirectory(_ sessionID: String) -> Bool {
            FileManager.default.fileExists(
                atPath: sessionsDir.appendingPathComponent(sessionID, isDirectory: true).path)
        }

        func hasDraft(_ sessionID: String) -> Bool {
            ArchiveRemovesSessionDirectoriesTests.hasDraft(sessionsDir, sessionID: sessionID)
        }
    }

    private static func makeHome(_ prefix: String) throws -> (home: URL, sessionsDir: URL) {
        let home = URL(fileURLWithPath: fencedScratchRoot(prefix: prefix), isDirectory: true)
        let sessionsDir = home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        return (home, sessionsDir)
    }

    /// A repo worktree with no checkout on disk: archive's git reads fail
    /// softly, which is all the explicit archive needs here.
    private static func makeFixture() async throws -> Fixture {
        let (home, sessionsDir) = try makeHome("archmod")
        let db = try TBDDatabase(
            inMemory: true,
            terminalHistoryDir: home.appendingPathComponent("history", isDirectory: true).path)
        let repo = try await db.repos.create(
            path: home.appendingPathComponent("repo", isDirectory: true).path,
            displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "tbd/wt",
            path: home.appendingPathComponent("wt", isDirectory: true).path,
            tmuxServer: "tbd-archmod")
        return Fixture(
            home: home, sessionsDir: sessionsDir, db: db, repo: repo, worktree: worktree)
    }

    /// Writes a session directory as the mod and the daemon leave it: a spawn
    /// record and a saved draft.
    @discardableResult
    private static func seedSessionDirectory(_ sessionsDir: URL, sessionID: String) throws -> URL {
        try SessionModFiles.writeSpawnRecord(
            SessionModFiles.SpawnRecord(
                sessionId: sessionID, incarnationId: UUID().uuidString,
                spawnedAtMs: 1_700_000_000_000, features: ["composer-draft"]),
            sessionsDir: sessionsDir)
        let directory = sessionsDir.appendingPathComponent(sessionID, isDirectory: true)
        let draft = SessionModFiles.ComposerDraftRecord(
            sessionId: sessionID, hasDraft: true, text: "half a thought", cursor: 14,
            savedAtMs: 1_700_000_000_000)
        try JSONEncoder().encode(draft).write(
            to: directory.appendingPathComponent(SessionModFiles.composerDraftFileName))
        return directory
    }

    private static func hasDraft(_ sessionsDir: URL, sessionID: String) -> Bool {
        FileManager.default.fileExists(atPath: sessionsDir
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent(SessionModFiles.composerDraftFileName).path)
    }

    /// A holder registry whose rendezvous paths come from an explicit, short
    /// environment, so nothing reaches the real `~/tbd`.
    private static func holderRegistry(listing terminals: [Terminal]) -> HolderRegistry {
        HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": "/tmp/tbd-am-\(UUID().uuidString.prefix(8))"],
            listTerminals: { terminals })
    }

    // MARK: - The rule

    /// A teardown that stopped the process settles it. Otherwise only a parked
    /// row has no process — and not while its park is still in flight.
    @Test func sessionHasEndedOnlyWhenNoProcessCanRemain() {
        let live = Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-rule", kind: .claude)
        #expect(WorktreeLifecycle.sessionHasEnded(live, teardownStoppedIt: true))
        #expect(!WorktreeLifecycle.sessionHasEnded(live, teardownStoppedIt: false))

        var parked = live
        parked.hibernatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(WorktreeLifecycle.sessionHasEnded(parked, teardownStoppedIt: false))

        var legacyParked = live
        legacyParked.suspendedAt = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(WorktreeLifecycle.sessionHasEnded(legacyParked, teardownStoppedIt: false))

        var parking = parked
        parking.pendingSessionIncarnationID = UUID()
        #expect(!WorktreeLifecycle.sessionHasEnded(parking, teardownStoppedIt: false),
                "a park still in flight may have a running agent behind it")
        #expect(WorktreeLifecycle.sessionHasEnded(parking, teardownStoppedIt: true))
    }

    /// Two rows can carry one session ID. Its directory may go only when
    /// every row naming it has ended: one left running may still write there.
    @Test func aSessionNamedByARowLeftRunningIsNotRemovable() {
        func row(_ sessionID: String?) -> Terminal {
            Terminal(
                worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
                label: TerminalLabel.claudeCode, claudeSessionID: sessionID, kind: .claude)
        }
        var tally = WorktreeLifecycle.SessionTeardownTally()
        tally.record(row("sess-shared"), teardownStoppedIt: true)
        tally.record(row("sess-shared"), teardownStoppedIt: false)
        tally.record(row("sess-alone"), teardownStoppedIt: true)
        tally.record(row("sess-running"), teardownStoppedIt: false)
        tally.record(row(nil), teardownStoppedIt: true)

        #expect(tally.removableSessionIDs == ["sess-alone"])
    }

    // MARK: - Explicit archive

    /// Two rows naming one session, one of them a live tmux row archive leaves
    /// running: the session may still be running there, so its directory stays
    /// although the other row's holder was disposed of.
    @Test func archiveKeepsADirectoryWhileAnyRowNamingItsSessionMayRun() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let holder = try await fixture.liveHolderClaude("sess-shared")
        _ = try await fixture.tmuxClaude("sess-shared", pane: "%3")
        try fixture.seed("sess-shared")
        let registry = Self.holderRegistry(listing: [holder])
        _ = await registry.adoptAll()

        _ = try await fixture.lifecycle(registry: registry)
            .beginArchiveWorktree(worktreeID: fixture.worktree.id)

        #expect(fixture.hasDraft("sess-shared"),
                "a directory went while a row naming its session was left running")
    }

    /// A parked session has no process, so its directory goes although the
    /// teardown itself stopped nothing: a parked holder row names no job to
    /// kill, and a parked tmux row runs no tmux command.
    @Test func archivingAParkedSessionRemovesItsDirectory() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }

        _ = try await fixture.parkedTmuxClaude("sess-parked-tmux", pane: "%3")
        let parkedHolder = try await fixture.parkedHolderClaude("sess-parked-holder")
        #expect(parkedHolder.childPID == nil)
        try fixture.seed("sess-parked-tmux")
        try fixture.seed("sess-parked-holder")
        let registry = Self.holderRegistry(listing: [parkedHolder])

        _ = try await fixture.lifecycle(registry: registry)
            .beginArchiveWorktree(worktreeID: fixture.worktree.id)

        #expect(!fixture.hasDirectory("sess-parked-tmux"))
        #expect(!fixture.hasDirectory("sess-parked-holder"))
        #expect(try await fixture.db.worktrees.get(id: fixture.worktree.id)?.status == .archived)
    }

    /// Archive disposes of a live holder's job, then removes its directory.
    @Test func archivingALiveHolderSessionRemovesItsDirectoryAfterDisposal() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let terminal = try await fixture.liveHolderClaude("sess-live-holder")
        try fixture.seed("sess-live-holder")
        // `adoptAll` records a status for a session nothing answers for, and
        // only `abandon` clears it: the observable that the disposal ran.
        let registry = Self.holderRegistry(listing: [terminal])
        _ = await registry.adoptAll()
        let armed = await registry.lastKnownStatus(for: terminal.id)
        #expect(armed == .exitedStatusUnknown, "the fixture never armed the observable")

        _ = try await fixture.lifecycle(registry: registry)
            .beginArchiveWorktree(worktreeID: fixture.worktree.id)

        let disposed = await registry.lastKnownStatus(for: terminal.id)
        #expect(disposed == nil, "archive never disposed of the holder")
        #expect(!fixture.hasDirectory("sess-live-holder"))
    }

    /// A session the teardown left running keeps its directory: the mod is
    /// still writing to it, and `OrphanGC` reclaims it once nothing names it.
    /// A holder with no registry to dispose of it, and a live tmux row, whose
    /// close runs no tmux command, are the two ways that happens.
    @Test func archiveKeepsTheDirectoryOfASessionItLeftRunning() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        _ = try await fixture.liveHolderClaude("sess-undisposed")
        _ = try await fixture.tmuxClaude("sess-tmux", pane: "%3")
        for sessionID in ["sess-undisposed", "sess-tmux"] {
            try fixture.seed(sessionID)
        }

        _ = try await fixture.lifecycle(registry: nil)
            .beginArchiveWorktree(worktreeID: fixture.worktree.id)

        #expect(fixture.hasDraft("sess-undisposed"))
        #expect(fixture.hasDraft("sess-tmux"))
        #expect(try await fixture.db.worktrees.get(id: fixture.worktree.id)?.status == .archived,
                "a session left running must not stop the archive")
    }

    /// The directories of sessions outside the archived worktree survive:
    /// another worktree's, and one no row names at all.
    @Test func otherSessionsDirectoriesAreUntouched() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let sibling = try await fixture.db.worktrees.create(
            repoID: fixture.repo.id, name: "sibling",
            branch: "tbd/sibling",
            path: fixture.home.appendingPathComponent("sibling", isDirectory: true).path,
            tmuxServer: "tbd-archmod")
        _ = try await fixture.parkedTmuxClaude("sess-archived")
        _ = try await fixture.parkedTmuxClaude("sess-sibling", in: sibling.id, pane: "%2")
        for sessionID in ["sess-archived", "sess-sibling", "sess-unnamed"] {
            try fixture.seed(sessionID)
        }

        _ = try await fixture.lifecycle().beginArchiveWorktree(worktreeID: fixture.worktree.id)

        #expect(!fixture.hasDirectory("sess-archived"))
        #expect(fixture.hasDraft("sess-sibling"))
        #expect(fixture.hasDraft("sess-unnamed"))
    }

    /// Archive then revive resumes the session with an empty box: the revived
    /// spawn writes its spawn record into a fresh directory, and no draft
    /// comes back with it.
    @Test func revivingAfterArchiveFindsNoDraft() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let (home, sessionsDir) = try Self.makeHome("archrev")
        defer { try? FileManager.default.removeItem(at: home) }
        let db = try TBDDatabase(
            inMemory: true,
            terminalHistoryDir: home.appendingPathComponent("history", isDirectory: true).path)
        try await db.config.setComposerDraftEnabled(true)
        try await db.config.setPrimaryAgentPreference(.claude)
        // Both spawns go through the holder spawn double; archive disposes of
        // the first through the same registry.
        let holder = FakeHolderLaunch()
        var lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), hooks: HookResolver(),
            configDirManager: makeIsolatedConfigDirManager(tag: "archrev"),
            sessionsDir: sessionsDir,
            leftoverTmuxProbe: .absent)
        lifecycle.holderRegistry = makeHolderRegistryDouble(launch: holder)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)
        let primary = try #require(
            try await db.terminals.list(worktreeID: wt.id).first { $0.kind == .claude })
        let sessionID = try #require(primary.claudeSessionID)
        try Self.seedSessionDirectory(sessionsDir, sessionID: sessionID)

        try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)
        let disposed = holder.abandonments.map(\.terminalID)
        #expect(disposed.contains(primary.id), "archive never disposed of the primary's holder")
        #expect(!FileManager.default.fileExists(
            atPath: sessionsDir.appendingPathComponent(sessionID, isDirectory: true).path))

        let revived = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: false)
        let resumed = try await db.terminals.list(worktreeID: revived.id)
        #expect(resumed.contains { $0.claudeSessionID == sessionID },
                "revive did not resume the archived session")
        #expect(readSpawnRecord(sessionsDir: sessionsDir, sessionID: sessionID) != nil,
                "the resumed spawn wrote no spawn record")
        #expect(!Self.hasDraft(sessionsDir, sessionID: sessionID),
                "the archived session's draft came back on revive")
    }

    // MARK: - Reconcile's archive of a vanished checkout

    /// An actuation log whose every write naming `terminalID` fails, so that
    /// one terminal's teardown cannot be recorded while the others' can.
    private static func actuationLog(
        failingWritesNaming terminalID: UUID, path: String
    ) -> ActuationLog {
        let needles = [terminalID.uuidString, terminalID.uuidString.lowercased()]
            .map { Data($0.utf8) }
        return ActuationLog(path: path, syscalls: ActuationLogSyscalls(
            write: { descriptor, buffer, count in
                let bytes = Data(bytes: buffer, count: count)
                if needles.contains(where: { bytes.range(of: $0) != nil }) {
                    errno = EIO
                    return -1
                }
                return Foundation.write(descriptor, buffer, count)
            },
            fsync: { descriptor in Foundation.fsync(descriptor) }))
    }

    /// Reconcile leaves a worktree whose teardowns it could not all record
    /// for the next sweep, rows and all — so the directories stay too, even
    /// the one whose teardown it did record. The next sweep archives the
    /// worktree and removes them. Both rows are parked, so each session has
    /// ended and only the record decides.
    @Test func reconcileArchiveRemovesDirectoriesOnlyAfterEveryTeardown() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let (home, sessionsDir) = try Self.makeHome("archrec")
        defer { try? FileManager.default.removeItem(at: home) }
        let db = try TBDDatabase(
            inMemory: true,
            terminalHistoryDir: home.appendingPathComponent("history", isDirectory: true).path)
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), hooks: HookResolver(),
            configDirManager: makeIsolatedConfigDirManager(tag: "archrec"),
            sessionsDir: sessionsDir,
            // The worktree the first sweep leaves active reaches the leftover-tmux
            // arm too. A server that may still be running keeps that arm off its
            // rows, so the only thing this test changes between sweeps is whether
            // every teardown could be recorded.
            leftoverTmuxProbe: LeftoverTmuxServerProbe { _ in .running })
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")
        // A row whose path git does not list: the vanished checkout reconcile
        // archives.
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "gone", branch: "gone-branch",
            path: tempDir.appendingPathComponent("vanished").path, tmuxServer: "tbd-archrec")
        let recorded = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-recorded", kind: .claude)
        try await db.terminals.setHibernated(id: recorded.id, sessionID: "sess-recorded")
        let unrecorded = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-unrecorded", kind: .claude)
        try await db.terminals.setHibernated(id: unrecorded.id, sessionID: "sess-unrecorded")
        try Self.seedSessionDirectory(sessionsDir, sessionID: "sess-recorded")
        try Self.seedSessionDirectory(sessionsDir, sessionID: "sess-unrecorded")

        try await lifecycle.reconcile(
            repoID: repo.id,
            actuationLog: Self.actuationLog(
                failingWritesNaming: unrecorded.id,
                path: home.appendingPathComponent("actuations.jsonl").path))

        #expect(try await db.worktrees.get(id: wt.id)?.status == .active,
                "the fixture never made one teardown unrecordable")
        #expect(Self.hasDraft(sessionsDir, sessionID: "sess-recorded"),
                "a directory went before reconcile knew every teardown was recorded")
        #expect(Self.hasDraft(sessionsDir, sessionID: "sess-unrecorded"))

        try await lifecycle.reconcile(
            repoID: repo.id, actuationLog: makeTestActuationLog())

        #expect(try await db.worktrees.get(id: wt.id)?.status == .archived)
        #expect(!FileManager.default.fileExists(
            atPath: sessionsDir.appendingPathComponent("sess-recorded").path))
        #expect(!FileManager.default.fileExists(
            atPath: sessionsDir.appendingPathComponent("sess-unrecorded").path))
    }

    // MARK: - Scratch archive

    /// The scratch archive ends each session its own way: a parked session's
    /// directory goes, whichever transport its row is on, and a live tmux
    /// row's stays, because closing it runs no tmux command.
    @Test func scratchArchiveRemovesDirectories() async throws {
        let (home, sessionsDir) = try Self.makeHome("archscr")
        defer { try? FileManager.default.removeItem(at: home) }
        let db = try TBDDatabase(
            inMemory: true,
            terminalHistoryDir: home.appendingPathComponent("history", isDirectory: true).path)
        let scratchPath = home.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchPath, withIntermediateDirectories: true)
        let wt = try await db.worktrees.createScratch(
            name: "scratch", displayName: "scratch", path: scratchPath.path,
            tmuxServer: "tbd-archscr")

        let configDirManager = makeIsolatedConfigDirManager(tag: "archscr")
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), hooks: HookResolver(),
            configDirManager: configDirManager,
            sessionsDir: sessionsDir,
            leftoverTmuxProbe: .absent)
        let router = RPCRouter(
            db: db, lifecycle: lifecycle, startTime: Date(),
            configDirManager: configDirManager, sessionsDir: sessionsDir,
            actuationLog: makeTestActuationLog())

        _ = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-live-tmux", kind: .claude)
        let parkedTmux = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-parked-tmux", kind: .claude)
        try await db.terminals.setHibernated(id: parkedTmux.id, sessionID: "sess-parked-tmux")
        let parked = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-parked", kind: .claude,
            transport: .holder)
        try await db.terminals.setHibernated(id: parked.id, sessionID: "sess-parked")
        for sessionID in ["sess-live-tmux", "sess-parked-tmux", "sess-parked"] {
            try Self.seedSessionDirectory(sessionsDir, sessionID: sessionID)
        }

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.scratchArchive, params: ScratchArchiveParams(worktreeID: wt.id)))

        #expect(response.success, "scratch.archive failed: \(response.error ?? "")")
        #expect(try await db.worktrees.get(id: wt.id)?.status == .archived)
        #expect(Self.hasDraft(sessionsDir, sessionID: "sess-live-tmux"))
        #expect(!FileManager.default.fileExists(
            atPath: sessionsDir.appendingPathComponent("sess-parked-tmux").path))
        #expect(!FileManager.default.fileExists(
            atPath: sessionsDir.appendingPathComponent("sess-parked").path))
    }
}
