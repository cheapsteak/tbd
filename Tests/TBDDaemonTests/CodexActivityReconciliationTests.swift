import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

@Suite("codex activity reconciliation")
struct CodexActivityReconciliationTests {
    private static let raceRendezvousTimeout: Duration = .seconds(30)

    let db: TBDDatabase
    let router: RPCRouter
    let presentationObservedAt: Date

    init() throws {
        let db = try TBDDatabase(inMemory: true)
        let presentationObservedAt = Date(timeIntervalSince1970: 1_790_000_000)
        self.db = db
        self.presentationObservedAt = presentationObservedAt
        self.router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            now: { presentationObservedAt },
            actuationLog: makeTestActuationLog()
        )
    }

    private func makeRouter(now: @escaping @Sendable () -> Date) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(),
                tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            now: now,
            actuationLog: makeTestActuationLog())
    }

    private func makeBoundaryTerminal(
        tag: String,
        kind: TerminalKind = .codex
    ) async throws -> Terminal {
        let repo = try await db.repos.create(
            path: "/tmp/car-boundary-\(tag)-repo-\(UUID().uuidString)",
            displayName: "car-boundary-\(tag)", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-boundary-\(tag)-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-boundary-\(tag)")
        return try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: kind == .codex ? TerminalLabel.codex : kind.rawValue,
            kind: kind)
    }

    private func seedBoundary(_ offset: Int64, terminalID: UUID) async throws {
        try await db.writerForTests.write { database in
            try database.execute(
                sql: "UPDATE terminal SET codexTranscriptBoundaryOffset = ? WHERE id = ?",
                arguments: [offset, terminalID.uuidString])
        }
    }

    private func makeCodexRecreateFixture(
        tag: String,
        tmux: TmuxManager,
        now: @escaping @Sendable () -> Date = Date.init
    ) async throws -> (router: RPCRouter, terminal: Terminal, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-recreate-\(tag)-\(UUID().uuidString)", isDirectory: true)
        let codexHome = directory.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repo = try await db.repos.create(
            path: directory.path,
            displayName: "recreate-\(tag)",
            defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt",
            branch: "main",
            path: directory.path,
            tmuxServer: "tbd-codex-recreate-\(tag)")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: "@old",
            tmuxPaneID: "%old",
            label: "Codex Recovery",
            kind: .codex)
        try await db.terminals.updateSession(
            id: terminal.id,
            sessionID: "old-session",
            transcriptPath: "/tmp/old-codex-rollout.jsonl")
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            codexExecutableResolver: { "/bin/true" },
            codexHomeEnsurer: { codexHome },
            now: now,
            actuationLog: makeTestActuationLog())
        return (router, terminal, directory)
    }

    @Test("terminal.list exposes transcript working without changing persisted hook activity")
    func terminalListExposesWorkingPresentationWithoutMutation() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-repo-\(UUID().uuidString)",
            displayName: "car-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt",
            branch: "main",
            path: "/tmp/car-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car"
        )

        let transcriptPath = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"a"}}"# + "\n")
        defer { try? FileManager.default.removeItem(at: transcriptPath.deletingLastPathComponent()) }

        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: "Codex",
            kind: .codex
        )
        _ = try #require(try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            sessionID: "codex-session",
            transcriptPath: transcriptPath.path,
            observedAt: Date(timeIntervalSince1970: 1_779_999_999)))
        let observedAt = Date(timeIntervalSince1970: 1_780_000_000)
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .idle,
            source: .hookEvent("Stop"), observedAt: observedAt)

        let request = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id)
        )
        let response = await router.handle(request)
        #expect(response.success)

        let terminals = try response.decodeResult([Terminal].self)
        #expect(terminals.count == 1)
        #expect(terminals[0].presentationActivityState == .working)
        #expect(terminals[0].presentationActivityObservedAt == presentationObservedAt)
        #expect(terminals[0].activityState == .idle)
        #expect(terminals[0].activityStateSource == .hookEvent("Stop"))
        #expect(terminals[0].activityStateObservedAt == observedAt)

        let persisted = try await db.terminals.get(id: terminal.id)
        #expect(persisted?.presentationActivityState == nil)
        #expect(persisted?.presentationActivityObservedAt == nil)
        #expect(persisted?.activityState == .idle)
        #expect(persisted?.activityStateSource == .hookEvent("Stop"))
        #expect(persisted?.activityStateObservedAt == observedAt)
    }

    @Test("ordinary activity hooks do not invalidate an in-flight transcript observation")
    func ordinaryActivityHookKeepsTranscriptEvidence() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-hook-race-repo-\(UUID().uuidString)",
            displayName: "car-hook-race-repo",
            defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt",
            branch: "main",
            path: "/tmp/car-hook-race-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-hook-race")
        let transcript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"current"}}"#
                + "\n")
        defer { try? FileManager.default.removeItem(at: transcript.deletingLastPathComponent()) }
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: "Codex",
            kind: .codex)
        _ = try #require(try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            sessionID: "current-session",
            transcriptPath: transcript.path,
            observedAt: Date(timeIntervalSince1970: 1_790_000_009)))
        let initialActivityAt = Date(timeIntervalSince1970: 1_790_000_010)
        try await db.terminals.setActivityState(
            id: terminal.id,
            activityState: .idle,
            source: .hookEvent("Stop"),
            observedAt: initialActivityAt)

        let listAt = initialActivityAt.addingTimeInterval(1)
        let hookAt = listAt.addingTimeInterval(1)
        let dates = BlockingListDates(first: listAt, subsequent: hookAt)
        let raceRouter = makeRouter(now: dates.provider)
        let list = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id))
        let hook = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(
                terminalID: terminal.id,
                activityState: .working))

        let inFlightList = gateHoldingTask { await raceRouter.handle(list) }
        guard await waitUntil(
            { dates.firstCallIsBlocked }, timeout: Self.raceRendezvousTimeout
        ) else {
            dates.releaseFirstCall()
            _ = await inFlightList.value
            Issue.record("terminal.list never reached its transcript stamp")
            return
        }
        #expect((await raceRouter.handle(hook)).success)
        dates.releaseFirstCall()

        let response = await inFlightList.value
        #expect(response.success)
        let listed = try #require(
            response.decodeResult([Terminal].self).first(where: { $0.id == terminal.id }))
        #expect(listed.activityState == .working)
        #expect(listed.activityStateOrderObservedAt == hookAt)
        #expect(listed.presentationActivityState == .working)
        #expect(listed.presentationActivityObservedAt == listAt)
    }

    @Test("accepted same-path SessionStart supersedes an orphan transcript turn")
    func samePathSessionStartResetsTranscriptLifecycle() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-reset-repo-\(UUID().uuidString)",
            displayName: "car-reset-repo",
            defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt",
            branch: "main",
            path: "/tmp/car-reset-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-reset")
        let transcript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"orphan"}}"#
                + "\n")
        defer { try? FileManager.default.removeItem(at: transcript.deletingLastPathComponent()) }
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: "Codex",
            kind: .codex)
        try await db.terminals.updateSession(
            id: terminal.id,
            sessionID: "same-session",
            transcriptPath: transcript.path)
        let list = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id))

        let before = await router.handle(list)
        #expect(before.success)
        #expect(try before.decodeResult([Terminal].self).first?
            .presentationActivityState == nil)

        try append(
            Data((#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"current"}}"#
                + "\n").utf8),
            to: transcript)
        let current = await router.handle(list)
        #expect(current.success)
        #expect(try current.decodeResult([Terminal].self).first?
            .presentationActivityState == .working)

        let sessionStart = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "same-session",
                transcriptPath: transcript.path,
                source: "resume"))
        #expect((await router.handle(sessionStart)).success)

        let afterBoundary = await router.handle(list)
        #expect(afterBoundary.success)
        #expect(try afterBoundary.decodeResult([Terminal].self).first?
            .presentationActivityState == nil)

        try append(
            Data((#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"later"}}"#
                + "\n").utf8),
            to: transcript)
        let afterLaterTurn = await router.handle(list)
        #expect(afterLaterTurn.success)
        #expect(try afterLaterTurn.decodeResult([Terminal].self).first?
            .presentationActivityState == .working)
    }

    @Test("first SessionStart retains a turn that began before the hook arrived")
    func firstSessionStartRetainsAlreadyStartedTurn() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-first-start-repo-\(UUID().uuidString)",
            displayName: "car-first-start-repo",
            defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt",
            branch: "main",
            path: "/tmp/car-first-start-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-first-start")
        let transcript = try makeTranscript(
            #"{"type":"session_meta","payload":{"id":"initial-session"}}"# + "\n"
                + #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"initial-turn"}}"#
                + "\n")
        defer { try? FileManager.default.removeItem(at: transcript.deletingLastPathComponent()) }
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: "Codex",
            kind: .codex)
        #expect(terminal.claudeSessionID == nil)

        let sessionStart = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "initial-session",
                transcriptPath: transcript.path,
                source: "SessionStart"))
        #expect((await router.handle(sessionStart)).success)

        let list = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id))
        let working = await router.handle(list)
        #expect(working.success)
        #expect(try working.decodeResult([Terminal].self).first?
            .presentationActivityState == .working)

        try append(
            Data((
                #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"initial-turn"}}"#
                    + "\n").utf8),
            to: transcript)
        let idle = await router.handle(list)
        #expect(idle.success)
        #expect(try idle.decodeResult([Terminal].self).first?
            .presentationActivityState == .idle)
    }

    @Test("recreated Codex window adopts its new process's initial task")
    func recreatedCodexWindowAdoptsInitialTask() async throws {
        let worktreeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-recreate-\(UUID().uuidString)", isDirectory: true)
        let codexHome = worktreeDirectory.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: worktreeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktreeDirectory) }

        let repo = try await db.repos.create(
            path: worktreeDirectory.path,
            displayName: "recreate-repo",
            defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt",
            branch: "main",
            path: worktreeDirectory.path,
            tmuxServer: "tbd-codex-recreate")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            // Dry-run window creation deliberately reuses these coordinates,
            // proving the process token closes the tmux-ID/label ABA case.
            tmuxWindowID: "@mock-0",
            tmuxPaneID: "%mock-0",
            label: "Codex Recovery",
            kind: .codex)
        let oldSessionAt = Date(timeIntervalSince1970: 1_790_000_100)
        let dates = TestDateSource(oldSessionAt)
        let launchRecorder = BlockingCodexLaunchRecorder()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: launchRecorder.recorder)
        let recreateRouter = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            codexExecutableResolver: { "/bin/true" },
            codexHomeEnsurer: { codexHome },
            now: dates.provider,
            actuationLog: makeTestActuationLog())
        let oldTranscript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"old-turn"}}"#
                + "\n")
        defer {
            try? FileManager.default.removeItem(at: oldTranscript.deletingLastPathComponent())
        }
        let oldSessionStart = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "old-session",
                transcriptPath: oldTranscript.path,
                source: "startup"))
        #expect((await recreateRouter.handle(oldSessionStart)).success)
        let list = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id))
        #expect((await recreateRouter.handle(list)).success)

        let transcript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"new-turn"}}"#
                + "\n")
        defer { try? FileManager.default.removeItem(at: transcript.deletingLastPathComponent()) }
        dates.advance(by: 10)
        let recreate = try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: terminal.id))
        let recreateTask = gateHoldingTask { await recreateRouter.handle(recreate) }
        guard await waitUntil(
            { launchRecorder.codexLaunchIsBlocked },
            timeout: Self.raceRendezvousTimeout
        ) else {
            launchRecorder.releaseCodexLaunch()
            _ = await recreateTask.value
            Issue.record("recreate never reached the Codex process launch")
            return
        }

        // Exercise the real race: a delayed hook from the dead process reaches
        // the handler after the prelaunch process token commits. Its legacy
        // nil token must be rejected while the replacement launch is paused.
        dates.advance(by: 1)
        let gapSessionStart = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "old-session",
                transcriptPath: oldTranscript.path,
                source: "startup"))
        #expect((await recreateRouter.handle(gapSessionStart)).success)
        let staged = try #require(try await db.terminals.get(id: terminal.id))
        let replacementToken = try #require(staged.sessionIncarnationID)
        #expect(staged.tmuxWindowID == terminal.tmuxWindowID)
        #expect(staged.tmuxPaneID == terminal.tmuxPaneID)
        #expect(staged.label == terminal.label)
        #expect(staged.claudeSessionID == nil)
        #expect(launchRecorder.blockedCommand?.last?.contains(
            "TBD_TERMINAL_INCARNATION_ID='\(replacementToken.uuidString)'") == true)
        let matchedCLIPath = try #require(AgentProcessEnvironment.cliPath)
        #expect(launchRecorder.blockedCommand?.last?.contains(
            "TBD_CLI_PATH=\(SystemPromptBuilder.shellEscape(matchedCLIPath))") == true)
        launchRecorder.releaseCodexLaunch()

        let recreateResponse = await recreateTask.value
        #expect(recreateResponse.success, "recreate failed: \(recreateResponse.error ?? "nil")")
        let finalized = try #require(try await db.terminals.get(id: terminal.id))
        #expect(finalized.claudeSessionID == nil)
        #expect(finalized.transcriptPath == nil)
        #expect(finalized.sessionOrderObservedAt == nil)

        // The replacement process echoes its environment token and can attach
        // immediately; no post-launch writer can erase the accepted hook.
        dates.advance(by: 1)
        let sessionStart = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "new-session",
                transcriptPath: transcript.path,
                source: "startup",
                sessionIncarnationID: replacementToken))
        #expect((await recreateRouter.handle(sessionStart)).success)

        let recreated = try #require(try await db.terminals.get(id: terminal.id))
        #expect(recreated.label == "Codex Recovery")
        #expect(recreated.kind == .codex)
        #expect(recreated.claudeSessionID == "new-session")
        #expect(recreated.transcriptPath == transcript.path)
        #expect(recreated.sessionOrderObservedAt == dates.now)
        #expect(recreated.activityState == .idle)
        let launchCommands = launchRecorder.snapshot()
        let newWindowIndex = try #require(
            launchCommands.firstIndex(where: { $0.contains("new-window") }))
        let codexLaunchIndex = try #require(
            launchCommands.firstIndex(where: { command in
                command.contains("respawn-window")
                    && command.last?.contains(" --profile") == true
            }))
        #expect(newWindowIndex < codexLaunchIndex)
        #expect(launchCommands[newWindowIndex].last?.contains(" --profile") == false)

        // A delayed hook from the dead process must not mutate the replacement
        // process after its new identity is attached.
        dates.advance(by: 1)
        let staleActivity = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(
                terminalID: terminal.id,
                activityState: .working,
                sessionID: "old-session"))
        #expect((await recreateRouter.handle(staleActivity)).success)
        #expect(try await db.terminals.get(id: terminal.id)?.activityState == .idle)

        let working = await recreateRouter.handle(list)
        #expect(working.success)
        #expect(try working.decodeResult([Terminal].self).first?
            .presentationActivityState == .working)

        try append(
            Data((
                #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"new-turn"}}"#
                    + "\n").utf8),
            to: transcript)
        let idle = await recreateRouter.handle(list)
        #expect(idle.success)
        #expect(try idle.decodeResult([Terminal].self).first?
            .presentationActivityState == .idle)
    }

    @Test("failed Codex staging keeps the previous durable session")
    func failedCodexStagingKeepsPreviousSession() async throws {
        let recorder = LockedCommandRecorder()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: recorder.append,
            dryRunCreateWindowError: { _ in
                TmuxError.unexpectedOutput("staging failed")
            })
        let fixture = try await makeCodexRecreateFixture(tag: "stage-failure", tmux: tmux)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let request = try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: fixture.terminal.id))

        let response = await fixture.router.handle(request)

        #expect(!response.success)
        let stored = try #require(try await db.terminals.get(id: fixture.terminal.id))
        #expect(stored.tmuxWindowID == "@old")
        #expect(stored.tmuxPaneID == "%old")
        #expect(stored.claudeSessionID == "old-session")
        #expect(stored.transcriptPath == "/tmp/old-codex-rollout.jsonl")
        #expect(!recorder.snapshot().contains { command in
            command.contains("respawn-window")
        })
    }

    @Test("failed Codex launch leaves a cleared retryable row and removes its stage")
    func failedCodexLaunchLeavesRetryableRow() async throws {
        let recorder = LockedCommandRecorder()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: recorder.append,
            dryRunRespawnWindowError: { windowID in
                windowID == "@mock-0"
                    ? TmuxError.unexpectedOutput("Codex launch failed")
                    : nil
            })
        let resetAt = Date(timeIntervalSince1970: 1_790_000_200)
        let fixture = try await makeCodexRecreateFixture(
            tag: "launch-failure", tmux: tmux, now: { resetAt })
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let request = try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: fixture.terminal.id))

        let response = await fixture.router.handle(request)

        #expect(!response.success)
        let stored = try #require(try await db.terminals.get(id: fixture.terminal.id))
        #expect(stored.tmuxWindowID == "@mock-0")
        #expect(stored.tmuxPaneID == "%mock-0")
        #expect(stored.label == "Codex Recovery")
        #expect(stored.kind == .codex)
        #expect(stored.claudeSessionID == nil)
        #expect(stored.transcriptPath == nil)
        #expect(stored.sessionOrderObservedAt == nil)
        #expect(stored.activityState == .unknown)
        let commands = recorder.snapshot()
        #expect(commands.contains { command in
            command.contains("respawn-window") && command.contains("@mock-0")
        })
        #expect(commands.contains { command in
            command.contains("kill-window") && command.contains("@mock-0")
        })
    }

    @Test("sub-millisecond initial generation survives a database round trip")
    func submillisecondInitialGenerationRemainsWorkingAfterList() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-submillisecond-initial-repo-\(UUID().uuidString)",
            displayName: "car-submillisecond-initial-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-submillisecond-initial-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-submillisecond-initial")
        let transcript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"initial"}}"#
                + "\n")
        defer { try? FileManager.default.removeItem(at: transcript.deletingLastPathComponent()) }
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        let observedAt = Date(timeIntervalSince1970: 1_790_000_000.123_6)
        let roundedRouter = makeRouter(now: { observedAt })

        let start = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id, sessionID: "initial-session",
                transcriptPath: transcript.path, source: "SessionStart"))
        #expect((await roundedRouter.handle(start)).success)
        let stored = try #require(try await db.terminals.get(id: terminal.id))
        let persistedGeneration = try #require(stored.sessionOrderObservedAt)
        #expect(persistedGeneration == observedAt)

        let list = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id))
        let response = await roundedRouter.handle(list)
        #expect(response.success)
        #expect(try response.decodeResult([Terminal].self).first?
            .presentationActivityState == .working)
    }

    @Test("a stored transcript path makes a nil-identity SessionStart a later attachment")
    func storedTranscriptPathFencesNilIdentitySessionStart() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-partial-path-repo-\(UUID().uuidString)",
            displayName: "car-partial-path-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-partial-path-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-partial-path")
        let transcript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"orphan"}}"#
                + "\n")
        defer { try? FileManager.default.removeItem(at: transcript.deletingLastPathComponent()) }
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        try await db.writerForTests.write { database in
            try database.execute(
                sql: "UPDATE terminal SET transcriptPath = ? WHERE id = ?",
                arguments: [transcript.path, terminal.id.uuidString])
        }

        let sessionStart = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id, sessionID: "recovered-session",
                transcriptPath: transcript.path, source: "SessionStart"))
        #expect((await router.handle(sessionStart)).success)

        let list = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id))
        let response = await router.handle(list)
        #expect(response.success)
        #expect(try response.decodeResult([Terminal].self).first?
            .presentationActivityState == nil)
        #expect(try await db.terminals.get(id: terminal.id)?.codexTranscriptBoundaryOffset
            == Int64(try Data(contentsOf: transcript).count))
    }

    @Test("a stored session-order watermark makes a nil-identity SessionStart later")
    func storedSessionOrderFencesNilIdentitySessionStart() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-partial-order-repo-\(UUID().uuidString)",
            displayName: "car-partial-order-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-partial-order-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-partial-order")
        let transcript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"orphan"}}"#
                + "\n")
        defer { try? FileManager.default.removeItem(at: transcript.deletingLastPathComponent()) }
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        try await db.writerForTests.write { database in
            try database.execute(
                sql: "UPDATE terminal SET sessionOrderObservedAt = ? WHERE id = ?",
                arguments: [presentationObservedAt.addingTimeInterval(-1), terminal.id.uuidString])
        }

        let sessionStart = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id, sessionID: "recovered-session",
                transcriptPath: transcript.path, source: "SessionStart"))
        #expect((await router.handle(sessionStart)).success)

        let list = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id))
        let response = await router.handle(list)
        #expect(response.success)
        #expect(try response.decodeResult([Terminal].self).first?
            .presentationActivityState == nil)
        #expect(try await db.terminals.get(id: terminal.id)?.codexTranscriptBoundaryOffset
            == Int64(try Data(contentsOf: transcript).count))
    }

    @Test("a stored identity makes a SessionStart a later attachment")
    func storedIdentityFencesNextSessionStart() async throws {
        let terminal = try await makeBoundaryTerminal(tag: "partial-identity")
        let transcript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"old"}}"#
                + "\n")
        defer { try? FileManager.default.removeItem(at: transcript.deletingLastPathComponent()) }
        try await db.writerForTests.write { database in
            try database.execute(
                sql: "UPDATE terminal SET claudeSessionID = ? WHERE id = ?",
                arguments: ["prior-session", terminal.id.uuidString])
        }

        let application = try #require(try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            sessionID: "next-session",
            transcriptPath: transcript.path,
            observedTranscriptBoundary: ObservedTranscriptBoundary(
                path: transcript.path,
                eof: Int64(try Data(contentsOf: transcript).count)),
            observedAt: presentationObservedAt))

        #expect(!application.isInitialAttachment)
        #expect(application.transcriptBoundaryOffset
            == Int64(try Data(contentsOf: transcript).count))
        #expect(try await db.terminals.get(id: terminal.id)?.codexTranscriptBoundaryOffset
            == application.transcriptBoundaryOffset)
    }

    @Test("a stored boundary makes an otherwise empty SessionStart a later attachment")
    func storedBoundaryFencesNextSessionStart() async throws {
        let terminal = try await makeBoundaryTerminal(tag: "partial-boundary")
        let transcript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"old"}}"#
                + "\n")
        defer { try? FileManager.default.removeItem(at: transcript.deletingLastPathComponent()) }
        try await seedBoundary(7, terminalID: terminal.id)
        let eof = Int64(try Data(contentsOf: transcript).count)

        let application = try #require(try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            sessionID: "next-session",
            transcriptPath: transcript.path,
            observedTranscriptBoundary: ObservedTranscriptBoundary(
                path: transcript.path,
                eof: eof),
            observedAt: presentationObservedAt))

        #expect(!application.isInitialAttachment)
        #expect(application.transcriptBoundaryOffset == eof)
        #expect(try await db.terminals.get(id: terminal.id)?.codexTranscriptBoundaryOffset == eof)
    }

    @Test("an initial Codex attachment stores zero regardless of observed EOF")
    func initialAttachmentStoresZeroBoundary() async throws {
        let terminal = try await makeBoundaryTerminal(tag: "initial")

        let application = try #require(try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            sessionID: "initial-session",
            transcriptPath: "/tmp/car-boundary-initial.jsonl",
            observedTranscriptBoundary: ObservedTranscriptBoundary(
                path: "/tmp/car-boundary-initial.jsonl",
                eof: 4_096),
            observedAt: presentationObservedAt))

        #expect(application.isInitialAttachment)
        #expect(application.transcriptBoundaryOffset == 0)
        #expect(try await db.terminals.get(id: terminal.id)?.codexTranscriptBoundaryOffset == 0)
    }

    @Test("stale and equal-stamped SessionStarts cannot move an accepted boundary")
    func rejectedSessionStartsPreserveAcceptedBoundary() async throws {
        let terminal = try await makeBoundaryTerminal(tag: "rejected")
        _ = try #require(try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            sessionID: "initial-session",
            transcriptPath: "/tmp/car-boundary-rejected.jsonl",
            observedTranscriptBoundary: ObservedTranscriptBoundary(
                path: "/tmp/car-boundary-rejected.jsonl",
                eof: 10),
            observedAt: presentationObservedAt))
        let acceptedAt = presentationObservedAt.addingTimeInterval(1)
        let accepted = try #require(try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            sessionID: "accepted-session",
            transcriptPath: "/tmp/car-boundary-rejected.jsonl",
            observedTranscriptBoundary: ObservedTranscriptBoundary(
                path: "/tmp/car-boundary-rejected.jsonl",
                eof: 111),
            observedAt: acceptedAt))
        #expect(accepted.transcriptBoundaryOffset == 111)

        #expect(try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            sessionID: "stale-session",
            transcriptPath: "/tmp/car-boundary-stale.jsonl",
            observedTranscriptBoundary: ObservedTranscriptBoundary(
                path: "/tmp/car-boundary-stale.jsonl",
                eof: 222),
            observedAt: presentationObservedAt) == nil)
        #expect(try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            sessionID: "accepted-session",
            transcriptPath: "/tmp/car-boundary-rejected.jsonl",
            observedTranscriptBoundary: ObservedTranscriptBoundary(
                path: "/tmp/car-boundary-rejected.jsonl",
                eof: 333),
            observedAt: acceptedAt) == nil)

        let stored = try #require(try await db.terminals.get(id: terminal.id))
        #expect(stored.claudeSessionID == "accepted-session")
        #expect(stored.transcriptPath == "/tmp/car-boundary-rejected.jsonl")
        #expect(stored.codexTranscriptBoundaryOffset == 111)
    }

    @Test("a retained path mismatch cannot persist an EOF observed for another transcript")
    func retainedPathMismatchRejectsObservedEOF() async throws {
        let terminal = try await makeBoundaryTerminal(tag: "retained-path-race")
        let observedPath = "/tmp/car-boundary-observed.jsonl"
        let transactionPath = "/tmp/car-boundary-transaction.jsonl"
        try await db.writerForTests.write { database in
            try database.execute(
                sql: """
                    UPDATE terminal
                    SET claudeSessionID = ?, transcriptPath = ?
                    WHERE id = ?
                    """,
                arguments: ["prior-session", transactionPath, terminal.id.uuidString])
        }

        let application = try #require(try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            sessionID: "next-session",
            transcriptPath: nil,
            observedTranscriptBoundary: ObservedTranscriptBoundary(
                path: observedPath,
                eof: 12_345),
            observedAt: presentationObservedAt))

        #expect(!application.isInitialAttachment)
        #expect(application.transcriptPath == transactionPath)
        #expect(application.transcriptBoundaryOffset == nil)
        let stored = try #require(try await db.terminals.get(id: terminal.id))
        #expect(stored.transcriptPath == transactionPath)
        #expect(stored.codexTranscriptBoundaryOffset == nil)
    }

    @Test("unordered session replacement clears the Codex boundary")
    func updateSessionClearsBoundary() async throws {
        let terminal = try await makeBoundaryTerminal(tag: "update-session")
        try await seedBoundary(101, terminalID: terminal.id)

        try await db.terminals.updateSession(
            id: terminal.id,
            sessionID: "replacement",
            transcriptPath: "/tmp/car-boundary-replacement.jsonl")

        #expect(try await db.terminals.get(id: terminal.id)?.codexTranscriptBoundaryOffset == nil)
    }

    @Test("in-place session identity replacement clears the Codex boundary")
    func updateSessionIDClearsBoundary() async throws {
        let terminal = try await makeBoundaryTerminal(tag: "update-session-id")
        try await seedBoundary(102, terminalID: terminal.id)

        try await db.terminals.updateSessionID(id: terminal.id, sessionID: "replacement")

        #expect(try await db.terminals.get(id: terminal.id)?.codexTranscriptBoundaryOffset == nil)
    }

    @Test("shell window recreation clears the Codex boundary")
    func clearRecreatedClearsBoundary() async throws {
        let terminal = try await makeBoundaryTerminal(tag: "clear-recreated")
        try await seedBoundary(103, terminalID: terminal.id)

        try await db.terminals.clearRecreated(id: terminal.id)

        #expect(try await db.terminals.get(id: terminal.id)?.codexTranscriptBoundaryOffset == nil)
    }

    @Test("in-place Codex window replacement clears the old process boundary")
    func replaceRecreatedCodexWindowClearsBoundary() async throws {
        let terminal = try await makeBoundaryTerminal(tag: "replace-recreated")
        try await seedBoundary(104, terminalID: terminal.id)

        _ = try await db.terminals.replaceRecreatedCodexWindow(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            windowID: "@new",
            paneID: "%new",
            at: presentationObservedAt)

        let stored = try #require(try await db.terminals.get(id: terminal.id))
        #expect(stored.tmuxWindowID == "@new")
        #expect(stored.tmuxPaneID == "%new")
        #expect(stored.codexTranscriptBoundaryOffset == nil)
    }

    @Test("a delayed SessionStart cannot repopulate a terminal cleared during recreation")
    func clearRecreatedRejectsPriorIncarnationSessionStart() async throws {
        let terminal = try await makeBoundaryTerminal(tag: "stale-clear-recreated")
        let expectedIncarnation = TerminalSessionIncarnation(terminal: terminal)
        try await seedSessionStateForRecreation(terminalID: terminal.id)

        try await db.terminals.clearRecreated(
            id: terminal.id,
            at: presentationObservedAt.addingTimeInterval(1))
        let application = try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: expectedIncarnation,
            sessionID: "dead-session",
            transcriptPath: "/tmp/car-dead-clear-recreated.jsonl",
            observedTranscriptBoundary: ObservedTranscriptBoundary(
                path: "/tmp/car-dead-clear-recreated.jsonl",
                eof: 999),
            observedAt: presentationObservedAt.addingTimeInterval(2))

        #expect(application == nil)
        let stored = try #require(try await db.terminals.get(id: terminal.id))
        #expect(stored.kind == .shell)
        #expect(stored.claudeSessionID == nil)
        #expect(stored.transcriptPath == nil)
        #expect(stored.sessionOrderObservedAt == nil)
        #expect(stored.codexTranscriptBoundaryOffset == nil)
    }

    @Test("a delayed SessionStart cannot repopulate a replacement Codex window")
    func replaceRecreatedRejectsPriorIncarnationSessionStart() async throws {
        let terminal = try await makeBoundaryTerminal(tag: "stale-replace-recreated")
        let expectedIncarnation = TerminalSessionIncarnation(terminal: terminal)
        try await seedSessionStateForRecreation(terminalID: terminal.id)

        _ = try await db.terminals.replaceRecreatedCodexWindow(
            id: terminal.id,
            expectedIncarnation: expectedIncarnation,
            windowID: "@replacement",
            paneID: "%replacement",
            at: presentationObservedAt.addingTimeInterval(1))
        let application = try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: expectedIncarnation,
            sessionID: "dead-session",
            transcriptPath: "/tmp/car-dead-replace-recreated.jsonl",
            observedTranscriptBoundary: ObservedTranscriptBoundary(
                path: "/tmp/car-dead-replace-recreated.jsonl",
                eof: 999),
            observedAt: presentationObservedAt.addingTimeInterval(2))

        #expect(application == nil)
        let stored = try #require(try await db.terminals.get(id: terminal.id))
        #expect(stored.tmuxWindowID == "@replacement")
        #expect(stored.tmuxPaneID == "%replacement")
        #expect(stored.claudeSessionID == nil)
        #expect(stored.transcriptPath == nil)
        #expect(stored.sessionOrderObservedAt == nil)
        #expect(stored.codexTranscriptBoundaryOffset == nil)
    }

    private func seedSessionStateForRecreation(terminalID: UUID) async throws {
        try await db.writerForTests.write { database in
            try database.execute(
                sql: """
                    UPDATE terminal
                    SET claudeSessionID = ?, transcriptPath = ?,
                        sessionOrderObservedAt = ?, codexTranscriptBoundaryOffset = ?
                    WHERE id = ?
                    """,
                arguments: [
                    "live-session", "/tmp/car-live-before-recreate.jsonl",
                    presentationObservedAt, 123, terminalID.uuidString,
                ])
        }
    }

    @Test("concurrent SessionStarts classify exactly one accepted transaction as initial")
    func concurrentSessionStartsClassifyInitialAttachmentAtomically() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-atomic-session-repo-\(UUID().uuidString)",
            displayName: "car-atomic-session-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-atomic-session-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-atomic-session")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        let gate = ConcurrentAsyncGate(participantCount: 2)
        let firstAt = presentationObservedAt
        let secondAt = firstAt.addingTimeInterval(1)

        let first = Task {
            await gate.waitForRelease()
            return try await db.terminals.applySessionStart(
                id: terminal.id,
                expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
                sessionID: "first-session",
                transcriptPath: "/tmp/car-atomic-first.jsonl", observedAt: firstAt)
        }
        let second = Task {
            await gate.waitForRelease()
            return try await db.terminals.applySessionStart(
                id: terminal.id,
                expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
                sessionID: "second-session",
                transcriptPath: "/tmp/car-atomic-second.jsonl", observedAt: secondAt)
        }
        await gate.releaseAll()

        let firstApplication = try await first.value
        let secondApplication = try await second.value
        let applications = [firstApplication, secondApplication].compactMap { $0 }
        #expect((1...2).contains(applications.count))
        #expect(applications.filter(\.isInitialAttachment).count == 1)
        let stored = try #require(try await db.terminals.get(id: terminal.id))
        #expect(stored.claudeSessionID == "second-session")
        #expect(stored.transcriptPath == "/tmp/car-atomic-second.jsonl")
        #expect(stored.sessionOrderObservedAt == secondAt)
    }

    @Test("distinct SessionStarts within one millisecond retain ordered generations")
    func sameMillisecondSessionStartsEstablishLaterBoundary() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-same-millisecond-repo-\(UUID().uuidString)",
            displayName: "car-same-millisecond-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-same-millisecond-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-same-millisecond")
        let transcript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"orphan"}}"#
                + "\n")
        defer { try? FileManager.default.removeItem(at: transcript.deletingLastPathComponent()) }
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        let firstAt = Date(timeIntervalSince1970: 1_790_000_000.123_1)
        let secondAt = Date(timeIntervalSince1970: 1_790_000_000.123_4)

        let first = try #require(try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            sessionID: "first-session",
            transcriptPath: transcript.path, observedAt: firstAt))
        let second = try #require(try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            sessionID: "second-session",
            transcriptPath: transcript.path, observedAt: secondAt))
        let firstGeneration = try #require(first.orderObservedAt)
        let secondGeneration = try #require(second.orderObservedAt)
        #expect(firstGeneration < secondGeneration)
        #expect(try await db.terminals.get(id: terminal.id)?.sessionOrderObservedAt
            == secondGeneration)

        await router.codexActivityTracker.adoptInitialSession(
            transcriptPath: transcript.path,
            worktreeID: wt.id,
            terminalID: terminal.id,
            generation: firstGeneration)
        #expect(await router.codexActivityTracker.hasBaseline(
            transcriptPath: transcript.path))
        await router.codexActivityTracker.establishSessionBoundary(
            transcriptPath: transcript.path,
            worktreeID: wt.id,
            terminalID: terminal.id,
            generation: secondGeneration,
            boundaryOffset: second.transcriptBoundaryOffset)
        #expect(await router.codexActivityTracker.observe(
            transcriptPath: transcript.path, worktreeID: wt.id) == nil)
    }

    @Test("legacy text session generation still decodes and orders")
    func legacyTextSessionGenerationRemainsCompatible() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-legacy-generation-repo-\(UUID().uuidString)",
            displayName: "car-legacy-generation-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-legacy-generation-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-legacy-generation")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        let legacyText = "2026-08-20 12:34:56.789"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let legacyAt = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 20,
            hour: 12, minute: 34, second: 56, nanosecond: 789_000_000)))
        try await db.writerForTests.write { database in
            try database.execute(
                sql: """
                    UPDATE terminal
                    SET claudeSessionID = ?, sessionOrderObservedAt = ?
                    WHERE id = ?
                    """,
                arguments: ["legacy-session", legacyText, terminal.id.uuidString])
        }

        #expect(try await db.terminals.get(id: terminal.id)?.sessionOrderObservedAt == legacyAt)
        #expect(try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            sessionID: "stale-session", transcriptPath: nil,
            observedAt: legacyAt.addingTimeInterval(-0.000_1)) == nil)
        let laterAt = legacyAt.addingTimeInterval(0.000_1)
        let later = try #require(try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            sessionID: "later-session", transcriptPath: nil,
            observedAt: laterAt))
        let laterGeneration = try #require(later.orderObservedAt)
        #expect(laterGeneration > legacyAt)
        #expect(abs(laterGeneration.timeIntervalSince(laterAt)) < 0.000_001)
        #expect(try await db.terminals.get(id: terminal.id)?.sessionOrderObservedAt
            == laterGeneration)
    }

    @Test("initial durable boundary recovers during list reconstruction")
    func initialBoundaryRecoversAcrossPersistedSessionListRace() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-adoption-race-repo-\(UUID().uuidString)",
            displayName: "car-adoption-race-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-adoption-race-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-adoption-race")
        let transcript = try makeTranscript(
            #"{"type":"session_meta","payload":{"id":"initial-session"}}"# + "\n"
                + #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"initial-turn"}}"#
                + "\n")
        defer { try? FileManager.default.removeItem(at: transcript.deletingLastPathComponent()) }
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)

        let observedAt = Date(timeIntervalSince1970: 1_790_000_000.123_6)
        let application = try #require(try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            sessionID: "initial-session",
            transcriptPath: transcript.path, observedAt: observedAt))
        #expect(application.isInitialAttachment)
        let stored = try #require(try await db.terminals.get(id: terminal.id))
        let persistedGeneration = try #require(stored.sessionOrderObservedAt)
        #expect(persistedGeneration == observedAt)

        let list = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id))
        let racedList = await router.handle(list)
        #expect(racedList.success)
        #expect(try racedList.decodeResult([Terminal].self).first?
            .presentationActivityState == .working)

        await router.codexActivityTracker.adoptInitialSession(
            transcriptPath: transcript.path,
            worktreeID: wt.id,
            terminalID: terminal.id,
            generation: try #require(application.orderObservedAt))
        let afterAdoption = await router.handle(list)
        #expect(afterAdoption.success)
        #expect(try afterAdoption.decodeResult([Terminal].self).first?
            .presentationActivityState == .working)
    }

    @Test("a fresh router progressively recovers activity older than the transcript tail")
    func freshRouterRecoversInitialSessionBeyondOneMiB() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-cold-recovery-repo-\(UUID().uuidString)",
            displayName: "car-cold-recovery-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-cold-recovery-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-cold-recovery")
        let transcript = try makeTranscript(String(decoding: lifecycleEvent(
            type: "task_started", turnID: "current"), as: UTF8.self))
        defer { try? FileManager.default.removeItem(at: transcript.deletingLastPathComponent()) }
        for index in 0..<17 {
            try append(lifecycleEvent(
                type: "agent_message",
                turnID: "padding-\(index)",
                exactByteCount: 64 * 1024), to: transcript)
        }
        #expect(try Data(contentsOf: transcript).count > 1024 * 1024)

        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        let sessionStart = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "initial-session",
                transcriptPath: transcript.path,
                source: "SessionStart"))
        #expect((await router.handle(sessionStart)).success)
        #expect(try await db.terminals.get(id: terminal.id)?
            .codexTranscriptBoundaryOffset == 0)

        let restartedRouter = makeRouter(now: { presentationObservedAt })
        let list = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id))
        let firstResponse = await restartedRouter.handle(list)
        #expect(firstResponse.success)
        #expect(try firstResponse.decodeResult([Terminal].self).first?
            .presentationActivityState == nil)

        var recoveredState: TerminalActivityState?
        for _ in 0..<3 where recoveredState == nil {
            let response = await restartedRouter.handle(list)
            #expect(response.success)
            recoveredState = try response.decodeResult([Terminal].self).first?
                .presentationActivityState
        }
        #expect(recoveredState == .working)
        #expect(try await db.terminals.get(id: terminal.id)?
            .codexTranscriptBoundaryOffset == 0)

        try append(lifecycleEvent(
            type: "task_complete", turnID: "current"), to: transcript)
        var completedState = recoveredState
        for _ in 0..<2 where completedState != .idle {
            let response = await restartedRouter.handle(list)
            #expect(response.success)
            completedState = try response.decodeResult([Terminal].self).first?
                .presentationActivityState
        }
        #expect(completedState == .idle)
    }

    @Test("durable boundary supersedes same-generation provisional EOF but not newer state")
    func durableBoundaryWinsAfterListReconstructionRace() async throws {
        let tracker = CodexTranscriptActivityTracker()
        let transcript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"current"}}"#
                + "\n")
        defer { try? FileManager.default.removeItem(at: transcript.deletingLastPathComponent()) }
        let worktreeID = UUID()
        let terminalID = UUID()
        let generation = Date(timeIntervalSince1970: 1_790_300_000)

        let provisionalTarget = CodexTranscriptActivityTracker.Target(
            transcriptPath: transcript.path,
            worktreeID: worktreeID,
            terminalID: terminalID,
            sessionGeneration: generation)
        await tracker.establishSessionBoundariesIfAbsent(
            transcripts: [provisionalTarget])
        #expect(await tracker.observe(
            transcriptPath: transcript.path,
            worktreeID: worktreeID) == nil)

        await tracker.establishSessionBoundary(
            transcriptPath: transcript.path,
            worktreeID: worktreeID,
            terminalID: terminalID,
            generation: generation,
            boundaryOffset: 0)
        await tracker.establishSessionBoundary(
            transcriptPath: transcript.path,
            worktreeID: worktreeID,
            terminalID: terminalID,
            generation: generation.addingTimeInterval(-1),
            boundaryOffset: Int64(try Data(contentsOf: transcript).count))

        #expect(await tracker.observe(
            transcriptPath: transcript.path,
            worktreeID: worktreeID) == .working)
    }

    @Test("an unavailable initial rollout remains eligible for later bootstrap")
    func unavailableInitialSessionBootstrapsWhenRolloutAppears() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-late-rollout-repo-\(UUID().uuidString)",
            displayName: "car-late-rollout-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-late-rollout-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-late-rollout")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-car-late-rollout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("rollout.jsonl")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        let sessionStart = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id, sessionID: "initial-session",
                transcriptPath: transcript.path, source: "SessionStart"))
        #expect((await router.handle(sessionStart)).success)
        #expect(!(await router.codexActivityTracker.hasBaseline(
            transcriptPath: transcript.path)))

        try (#"{"type":"session_meta","payload":{"id":"initial-session"}}"# + "\n"
            + #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"initial-turn"}}"#
            + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let list = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id))
        let response = await router.handle(list)
        #expect(response.success)
        #expect(try response.decodeResult([Terminal].self).first?
            .presentationActivityState == .working)
    }

    @Test("a fresh tracker replays an unavailable initial rollout when it appears")
    func unavailableInitialBoundaryReplaysWhenRolloutAppears() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-unavailable-restart-repo-\(UUID().uuidString)",
            displayName: "car-unavailable-restart-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-unavailable-restart-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-unavailable-restart")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tbd-car-unavailable-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("rollout.jsonl")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        _ = try #require(try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            sessionID: "persisted-session",
            transcriptPath: transcript.path, observedAt: presentationObservedAt))
        let restartedRouter = makeRouter(now: { presentationObservedAt })
        let list = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id))

        let unavailable = await restartedRouter.handle(list)
        #expect(unavailable.success)
        #expect(try unavailable.decodeResult([Terminal].self).first?
            .presentationActivityState == nil)

        try (#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"historical"}}"#
            + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let afterFileAppears = await restartedRouter.handle(list)
        #expect(afterFileAppears.success)
        #expect(try afterFileAppears.decodeResult([Terminal].self).first?
            .presentationActivityState == .working)
    }

    @Test("sub-millisecond later boundary remains pending across database reload")
    func submillisecondUnavailableLaterBoundaryDoesNotBootstrapHistory() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-submillisecond-boundary-repo-\(UUID().uuidString)",
            displayName: "car-submillisecond-boundary-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-submillisecond-boundary-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-submillisecond-boundary")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tbd-car-submillisecond-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missingTranscript = directory.appendingPathComponent("rollout.jsonl")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        _ = try #require(try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            sessionID: "initial-session",
            transcriptPath: "/tmp/car-submillisecond-initial.jsonl",
            observedAt: Date(timeIntervalSince1970: 1_790_000_000)))
        let observedAt = Date(timeIntervalSince1970: 1_790_000_001.123_4)
        let roundedRouter = makeRouter(now: { observedAt })

        let start = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id, sessionID: "later-session",
                transcriptPath: missingTranscript.path, source: "SessionStart"))
        #expect((await roundedRouter.handle(start)).success)
        let stored = try #require(try await db.terminals.get(id: terminal.id))
        let persistedGeneration = try #require(stored.sessionOrderObservedAt)
        #expect(persistedGeneration == observedAt)

        try (#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"historical"}}"#
            + "\n").write(to: missingTranscript, atomically: true, encoding: .utf8)
        let list = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id))
        let response = await roundedRouter.handle(list)
        #expect(response.success)
        #expect(try response.decodeResult([Terminal].self).first?
            .presentationActivityState == nil)
    }

    @Test("a later session boundary defeats an older delayed initial adoption")
    func laterGenerationBoundaryWinsOverDelayedInitialAdoption() async throws {
        let initialTranscript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"orphan"}}"#
                + "\n")
        defer {
            try? FileManager.default.removeItem(
                at: initialTranscript.deletingLastPathComponent())
        }
        let laterTranscript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"later"}}"#
                + "\n")
        defer {
            try? FileManager.default.removeItem(
                at: laterTranscript.deletingLastPathComponent())
        }
        let worktreeID = UUID()
        let terminalID = UUID()
        let initialGeneration = presentationObservedAt
        let laterGeneration = initialGeneration.addingTimeInterval(1)

        await router.codexActivityTracker.adoptInitialSession(
            transcriptPath: initialTranscript.path,
            worktreeID: worktreeID,
            terminalID: terminalID,
            generation: initialGeneration)
        #expect(await router.codexActivityTracker.hasBaseline(
            transcriptPath: initialTranscript.path))
        await router.codexActivityTracker.establishSessionBoundary(
            transcriptPath: laterTranscript.path,
            worktreeID: worktreeID,
            terminalID: terminalID,
            generation: laterGeneration,
            boundaryOffset: nil)
        await router.codexActivityTracker.adoptInitialSession(
            transcriptPath: initialTranscript.path,
            worktreeID: worktreeID,
            terminalID: terminalID,
            generation: initialGeneration)
        #expect(!(await router.codexActivityTracker.hasBaseline(
            transcriptPath: initialTranscript.path)))
    }

    @Test("tracker retention prunes session-generation ordering with its transcript")
    func retentionPrunesSessionGenerationState() async throws {
        let transcript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"eligible"}}"#
                + "\n")
        defer { try? FileManager.default.removeItem(at: transcript.deletingLastPathComponent()) }
        let worktreeID = UUID()
        let terminalID = UUID()
        let initialGeneration = presentationObservedAt
        let laterGeneration = initialGeneration.addingTimeInterval(1)

        await router.codexActivityTracker.establishSessionBoundary(
            transcriptPath: transcript.path,
            worktreeID: worktreeID,
            terminalID: terminalID,
            generation: laterGeneration,
            boundaryOffset: nil)
        await router.codexActivityTracker.retain(
            transcriptPaths: [], scope: worktreeID)
        await router.codexActivityTracker.adoptInitialSession(
            transcriptPath: transcript.path,
            worktreeID: worktreeID,
            terminalID: terminalID,
            generation: initialGeneration)
        await router.codexActivityTracker.establishSessionBoundary(
            transcriptPath: transcript.path,
            worktreeID: worktreeID,
            terminalID: terminalID,
            generation: initialGeneration.addingTimeInterval(0.5),
            boundaryOffset: nil)

        #expect(await router.codexActivityTracker.observe(
            transcriptPath: transcript.path, worktreeID: worktreeID) == nil)
    }

    @Test("a persisted SessionStart boundary survives a fresh tracker")
    func samePathSessionBoundarySurvivesFreshTracker() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-restart-repo-\(UUID().uuidString)",
            displayName: "car-restart-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-restart-wt-\(UUID().uuidString)", tmuxServer: "tbd-car-restart")
        let transcript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"orphan"}}"#
                + "\n")
        defer { try? FileManager.default.removeItem(at: transcript.deletingLastPathComponent()) }
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        try await db.terminals.updateSession(
            id: terminal.id, sessionID: "same-session", transcriptPath: transcript.path)
        let sessionStart = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id, sessionID: "same-session",
                transcriptPath: transcript.path, source: "SessionStart"))
        #expect((await router.handle(sessionStart)).success)
        _ = try await db.terminals.applyActivityObservation(
            id: terminal.id,
            activityState: .working,
            source: .hookEvent(RPCMethod.terminalActivityEvent),
            observedAt: presentationObservedAt.addingTimeInterval(1))

        let restartedRouter = makeRouter(now: { presentationObservedAt })
        let list = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id))
        let afterRestart = await restartedRouter.handle(list)
        #expect(afterRestart.success)
        #expect(try afterRestart.decodeResult([Terminal].self).first?
            .presentationActivityState == nil)
    }

    @Test("an equal-stamped duplicate SessionStart does not hide a later turn")
    func duplicateSessionStartDoesNotResetLaterTurn() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-duplicate-repo-\(UUID().uuidString)",
            displayName: "car-duplicate-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-duplicate-wt-\(UUID().uuidString)", tmuxServer: "tbd-car-duplicate")
        let transcript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"orphan"}}"#
                + "\n")
        defer { try? FileManager.default.removeItem(at: transcript.deletingLastPathComponent()) }
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        try await db.terminals.updateSession(
            id: terminal.id, sessionID: "same-session", transcriptPath: transcript.path)
        let sessionStart = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id, sessionID: "same-session",
                transcriptPath: transcript.path, source: "SessionStart"))
        #expect((await router.handle(sessionStart)).success)
        try append(
            Data((#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"later"}}"#
                + "\n").utf8),
            to: transcript)

        #expect((await router.handle(sessionStart)).success)
        let list = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id))
        let response = await router.handle(list)
        #expect(response.success)
        #expect(try response.decodeResult([Terminal].self).first?
            .presentationActivityState == .working)
    }

    @Test("matching transcript completion clears presentation while missed Stop remains persisted working")
    func terminalListObservesAppendedCompletionWithoutMutation() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-idle-repo-\(UUID().uuidString)",
            displayName: "car-idle-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt",
            branch: "main",
            path: "/tmp/car-idle-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-idle"
        )

        let transcriptPath = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"a"}}"# + "\n")
        defer { try? FileManager.default.removeItem(at: transcriptPath.deletingLastPathComponent()) }

        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: "Codex",
            kind: .codex
        )
        _ = try #require(try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            sessionID: "codex-session",
            transcriptPath: transcriptPath.path,
            observedAt: Date(timeIntervalSince1970: 1_779_999_999)))
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .working, source: .hookEvent("TurnStart"),
            observedAt: Date(timeIntervalSince1970: 1_780_000_000))

        let request = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id)
        )
        let workingResponse = await router.handle(request)
        #expect(workingResponse.success)
        let working = try workingResponse.decodeResult([Terminal].self)
        #expect(working.first?.presentationActivityState == .working)

        let handle = try FileHandle(forWritingTo: transcriptPath)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            (#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"a"}}"# + "\n").utf8))
        try handle.close()

        let idleResponse = await router.handle(request)
        #expect(idleResponse.success)
        let idle = try idleResponse.decodeResult([Terminal].self)
        #expect(idle.first?.presentationActivityState == .idle)
        #expect(idle.first?.activityState == .working)

        let persisted = try await db.terminals.get(id: terminal.id)
        #expect(persisted?.presentationActivityState == nil)
        #expect(persisted?.activityState == .working)
    }

    @Test("terminal.list leaves presentation unknown for unreadable Codex transcript and Claude")
    func terminalListUsesPresentationOnlyForReadableCodexTranscript() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-scope-repo-\(UUID().uuidString)",
            displayName: "car-scope-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-scope-wt-\(UUID().uuidString)", tmuxServer: "tbd-car-scope")
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).jsonl").path

        let codex = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        try await db.terminals.updateSession(
            id: codex.id, sessionID: "codex-session", transcriptPath: missingPath)
        try await db.terminals.setActivityState(
            id: codex.id, activityState: .working, source: .hookEvent("TurnStart"))

        let claudeTranscript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"a"}}"# + "\n")
        defer { try? FileManager.default.removeItem(at: claudeTranscript.deletingLastPathComponent()) }
        let claude = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: "Claude", kind: .claude)
        try await db.terminals.updateSession(
            id: claude.id, sessionID: "claude-session", transcriptPath: claudeTranscript.path)

        let request = try RPCRequest(
            method: RPCMethod.terminalList, params: TerminalListParams(worktreeID: wt.id))
        let response = await router.handle(request)
        #expect(response.success)

        let terminals = try response.decodeResult([Terminal].self)
        #expect(terminals.first(where: { $0.id == codex.id })?.presentationActivityState == nil)
        #expect(terminals.first(where: { $0.id == codex.id })?.presentationActivityObservedAt
            == presentationObservedAt)
        #expect(terminals.first(where: { $0.id == codex.id })?.activityState == .working)
        #expect(terminals.first(where: { $0.id == claude.id })?.presentationActivityState == nil)
        #expect(terminals.first(where: { $0.id == claude.id })?.presentationActivityObservedAt == nil)
    }

    @Test(
        "terminal.list binds presentation to the post-observation transcript identity",
        .serialized,
        arguments: [true, false]
    )
    func terminalListRejectsPresentationFromRetargetedTranscript(
        scoped: Bool
    ) async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-rollover-repo-\(UUID().uuidString)",
            displayName: "car-rollover-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-rollover-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-rollover")
        let oldTranscript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"old"}}"#
                + "\n")
        let currentTranscript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"current"}}"#
                + "\n")
        defer {
            try? FileManager.default.removeItem(
                at: oldTranscript.deletingLastPathComponent())
            try? FileManager.default.removeItem(
                at: currentTranscript.deletingLastPathComponent())
        }
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        _ = try #require(try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            sessionID: "old-session",
            transcriptPath: oldTranscript.path,
            observedAt: Date(timeIntervalSince1970: 1_790_000_099)))

        let firstAt = Date(timeIntervalSince1970: 1_790_000_100)
        let currentAt = firstAt.addingTimeInterval(1)
        let dates = BlockingListDates(first: firstAt, subsequent: currentAt)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            now: dates.provider,
            actuationLog: makeTestActuationLog())
        let list = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: scoped ? wt.id : nil))
        let priorResponse = await self.router.handle(list)
        #expect(priorResponse.success)
        let priorTerminal = try #require(
            priorResponse.decodeResult([Terminal].self).first(where: { $0.id == terminal.id }))
        #expect(priorTerminal.presentationActivityState == .working)
        #expect(priorTerminal.presentationActivityObservedAt == presentationObservedAt)
        let sessionStart = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "current-session",
                transcriptPath: currentTranscript.path,
                source: "SessionStart"))

        let staleList = gateHoldingTask { await router.handle(list) }
        guard await waitUntil(
            { dates.firstCallIsBlocked }, timeout: Self.raceRendezvousTimeout
        ) else {
            dates.releaseFirstCall()
            _ = await staleList.value
            Issue.record("first terminal.list never reached its transcript stamp")
            return
        }
        let sessionUpdate = Task { await router.handle(sessionStart) }
        guard await waitUntilAsync(
            {
                let current = try? await db.terminals.get(id: terminal.id)
                return current?.claudeSessionID == "current-session"
            },
            timeout: Self.raceRendezvousTimeout
        ) else {
            dates.releaseFirstCall()
            _ = await staleList.value
            _ = await sessionUpdate.value
            Issue.record("SessionStart never committed its atomic retarget")
            return
        }
        let currentList = Task { await router.handle(list) }
        dates.releaseFirstCall()

        let staleResponse = await staleList.value
        #expect((await sessionUpdate.value).success)
        let currentResponse = await currentList.value
        #expect(staleResponse.success)
        #expect(currentResponse.success)
        let staleTerminal = try #require(
            staleResponse.decodeResult([Terminal].self).first(where: { $0.id == terminal.id }))
        let currentTerminal = try #require(
            currentResponse.decodeResult([Terminal].self).first(where: { $0.id == terminal.id }))

        #expect(staleTerminal.claudeSessionID == "current-session")
        #expect(staleTerminal.transcriptPath == currentTranscript.path)
        #expect(staleTerminal.presentationActivityState == nil)
        #expect(staleTerminal.presentationActivityObservedAt == firstAt)
        #expect(currentTerminal.transcriptPath == currentTranscript.path)
        // SessionStart establishes a boundary at the transcript's current EOF,
        // so pre-boundary lifecycle events are not evidence for the new session.
        #expect(currentTerminal.presentationActivityState == nil)
        #expect(currentTerminal.presentationActivityObservedAt == currentAt)
        #expect(!(await router.codexActivityTracker.hasBaseline(
            transcriptPath: oldTranscript.path)))
        #expect(await router.codexActivityTracker.hasBaseline(
            transcriptPath: currentTranscript.path))
    }

    @Test(
        "terminal.list rejects a pre-boundary observation when the path is unchanged",
        .serialized,
        arguments: [true, false]
    )
    func terminalListRejectsPreBoundarySamePathObservation(
        scoped: Bool
    ) async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-generation-repo-\(UUID().uuidString)",
            displayName: "car-generation-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-generation-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-generation")
        let transcript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"orphan"}}"#
                + "\n")
        defer { try? FileManager.default.removeItem(at: transcript.deletingLastPathComponent()) }
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        try await db.terminals.updateSession(
            id: terminal.id, sessionID: "same-session", transcriptPath: transcript.path)

        let listAt = Date(timeIntervalSince1970: 1_790_000_200)
        let sessionAt = listAt.addingTimeInterval(1)
        let dates = BlockingListDates(first: listAt, subsequent: sessionAt)
        let raceRouter = makeRouter(now: dates.provider)
        let list = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: scoped ? wt.id : nil))
        let sessionStart = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id, sessionID: "same-session",
                transcriptPath: transcript.path, source: "SessionStart"))

        let staleList = gateHoldingTask { await raceRouter.handle(list) }
        guard await waitUntil(
            { dates.firstCallIsBlocked }, timeout: Self.raceRendezvousTimeout
        ) else {
            dates.releaseFirstCall()
            _ = await staleList.value
            Issue.record("terminal.list never reached its transcript stamp")
            return
        }
        let sessionUpdate = Task { await raceRouter.handle(sessionStart) }
        guard await waitUntilAsync(
            {
                let current = try? await db.terminals.get(id: terminal.id)
                return current?.activityStateOrderObservedAt == sessionAt
            },
            timeout: Self.raceRendezvousTimeout
        ) else {
            dates.releaseFirstCall()
            _ = await staleList.value
            _ = await sessionUpdate.value
            Issue.record("same-path SessionStart never advanced its activity generation")
            return
        }
        dates.releaseFirstCall()

        let staleResponse = await staleList.value
        #expect((await sessionUpdate.value).success)
        #expect(staleResponse.success)
        let staleTerminal = try #require(
            staleResponse.decodeResult([Terminal].self).first(where: { $0.id == terminal.id }))
        #expect(staleTerminal.claudeSessionID == "same-session")
        #expect(staleTerminal.transcriptPath == transcript.path)
        #expect(staleTerminal.presentationActivityState == nil)
        #expect(staleTerminal.presentationActivityObservedAt == listAt)
    }

    @Test("terminal.list revalidates the durable transcript boundary")
    func terminalListRejectsPresentationFromChangedBoundary() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-boundary-identity-repo-\(UUID().uuidString)",
            displayName: "car-boundary-identity-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-boundary-identity-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-boundary-identity")
        let transcript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"current"}}"#
                + "\n")
        defer { try? FileManager.default.removeItem(at: transcript.deletingLastPathComponent()) }
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        let generation = Date(timeIntervalSince1970: 1_790_400_600)
        _ = try #require(try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            sessionID: "current-session",
            transcriptPath: transcript.path, observedAt: generation))
        let dates = BlockingListDates(
            first: presentationObservedAt,
            subsequent: presentationObservedAt.addingTimeInterval(1))
        let raceRouter = makeRouter(now: dates.provider)
        let list = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id))

        let inFlightList = gateHoldingTask { await raceRouter.handle(list) }
        guard await waitUntil(
            { dates.firstCallIsBlocked }, timeout: Self.raceRendezvousTimeout
        ) else {
            dates.releaseFirstCall()
            _ = await inFlightList.value
            Issue.record("terminal.list never reached its transcript stamp")
            return
        }
        try await db.writerForTests.write { database in
            try database.execute(
                sql: "UPDATE terminal SET codexTranscriptBoundaryOffset = ? WHERE id = ?",
                arguments: [Int64(1), terminal.id.uuidString])
        }
        dates.releaseFirstCall()

        let response = await inFlightList.value
        #expect(response.success)
        let listed = try #require(
            response.decodeResult([Terminal].self).first(where: { $0.id == terminal.id }))
        #expect(listed.presentationActivityState == nil)
        #expect(listed.presentationActivityObservedAt == presentationObservedAt)
    }

    @Test("terminal.list retention respects worktree and fleet scopes")
    func terminalListRetainsTrackerBaselinesByRequestScope() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-retain-repo-\(UUID().uuidString)",
            displayName: "car-retain-repo", defaultBranch: "main")
        let firstWorktree = try await db.worktrees.create(
            repoID: repo.id, name: "first", branch: "first",
            path: "/tmp/car-retain-first-\(UUID().uuidString)", tmuxServer: "tbd-car-first")
        let secondWorktree = try await db.worktrees.create(
            repoID: repo.id, name: "second", branch: "second",
            path: "/tmp/car-retain-second-\(UUID().uuidString)", tmuxServer: "tbd-car-second")
        let firstPath = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"a"}}"# + "\n")
        let secondPath = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"b"}}"# + "\n")
        defer {
            try? FileManager.default.removeItem(at: firstPath.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondPath.deletingLastPathComponent())
        }
        let first = try await db.terminals.create(
            worktreeID: firstWorktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .codex)
        let second = try await db.terminals.create(
            worktreeID: secondWorktree.id, tmuxWindowID: "@2", tmuxPaneID: "%2", kind: .codex)
        try await db.terminals.updateSession(
            id: first.id, sessionID: "first", transcriptPath: firstPath.path)
        try await db.terminals.updateSession(
            id: second.id, sessionID: "second", transcriptPath: secondPath.path)

        let fleetRequest = try RPCRequest(
            method: RPCMethod.terminalList, params: TerminalListParams())
        #expect(await router.handle(fleetRequest).success)
        #expect(await router.codexActivityTracker.baselineCount == 2)

        try await db.terminals.delete(id: first.id)
        let scopedRequest = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: firstWorktree.id))
        #expect(await router.handle(scopedRequest).success)
        #expect(!(await router.codexActivityTracker.hasBaseline(transcriptPath: firstPath.path)))
        #expect(await router.codexActivityTracker.hasBaseline(transcriptPath: secondPath.path))

        try await db.terminals.delete(id: second.id)
        #expect(await router.handle(fleetRequest).success)
        #expect(await router.codexActivityTracker.baselineCount == 0)
    }

    @Test("terminal.list shares its transcript byte budget fairly across Codex terminals")
    func terminalListSharesTranscriptBudgetFairly() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-budget-repo-\(UUID().uuidString)",
            displayName: "car-budget-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-budget-wt-\(UUID().uuidString)", tmuxServer: "tbd-car-budget")
        let paths = try ["first", "second"].map { turnID in
            try makeTranscript(String(decoding: lifecycleEvent(
                type: "task_complete", turnID: turnID), as: UTF8.self))
        }
        defer {
            for path in paths {
                try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
            }
        }

        for (index, path) in paths.enumerated() {
            let terminal = try await db.terminals.create(
                worktreeID: wt.id,
                tmuxWindowID: "@\(index + 1)", tmuxPaneID: "%\(index + 1)",
                label: "Codex \(index + 1)", kind: .codex)
            try await db.terminals.updateSession(
                id: terminal.id, sessionID: "codex-\(index + 1)", transcriptPath: path.path)
        }

        let request = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id))
        #expect(await router.handle(request).success)

        let oversizedRecordByteCount = CodexTranscriptActivityTracker.maxBufferedRecordByteCount + 128
        for (index, path) in paths.enumerated() {
            try append(
                lifecycleEvent(
                    type: "agent_message", turnID: "padding-\(index)",
                    exactByteCount: oversizedRecordByteCount)
                    + lifecycleEvent(type: "task_started", turnID: "turn-\(index)"),
                to: path)
        }

        let firstResponse = await router.handle(request)
        #expect(firstResponse.success)
        let firstTerminals = try firstResponse.decodeResult([Terminal].self)
        #expect(firstTerminals.allSatisfy { $0.presentationActivityState == nil })

        var bufferedByteCount = 0
        var progressedPathCount = 0
        for path in paths {
            let buffered = await router.codexActivityTracker.bufferedRecordState(
                transcriptPath: path.path)
            bufferedByteCount += buffered?.byteCount ?? 0
            if let buffered, buffered.byteCount > 0 {
                progressedPathCount += 1
            }
        }
        #expect(bufferedByteCount == Int(CodexTranscriptActivityTracker.requestReadByteLimit))
        #expect(progressedPathCount == paths.count)

        try append(
            lifecycleEvent(
                type: "agent_message", turnID: "first-keeps-growing",
                exactByteCount: 64 * 1024),
            to: paths[0])
        let secondResponse = await router.handle(request)
        #expect(secondResponse.success)
        let secondTerminals = try secondResponse.decodeResult([Terminal].self)
        #expect(secondTerminals.allSatisfy { $0.presentationActivityState == nil })

        try append(
            lifecycleEvent(
                type: "agent_message", turnID: "first-still-growing",
                exactByteCount: 64 * 1024),
            to: paths[0])
        let finalResponse = await router.handle(request)
        #expect(finalResponse.success)
        let finalTerminals = try finalResponse.decodeResult([Terminal].self)
        #expect(finalTerminals.allSatisfy { $0.presentationActivityState == .working })
    }

    private func makeTranscript(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("session.jsonl")
        try contents.write(to: path, atomically: true, encoding: .utf8)
        return path
    }

    private func lifecycleEvent(
        type: String,
        turnID: String,
        exactByteCount: Int? = nil
    ) -> Data {
        func encoded(padding: String?) -> Data {
            let paddingField = padding.map { #", "padding":"\#($0)""# } ?? ""
            return Data((
                #"{"type":"event_msg","payload":{"type":"\#(type)","turn_id":"\#(turnID)"\#(paddingField)}}"#
                    + "\n").utf8)
        }

        guard let exactByteCount else { return encoded(padding: nil) }
        let emptyPadded = encoded(padding: "")
        precondition(exactByteCount >= emptyPadded.count)
        return encoded(padding: String(repeating: "x", count: exactByteCount - emptyPadded.count))
    }

    private func append(_ data: Data, to path: URL) throws {
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    // MARK: - The date seam on the two handlers that WRITE codex activity

    /// Pinned through the router's date seam, so each stored stamp is an exact
    /// assertion rather than a freshness window.
    static let observedAt = Date(timeIntervalSince1970: 1_781_234_567)

    /// A second router over the same database, with its `now` pinned.
    ///
    /// `setActivityState` defaults `observedAt` to a bare `Date()` **at the
    /// store**, so a handler that omits the argument mints a timestamp nothing
    /// outside the store can name. That is not a cosmetic difference: the stamp
    /// is *compared* — `SessionStateResolver` orders it against the
    /// awaiting-input stamp at rung 4 to decide which observation is newer — so
    /// per the root `CLAUDE.md` date-seam rule it is data, and it belongs on the
    /// router's seam like every sibling call site in this file.
    private func pinnedRouter() -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(),
                tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            now: { Self.observedAt },
            actuationLog: makeTestActuationLog())
    }

    @Test("terminal.sessionEvent stamps the codex idle observation from the router's date seam")
    func sessionEventStampsFromTheDateSeam() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-seam-repo-\(UUID().uuidString)",
            displayName: "car-seam-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-seam-wt-\(UUID().uuidString)", tmuxServer: "tbd-car-seam")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)

        let request = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id, sessionID: "codex-session",
                transcriptPath: nil, source: "SessionStart"))
        #expect(await pinnedRouter().handle(request).success)

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(after.activityState == .idle)
        #expect(after.activityStateObservedAt == Self.observedAt)
        #expect(after.observedActivity?.observedAt == Self.observedAt)
    }

    @Test("terminal.recreateWindow stamps the derived codex unknown from the router's date seam")
    func recreateWindowStampsFromTheDateSeam() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-car-recreate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = try await db.repos.create(
            path: root.path, displayName: "car-recreate-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: root.path, tmuxServer: "tbd-car-recreate")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@old", tmuxPaneID: "%old",
            label: TerminalLabel.codex, kind: .codex)
        // A prior observation, so "the stamp moved" is a real claim rather than
        // a column that happened to be nil before and non-nil after.
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .working, source: .hookEvent("TurnStart"),
            observedAt: Date(timeIntervalSince1970: 1_770_000_000))

        let router = pinnedRouter()
        router.codexExecutableResolver = { "/opt/test/bin/codex" }
        router.codexHomeEnsurer = { root.appendingPathComponent("codex-home", isDirectory: true) }

        let request = try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: terminal.id))
        let response = await router.handle(request)
        #expect(response.success, "expected success; error: \(response.error ?? "nil")")

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(after.activityState == .unknown)
        #expect(after.activityStateObservedAt == Self.observedAt)
        #expect(after.observedActivity?.observedAt == Self.observedAt)
    }
}

