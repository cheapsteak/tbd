import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import DaemonTestSupport
import TestSupport

// Nested under TBDHomeSerialized: the startup sweep prunes continuation packets
// under the runtime dir, which it resolves from `TBD_HOME` per call through a
// static member with no seam, so this suite must not run while a sibling suite
// has `TBD_HOME` pointed at a temp dir it is about to delete. See
// TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {
/// Continue in Claude. The replacement it made ran in a tmux window, and TBD
/// no longer starts processes on tmux, so `terminal.continueInClaude` refuses
/// every terminal and the startup sweep only reports a replacement an earlier
/// build left pending. What remains under test is each refusal, that the
/// sweep restores nothing, the packet-file pruning, and the store and
/// readiness primitives the transaction was built from.
@Suite("Continue in Claude transaction")
struct ContinueInClaudeTransactionTests {
    private final class CommandRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [[String]] = []

        func append(_ arguments: [String]) {
            lock.withLock { storage.append(arguments) }
        }

        var commands: [[String]] { lock.withLock { storage } }
    }

    // MARK: - The refusals

    @Test("a Codex tab on tmux is refused and left exactly as it was")
    func tmuxCodexTabIsRefused() async throws {
        let fixture = try await makeRPCFixture(kind: .codex, transport: .tmux)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let response = await continueRequest(fixture)

        #expect(!response.success)
        #expect(response.error == RPCRouter.tmuxContinueInClaudeRefusal(
            terminalID: fixture.terminal.id))
        #expect(try await fixture.db.terminals.get(id: fixture.terminal.id) == fixture.terminal)
        #expect(fixture.recorder.commands.isEmpty,
                "a refused continue drove tmux: \(fixture.recorder.commands)")
    }

    @Test("a Codex tab on the pty holder is refused and left exactly as it was")
    func holderCodexTabIsRefused() async throws {
        let fixture = try await makeRPCFixture(kind: .codex, transport: .holder)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let response = await continueRequest(fixture)

        #expect(!response.success)
        #expect(response.error == RPCRouter.holderContinueInClaudeRefusal(
            terminalID: fixture.terminal.id))
        #expect(try await fixture.db.terminals.get(id: fixture.terminal.id) == fixture.terminal)
        #expect(fixture.recorder.commands.isEmpty)
    }

    /// A tab that is not Codex keeps the wrong-provider code, which clients
    /// read to tell "nothing to continue" from a transport refusal.
    @Test("a tab that is not Codex is refused with the wrong-provider code")
    func nonCodexTabIsRefusedWithTheWrongProviderCode() async throws {
        let fixture = try await makeRPCFixture(kind: .claude, transport: .tmux)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let response = await continueRequest(fixture)

        #expect(!response.success)
        #expect(response.knownErrorCode == .terminalWrongProvider)
        #expect(try await fixture.db.terminals.get(id: fixture.terminal.id) == fixture.terminal)
        #expect(fixture.recorder.commands.isEmpty)
    }

    // MARK: - The startup sweep

    /// A replacement an earlier build left pending is reported, never acted
    /// on: restoring Codex meant relaunching a process in its tmux window.
    @Test("the startup sweep leaves a pending replacement exactly as it was")
    func startupSweepRestoresNothing() async throws {
        let fixture = try await makeRPCFixture(kind: .codex, transport: .tmux)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pending = try #require(try await fixture.db.terminals.beginContinueInClaude(
            id: fixture.terminal.id,
            expectedState: TerminalContinueInClaudeSnapshot(terminal: fixture.terminal),
            pendingIncarnationID: UUID()))

        await fixture.router.reconcilePendingContinueInClaude()

        #expect(try await fixture.db.terminals.get(id: fixture.terminal.id) == pending)
        #expect(try await fixture.db.terminals.listPendingCodexContinuations()
            .map(\.id) == [fixture.terminal.id])
        #expect(fixture.recorder.commands.isEmpty,
                "the sweep drove tmux: \(fixture.recorder.commands)")
    }

    @Test("stale continuation packets are pruned and fresh ones are kept")
    func stalePacketFilesArePruned() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("packet-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func packet(_ text: String) throws -> String {
            let url = directory.appendingPathComponent(
                ContinuationPacketFile.prefix + UUID().uuidString + ContinuationPacketFile.suffix)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
        let stalePath = try packet("old")
        let freshPath = try packet("new")
        let unrelated = directory.appendingPathComponent("unrelated.txt")
        try "keep".write(to: unrelated, atomically: true, encoding: .utf8)
        let now = Date()
        for path in [stalePath, unrelated.path] {
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-2 * ContinuationPacketFile.staleAge)],
                ofItemAtPath: path)
        }

        ContinuationPacketFile.pruneStale(directory: directory, now: now)

        #expect(!FileManager.default.fileExists(atPath: stalePath))
        #expect(FileManager.default.fileExists(atPath: freshPath))
        #expect(FileManager.default.fileExists(atPath: unrelated.path),
                "the sweep removed a stale file that is not a packet")
    }

    // MARK: - The primitives

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
        // A new incarnation, which has not reported its state yet.
        #expect(committed.activityState == .unknown)
        #expect(committed.activityStateSource == .derived)
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
        #expect(restored.activityState == .unknown)
        #expect(restored.activityStateSource == .derived)
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

    // MARK: - Fixtures

    private struct RPCFixture {
        let root: URL
        let db: TBDDatabase
        let router: RPCRouter
        let recorder: CommandRecorder
        let terminal: Terminal
    }

    private func makeRPCFixture(
        kind: TerminalKind, transport: TerminalTransport
    ) async throws -> RPCFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("continue-rpc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
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
        let recorder = CommandRecorder()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: recorder.append)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            sessionsDir: root.appendingPathComponent("sessions", isDirectory: true),
            actuationLog: makeTestActuationLog())
        let created = try await db.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: transport == .holder ? "" : "@source",
            tmuxPaneID: transport == .holder ? "" : "%source",
            label: kind == .codex ? TerminalLabel.codex : TerminalLabel.claudeCode,
            claudeSessionID: "source-thread",
            kind: kind,
            transport: transport)
        try await db.terminals.setActivityState(
            id: created.id,
            activityState: .idle,
            source: .hookEvent("task_complete"),
            observedAt: Date(timeIntervalSinceReferenceDate: 10))
        let terminal = try #require(try await db.terminals.get(id: created.id))
        return RPCFixture(
            root: root, db: db, router: router, recorder: recorder, terminal: terminal)
    }

    private func continueRequest(_ fixture: RPCFixture) async -> RPCResponse {
        await fixture.router.handle(try! RPCRequest(
            method: RPCMethod.terminalContinueInClaude,
            params: TerminalContinueInClaudeParams(
                sourceTerminalID: fixture.terminal.id)))
    }

    private struct StoreFixture {
        let root: URL
        let rollout: URL
        let db: TBDDatabase
        let terminal: Terminal
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
}
