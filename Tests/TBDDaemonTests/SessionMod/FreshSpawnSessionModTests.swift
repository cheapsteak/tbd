import Clocks
import Foundation
import DaemonTestSupport
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Fresh Claude spawns made with a session-mod feature on: `terminal.create`,
/// a worktree's primary, its archived-session restores, a revive from closed
/// history, and a fork of a blank session. Each mints an incarnation, writes it
/// into the new row, writes the spawn record naming it, and exports it. A fork
/// of a real conversation learns its session id only once it has launched, so
/// it stays legacy. With every feature off, every one of them is the spawn it
/// always was.
///
/// tmux runs in dry-run mode, so the spawned process's environment is read off
/// the recorded `new-window` argv (its `-e` pairs).
@Suite("Session mod: fresh Claude spawns")
struct FreshSpawnSessionModTests {

    // MARK: - Fixture

    private final class TmuxCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[String]] = []
        func record(_ argv: [String]) {
            lock.lock(); defer { lock.unlock() }
            calls.append(argv)
        }
        var all: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return calls
        }
    }

    private struct Fixture {
        let db: TBDDatabase
        let lifecycle: WorktreeLifecycle
        let router: RPCRouter
        let tmux: TmuxCalls
        let repo: Repo
        let worktree: Worktree
        let sessionsDir: URL
        let home: URL

        func tearDown() {
            try? FileManager.default.removeItem(at: home)
        }

        func setFlag(_ on: Bool) async throws {
            try await db.config.setComposerDraftEnabled(on)
        }

        func sessionsDirContents() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: sessionsDir.path))
        }

        func create(_ params: TerminalCreateParams) async throws -> Terminal {
            let response = await router.handle(try RPCRequest(
                method: RPCMethod.terminalCreate, params: params))
            try #require(response.success, "terminal.create failed: \(response.error ?? "")")
            return try response.decodeResult(Terminal.self)
        }

        func createClaude(resumeSessionID: String? = nil) async throws -> Terminal {
            try await create(TerminalCreateParams(
                worktreeID: worktree.id, type: .claude, resumeSessionID: resumeSessionID))
        }

        /// Every Claude row in the worktree, keyed by its session id.
        func claudeRowsBySession() async throws -> [String: Terminal] {
            let rows = try await db.terminals.list(worktreeID: worktree.id)
            var bySession: [String: Terminal] = [:]
            for row in rows where row.kind == .claude {
                let sessionID = try #require(row.claudeSessionID)
                bySession[sessionID] = row
            }
            return bySession
        }

        /// A closed Claude terminal in this worktree's history, resumable by
        /// `sessionID`; returns the history entry's id.
        func storeClosedClaude(sessionID: String) async -> UUID {
            let closed = Terminal(
                worktreeID: worktree.id, tmuxWindowID: "@9", tmuxPaneID: "%9",
                label: TerminalLabel.claudeCode, claudeSessionID: sessionID, kind: .claude)
            await db.terminalHistory.store(
                terminal: closed, text: "prior claude output\n", closedAt: Date())
            return closed.id
        }

        func reviveHistory(entryID: UUID) async throws -> Terminal {
            let response = await router.handle(try RPCRequest(
                method: RPCMethod.terminalHistoryRevive,
                params: TerminalHistoryReviveParams(worktreeID: worktree.id, id: entryID)))
            try #require(response.success, "terminalHistory.revive failed: \(response.error ?? "")")
            return try response.decodeResult(Terminal.self)
        }

        /// Points `terminal`'s session at a transcript holding `line`, so the
        /// swap's scanner classifies it from content.
        func giveTranscript(_ terminal: Terminal, line: String) async throws {
            let sessionID = try #require(terminal.claudeSessionID)
            let file = home.appendingPathComponent("\(sessionID).jsonl")
            try line.write(to: file, atomically: true, encoding: .utf8)
            try await db.terminals.updateSession(
                id: terminal.id, sessionID: sessionID, transcriptPath: file.path)
        }

        /// Forks `source` into a new tab on another account.
        func forkSwap(_ source: Terminal) async throws -> Terminal {
            let target = try await db.modelProfiles.create(name: "acme-b", kind: .oauth)
            let response = await router.handle(try RPCRequest(
                method: RPCMethod.terminalSwapProfile,
                params: TerminalSwapProfileParams(
                    terminalID: source.id, newProfileID: target.id, mode: .fork)))
            try #require(response.success, "terminal.swapProfile failed: \(response.error ?? "")")
            return try response.decodeResult(Terminal.self)
        }

        func sendSessionStart(
            _ terminalID: UUID, sessionID: String, transcriptPath: String, incarnation: UUID?
        ) async throws {
            let response = await router.handle(try RPCRequest(
                method: RPCMethod.terminalSessionEvent,
                params: TerminalSessionEventParams(
                    terminalID: terminalID,
                    sessionID: sessionID,
                    transcriptPath: transcriptPath,
                    source: "startup",
                    sessionIncarnationID: incarnation)))
            #expect(response.success)
        }

        /// The process environment the window spawned for `terminalID` was
        /// given: the `-e` pairs of its `new-window`, which carries the
        /// terminal's id in its command.
        func launchEnvironment(
            of terminalID: UUID, sourceLocation: SourceLocation = #_sourceLocation
        ) throws -> [String: String] {
            let launch = try #require(
                tmux.all.last {
                    $0.contains("new-window") && ($0.last?.contains(terminalID.uuidString) ?? false)
                },
                "no new-window was recorded for terminal \(terminalID)",
                sourceLocation: sourceLocation)
            return tmuxEnvironmentFlags(launch)
        }

        /// The spawn carried the mod: its row holds an incarnation, its launch
        /// exported that incarnation with the other two variables, and its
        /// session's spawn record names it. Returns the incarnation.
        @discardableResult
        func expectMod(
            _ terminalID: UUID, sourceLocation: SourceLocation = #_sourceLocation
        ) async throws -> UUID {
            let row = try #require(
                try await db.terminals.get(id: terminalID), sourceLocation: sourceLocation)
            let incarnation = try #require(
                row.sessionIncarnationID,
                "a fresh Claude spawn with the flag on wrote no incarnation into its row",
                sourceLocation: sourceLocation)
            #expect(row.pendingSessionIncarnationID == nil, sourceLocation: sourceLocation)
            let sessionID = try #require(row.claudeSessionID, sourceLocation: sourceLocation)
            let environment = try launchEnvironment(of: terminalID, sourceLocation: sourceLocation)
            #expect(environment[SessionModSpawn.sessionsDirVariable] == sessionsDir.path,
                    sourceLocation: sourceLocation)
            #expect(environment[SessionModSpawn.featuresVariable] == "composer-draft",
                    sourceLocation: sourceLocation)
            #expect(environment[SessionModSpawn.incarnationVariable] == incarnation.uuidString,
                    sourceLocation: sourceLocation)
            let record = try #require(
                readSpawnRecord(sessionsDir: sessionsDir, sessionID: sessionID),
                "no spawn record for session \(sessionID)",
                sourceLocation: sourceLocation)
            #expect(record.sessionId == sessionID, sourceLocation: sourceLocation)
            #expect(record.incarnationId == incarnation.uuidString, sourceLocation: sourceLocation)
            #expect(record.features == ["composer-draft"], sourceLocation: sourceLocation)
            return incarnation
        }

        /// The spawn is the one it always was: no incarnation in its row and
        /// none of the three variables in its launch.
        func expectNoMod(
            _ terminalID: UUID, sourceLocation: SourceLocation = #_sourceLocation
        ) async throws {
            let row = try #require(
                try await db.terminals.get(id: terminalID), sourceLocation: sourceLocation)
            #expect(row.sessionIncarnationID == nil, sourceLocation: sourceLocation)
            let environment = try launchEnvironment(of: terminalID, sourceLocation: sourceLocation)
            #expect(environment[SessionModSpawn.sessionsDirVariable] == nil,
                    sourceLocation: sourceLocation)
            #expect(environment[SessionModSpawn.featuresVariable] == nil,
                    sourceLocation: sourceLocation)
            #expect(environment[SessionModSpawn.incarnationVariable] == nil,
                    sourceLocation: sourceLocation)
        }
    }

    private static func makeFixture(flagOn: Bool) async throws -> Fixture {
        let home = URL(fileURLWithPath: fencedScratchRoot(prefix: "freshmod"), isDirectory: true)
        let sessionsDir = home.appendingPathComponent("sessions", isDirectory: true)
        // terminal.create and the revive refuse to spawn into a missing
        // directory, so the worktree path has to exist.
        let worktreePath = home.appendingPathComponent("wt", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreePath, withIntermediateDirectories: true)

        let calls = TmuxCalls()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { calls.record($0) },
            dryRunCapturePane: { _, _ in "" })
        let db = try TBDDatabase(
            inMemory: true,
            terminalHistoryDir: home.appendingPathComponent("history", isDirectory: true).path)
        try await db.config.setComposerDraftEnabled(flagOn)
        try await db.config.setPrimaryAgentPreference(.claude)

        // A carryover primary and a fork of a real conversation schedule a
        // session-id recapture. This one runs at once and finds nothing, so no
        // task outlives the test and nothing reads a session file at a
        // process-wide path.
        let inertRecapture: @Sendable (TBDDatabase, TmuxManager) -> SessionRecaptureScheduler = {
            db, tmux in
            SessionRecaptureScheduler(
                db: db, tmux: tmux, captureSessionID: { _ in nil }, clock: ImmediateClock())
        }
        let configDirManager = makeIsolatedConfigDirManager(tag: "fresh-spawn-mod")
        var lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
            configDirManager: configDirManager,
            sessionsDir: sessionsDir)
        lifecycle.sessionRecaptureFactory = inertRecapture
        let router = RPCRouter(
            db: db, lifecycle: lifecycle, tmux: tmux, startTime: Date(),
            configDirManager: configDirManager,
            sessionsDir: sessionsDir,
            actuationLog: makeTestActuationLog())
        router.sessionRecaptureFactory = inertRecapture

        let repo = try await db.repos.create(
            path: "/tmp/tbd-freshmod-repo-\(UUID().uuidString)",
            displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "tbd/wt",
            path: worktreePath.path, tmuxServer: "tbd-freshmod-test")
        return Fixture(
            db: db, lifecycle: lifecycle, router: router, tmux: calls,
            repo: repo, worktree: worktree, sessionsDir: sessionsDir, home: home)
    }

    // MARK: - The incarnation the row holds is the one the process reports

    /// `applySessionStart` accepts only a hook whose reported incarnation
    /// equals the row's. A fresh row written without the incarnation its
    /// process exports would drop every SessionStart that process sends.
    @Test func freshSpawnPersistsTheIncarnationItExports() async throws {
        let fixture = try await Self.makeFixture(flagOn: true)
        defer { fixture.tearDown() }

        let created = try await fixture.createClaude()
        let incarnation = try await fixture.expectMod(created.id)
        #expect(created.sessionIncarnationID == incarnation,
                "the create result does not carry the row's incarnation")
        let sessionID = try #require(created.claudeSessionID)

        // A hook from a process this row did not launch — no incarnation — is
        // dropped, so the acceptance below is the incarnation's doing.
        try await fixture.sendSessionStart(
            created.id, sessionID: sessionID,
            transcriptPath: "/tmp/tbd-freshmod-stale.jsonl", incarnation: nil)
        #expect(try await fixture.db.terminals.get(id: created.id)?.transcriptPath == nil)

        // The spawn's own SessionStart, reporting the exported incarnation.
        try await fixture.sendSessionStart(
            created.id, sessionID: sessionID,
            transcriptPath: "/tmp/tbd-freshmod-live.jsonl", incarnation: incarnation)
        let applied = try #require(try await fixture.db.terminals.get(id: created.id))
        #expect(applied.transcriptPath == "/tmp/tbd-freshmod-live.jsonl")
        #expect(applied.sessionIncarnationID == incarnation)
    }

    /// With every feature off, each fresh spawn site is unchanged: no
    /// incarnation, none of the three variables, no spawn record — and the
    /// legacy nil/nil SessionStart still lands.
    @Test func freshSpawnWithTheFlagOffIsUnchanged() async throws {
        let fixture = try await Self.makeFixture(flagOn: false)
        defer { fixture.tearDown() }

        let fresh = try await fixture.createClaude()
        try await fixture.expectNoMod(fresh.id)
        let resumed = try await fixture.createClaude(resumeSessionID: "resumed-off")
        try await fixture.expectNoMod(resumed.id)

        _ = try await fixture.lifecycle.spawnPrimaryTerminals(
            worktree: fixture.worktree, repo: fixture.repo, skipClaude: false,
            archivedClaudeSessions: ["archived-off-1", "archived-off-2"],
            preSessionTerminalID: nil)
        let restored = try await fixture.claudeRowsBySession()
        try await fixture.expectNoMod(try #require(restored["archived-off-1"]).id)
        try await fixture.expectNoMod(try #require(restored["archived-off-2"]).id)

        let entryID = await fixture.storeClosedClaude(sessionID: "history-off")
        let revived = try await fixture.reviveHistory(entryID: entryID)
        try await fixture.expectNoMod(revived.id)

        let blankSource = try await fixture.createClaude()
        try await fixture.giveTranscript(
            blankSource, line: #"{"type":"permission-mode","permissionMode":"default"}"#)
        let blankFork = try await fixture.forkSwap(blankSource)
        try await fixture.expectNoMod(blankFork.id)

        #expect(try fixture.sessionsDirContents().isEmpty)

        let sessionID = try #require(fresh.claudeSessionID)
        try await fixture.sendSessionStart(
            fresh.id, sessionID: sessionID,
            transcriptPath: "/tmp/tbd-freshmod-legacy.jsonl", incarnation: nil)
        #expect(try await fixture.db.terminals.get(id: fresh.id)?.transcriptPath
            == "/tmp/tbd-freshmod-legacy.jsonl")
    }

    // MARK: - Each fresh spawn site

    /// `terminal.create` writes the record under the id `--session-id` names
    /// for a fresh session and under the id `--resume` names for a resume. A
    /// shell is not a Claude spawn and gets nothing.
    @Test func terminalCreateWritesSpawnRecord() async throws {
        let fixture = try await Self.makeFixture(flagOn: true)
        defer { fixture.tearDown() }

        let fresh = try await fixture.createClaude()
        let freshSessionID = try #require(fresh.claudeSessionID)
        let freshIncarnation = try await fixture.expectMod(fresh.id)

        let resumed = try await fixture.createClaude(resumeSessionID: "resumed-session")
        #expect(resumed.claudeSessionID == "resumed-session")
        let resumedIncarnation = try await fixture.expectMod(resumed.id)
        #expect(resumedIncarnation != freshIncarnation)

        let shell = try await fixture.create(
            TerminalCreateParams(worktreeID: fixture.worktree.id, type: .shell))
        try await fixture.expectNoMod(shell.id)

        #expect(try fixture.sessionsDirContents() == [freshSessionID, "resumed-session"])
    }

    /// A worktree's Claude primary carries the mod.
    @Test func worktreePrimaryWritesSpawnRecord() async throws {
        let fixture = try await Self.makeFixture(flagOn: true)
        defer { fixture.tearDown() }

        _ = try await fixture.lifecycle.spawnPrimaryTerminals(
            worktree: fixture.worktree, repo: fixture.repo, skipClaude: false,
            preSessionTerminalID: nil)

        let rows = try await fixture.claudeRowsBySession()
        let (sessionID, primary) = try #require(rows.first)
        #expect(rows.count == 1)
        try await fixture.expectMod(primary.id)
        #expect(try fixture.sessionsDirContents() == [sessionID])
    }

    /// A conversation carried into a new worktree forks (`--fork-session`):
    /// its session id exists only once it has launched, and its recapture is
    /// scheduled expecting no incarnation. It stays legacy.
    @Test func carryoverPrimaryStaysLegacy() async throws {
        let fixture = try await Self.makeFixture(flagOn: true)
        defer { fixture.tearDown() }

        _ = try await fixture.lifecycle.spawnPrimaryTerminals(
            worktree: fixture.worktree, repo: fixture.repo, skipClaude: false,
            preSessionTerminalID: nil,
            carryover: ConversationCarryover(sourceSessionID: "carried-source", notesSeed: ""))

        let primary = try #require(try await fixture.claudeRowsBySession()["carried-source"])
        try await fixture.expectNoMod(primary.id)
        #expect(try fixture.sessionsDirContents().isEmpty)
    }

    /// Reviving an archived worktree restores every archived session: the
    /// primary resumes the first, and each other gets a tab of its own. Every
    /// one carries the mod under an incarnation of its own.
    @Test func archiveReviveWritesSpawnRecordForEverySession() async throws {
        let fixture = try await Self.makeFixture(flagOn: true)
        defer { fixture.tearDown() }
        let sessions = ["archived-one", "archived-two", "archived-three"]

        _ = try await fixture.lifecycle.spawnPrimaryTerminals(
            worktree: fixture.worktree, repo: fixture.repo, skipClaude: false,
            archivedClaudeSessions: sessions,
            preSessionTerminalID: nil)

        let rows = try await fixture.claudeRowsBySession()
        #expect(Set(rows.keys) == Set(sessions))
        var incarnations: Set<UUID> = []
        for session in sessions {
            let row = try #require(rows[session], "no tab restored session \(session)")
            let incarnation = try await fixture.expectMod(row.id)
            incarnations.insert(incarnation)
        }
        #expect(incarnations.count == sessions.count, "two restored sessions share an incarnation")
        #expect(try fixture.sessionsDirContents() == Set(sessions))
    }

    /// Reviving a closed Claude terminal resumes its session, and carries the
    /// mod.
    @Test func historyReviveWritesSpawnRecord() async throws {
        let fixture = try await Self.makeFixture(flagOn: true)
        defer { fixture.tearDown() }

        let entryID = await fixture.storeClosedClaude(sessionID: "history-session")
        let revived = try await fixture.reviveHistory(entryID: entryID)

        #expect(revived.claudeSessionID == "history-session")
        let incarnation = try await fixture.expectMod(revived.id)
        #expect(revived.sessionIncarnationID == incarnation)
        #expect(try fixture.sessionsDirContents() == ["history-session"])
    }

    /// A fork of a real conversation runs `--fork-session`, and Claude names
    /// the forked session only once it has launched: no session directory can
    /// be chosen beforehand, so the fork stays legacy.
    @Test func forkSwapStaysLegacy() async throws {
        let fixture = try await Self.makeFixture(flagOn: false)
        defer { fixture.tearDown() }
        let source = try await fixture.createClaude()
        try await fixture.giveTranscript(
            source, line: #"{"type":"user","message":{"role":"user","content":"hello there"}}"#)
        try await fixture.setFlag(true)

        let fork = try await fixture.forkSwap(source)

        #expect(fork.id != source.id)
        let launch = try #require(fixture.tmux.all.last {
            $0.contains("new-window") && ($0.last?.contains(fork.id.uuidString) ?? false)
        })
        #expect(launch.last?.contains("--fork-session") == true,
                "a fork of a real conversation did not fork the session")
        try await fixture.expectNoMod(fork.id)
        #expect(try fixture.sessionsDirContents().isEmpty)
    }

    /// A fork of a blank session forks nothing: it opens a new session under
    /// an id the swap minted, which is a fresh spawn, so it carries the mod.
    @Test func blankForkSwapWritesSpawnRecord() async throws {
        let fixture = try await Self.makeFixture(flagOn: false)
        defer { fixture.tearDown() }
        let source = try await fixture.createClaude()
        try await fixture.giveTranscript(
            source, line: #"{"type":"permission-mode","permissionMode":"default"}"#)
        try await fixture.setFlag(true)

        let fork = try await fixture.forkSwap(source)

        let forkSessionID = try #require(fork.claudeSessionID)
        #expect(forkSessionID != source.claudeSessionID)
        try await fixture.expectMod(fork.id)
        #expect(try fixture.sessionsDirContents() == [forkSessionID])
    }
}
