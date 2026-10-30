import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import DaemonTestSupport
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

    /// The listed row is the stored row: no transcript-derived presentation
    /// rides on it, even for a Codex rollout with a turn in flight — not in the
    /// model, and not on the wire.
    @Test("terminal.list publishes no presentation")
    func terminalListPublishesNoPresentation() async throws {
        let terminal = try await makeBoundaryTerminal(tag: "no-presentation")
        let transcript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"a"}}"# + "\n")
        defer { try? FileManager.default.removeItem(at: transcript.deletingLastPathComponent()) }
        _ = try #require(try await db.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            sessionID: "codex-session",
            transcriptPath: transcript.path,
            observedAt: presentationObservedAt.addingTimeInterval(-1)))

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: terminal.worktreeID)))
        #expect(response.success)
        let listed = try #require(
            response.decodeResult([Terminal].self).first(where: { $0.id == terminal.id }))
        #expect(listed.activityState == .unknown)
        let wire = try #require(response.result)
        #expect(!wire.contains("presentationActivity"))
    }

    @Test("recreated Codex window attaches its new process's session")
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
            "TBD_CLI_PATH=\(shellEscape(matchedCLIPath))") == true)
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
        // The new incarnation has not reported its state.
        #expect(recreated.activityState == .unknown)
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
        #expect(stored.codexTranscriptBoundaryOffset == 0)
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

    @Test("suspending with an unordered session identity clears the Codex boundary")
    func setSuspendedClearsBoundary() async throws {
        let terminal = try await makeBoundaryTerminal(tag: "set-suspended")
        try await seedBoundary(103, terminalID: terminal.id)

        try await db.terminals.setSuspended(
            id: terminal.id,
            sessionID: "replacement",
            at: presentationObservedAt)

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

    @Test("a sub-millisecond later generation survives a database round trip")
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
        // The rollout did not exist when the later session attached, so no
        // safe boundary was available.
        #expect(stored.codexTranscriptBoundaryOffset == nil)
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
        // Continue in Claude's rollout reads are what take baselines; the list
        // only prunes them.
        _ = await router.codexActivityTracker.observe(
            transcriptPath: firstPath.path, worktreeID: firstWorktree.id)
        _ = await router.codexActivityTracker.observe(
            transcriptPath: secondPath.path, worktreeID: secondWorktree.id)
        #expect(await router.codexActivityTracker.baselineCount == 2)

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

    // MARK: - The date seam on the handler that WRITES codex activity

    /// Pinned through the router's date seam, so each stored stamp is an exact
    /// assertion rather than a freshness window.
    static let observedAt = Date(timeIntervalSince1970: 1_781_234_567)

    /// A second router over the same database, with its `now` pinned.
    ///
    private func makeTranscript(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("session.jsonl")
        try contents.write(to: path, atomically: true, encoding: .utf8)
        return path
    }

    /// `setActivityState` defaults `observedAt` to a bare `Date()` **at the
    /// store**, so a handler that omits the argument mints a timestamp nothing
    /// outside the store can name. That is not a cosmetic difference: the stamp
    /// is *compared* — hibernation ages the at-rest clock by it, and an ordered
    /// write refuses an observation older than it — so per the root
    /// `CLAUDE.md` date-seam rule it is data, and it belongs on the router's
    /// seam like every sibling call site in this file.
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