private func waitUntilAsync(
    _ condition: @escaping @Sendable () async -> Bool,
    timeout: Duration = .seconds(2)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    repeat {
        if await condition() { return true }
        await Task.yield()
    } while clock.now < deadline
    return false
}

private actor ConcurrentAsyncGate {
    private let participantCount: Int
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    func waitForRelease() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func releaseAll() async {
        while continuations.count < participantCount {
            await Task.yield()
        }
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

/// Holds the first `now()` call until the test releases it, so "the earlier
/// request is mid-flight" is a deterministic state rather than a timing window.
///
/// The held request MUST be started with `gateHoldingTask`: this blocks the
/// thread it runs on, and a blocked cooperative-pool thread starves every
/// other test in the process. See `Tests/TestSupport/BoundedGateSupport.swift`.
private final class BlockingListDates: @unchecked Sendable {
    private let lock = NSLock()
    private let first: Date
    private let subsequent: Date
    private let release = DispatchSemaphore(value: 0)
    private var callCount = 0
    private var firstBlocked = false

    init(first: Date, subsequent: Date) {
        self.first = first
        self.subsequent = subsequent
    }

    var firstCallIsBlocked: Bool {
        lock.withLock { firstBlocked }
    }

    var provider: @Sendable () -> Date {
        { [self] in
            let call = lock.withLock { () -> Int in
                let call = callCount
                callCount += 1
                if call == 0 { firstBlocked = true }
                return call
            }
            guard call == 0 else { return subsequent }
            release.waitForGate("codex activity reconciliation first date-provider call")
            return first
        }
    }

    func releaseFirstCall() {
        release.signal()
    }
}

/// Holds the exact tmux command that first launches Codex so the test can send
/// SessionStart while `terminal.recreateWindow` is still inside that launch.
/// The recreate request runs with `gateHoldingTask`, keeping this synchronous
/// dry-run recorder off Swift's cooperative thread pool.
private final class BlockingCodexLaunchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var commands: [[String]] = []
    private var blocked = false

    var codexLaunchIsBlocked: Bool {
        lock.withLock { blocked }
    }

    var blockedCommand: [String]? {
        lock.withLock { commands.last(where: { $0.last?.contains(" --profile") == true }) }
    }

    var recorder: @Sendable ([String]) -> Void {
        { [self] command in
            let shouldBlock = lock.withLock { () -> Bool in
                commands.append(command)
                guard !blocked, command.last?.contains(" --profile") == true else {
                    return false
                }
                blocked = true
                return true
            }
            if shouldBlock {
                release.waitForGate("recreated Codex process launch")
            }
        }
    }

    func releaseCodexLaunch() {
        release.signal()
    }

    func snapshot() -> [[String]] {
        lock.withLock { commands }
    }
}
