import Clocks
import Foundation
import DaemonTestSupport
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Where the resume gate (`TmuxResumeGate`) sits among the writes a start of
/// an existing session makes, and which starts never ask it.
///
/// `terminal.create` resuming a session, and Closed Terminals' reopen
/// (`terminalHistory.revive`), ask the gate before start admission, the trust
/// seed, the session title and the session mod's spawn record; a resume of a
/// Codex thread asks it before preparing the Codex home. Each test sends the
/// refused request and finds none of those effects, then sends the same
/// request once the server is gone and finds every one of them, so the
/// absence is the gate's doing and not a fixture that could never write.
///
/// A start that forks the session (`forksSession`) asks no probe and goes
/// ahead while the server may run: a profile switch's fork tab, and a Claude
/// conversation carried onto a fresh branch. A Codex thread carried into a new
/// worktree resumes the thread itself, so the create's spawn refuses it.
///
/// The probe is injected, records what it was asked and answers `.running`
/// until a test switches it, so no test asks a real socket. Profile config
/// dirs, session dirs, notes and Closed Terminals content sit under each
/// test's temporary root.
@Suite("Resume gate ordering")
struct TmuxResumeGateOrderingTests {
    /// What the injected probe answers, switchable mid-test.
    final class ServerState: @unchecked Sendable {
        private let lock = NSLock()
        private var value: LeftoverTmuxServerState = .running
        var state: LeftoverTmuxServerState {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// How many times a seam was called.
    final class CallCount: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func record() { lock.withLock { value += 1 } }
    }

    struct Fixture {
        let root: URL
        let db: TBDDatabase
        let router: RPCRouter
        let worktree: Worktree
        let holder: FakeHolderLaunch
        let server: ServerState
        let probe: RecordingLeftoverTmuxProbe
        let admission: StubAdmission
        let configDirManager: ClaudeProfileConfigDirManager
        let sessionTitles: ClaudeSessionTitleStore
        let sessionsDir: URL
        /// The default profile every Claude start resolves: the trust seed
        /// writes into its config dir under `root`.
        let profile: ModelProfile
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

        /// Whether the trust seed has written the worktree's path into the
        /// default profile's `.claude.json`.
        func trustSeeded() throws -> Bool {
            let claudeJSON = configDirManager.configDirectory(forProfileID: profile.id)
                .appendingPathComponent(".claude.json")
            guard let data = FileManager.default.contents(atPath: claudeJSON.path) else {
                return false
            }
            guard let topLevel = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Issue.record("\(claudeJSON.path) is not a JSON object")
                return false
            }
            let projects = topLevel["projects"] as? [String: Any]
            let entry = projects?[worktree.localPath] as? [String: Any]
            return entry?["hasTrustDialogAccepted"] as? Bool == true
        }

        /// Every session title the store holds in the worktree, given or
        /// reserved.
        func heldTitles() async -> [UUID: String] {
            await sessionTitles.titles(worktreeID: worktree.id)
        }

        /// The session mod's spawn record for `sessionID`, if one was written.
        func spawnRecord(_ sessionID: String) -> SessionModFiles.SpawnRecord? {
            readSpawnRecord(sessionsDir: sessionsDir, sessionID: sessionID)
        }
    }

    private static let sessionID = "sess-acme-ordering"

