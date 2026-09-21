import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

@Suite("Continue in Claude transaction")
struct ContinueInClaudeTransactionTests {
    private final class CommandRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [[String]] = []

        func append(_ arguments: [String]) {
            lock.withLock { storage.append(arguments) }
        }

        var commands: [[String]] { lock.withLock { storage } }

        var freshClaudeSessionID: String? {
            let command = commands.last { $0.contains("respawn-window") }?.last
            guard let command,
                  let suffix = command.components(separatedBy: "--session-id ").last,
                  suffix != command else { return nil }
            return suffix.split(separator: " ").first.map(String.init)
        }
    }

    private final class FailurePlan: @unchecked Sendable {
        enum Failure: Error { case injected }
        private let lock = NSLock()
        private var remaining: Int

        init(_ remaining: Int) { self.remaining = remaining }

        func next() -> Error? {
            lock.withLock {
                guard remaining > 0 else { return nil }
                if remaining != .max { remaining -= 1 }
                return Failure.injected
            }
        }
    }

    private final class DeltaRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [StateDelta] = []
        func append(_ delta: StateDelta) { lock.withLock { storage.append(delta) } }
        var deltas: [StateDelta] { lock.withLock { storage } }
    }

    @Test("readiness remembers an exact token and rejects mismatches")
    func readinessIsExactAndRemembered() async throws {
        let coordinator = ContinueInClaudeReadinessCoordinator()
        let terminalID = UUID()
        let token = UUID()
        let key = ContinueInClaudeReadinessCoordinator.Key(
            terminalID: terminalID, incarnationID: token)
        await coordinator.arm(key)

        let wrongAccepted = await coordinator.noteReady(
            ContinueInClaudeReadyEvent(
                sessionID: "wrong",
                transcriptPath: "/tmp/wrong.jsonl",
                source: "startup",
                cwd: "/tmp",
                observedAt: Date(timeIntervalSinceReferenceDate: 1)),
            for: .init(terminalID: terminalID, incarnationID: UUID()))
        #expect(!wrongAccepted)

        let event = ContinueInClaudeReadyEvent(
            sessionID: "ready",
            transcriptPath: "/tmp/ready.jsonl",
            source: "startup",
            cwd: "/tmp",
            observedAt: Date(timeIntervalSinceReferenceDate: 2))
        #expect(await coordinator.noteReady(event, for: key))
        #expect(try await coordinator.wait(for: key) == event)
    }

    @Test("staging preserves Codex identity and finalization commits Claude atomically")
    func storeStagesThenCommitsProvider() async throws {
        let fixture = try await makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.terminal
        let token = UUID()

        let staged = try #require(try await fixture.db.terminals.beginContinueInClaude(
            id: source.id,
            expectedState: TerminalContinueInClaudeSnapshot(terminal: source),
            pendingIncarnationID: token))
        #expect(staged.kind == .codex)
        #expect(staged.label == TerminalLabel.codex)
        #expect(staged.claudeSessionID == "codex-thread")
        #expect(staged.transcriptPath == fixture.rollout.path)
        #expect(staged.sessionIncarnationID == source.sessionIncarnationID)
        #expect(staged.pendingSessionIncarnationID == token)

        let profileID = UUID()
        let committed = try #require(try await fixture.db.terminals.finalizeContinueInClaude(
            id: source.id,
            expectedPendingIncarnationID: token,
            profileID: profileID,
            sessionID: "claude-session",
            transcriptPath: "/tmp/claude-session.jsonl",
            observedAt: Date(timeIntervalSinceReferenceDate: 50)))
        #expect(committed.id == source.id)
        #expect(committed.tmuxWindowID == source.tmuxWindowID)
        #expect(committed.tmuxPaneID == source.tmuxPaneID)
        #expect(committed.kind == .claude)
        #expect(committed.label == TerminalLabel.claudeCode)
        #expect(committed.profileID == profileID)
        #expect(committed.claudeSessionID == "claude-session")
        #expect(committed.transcriptPath == "/tmp/claude-session.jsonl")
        #expect(committed.sessionIncarnationID == token)
        #expect(committed.pendingSessionIncarnationID == nil)
        #expect(try await fixture.db.terminals.list(
            worktreeID: source.worktreeID).count == 1)
    }

    @Test("rollback rotates the token and never commits Claude identity")
    func storeRollbackRetainsCodexIdentity() async throws {
        let fixture = try await makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destinationToken = UUID()
        _ = try #require(try await fixture.db.terminals.beginContinueInClaude(
            id: fixture.terminal.id,
            expectedState: TerminalContinueInClaudeSnapshot(terminal: fixture.terminal),
            pendingIncarnationID: destinationToken))
        let recoveryToken = UUID()
        let recovery = try #require(
            try await fixture.db.terminals.rotateContinueInClaudeToCodexRecovery(
                id: fixture.terminal.id,
                expectedPendingIncarnationID: destinationToken,
                recoveryIncarnationID: recoveryToken))
        #expect(recovery.kind == .codex)
        #expect(recovery.claudeSessionID == "codex-thread")
        #expect(recovery.transcriptPath == fixture.rollout.path)
        #expect(recovery.pendingSessionIncarnationID == recoveryToken)

        let restored = try #require(
            try await fixture.db.terminals.finalizePendingCodexRecovery(
                id: fixture.terminal.id,
                expectedPendingIncarnationID: recoveryToken,
                sourceThreadID: "codex-thread",
                sourceRolloutPath: fixture.rollout.path,
                observedAt: Date(timeIntervalSinceReferenceDate: 60)))
        #expect(restored.kind == .codex)
        #expect(restored.label == TerminalLabel.codex)
        #expect(restored.claudeSessionID == "codex-thread")
        #expect(restored.transcriptPath == fixture.rollout.path)
        #expect(restored.sessionIncarnationID == recoveryToken)
        #expect(restored.pendingSessionIncarnationID == nil)
    }

    @Test("changed activity makes the continuation CAS refuse without mutation")
    func activityCASRefusesChangedTurn() async throws {
        let fixture = try await makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = TerminalContinueInClaudeSnapshot(terminal: fixture.terminal)
        try await fixture.db.terminals.setActivityState(
            id: fixture.terminal.id,
            activityState: .working,
            source: .hookEvent("task_started"),
            observedAt: Date(timeIntervalSinceReferenceDate: 20))
        let changed = try #require(
            try await fixture.db.terminals.get(id: fixture.terminal.id))

        let staged = try await fixture.db.terminals.beginContinueInClaude(
            id: fixture.terminal.id,
            expectedState: snapshot,
            pendingIncarnationID: UUID())

        #expect(staged == nil)
        #expect(try await fixture.db.terminals.get(id: fixture.terminal.id) == changed)
    }

    @Test("RPC success keeps one row and one window and commits only after readiness")
    func rpcSuccessReplacesInPlace() async throws {
        let fixture = try await makeRPCFixture(ownsPane: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let request = try RPCRequest(
            method: RPCMethod.terminalContinueInClaude,
            params: TerminalContinueInClaudeParams(
                sourceTerminalID: fixture.terminal.id))
        let responseTask = Task { await fixture.router.handle(request) }
        let pending = try await waitForPending(
            terminalID: fixture.terminal.id, in: fixture.db)
        let freshSessionID = try #require(await waitForFreshClaudeSessionID(
            in: fixture.recorder))
        #expect(try await fixture.db.terminals.get(id: fixture.terminal.id)?.kind == .codex)

        let hook = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: fixture.terminal.id,
                sessionID: freshSessionID,
                transcriptPath: fixture.root.appendingPathComponent("claude.jsonl").path,
                source: "startup",
                cwd: fixture.root.path,
                sessionIncarnationID: pending))
        #expect((await fixture.router.handle(hook)).success)

        let response = await responseTask.value
        #expect(response.success)
        let updated = try response.decodeResult(Terminal.self)
        #expect(updated.id == fixture.terminal.id)
        #expect(updated.tmuxWindowID == fixture.terminal.tmuxWindowID)
        #expect(updated.tmuxPaneID == fixture.terminal.tmuxPaneID)
        #expect(updated.kind == .claude)
        #expect(updated.sessionIncarnationID == pending)
        #expect(updated.pendingSessionIncarnationID == nil)
        #expect(try await fixture.db.terminals.list(
            worktreeID: fixture.terminal.worktreeID).count == 1)
        #expect(fixture.recorder.commands.filter { $0.contains("respawn-window") }.count == 1)
        #expect(!fixture.recorder.commands.contains { $0.contains("send-keys") })
        let replacement = fixture.deltas.deltas.compactMap { delta -> Terminal? in
            guard case .terminalReplaced(let terminal) = delta else { return nil }
            return terminal
        }.last
        #expect(replacement == updated)
    }

    @Test("strict pane ownership refusal clears the fence without respawning")
    func rpcOwnershipFenceLeavesCodexUntouched() async throws {
        let fixture = try await makeRPCFixture(ownsPane: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = fixture.terminal

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalContinueInClaude,
            params: TerminalContinueInClaudeParams(
                sourceTerminalID: fixture.terminal.id)))

        #expect(!response.success)
        #expect(response.errorCode == RPCErrorCode.terminalSessionGone.rawValue)
        let after = try #require(try await fixture.db.terminals.get(id: before.id))
        #expect(after.kind == .codex)
        #expect(after.claudeSessionID == before.claudeSessionID)
        #expect(after.transcriptPath == before.transcriptPath)
        #expect(after.sessionIncarnationID == before.sessionIncarnationID)
        #expect(after.pendingSessionIncarnationID == nil)
        #expect(!fixture.recorder.commands.contains { $0.contains("respawn-window") })
    }

    @Test("an unreadable ownership probe retracts the staged fence")
    func rpcThrowingOwnershipProbeLeavesCodexUntouched() async throws {
        let fixture = try await makeRPCFixture(
            ownsPane: true, paneProbeThrows: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = fixture.terminal

        let response = await continueRequest(fixture)

        #expect(!response.success)
        let after = try #require(try await fixture.db.terminals.get(id: before.id))
        #expect(after.kind == .codex)
        #expect(after.sessionIncarnationID == before.sessionIncarnationID)
        #expect(after.pendingSessionIncarnationID == nil)
        #expect(!fixture.recorder.commands.contains { $0.contains("respawn-window") })
    }

    @Test("durable pending recovery always restores Codex")
    func startupRecoveryRestoresSourceIdentity() async throws {
        let fixture = try await makeRPCFixture(ownsPane: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let crashedDestinationToken = UUID()
        _ = try #require(try await fixture.db.terminals.beginContinueInClaude(
            id: fixture.terminal.id,
            expectedState: TerminalContinueInClaudeSnapshot(terminal: fixture.terminal),
            pendingIncarnationID: crashedDestinationToken))

        let recoveryTask = Task {
            await fixture.router.reconcilePendingContinueInClaude()
        }
        let recoveryToken = try await waitForPending(
            terminalID: fixture.terminal.id,
            differentFrom: crashedDestinationToken,
            in: fixture.db)
        let hook = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: fixture.terminal.id,
                sessionID: "codex-thread",
                transcriptPath: fixture.rollout.path,
                source: "startup",
                cwd: fixture.root.path,
                sessionIncarnationID: recoveryToken))
        #expect((await fixture.router.handle(hook)).success)
        await recoveryTask.value

        let restored = try #require(
            try await fixture.db.terminals.get(id: fixture.terminal.id))
        #expect(restored.kind == .codex)
        #expect(restored.claudeSessionID == "codex-thread")
        #expect(restored.transcriptPath == fixture.rollout.path)
        #expect(restored.sessionIncarnationID == recoveryToken)
        #expect(restored.pendingSessionIncarnationID == nil)
        #expect(try await fixture.db.terminals.list(
            worktreeID: fixture.terminal.worktreeID).count == 1)
    }

    @Test("recovery adopts a live exact-stamped pane in its actual window")
    func recoveryAdoptsExactStampedPaneWindow() async throws {
        let fixture = try await makeRPCFixture(
            ownsPane: true, paneWindowID: "@actual")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let crashedDestinationToken = UUID()
        _ = try #require(try await fixture.db.terminals.beginContinueInClaude(
            id: fixture.terminal.id,
            expectedState: TerminalContinueInClaudeSnapshot(terminal: fixture.terminal),
            pendingIncarnationID: crashedDestinationToken))

        let recoveryTask = Task {
            await fixture.router.reconcilePendingContinueInClaude()
        }
        let recoveryToken = try await waitForPending(
            terminalID: fixture.terminal.id,
            differentFrom: crashedDestinationToken,
            in: fixture.db)
        try await waitForRespawnCount(1, in: fixture.recorder)
        #expect((await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: fixture.terminal.id,
                sessionID: "codex-thread",
                transcriptPath: fixture.rollout.path,
                source: "startup",
                cwd: fixture.root.path,
                sessionIncarnationID: recoveryToken)))).success)
        await recoveryTask.value

        let restored = try #require(
            try await fixture.db.terminals.get(id: fixture.terminal.id))
        #expect(restored.tmuxWindowID == "@actual")
        #expect(restored.tmuxPaneID == "%source")
        #expect(restored.pendingSessionIncarnationID == nil)
        #expect(!fixture.recorder.commands.contains { $0.contains("new-window") })
        #expect(fixture.recorder.commands.contains {
            $0.contains("respawn-window") && $0.contains("@actual")
        })
    }

    @Test("recovery refuses a live pane whose identity is unavailable")
    func recoveryFailsClosedForUnstampedLivePane() async throws {
        let fixture = try await makeRPCFixture(ownsPane: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let crashedDestinationToken = UUID()
        _ = try #require(try await fixture.db.terminals.beginContinueInClaude(
            id: fixture.terminal.id,
            expectedState: TerminalContinueInClaudeSnapshot(terminal: fixture.terminal),
            pendingIncarnationID: crashedDestinationToken))

        await fixture.router.reconcilePendingContinueInClaude()

        let pending = try #require(
            try await fixture.db.terminals.get(id: fixture.terminal.id))
        #expect(pending.kind == .codex)
        #expect(pending.pendingSessionIncarnationID != nil)
        #expect(pending.pendingSessionIncarnationID != crashedDestinationToken)
        #expect(!fixture.recorder.commands.contains { $0.contains("new-window") })
        #expect(!fixture.recorder.commands.contains { $0.contains("respawn-window") })
    }

    @Test("authoritative rollout activity overrides a stale persisted idle fact")
    func authoritativeWorkingRolloutRefusesContinue() async throws {
        let fixture = try await makeRPCFixture(ownsPane: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let started = """
            {"type":"event_msg","payload":{"type":"task_started","turn_id":"live-turn","started_at":20}}
            """
        try append(started + "\n", to: fixture.rollout)

        let response = await continueRequest(fixture)

        #expect(response.errorCode == RPCErrorCode.terminalBusy.rawValue)
        let after = try #require(
            try await fixture.db.terminals.get(id: fixture.terminal.id))
        #expect(after.observedActivity?.value == .idle)
        #expect(after.pendingSessionIncarnationID == nil)
        #expect(!fixture.recorder.commands.contains { $0.contains("respawn-window") })
    }

    @Test("authoritative rollout inspection fails closed while bounded scan is behind")
    func authoritativeBehindRolloutRefusesContinue() async throws {
        let fixture = try await makeRPCFixture(ownsPane: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bulkyRecord = "{\"type\":\"response_item\",\"padding\":\""
            + String(repeating: "x", count: 1_100_000) + "\"}\n"
        try append(bulkyRecord, to: fixture.rollout)

        let response = await continueRequest(fixture)

        #expect(response.errorCode == RPCErrorCode.terminalBusy.rawValue)
        #expect(try await fixture.db.terminals.get(id: fixture.terminal.id)?
            .pendingSessionIncarnationID == nil)
        #expect(!fixture.recorder.commands.contains { $0.contains("respawn-window") })
    }

    @Test("busy, wrong-provider, unreadable-rollout, and missing-profile preflight do not respawn")
    func preflightRefusalsLeaveSourceUntouched() async throws {
        do {
            let fixture = try await makeRPCFixture(ownsPane: true)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try await fixture.db.terminals.setActivityState(
                id: fixture.terminal.id,
                activityState: .working,
                source: .hookEvent("task_started"),
                observedAt: Date(timeIntervalSinceReferenceDate: 30))
            let before = try #require(
                try await fixture.db.terminals.get(id: fixture.terminal.id))
            let response = await continueRequest(fixture)
            #expect(response.errorCode == RPCErrorCode.terminalBusy.rawValue)
            #expect(try await fixture.db.terminals.get(id: before.id) == before)
            #expect(!fixture.recorder.commands.contains { $0.contains("respawn-window") })
        }
        do {
            let fixture = try await makeRPCFixture(ownsPane: true)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let shell = try await fixture.db.terminals.create(
                worktreeID: fixture.terminal.worktreeID,
                tmuxWindowID: "@shell",
                tmuxPaneID: "%shell",
                label: TerminalLabel.shell,
                kind: .shell)
            let response = await fixture.router.handle(try RPCRequest(
                method: RPCMethod.terminalContinueInClaude,
                params: TerminalContinueInClaudeParams(sourceTerminalID: shell.id)))
            #expect(response.errorCode == RPCErrorCode.terminalWrongProvider.rawValue)
            #expect(try await fixture.db.terminals.get(id: shell.id) == shell)
        }
        do {
            let fixture = try await makeRPCFixture(ownsPane: true)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try FileManager.default.removeItem(at: fixture.rollout)
            let before = try #require(
                try await fixture.db.terminals.get(id: fixture.terminal.id))
            let response = await continueRequest(fixture)
            #expect(!response.success)
            #expect(try await fixture.db.terminals.get(id: before.id) == before)
        }
        do {
            let fixture = try await makeRPCFixture(ownsPane: true)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let before = try #require(
                try await fixture.db.terminals.get(id: fixture.terminal.id))
            let response = await fixture.router.handle(try RPCRequest(
                method: RPCMethod.terminalContinueInClaude,
                params: TerminalContinueInClaudeParams(
                    sourceTerminalID: fixture.terminal.id,
                    profileID: UUID())))
            #expect(response.errorCode == RPCErrorCode.profileMissing.rawValue)
            #expect(try await fixture.db.terminals.get(id: before.id) == before)
        }
    }

    @Test("destination launch failure restores Codex under a rotated token")
    func destinationLaunchFailureRollsBack() async throws {
        let fixture = try await makeRPCFixture(
            ownsPane: true, respawnFailures: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let responseTask = Task { await continueRequest(fixture) }
        try await waitForRespawnCount(2, in: fixture.recorder)
        let recoveryToken = try await waitForPending(
            terminalID: fixture.terminal.id,
            in: fixture.db)
        #expect((await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: fixture.terminal.id,
                sessionID: "codex-thread",
                transcriptPath: fixture.rollout.path,
                source: "startup",
                cwd: fixture.root.path,
                sessionIncarnationID: recoveryToken)))).success)

        let response = await responseTask.value
        #expect(!response.success)
        let restored = try #require(
            try await fixture.db.terminals.get(id: fixture.terminal.id))
        #expect(restored.kind == .codex)
        #expect(restored.sessionIncarnationID == recoveryToken)
        #expect(restored.pendingSessionIncarnationID == nil)
        #expect(restored.claudeSessionID == "codex-thread")
        #expect(restored.transcriptPath == fixture.rollout.path)
    }

    @Test("destination timeout rolls back and a delayed target hook stays stale")
    func destinationTimeoutRollsBackAndRejectsDelayedHook() async throws {
        let fixture = try await makeRPCFixture(ownsPane: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.router.continueInClaudeReadinessTimeout = .seconds(1)
        let responseTask = Task { await continueRequest(fixture) }
        let destinationToken = try await waitForPending(
            terminalID: fixture.terminal.id, in: fixture.db)
        let recoveryToken = try await waitForPending(
            terminalID: fixture.terminal.id,
            differentFrom: destinationToken,
            in: fixture.db,
            iterations: 100_000)
        try await waitForRespawnCount(2, in: fixture.recorder)
        #expect((await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: fixture.terminal.id,
                sessionID: "codex-thread",
                transcriptPath: fixture.rollout.path,
                source: "startup",
                cwd: fixture.root.path,
                sessionIncarnationID: recoveryToken)))).success)
        #expect(!(await responseTask.value).success)
        let restored = try #require(
            try await fixture.db.terminals.get(id: fixture.terminal.id))

        let delayed = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: fixture.terminal.id,
                sessionID: "delayed-claude",
                transcriptPath: fixture.root.appendingPathComponent("delayed.jsonl").path,
                source: "startup",
                cwd: fixture.root.path,
                sessionIncarnationID: destinationToken))
        #expect((await fixture.router.handle(delayed)).success)
        #expect(try await fixture.db.terminals.get(id: fixture.terminal.id) == restored)
    }

    @Test("failed rollback leaves a durable Codex recovery candidate")
    func failedRollbackRemainsPending() async throws {
        let fixture = try await makeRPCFixture(
            ownsPane: true, respawnFailures: .max)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let response = await continueRequest(fixture)
        #expect(!response.success)
        let pending = try #require(
            try await fixture.db.terminals.get(id: fixture.terminal.id))
        #expect(pending.kind == .codex)
        #expect(pending.pendingSessionIncarnationID != nil)
        #expect(pending.claudeSessionID == "codex-thread")
        #expect(pending.transcriptPath == fixture.rollout.path)
        #expect(try await fixture.db.terminals.listPendingCodexContinuations()
            .map(\.id) == [fixture.terminal.id])
    }

    private struct StoreFixture {
        let root: URL
        let rollout: URL
        let db: TBDDatabase
        let terminal: Terminal
    }

    private struct RPCFixture {
        let root: URL
        let rollout: URL
        let db: TBDDatabase
        let router: RPCRouter
        let recorder: CommandRecorder
        let deltas: DeltaRecorder
        let terminal: Terminal
    }

    private func makeRPCFixture(
        ownsPane: Bool,
        respawnFailures: Int = 0,
        paneWindowID: String = "@source",
        paneProbeThrows: Bool = false
    ) async throws -> RPCFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("continue-rpc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        try run("/usr/bin/git", ["init", root.path])
        let rollout = root.appendingPathComponent("rollout.jsonl")
        let sessionMeta = """
            {"type":"session_meta","payload":{"id":"codex-thread","cwd":\(json(root.path))}}
            """
        let userMessage = """
            {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Continue the task."}]}}
            """
        let lifecycleClose = """
            {"type":"event_msg","payload":{"type":"task_complete","turn_id":"ready-turn","started_at":1,"last_agent_message":"Ready."}}
            """
        try (sessionMeta + "\n" + userMessage + "\n" + lifecycleClose + "\n").write(
            to: rollout, atomically: true, encoding: .utf8)

        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: root.path,
            displayName: "Sample",
            defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id,
            name: "sample",
            branch: "feature/sample",
            path: root.path,
            tmuxServer: "continue-rpc")
        let terminalID = UUID()
        let recorder = CommandRecorder()
        let failurePlan = FailurePlan(respawnFailures)
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: recorder.append,
            dryRunRespawnWindowError: { _ in failurePlan.next() },
            dryRunPaneSendTarget: { _, _ in
                if paneProbeThrows { throw FailurePlan.Failure.injected }
                return .live(terminalID: ownsPane ? terminalID.uuidString : nil)
            },
            dryRunPaneWindowID: { _, _ in paneWindowID })
        let subscriptions = StateSubscriptionManager()
        let deltas = DeltaRecorder()
        subscriptions.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            subscriptions: subscriptions,
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())
        router.codexExecutableResolver = { "/opt/test/bin/codex" }
        router.codexHomeEnsurer = {
            root.appendingPathComponent("codex-home", isDirectory: true)
        }
        router.codexProfileFlagResolver = { (_: String) -> String in "--profile" }
        let created = try await db.terminals.create(
            id: terminalID,
            worktreeID: worktree.id,
            tmuxWindowID: "@source",
            tmuxPaneID: "%source",
            label: TerminalLabel.codex,
            kind: .codex)
        _ = try #require(try await db.terminals.applySessionStart(
            id: created.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: created),
            sessionID: "codex-thread",
            transcriptPath: rollout.path,
            observedAt: Date(timeIntervalSinceReferenceDate: 5)))
        try await db.terminals.setActivityState(
            id: created.id,
            activityState: .idle,
            source: .hookEvent("task_complete"),
            observedAt: Date(timeIntervalSinceReferenceDate: 10))
        let terminal = try #require(try await db.terminals.get(id: created.id))
        return RPCFixture(
            root: root,
            rollout: rollout,
            db: db,
            router: router,
            recorder: recorder,
            deltas: deltas,
            terminal: terminal)
    }

    private func continueRequest(_ fixture: RPCFixture) async -> RPCResponse {
        await fixture.router.handle(try! RPCRequest(
            method: RPCMethod.terminalContinueInClaude,
            params: TerminalContinueInClaudeParams(
                sourceTerminalID: fixture.terminal.id)))
    }

    private func waitForPending(
        terminalID: UUID,
        differentFrom oldToken: UUID? = nil,
        in db: TBDDatabase,
        iterations: Int = 100_000
    ) async throws -> UUID {
        for _ in 0..<iterations {
            if let token = try await db.terminals.get(id: terminalID)?
                .pendingSessionIncarnationID,
               token != oldToken {
                return token
            }
            await Task.yield()
        }
        Issue.record("replacement never persisted a pending incarnation")
        throw CancellationError()
    }

    private func waitForRespawnCount(
        _ count: Int,
        in recorder: CommandRecorder
    ) async throws {
        for _ in 0..<5_000 {
            if recorder.commands.filter({ $0.contains("respawn-window") }).count >= count {
                return
            }
            await Task.yield()
        }
        Issue.record("replacement never reached respawn count \(count)")
        throw CancellationError()
    }

    private func waitForFreshClaudeSessionID(
        in recorder: CommandRecorder
    ) async -> String? {
        for _ in 0..<2_000 {
            if let sessionID = recorder.freshClaudeSessionID { return sessionID }
            await Task.yield()
        }
        return nil
    }

    private func json(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableRuntimeMismatch)
        }
    }

    private func append(_ value: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(value.utf8))
    }

    private func isolatedConfigDirManager() -> ClaudeProfileConfigDirManager {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "continue-in-claude-profile-\(UUID().uuidString)",
                isDirectory: true)
        return ClaudeProfileConfigDirManager(
            baseDirectory: home.appendingPathComponent(
                "profiles", isDirectory: true),
            hostBaseDirectory: home.appendingPathComponent(
                "claude-host", isDirectory: true))
    }

    private func makeStoreFixture() async throws -> StoreFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("continue-transaction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let rollout = root.appendingPathComponent("rollout.jsonl")
        try "{}\n".write(to: rollout, atomically: true, encoding: .utf8)
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: root.path,
            displayName: "Sample",
            defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id,
            name: "sample",
            branch: "feature/sample",
            path: root.path,
            tmuxServer: "continue-transaction")
        let created = try await db.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: TerminalLabel.codex,
            claudeSessionID: "codex-thread",
            kind: .codex)
        try await db.terminals.updateSession(
            id: created.id,
            sessionID: "codex-thread",
            transcriptPath: rollout.path)
        try await db.terminals.setActivityState(
            id: created.id,
            activityState: .idle,
            source: .hookEvent("task_complete"),
            observedAt: Date(timeIntervalSinceReferenceDate: 10))
        let terminal = try #require(try await db.terminals.get(id: created.id))
        return StoreFixture(root: root, rollout: rollout, db: db, terminal: terminal)
    }
}
