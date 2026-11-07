import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// The router's conformance to `PhoneSessionActions`, the phone bridge's one
/// door into the RPC layer. Every call goes through the protocol, as the
/// bridge makes it, so each test proves the conformance reaches the core it
/// names with the phone's identity and nothing else.
///
/// Tier 2: in-memory GRDB, a dry-run tmux and a real actuation log under the
/// run's fenced scratch dir.
@Suite("RPCRouter PhoneSessionActions")
struct RPCRouterPhoneSessionActionsTests {

    private struct Fixture {
        let db: TBDDatabase
        let router: RPCRouter
        let logPath: String

        var actions: any PhoneSessionActions { router }

        func actuationRows() -> [ActuationRow] {
            ActuationRecordReader(activePath: logPath).readRows()
        }
    }

    /// The router fixture of `RPCRouterRemoteAnswerTests`, with no remote
    /// manager. The router records no app identity, so the socket check that
    /// guards `prompt.answer` refuses every caller that reaches it.
    private func makeFixture() throws -> Fixture {
        let directory = URL(
            fileURLWithPath: fencedScratchRoot(prefix: "tbd-phone-actions"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logPath = directory.appendingPathComponent("actuations.jsonl").path
        let db = try TBDDatabase(inMemory: true)
        let subs = StateSubscriptionManager()
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver(),
                subscriptions: subs),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            subscriptions: subs,
            actuationLog: ActuationLog(path: logPath))
        return Fixture(db: db, router: router, logPath: logPath)
    }

    private func makeWorktree(_ f: Fixture, name: String) async throws -> Worktree {
        let repo = try await f.db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        return try await f.db.worktrees.create(
            repoID: repo.id, name: name, branch: "main",
            path: FileManager.default.temporaryDirectory.path, tmuxServer: "tbd-acme")
    }

    // MARK: - Handler-backed methods carry the phone actor

    @Test func phoneWakeRecordsThePhoneActor() async throws {
        let f = try makeFixture()
        let worktree = try await makeWorktree(f, name: "acme-wt")
        let terminal = try await f.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude)
        let d = UUID()

        _ = try await f.actions.phoneWake(TerminalWakeParams(terminalID: terminal.id), deviceID: d)

        let request = try #require(f.actuationRows().first { $0.method == RPCMethod.terminalWake })
        #expect(request.actor.kind == ActuationActor.Kind.phone)
        #expect(request.actor.device == d.uuidString, "the record names the phone's pairing")
        #expect(request.target?.terminal == terminal.id.uuidString)
    }

    /// Every worktree is asked about, and a plain shell is never reported on.
    @Test func phoneSessionStatesListsAgentTerminalsOnly() async throws {
        let f = try makeFixture()
        let first = try await makeWorktree(f, name: "acme-one")
        let second = try await makeWorktree(f, name: "acme-two")
        let shell = try await f.db.terminals.create(
            worktreeID: first.id, tmuxWindowID: "@0", tmuxPaneID: "%0", kind: .shell)
        let claude = try await f.db.terminals.create(
            worktreeID: first.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude)
        let codex = try await f.db.terminals.create(
            worktreeID: second.id, tmuxWindowID: "@2", tmuxPaneID: "%2", kind: .codex)

        let response = try await f.actions.phoneSessionStates()

        #expect(response.success, "error: \(response.error ?? "none")")
        let reports = try response.decodeResult(SessionStatesResult.self).reports
        let reported = Set(reports.map(\.terminalID))
        #expect(reported == [claude.id, codex.id])
        #expect(!reported.contains(shell.id), "a shell terminal is never reported on")
    }

    // MARK: - The answer core runs under the phone's pairing

    /// The socket check refuses every caller on this router, so an answer that
    /// reaches the terminal lookup took the paired-phone authority. The prompt's
    /// terminal does not exist, so the answer is `already_resolved`, and the
    /// record names the phone.
    @Test func phoneAnswerPromptSkipsTheSocketCheckAndRecordsThePhone() async throws {
        let f = try makeFixture()
        try await f.db.config.setTranscriptPromptAnswerEnabled(true)
        let d = UUID()
        let params = PromptAnswerParams(
            terminalID: UUID(), promptID: "p-1", answer: .permission(decision: .allow, message: nil))

        let response = try await f.actions.phoneAnswerPrompt(params, deviceID: d)

        #expect(response.error != RPCRouter.promptAnswerNotFromAppRefusal)
        #expect(response.success, "error: \(response.error ?? "none")")
        #expect(try response.decodeResult(PromptAnswerResult.self).outcome == .alreadyResolved)
        let request = try #require(f.actuationRows().first { $0.method == RPCMethod.promptAnswer })
        #expect(request.actor == ActuationActor.phone(deviceID: d))
    }

    // MARK: - The send rail

    /// The conformance reaches the paired-phone rail, which forces the gate on,
    /// so params that turn it off still cannot type into an open prompt.
    @Test func phoneSendIntoAnOpenPromptIsRefusedEvenWhenItsParamsTurnTheGateOff() async throws {
        let harness = try await SendHarness.make()
        _ = try await harness.db.terminals.setActivityState(
            id: harness.terminal.id,
            activityState: .waitingForUser,
            source: .programStatus,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            awaitingInputReason: AwaitingInputReason(
                message: "Allow Bash(rm -rf)?", hookEventName: "Notification",
                notificationType: "permission_prompt"))
        let actions: any PhoneSessionActions = harness.router

        let response = try await actions.phoneSend(
            TerminalSendParams(
                terminalID: harness.terminal.id, submit: true,
                parts: [.text("hi")], envelope: .suppressed, gateOnAwaitingInput: false),
            deviceID: UUID())

        #expect(!response.success)
        #expect(try #require(response.error).contains("Allow Bash(rm -rf)?"))
        #expect(harness.tmux.pastedBodies.isEmpty, "nothing may be typed")
    }
}