    /// The RPC fixture of `TmuxResumeGateRPCTests`, with the session mod's
    /// directory, the notes and the Closed Terminals content under `root`, a
    /// recording start admission, a default sign-in profile so the trust seed
    /// writes into `root`, composer drafts as the one session-mod feature, and
    /// a session-id recapture that finds nothing at once.
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmux-resume-order-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let db = try TBDDatabase(
            inMemory: true,
            notesDir: root.appendingPathComponent("notes", isDirectory: true).path,
            terminalHistoryDir: root.appendingPathComponent("history", isDirectory: true).path)
        let holder = FakeHolderLaunch()
        let registry = makeHolderRegistryDouble(launch: holder)
        let server = ServerState()
        let probe = RecordingLeftoverTmuxProbe { _ in server.state }
        let manager = ClaudeProfileConfigDirManager(
            baseDirectory: root.appendingPathComponent("profiles"),
            hostBaseDirectory: root.appendingPathComponent("claude"))
        var lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), hooks: HookResolver(),
            configDirManager: manager,
            codexExecutableResolver: CodexLaunchTestStub.executableResolver,
            codexHomeEnsurer: CodexLaunchTestStub.homeEnsurer,
            sessionsDir: sessionsDir,
            leftoverTmuxProbe: probe.probe)
        lifecycle.holderRegistry = registry
        let actuationPath = root.appendingPathComponent("actuations.jsonl").path
        let router = RPCRouter(
            db: db, lifecycle: lifecycle, configDirManager: manager,
            codexExecutableResolver: CodexLaunchTestStub.executableResolver,
            codexHomeEnsurer: CodexLaunchTestStub.homeEnsurer,
            sessionsDir: sessionsDir,
            actuationLog: ActuationLog(path: actuationPath),
            modelProfileKeychain: ModelProfileKeychain.Store(environment: ["TBD_HOME": root.path]))
        router.holderRegistry = registry
        await router.hibernationCoordinator.setHolderRegistry(registry)
        await router.hibernationCoordinator.setLeftoverTmuxProbe(probe.probe)
        let admission = StubAdmission(.admit)
        router.startAdmission = admission
        // A fork of a real conversation schedules a session-id recapture.
        // This one runs at once and finds nothing, so no task outlives the
        // test and nothing reads a real process.
        let inertRecapture: @Sendable (TBDDatabase) -> SessionRecaptureScheduler = { db in
            SessionRecaptureScheduler(
                db: db, captureSessionID: { _ in nil }, clock: ImmediateClock())
        }
        router.sessionRecaptureFactory = inertRecapture
        try await db.config.setStartAdmissionEnabled(true)
        try await db.config.setComposerDraftAsTheOnlyModFeature(true)
        let profile = try await db.modelProfiles.create(name: "acme", kind: .oauth)
        try await db.config.setDefaultProfileID(profile.id)
        let repo = try await db.repos.create(
            path: root.path, displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "acme", branch: "main", path: root.path,
            tmuxServer: "tbd-acme")
        return Fixture(
            root: root, db: db, router: router, worktree: worktree, holder: holder,
            server: server, probe: probe, admission: admission, configDirManager: manager,
            sessionTitles: lifecycle.sessionTitles, sessionsDir: sessionsDir,
            profile: profile, actuationPath: actuationPath)
    }

    /// A live tmux Claude row on `sessionID`, closed through `terminal.delete`,
    /// which runs no tmux command and marks its Closed Terminals entry with the
    /// worktree's server.
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

    /// A refusal of a Claude start of `sessionID`, answered before anything the
    /// start writes for the session: start admission was not consulted, the
    /// trust seed wrote nothing, no session title is held, and no spawn record
    /// or session directory exists.
    private func expectRefusedBeforeAnyWrite(
        _ response: RPCResponse, _ f: Fixture,
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
        #expect(f.probe.servers == ["tbd-acme"], sourceLocation: sourceLocation)
        #expect(f.holder.launches.isEmpty, sourceLocation: sourceLocation)
        #expect(try await f.db.terminalHistory.liveOnTmuxServers(sessionIDs: [Self.sessionID])
            == ["tbd-acme"], sourceLocation: sourceLocation)

        #expect(f.admission.requests.isEmpty,
                "start admission was consulted before the resume gate refused: \(f.admission.requests)",
                sourceLocation: sourceLocation)
        #expect(try f.trustSeeded() == false,
                "the trust seed wrote the worktree before the resume gate refused",
                sourceLocation: sourceLocation)
        let titles = await f.heldTitles()
        #expect(titles.isEmpty,
                "a session title was reserved before the resume gate refused: \(titles)",
                sourceLocation: sourceLocation)
        #expect(f.spawnRecord(Self.sessionID) == nil,
                "the session mod's spawn record was written before the resume gate refused",
                sourceLocation: sourceLocation)
        #expect(!FileManager.default.fileExists(
                    atPath: f.sessionsDir.appendingPathComponent(Self.sessionID).path),
                "the session's directory was made before the resume gate refused",
                sourceLocation: sourceLocation)
    }

    /// The control for `expectRefusedBeforeAnyWrite`: the same start, let
    /// through, made every one of the writes the refusal did not.
    private func expectEveryWriteOnceLetThrough(
        _ terminal: TBDShared.Terminal, _ f: Fixture,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        #expect(terminal.transport == .holder, sourceLocation: sourceLocation)
        #expect(terminal.claudeSessionID == Self.sessionID, sourceLocation: sourceLocation)
        let command = try #require(
            f.holder.launch(for: terminal.id)?.commandLine, sourceLocation: sourceLocation)
        #expect(command.contains("--resume \(Self.sessionID)"), "\(command)",
                sourceLocation: sourceLocation)

        #expect(f.admission.requests.count == 1,
                "start admission: \(f.admission.requests)", sourceLocation: sourceLocation)
        #expect(f.admission.requests.first?.terminalID == terminal.id,
                sourceLocation: sourceLocation)
        #expect(try f.trustSeeded(), "the trust seed did not write the worktree",
                sourceLocation: sourceLocation)
        let titles = await f.heldTitles()
        #expect(titles[terminal.id] != nil, "no session title for the start: \(titles)",
                sourceLocation: sourceLocation)
        let record = try #require(
            f.spawnRecord(Self.sessionID), "no spawn record for the session",
            sourceLocation: sourceLocation)
        #expect(record.sessionId == Self.sessionID, sourceLocation: sourceLocation)
        let row = try #require(
            try await f.db.terminals.get(id: terminal.id), sourceLocation: sourceLocation)
        let incarnation = try #require(row.sessionIncarnationID, sourceLocation: sourceLocation)
        #expect(record.incarnationId == incarnation.uuidString, sourceLocation: sourceLocation)
    }

    // MARK: - The gate before the writes

    /// `terminal.create` resuming a session a deleted live tmux row carried.
    @Test func terminalCreateResumingAMarkedSessionIsRefusedBeforeAnyWrite() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        _ = try await closeALiveTmuxRow(f)
        let params = TerminalCreateParams(
            worktreeID: f.worktree.id, type: .claude, resumeSessionID: Self.sessionID)

        let refused = try await f.send(RPCMethod.terminalCreate, params)
        try await expectRefusedBeforeAnyWrite(refused, f)

        f.server.state = .absent
        let created = try await f.send(RPCMethod.terminalCreate, params)
        #expect(created.success, "error: \(created.error ?? "nil")")
        let terminal = try created.decodeResult(TBDShared.Terminal.self)
        try await expectEveryWriteOnceLetThrough(terminal, f)
    }

    /// Closed Terminals' reopen of the entry a deleted live tmux row's close
    /// marked.
    @Test func closedTerminalsReopenOfAMarkedEntryIsRefusedBeforeAnyWrite() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let entry = try await closeALiveTmuxRow(f)
        let params = TerminalHistoryReviveParams(worktreeID: f.worktree.id, id: entry.id)

        let refused = try await f.send(RPCMethod.terminalHistoryRevive, params)
        try await expectRefusedBeforeAnyWrite(refused, f)

        f.server.state = .absent
        let reopened = try await f.send(RPCMethod.terminalHistoryRevive, params)
        #expect(reopened.success, "error: \(reopened.error ?? "nil")")
        let terminal = try reopened.decodeResult(TBDShared.Terminal.self)
        try await expectEveryWriteOnceLetThrough(terminal, f)
    }

    /// The History pane's resume of a Codex thread a deleted live tmux row
    /// carried goes through `terminal.create`, whose gate comes before the
    /// Codex preparation that writes the Codex home, and before start
    /// admission.
    @Test func sessionResumeOfAMarkedCodexThreadIsRefusedBeforeTheCodexHomeIsPrepared() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let thread = "acme-codex-thread"
        let identity = AgentSessionIdentity(agentKind: .codex, sessionID: thread)
        try await f.db.localAgentSessions.upsert(LocalAgentSession(
            worktreeID: f.worktree.id, identity: identity,
            firstObservedAt: .distantPast, lastObservedAt: .distantPast))
        try await f.db.terminalHistory.recordLiveTmuxClose(
            terminal: TBDShared.Terminal(
                worktreeID: f.worktree.id, tmuxWindowID: "@3", tmuxPaneID: "%3",
                claudeSessionID: thread, kind: .codex),
            server: f.worktree.tmuxServer)
        let homes = CallCount()
        f.router.codexHomeEnsurer = {
            homes.record()
            return URL(fileURLWithPath: CodexLaunchTestStub.homePath, isDirectory: true)
        }
        let params = SessionResumeParams(worktreeID: f.worktree.id, identity: identity)

        let refused = try await f.send(RPCMethod.sessionResume, params)
        #expect(!refused.success)
        #expect(refused.errorCode == RPCErrorCode.terminalOnTmux.rawValue)
        #expect(f.probe.servers == ["tbd-acme"])
        #expect(f.holder.launches.isEmpty)
        #expect(homes.count == 0, "the Codex home was prepared before the resume gate refused")
        #expect(f.admission.requests.isEmpty,
                "start admission was consulted before the resume gate refused: \(f.admission.requests)")

        f.server.state = .absent
        let resumed = try await f.send(RPCMethod.sessionResume, params)
        #expect(resumed.success, "error: \(resumed.error ?? "nil")")
        let terminal = try resumed.decodeResult(TBDShared.Terminal.self)
        #expect(homes.count == 1, "the Codex home was not prepared for the resume")
        #expect(f.admission.requests.count == 1, "start admission: \(f.admission.requests)")
        #expect(f.admission.requests.first?.terminalID == terminal.id)
        let command = try #require(f.holder.launch(for: terminal.id)?.commandLine)
        #expect(command.contains("resume '\(thread)'"), "\(command)")
    }

    // MARK: - Starts that fork ask nothing

    /// A profile switch's fork tab starts Claude with `--fork-session` from
    /// the marked session: a new session id, never a second agent on the
    /// marked one. So it asks no probe and opens while the server may run.
    @Test func aProfileSwitchForkOfAMarkedSessionAsksNoProbe() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        _ = try await closeALiveTmuxRow(f)
        let source = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, claudeSessionID: Self.sessionID, kind: .claude,
            transport: .holder)
        // A transcript with a turn in it, so the fork carries the
        // conversation (`--resume <id> --fork-session`) rather than starting
        // a fresh session.
        let transcript = f.root.appendingPathComponent("\(Self.sessionID).jsonl")
        try #"{"type":"user","message":{"role":"user","content":"hello there"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        try await f.db.terminals.updateSession(
            id: source.id, sessionID: Self.sessionID, transcriptPath: transcript.path)
        let target = try await f.db.modelProfiles.create(name: "acme-b", kind: .oauth)

        let swapped = try await f.send(
            RPCMethod.terminalSwapProfile,
            TerminalSwapProfileParams(terminalID: source.id, newProfileID: target.id, mode: .fork))

        #expect(swapped.success, "error: \(swapped.error ?? "nil")")
        let fork = try swapped.decodeResult(TBDShared.Terminal.self)
        #expect(fork.id != source.id)
        #expect(fork.transport == .holder)
        let command = try #require(f.holder.launch(for: fork.id)?.commandLine)
        #expect(command.contains("--resume \(Self.sessionID)"), "\(command)")
        #expect(command.contains("--fork-session"), "\(command)")
        #expect(f.probe.servers.isEmpty, "the fork asked the resume gate: \(f.probe.servers)")
    }

    /// `worktree.reviveConversationFresh` of a Claude conversation carries it
    /// into a new worktree with `--fork-session`. The router asks the gate
    /// for a Codex thread only, and the new worktree's spawn forks, so the
    /// revive asks no probe and goes ahead while the server that a mark of
    /// the session names may run.
    @Test func aFreshBranchReviveOfAMarkedClaudeConversationAsksNoProbe() async throws {
        let f = try await fixture()
        defer { f.tearDown() }
        let (gitRoot, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: gitRoot) }
        // This lifecycle resolves no profile, so a trust seed would write the
        // home directory's `.claude.json`. Off for non-scratch worktrees, it
        // writes nothing outside the test's roots.
        try await f.db.config.setAutoTrustWorktrees(enabled: false)
        let repo = try await makeTestRepo(db: f.db, tempDir: gitRoot, repoDir: repoDir)
        let archived = try await f.db.worktrees.create(
            repoID: repo.id, name: "acme-archived", branch: "tbd/acme-archived",
            path: gitRoot.appendingPathComponent("acme-archived").path,
            tmuxServer: "tbd-acme-archived")
        try await f.db.terminalHistory.recordLiveTmuxClose(
            terminal: TBDShared.Terminal(
                worktreeID: archived.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
                claudeSessionID: Self.sessionID, kind: .claude),
            server: archived.tmuxServer)
        try await f.db.worktrees.archive(id: archived.id, claudeSessionIDs: [Self.sessionID])
        try await f.db.localAgentSessions.upsert(LocalAgentSession(
            worktreeID: archived.id,
            identity: AgentSessionIdentity(agentKind: .claude, sessionID: Self.sessionID),
            firstObservedAt: .distantPast, lastObservedAt: .distantPast))
        // The revive refuses a conversation with no transcript under the
        // projects root it resumes from: the ambient one, with no profile.
        let transcript = f.configDirManager.ambientConfigDirectory
            .appendingPathComponent("projects/acme-source", isDirectory: true)
            .appendingPathComponent("\(Self.sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"type":"user","message":{"role":"user","content":"source conversation"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        #expect(try await f.db.terminalHistory.liveOnTmuxServers(sessionIDs: [Self.sessionID])
            == [archived.tmuxServer])

        let revived = try await f.send(
            RPCMethod.worktreeReviveConversationFresh,
            WorktreeReviveConversationFreshParams(
                archivedWorktreeID: archived.id, sessionID: Self.sessionID))

        #expect(revived.success, "error: \(revived.error ?? "nil")")
        let result = try revived.decodeResult(WorktreeReviveConversationFreshResult.self)
        let claude = try #require(
            try await f.db.terminals.list(worktreeID: result.worktree.id)
                .first { $0.kind == .claude })
        #expect(claude.transport == .holder)
        let command = try #require(f.holder.launch(for: claude.id)?.commandLine)
        #expect(command.contains("--resume \(Self.sessionID)"), "\(command)")
        #expect(command.contains("--fork-session"), "\(command)")
        #expect(f.probe.servers.isEmpty, "the fresh revive asked the resume gate: \(f.probe.servers)")
    }

    // MARK: - A carryover through worktree creation

    /// Worktree creation carrying a conversation over, with no gate asked
    /// beforehand (`completeCreateWorktree` with a carryover, the step a
    /// fresh-branch revive hands its conversation to). A Codex thread is
    /// resumed itself (`forksSession` false), so the primary spawn's gate
    /// refuses it while a mark of the thread names a server that may run: no
    /// Codex tab is started. The create had already made its checkout, so its
    /// rollback deletes the create's own row and re-adopts the checkout as a
    /// fresh active worktree with no tabs. A Claude conversation marked on the
    /// same server forks (`--fork-session`), so its create asks nothing and
    /// goes ahead.
    @Test func aCodexCarryoverOfAMarkedThreadIsRefusedWhileAClaudeCarryoverForks() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(
            inMemory: true,
            notesDir: tempDir.appendingPathComponent("notes", isDirectory: true).path,
            terminalHistoryDir: tempDir.appendingPathComponent("history", isDirectory: true).path)
        // No profile is resolved here, so a trust seed would write the home
        // directory's `.claude.json`. Off for non-scratch worktrees, it writes
        // nothing outside the test's root.
        try await db.config.setAutoTrustWorktrees(enabled: false)
        let holder = FakeHolderLaunch()
        let probe = RecordingLeftoverTmuxProbe { _ in .running }
        let claudeHome = tempDir.appendingPathComponent("claude-home", isDirectory: true)
        var configured = WorktreeLifecycle(
            db: db, git: GitManager(), hooks: HookResolver(),
            configDirManager: ClaudeProfileConfigDirManager(
                baseDirectory: claudeHome.appendingPathComponent("profiles", isDirectory: true),
                hostBaseDirectory: claudeHome),
            preSessionPollInterval: 0.05,
            processSignaller: ScriptedLivenessSignaller.doubleJobsRunning,
            codexExecutableResolver: CodexLaunchTestStub.executableResolver,
            codexHomeEnsurer: CodexLaunchTestStub.homeEnsurer,
            sessionsDir: tempDir.appendingPathComponent("sessions", isDirectory: true),
            leftoverTmuxProbe: probe.probe)
        configured.holderRegistry = makeHolderRegistryDouble(launch: holder)
        let lifecycle = configured
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let source = try await db.worktrees.create(
            repoID: repo.id, name: "acme-source", branch: "tbd/acme-source",
            path: tempDir.appendingPathComponent("acme-source").path,
            tmuxServer: "tbd-acme-source")
        let thread = "acme-thread"
        let claudeSession = "acme-session"
        try await db.terminalHistory.recordLiveTmuxClose(
            terminal: TBDShared.Terminal(
                worktreeID: source.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
                claudeSessionID: thread, kind: .codex),
            server: source.tmuxServer)
        try await db.terminalHistory.recordLiveTmuxClose(
            terminal: TBDShared.Terminal(
                worktreeID: source.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
                claudeSessionID: claudeSession, kind: .claude),
            server: source.tmuxServer)
        #expect(try await db.terminalHistory.liveOnTmuxServers(sessionIDs: [thread])
            == [source.tmuxServer])
        #expect(try await db.terminalHistory.liveOnTmuxServers(sessionIDs: [claudeSession])
            == [source.tmuxServer])

        let codexCreate = try await lifecycle.beginCreateWorktree(
            repoID: repo.id, displayName: "acme codex carryover")
        await #expect(throws: TmuxResumeRefusal(server: source.tmuxServer)) {
            _ = try await lifecycle.completeCreateWorktree(
                worktreeID: codexCreate.id,
                carryover: ConversationCarryover(
                    identity: AgentSessionIdentity(agentKind: .codex, sessionID: thread),
                    notesSeed: "# Revived conversation\n"),
                retryGeneratedNameOnCollision: false)
        }

        #expect(holder.launches.isEmpty, "a tab was started for the refused Codex carryover")
        #expect(probe.servers == [source.tmuxServer])
        #expect(try await db.terminalHistory.liveOnTmuxServers(sessionIDs: [thread])
            == [source.tmuxServer])
        // What the refused create leaves: its own row is gone, and the
        // checkout it made is kept on disk under one fresh active row with no
        // tabs.
        #expect(try await db.worktrees.get(id: codexCreate.id) == nil)
        #expect(FileManager.default.fileExists(atPath: codexCreate.localPath))
        let atCheckout = try await db.worktrees.list()
            .filter { $0.localPath == codexCreate.localPath }
        #expect(atCheckout.count == 1, "rows at the checkout: \(atCheckout)")
        let readopted = try #require(atCheckout.first)
        #expect(readopted.id != codexCreate.id)
        #expect(readopted.status == .active)
        #expect(try await db.terminals.list(worktreeID: readopted.id).isEmpty)

        let claudeCreate = try await lifecycle.beginCreateWorktree(
            repoID: repo.id, displayName: "acme claude carryover")
        let completion = try await lifecycle.completeCreateWorktree(
            worktreeID: claudeCreate.id,
            carryover: ConversationCarryover(
                sourceSessionID: claudeSession, notesSeed: "# Revived conversation\n"),
            retryGeneratedNameOnCollision: false)
        guard case .ready = completion else {
            Issue.record("expected the Claude carryover's create to complete synchronously")
            return
        }
        let claude = try #require(
            try await db.terminals.list(worktreeID: claudeCreate.id).first { $0.kind == .claude })
        #expect(claude.transport == .holder)
        let command = try #require(holder.launch(for: claude.id)?.commandLine)
        #expect(command.contains("--resume \(claudeSession)"), "\(command)")
        #expect(command.contains("--fork-session"), "\(command)")
        #expect(probe.servers == [source.tmuxServer],
                "the Claude carryover asked the resume gate: \(probe.servers)")
    }
}
